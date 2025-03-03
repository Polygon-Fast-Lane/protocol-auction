// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { ArbitrageTest } from "./base/ArbitrageTest.t.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";
import { DAppControl } from "../src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "../src/contracts/types/ConfigTypes.sol";
import { SolverOutcome } from "../src/contracts/types/EscrowTypes.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import "../src/contracts/types/DAppOperation.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";
import { IAtlas } from "../src/contracts/interfaces/IAtlas.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./base/builders/DAppOperationBuilder.sol";

interface IWETH {
    function withdraw(uint256 wad) external;
}

struct Balances{
    uint256 eth;
    uint256 atlETH;
    uint256 bonded;
}

contract FlashLoanTest is BaseTest {
    DummyDAppControlBuilder public control;

    Sig public sig;
    Balances public userBefore;
    Balances public userAfter;

    function setUp() public virtual override {
        BaseTest.setUp();

        // Deploy
        vm.startPrank(governanceEOA);

        control = new DummyDAppControlBuilder(address(atlas), WETH_ADDRESS);
        atlasVerification.initializeGovernance(address(control));
        vm.stopPrank();
    }

    function testFlashLoan_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        SimpleSolver solver = new SimpleSolver(WETH_ADDRESS, address(atlas));
        deal(WETH_ADDRESS, address(solver), 1e18); // 1 WETH to solver to pay bid
        atlas.bond(1 ether); // gas for solver to pay
        vm.stopPrank();

        vm.startPrank(userEOA);
        deal(userEOA, 100e18); // eth to solver for atleth deposit
        atlas.deposit{ value: 100e18 }();
        vm.stopPrank();

        // Input params for Atlas.metacall() - will be populated below

        UserOperation memory userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification))
            .withDapp(address(control))
            .withControl(address(control))
            .withCallConfig(control.CALL_CONFIG())
            .withDeadline(block.number + 2)
            .withData(new bytes(0))
            .build();

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.noPayback.selector))
            .withValue(10e18)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        // Solver signs the solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates dAppOp calldata after seeing rest of data
        DAppOperation memory dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();

        // Frontend signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // make the actual atlas call that should revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        uint256 result = (1 << uint256(SolverOutcome.BidNotPaid));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            userOp.control,
            solverOps[0].bidToken,
            solverOps[0].bidAmount,
            true,
            false,
            result
        );
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });
        vm.stopPrank();

        // now try it again with a valid solverOp - but dont fully pay back
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.onlyPayBid.selector, 1e18))
            .withValue(address(atlas).balance + 1)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Call again with partial payback, should still revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        result = (1 << uint256(SolverOutcome.CallValueTooHigh));
        console.log("result", result);
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            userOp.control,
            solverOps[0].bidToken,
            solverOps[0].bidAmount,
            false,
            false,
            result
        );
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });
        vm.stopPrank();

        // final try, should be successful with full payback
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.payback.selector, 1e18))
            .withValue(10e18)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(control))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        uint256 solverStartingTotal = WETH.balanceOf(address(solver));
        uint256 atlasStartingETH = address(atlas).balance;

        userBefore.eth = address(userEOA).balance;
        userBefore.atlETH = atlas.balanceOf(userEOA);
        userBefore.bonded = atlas.balanceOfBonded(userEOA);

        assertEq(solverStartingTotal, 1e18, "solver incorrect starting WETH");
        solverStartingTotal += (atlas.balanceOf(solverOneEOA) + atlas.balanceOfBonded(solverOneEOA));

        assertEq(atlasStartingETH, 104e18, "atlas incorrect starting ETH"); // 4e from solvers + 100e user deposit

        uint256 netSurcharge = atlas.cumulativeSurcharge();

        // Last call - should succeed
        vm.startPrank(userEOA);
        result = 0;
        vm.expectEmit(true, true, true, true);
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            userOp.control,
            solverOps[0].bidToken,
            solverOps[0].bidAmount,
            true,
            true,
            result
        );
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });
        vm.stopPrank();

        // atlas 2e beginning bal + 1e from solver +100e eth from user = 103e atlas total
        // after metacall 1e user payout + 0.0001e bundler(user) gas refund = 101.9999e after metacall

        {
            console.log("solverStartingTotal:  ", solverStartingTotal);
            console.log("solverEndingTotal  :  ", WETH.balanceOf(address(solver)) + atlas.balanceOf(solverOneEOA) + atlas.balanceOfBonded(solverOneEOA));
            solverStartingTotal -= (WETH.balanceOf(address(solver)) + atlas.balanceOf(solverOneEOA) + atlas.balanceOfBonded(solverOneEOA));
            console.log("solverDeltaTotal   :  ", solverStartingTotal);
        }

        userAfter.eth = address(userEOA).balance;
        userAfter.atlETH = atlas.balanceOf(userEOA);
        userAfter.bonded = atlas.balanceOfBonded(userEOA);

        {
            console.log("userStartingTotal  :", userBefore.eth + userBefore.atlETH + userBefore.bonded);
            console.log("userEndingTotal    :", userAfter.eth + userAfter.atlETH + userAfter.bonded);

            console.log("atlasStartingETH   :", atlasStartingETH);
            console.log("atlasEndingETH     :", address(atlas).balance);
        }

        netSurcharge = atlas.cumulativeSurcharge() - netSurcharge;
        console.log("NetCumulativeSrchrg:       ", netSurcharge);

        assertEq(WETH.balanceOf(address(solver)), 0, "solver WETH not used");
        assertEq(atlas.balanceOf(solverOneEOA), 0, "solver atlETH not used");
        console.log("atlasStartingETH   :", atlasStartingETH);
        console.log("atlasEnding  ETH   :", address(atlas).balance);

        // NOTE: solverStartingTotal is the solverTotal delta, not starting.
        assertTrue(address(atlas).balance >= atlasStartingETH - solverStartingTotal, "atlas incorrect ending ETH"); // atlas should NEVER lose balance during a metacall

        console.log("userStartingETH    :", userBefore.eth);
        console.log("userEndingETH      :", userAfter.eth);
        assertTrue((userAfter.eth - userBefore.eth) >= 1 ether, "user incorrect ending ETH"); // user bal should increase by 1e (bid) + gas refund
        assertTrue((userAfter.bonded - userBefore.bonded) == 0, "user incorrect ending bonded AtlETH"); // user bonded bal should increase by gas refund
    }
}

contract DummyDAppControlBuilder is DAppControl {
    address immutable weth;

    constructor(
        address _atlas,
        address _weth
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: false,
                trackPreOpsReturnData: false,
                trackUserReturnData: false,
                delegateUser: true,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: true,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false,
                multipleSuccessfulSolvers: false
            })
        )
    {
        weth = _weth;
    }

    function _allocateValueCall(address bidToken, uint256, bytes calldata) internal override {
        if (bidToken != address(0)) {
            revert("not supported");
        }

        SafeTransferLib.safeTransferETH(_user(), address(this).balance);
    }

    function getBidFormat(UserOperation calldata) public pure override returns (address bidToken) {
        bidToken = address(0);
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    fallback() external { }
}

contract SimpleSolver {
    address weth;
    address environment;
    address atlas;

    constructor(address _weth, address _atlas) {
        weth = _weth;
        atlas = _atlas;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address,
        uint256,
        bytes calldata solverOpData,
        bytes calldata
    )
        external
        payable
        returns (bool success, bytes memory data)
    {
        environment = executionEnvironment;
        (success, data) = address(this).call{ value: msg.value }(solverOpData);

        if (bytes4(solverOpData[:4]) == SimpleSolver.payback.selector) {
            uint256 shortfall = IAtlas(atlas).shortfall();

            if (shortfall < msg.value) shortfall = 0;
            else shortfall -= msg.value;

            IAtlas(atlas).reconcile{ value: msg.value }(shortfall);
        }
    }

    function noPayback() external payable {
        payable(address(0)).transfer(msg.value); // do something with the eth and dont pay it back
    }

    function onlyPayBid(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(environment).transfer(bidAmount); // pay back to atlas
        payable(address(0)).transfer(msg.value); // do something with the remaining eth
    }

    function payback(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(environment).transfer(bidAmount); // pay back to atlas
    }

    receive() external payable { }
}
