// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";
import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { DAppConfig } from "../src/contracts/types/ConfigTypes.sol";
import { SwapIntent, SwapIntentInvertBidDAppControl } from "../src/contracts/examples/intents-example/SwapIntentInvertBidDAppControl.sol";
import { SolverBaseInvertBid } from "../src/contracts/solver/SolverBaseInvertBid.sol";
import { DAppControl } from "../src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/LockTypes.sol";
import "../src/contracts/types/DAppOperation.sol";

contract SwapIntentTest is BaseTest {
    Sig public sig;

    function setUp() public virtual override {
        BaseTest.setUp();

        deal(WETH_ADDRESS, userEOA, 10e18);
    }

    function testAtlasSwapIntentInvertBid_solverBidRetreivalNotRequired_SkipCoverage() public {
        vm.startPrank(governanceEOA);
        SwapIntentInvertBidDAppControl controlContract = new SwapIntentInvertBidDAppControl(address(atlas), false);
        address control = address(controlContract);
        atlasVerification.initializeGovernance(control);
        vm.stopPrank();

        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;
        uint256 solverBidAmount = 1e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent, false);
        address executionEnvironment = createExecutionEnvironment(control);
        UserOperation memory userOp = buildUserOperation(control, swapIntent);
        SolverOperation memory solverOp = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmount);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;
        DAppOperation memory dAppOp = buildDAppOperation(control, userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmount, "Did not spend WETH == solverBidAmount");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function testAtlasSwapIntentInvertBid_solverBidRetreivalNotRequired_multipleSolvers_SkipCoverage() public {
        vm.startPrank(governanceEOA);
        SwapIntentInvertBidDAppControl controlContract = new SwapIntentInvertBidDAppControl(address(atlas), false);
        address control = address(controlContract);
        atlasVerification.initializeGovernance(control);
        vm.stopPrank();

        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;

        uint256 solverBidAmountOne = 1e18;
        uint256 solverBidAmountTwo = 2e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent, false);
        address executionEnvironment = createExecutionEnvironment(control);
        UserOperation memory userOp = buildUserOperation(control, swapIntent);
        SolverOperation memory solverOpOne = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmountOne);
        SolverOperation memory solverOpTwo = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmountTwo);
        
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = solverOpOne;
        solverOps[1] = solverOpTwo;
        DAppOperation memory dAppOp = buildDAppOperation(control, userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmountOne, "Did not spend WETH == solverBidAmountOne");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function testAtlasSwapIntentInvertBid_solverBidRetreivalRequired_SkipCoverage() public {
        vm.startPrank(governanceEOA);
        SwapIntentInvertBidDAppControl controlContract = new SwapIntentInvertBidDAppControl(address(atlas), true);
        address control = address(controlContract);
        atlasVerification.initializeGovernance(control);
        vm.stopPrank();

        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;
        uint256 solverBidAmount = 1e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent, true);
        address executionEnvironment = createExecutionEnvironment(control);
        UserOperation memory userOp = buildUserOperation(control, swapIntent);
        SolverOperation memory solverOp = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmount);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;
        DAppOperation memory dAppOp = buildDAppOperation(control, userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmount, "Did not spend WETH == solverBidAmount");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function createSwapIntent(uint256 amountUserBuys, uint256 maxAmountUserSells) internal view returns (SwapIntent memory) {
        return SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: amountUserBuys,
            tokenUserSells: WETH_ADDRESS,
            maxAmountUserSells: maxAmountUserSells
        });
    }

    function deployAndFundRFQSolver(SwapIntent memory swapIntent, bool solverBidRetreivalRequired) internal returns (SimpleRFQSolverInvertBid) {
        vm.startPrank(solverOneEOA);
        SimpleRFQSolverInvertBid rfqSolver = new SimpleRFQSolverInvertBid(WETH_ADDRESS, address(atlas), solverBidRetreivalRequired);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1 ether);
        vm.stopPrank();

        deal(DAI_ADDRESS, address(rfqSolver), swapIntent.amountUserBuys);
        assertEq(DAI.balanceOf(address(rfqSolver)), swapIntent.amountUserBuys, "Did not give enough DAI to solver");

        return rfqSolver;
    }

    function createExecutionEnvironment(address control) internal returns (address){
        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, control);
        console.log("executionEnvironment", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        return executionEnvironment;
    }

    function buildUserOperation(address control, SwapIntent memory swapIntent) internal returns (UserOperation memory) {
        UserOperation memory userOp;

        bytes memory userOpData = abi.encodeCall(SwapIntentInvertBidDAppControl.swap, swapIntent);

        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: txBuilder.control(),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: userOpData
        });
        userOp.sessionKey = governanceEOA;

        return userOp;
    }

    function buildSolverOperation(address control, UserOperation memory userOp, SwapIntent memory swapIntent, address executionEnvironment,
        address solverAddress, uint256 solverBidAmount) internal returns (SolverOperation memory) {
        bytes memory solverOpData =
            abi.encodeCall(SimpleRFQSolverInvertBid.fulfillRFQ, (swapIntent, executionEnvironment, solverBidAmount));

        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        SolverOperation memory solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: solverAddress,
            bidAmount: solverBidAmount,
            value: 0
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return solverOp;
    }

    function buildDAppOperation(address control, UserOperation memory userOp, SolverOperation[] memory solverOps) 
        internal returns (DAppOperation memory) {
        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
        DAppOperation memory dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return dAppOp;
    }

    function approveAtlasAndExecuteSwap(SwapIntent memory swapIntent, UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) internal {
        vm.startPrank(userEOA);

        // (bool simResult,,) = simulator.simUserOperation(userOp);
        // assertFalse(simResult, "metasimUserOperationcall tested true a");

        WETH.approve(address(atlas), swapIntent.maxAmountUserSells);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");
        uint256 gasLeftBefore = gasleft();

        vm.startPrank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });

        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());
        vm.stopPrank();
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract SimpleRFQSolverInvertBid is SolverBaseInvertBid {
    constructor(address weth, address atlas, bool solverBidRetrivalRequired) SolverBaseInvertBid(weth, atlas, msg.sender, solverBidRetrivalRequired) { }

    function fulfillRFQ(SwapIntent calldata swapIntent, address executionEnvironment, uint256 solverBidAmount) public {
        require(
            IERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= solverBidAmount,
            "Did not receive enough tokenUserSells (=solverBidAmount) to fulfill swapIntent"
        );
        require(
            IERC20(swapIntent.tokenUserBuys).balanceOf(address(this)) >= swapIntent.amountUserBuys,
            "Not enough tokenUserBuys to fulfill"
        );
        IERC20(swapIntent.tokenUserBuys).transfer(executionEnvironment, swapIntent.amountUserBuys);
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}