// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { DAppConfig } from "../src/contracts/types/ConfigTypes.sol";
import { DAppOperation } from "../src/contracts/types/DAppOperation.sol";
import { CallVerification } from "../src/contracts/libraries/CallVerification.sol";

import { SolverBase } from "../src/contracts/solver/SolverBase.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { TrebleSwapDAppControl } from "../src/contracts/examples/trebleswap/TrebleSwapDAppControl.sol";

contract TrebleSwapTest is BaseTest {
    struct SwapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputMin;
    }

    struct Args {
        UserOperation userOp;
        SolverOperation[] solverOps;
        DAppOperation dAppOp;
        uint256 blockBefore; // block before real tx happened
        bool nativeInput;
        bool nativeOutput;
    }

    struct BeforeAndAfterVars {
        uint256 userInputTokenBalance;
        uint256 userOutputTokenBalance;
        uint256 solverTrebBalance;
        uint256 burnAddressTrebBalance;
        uint256 atlasGasSurcharge;
    }

    // Base addresses
    address ODOS_ROUTER = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address BURN = address(0xdead);
    address ETH = address(0);
    address bWETH = 0x4200000000000000000000000000000000000006;
    address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address WUF = 0x4da78059D97f155E18B37765e2e042270f4E0fC4;
    address bDAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address BRETT = 0x532f27101965dd16442E59d40670FaF5eBB142E4;
    address TREB; // will be set to value in DAppControl in setUp

    uint256 ERR_MARGIN = 0.22e18; // 22% error margin
    uint256 bundlerGasEth = 1e16;

    TrebleSwapDAppControl trebleSwapControl;
    address executionEnvironment;

    Sig sig;
    Args args;
    SwapTokenInfo swapInfo;
    BeforeAndAfterVars beforeVars;

    function setUp() public virtual override {
        // Fork Base
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 18_906_794);
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        vm.startPrank(governanceEOA);
        trebleSwapControl = new TrebleSwapDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(trebleSwapControl));
        vm.stopPrank();

        vm.prank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(trebleSwapControl));

        TREB = trebleSwapControl.TREB();

        vm.label(bWETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(WUF, "WUF");
        vm.label(bDAI, "DAI");
        vm.label(TREB, "TREB");
    }

    // ---------------------------------------------------- //
    //                     Scenario Tests                   //
    // ---------------------------------------------------- //

    function testTrebleSwap_Metacall_Erc20ToErc20_ZeroSolvers() public {
        // Tx: https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
        // Swaps 197.2 USDC for at least 198,080,836.0295 WUF

        args.blockBefore = 18_906_794;
        args.nativeInput = false;
        args.nativeOutput = false;
        swapInfo = SwapTokenInfo({
            inputToken: USDC,
            inputAmount: 197_200_000,
            outputToken: WUF,
            outputMin: 1_980_808_360_295
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("Erc20ToErc20");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        // no solverOps
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: address(0) });
    }

    function testTrebleSwap_Metacall_Erc20ToErc20_OneSolver_GasCheck() public {
        // Tx: https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
        // Swaps 197.2 USDC for at least 198,080,836.0295 WUF

        args.blockBefore = 18_906_794;
        args.nativeInput = false;
        args.nativeOutput = false;
        swapInfo = SwapTokenInfo({
            inputToken: USDC,
            inputAmount: 197_200_000,
            outputToken: WUF,
            outputMin: 1_980_808_360_295
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("Erc20ToErc20");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        address solverContract = _setUpSolver(solverOneEOA, solverOnePK, 1e18);
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: solverContract });
    }

    function testTrebleSwap_Metacall_Erc20ToErc20_SwapsEvenIfSolverFails() public {
        // Tx: https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
        // Swaps 197.2 USDC for at least 198,080,836.0295 WUF

        args.blockBefore = 18_906_794;
        args.nativeInput = false;
        args.nativeOutput = false;
        swapInfo = SwapTokenInfo({
            inputToken: USDC,
            inputAmount: 197_200_000,
            outputToken: WUF,
            outputMin: 1_980_808_360_295
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("Erc20ToErc20");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        address solverContract = _setUpSolver(solverOneEOA, solverOnePK, 1e18);
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();

        // Set solver to fail during metacall, user swap should still go through
        MockTrebleSolver(payable(solverContract)).setShouldSucceed(false);

        _doMetacallAndChecks({ winningSolver: address(0) });
    }

    function testTrebleSwap_Metacall_EthToErc20_ZeroSolvers() public {
        // Tx: https://basescan.org/tx/0xe138def4155bea056936038b9374546a366828ab8bf1233056f9e2fe4c6af999
        // Swaps 0.123011147164483512 ETH for at least 307.405807527716546728 DAI

        args.blockBefore = 19_026_442;
        args.nativeInput = true;
        args.nativeOutput = false;
        swapInfo = SwapTokenInfo({
            inputToken: ETH,
            inputAmount: 123_011_147_164_483_512,
            outputToken: bDAI,
            outputMin: 307_405_807_527_716_546_728
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("EthToErc20");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        // no solverOps
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: address(0) });
    }

    function testTrebleSwap_Metacall_EthToErc20_OneSolver_GasCheck() public {
        // Tx: https://basescan.org/tx/0xe138def4155bea056936038b9374546a366828ab8bf1233056f9e2fe4c6af999
        // Swaps 0.123011147164483512 ETH for at least 307.405807527716546728 DAI

        args.blockBefore = 19_026_442;
        args.nativeInput = true;
        args.nativeOutput = false;
        swapInfo = SwapTokenInfo({
            inputToken: ETH,
            inputAmount: 123_011_147_164_483_512,
            outputToken: bDAI,
            outputMin: 307_405_807_527_716_546_728
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("EthToErc20");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        address solverContract = _setUpSolver(solverOneEOA, solverOnePK, 1e18);
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: solverContract });
    }

    function testTrebleSwap_Metacall_Erc20ToEth_ZeroSolvers() public {
        // https://basescan.org/tx/0xaf26570fceddf2d21219a9e03f2cfee52c600a40ddfdfc5d82eff14f3d322f8f
        // Swaps 24831.337726043809120256 BRETT for at least 0.786534993470006277 ETH

        args.blockBefore = 19_044_388;
        args.nativeInput = false;
        args.nativeOutput = true;
        swapInfo = SwapTokenInfo({
            inputToken: BRETT,
            inputAmount: 24_831_337_726_043_809_120_256,
            outputToken: ETH,
            outputMin: 786_534_993_470_006_277
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("Erc20ToEth");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        // no solverOps
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: address(0) });
    }

    function testTrebleSwap_Metacall_Erc20ToEth_OneSolver() public {
        // https://basescan.org/tx/0xaf26570fceddf2d21219a9e03f2cfee52c600a40ddfdfc5d82eff14f3d322f8f
        // Swaps 24831.337726043809120256 BRETT for at least 0.786534993470006277 ETH

        args.blockBefore = 19_044_388;
        args.nativeInput = false;
        args.nativeOutput = true;
        swapInfo = SwapTokenInfo({
            inputToken: BRETT,
            inputAmount: 24_831_337_726_043_809_120_256,
            outputToken: ETH,
            outputMin: 786_534_993_470_006_277
        });
        vm.roll(args.blockBefore);

        bytes memory userOpData = _buildUserOpData("Erc20ToEth");
        _checkActualCalldataMatchesExpected(userOpData);
        _buildUserOp(userOpData);
        address solverContract = _setUpSolver(solverOneEOA, solverOnePK, 1e18);
        _buildDAppOp();

        _setBalancesAndApprovals();
        _checkSimulationsPass();
        _doMetacallAndChecks({ winningSolver: solverContract });
    }

    // ---------------------------------------------------- //
    //                    Helper Functions                  //
    // ---------------------------------------------------- //

    function _doMetacallAndChecks(address winningSolver) internal {
        bool auctionWonExpected = winningSolver != address(0);
        beforeVars.userInputTokenBalance = _balanceOf(swapInfo.inputToken, userEOA);
        beforeVars.userOutputTokenBalance = _balanceOf(swapInfo.outputToken, userEOA);
        beforeVars.solverTrebBalance = _balanceOf(address(TREB), winningSolver);
        beforeVars.burnAddressTrebBalance = _balanceOf(address(TREB), BURN);
        beforeVars.atlasGasSurcharge = atlas.cumulativeSurcharge();
        uint256 msgValue = args.nativeInput ? swapInfo.inputAmount : 0;

        uint256 txGasUsed;
        uint256 estAtlasGasSurcharge = gasleft(); // Reused below during calculations

        // Do the actual metacall
        vm.prank(userEOA);
        bool auctionWon = atlas.metacall{ value: msgValue }(args.userOp, args.solverOps, args.dAppOp, address(0));

        // Estimate gas surcharge Atlas should have taken
        txGasUsed = estAtlasGasSurcharge - gasleft();
        estAtlasGasSurcharge = txGasUsed * tx.gasprice * atlas.ATLAS_SURCHARGE_RATE() / atlas.SCALE();

        // For benchmarking
        console.log("Metacall gas cost: ", txGasUsed);

        // Check Atlas auctionWon return value
        assertEq(auctionWon, auctionWonExpected, "auctionWon not as expected");

        // Check msg.value is 0 unless sending ETH as the input token to be swapped
        if (!args.nativeInput) assertEq(msgValue, 0, "msgValue should have been 0");

        // Check Atlas gas surcharge change
        if (args.solverOps.length > 0 && auctionWonExpected) {
            assertApproxEqRel(
                atlas.cumulativeSurcharge() - beforeVars.atlasGasSurcharge,
                estAtlasGasSurcharge,
                ERR_MARGIN,
                "Atlas gas surcharge not within estimated range"
            );
        } else if (args.solverOps.length == 0) {
            // No surcharge taken if no solvers.
            assertEq(
                atlas.cumulativeSurcharge(),
                beforeVars.atlasGasSurcharge,
                "Atlas gas surcharge changed when zero solvers"
            );
        } else {
            // If solver failed (solver's fault), surcharge still taken, but only on failing solverOp portion. Difficult
            // to estimate what that would be so skip this check in that 1 test case.
        }

        // Check user input token change
        if (args.nativeInput && auctionWonExpected) {
            // solver will refund some bundler ETH to user, throwing off ETH balance
            uint256 buffer = 1e17; // 0.1 ETH buffer as base for error margin comparison
            uint256 expectedBalanceAfter = beforeVars.userInputTokenBalance - swapInfo.inputAmount;
            assertApproxEqRel(
                _balanceOf(swapInfo.inputToken, userEOA) + buffer,
                expectedBalanceAfter + buffer,
                0.01e18, // error marin: 1% of the 0.1 ETH buffer
                "wrong user input token (ETH) balance change"
            );
        } else {
            assertEq(
                _balanceOf(swapInfo.inputToken, userEOA),
                beforeVars.userInputTokenBalance - swapInfo.inputAmount,
                "wrong user input token (ERC20/ETH) balance change"
            );
        }

        // Check user output token change
        assertTrue(
            _balanceOf(swapInfo.outputToken, userEOA) >= beforeVars.userOutputTokenBalance + swapInfo.outputMin,
            "wrong user output token balance change"
        );

        // Check solver and burn address TREB balance change
        if (auctionWonExpected) {
            // Solver TREB decreased by bidAmount
            assertEq(
                _balanceOf(address(TREB), winningSolver),
                beforeVars.solverTrebBalance - args.solverOps[0].bidAmount,
                "wrong solver TREB balance change"
            );
            // Burn address TREB increased by bidAmount
            assertEq(
                _balanceOf(address(TREB), BURN),
                beforeVars.burnAddressTrebBalance + args.solverOps[0].bidAmount,
                "wrong burn address TREB balance change"
            );
        } else {
            // No change in solver TREB
            assertEq(
                _balanceOf(address(TREB), winningSolver), beforeVars.solverTrebBalance, "solver TREB balance changed"
            );
            // No change in burn address TREB
            assertEq(
                _balanceOf(address(TREB), BURN), beforeVars.burnAddressTrebBalance, "burn address TREB balance changed"
            );
        }
    }

    function _checkSimulationsPass() internal {
        bool success;

        (success,,) = simulator.simUserOperation(args.userOp);
        assertEq(success, true, "simUserOperation failed");

        if (args.solverOps.length > 0) {
            (success,,) = simulator.simSolverCalls(args.userOp, args.solverOps, args.dAppOp);
            assertEq(success, true, "simSolverCalls failed");
        }
    }

    function _checkActualCalldataMatchesExpected(bytes memory userOpData) internal view {
        bytes memory encodedCall = abi.encodePacked(TrebleSwapDAppControl.decodeUserOpData.selector, userOpData);
        (bool res, bytes memory returnData) = address(trebleSwapControl).staticcall(encodedCall);
        assertEq(res, true, "calldata check failed in decode call");

        SwapTokenInfo memory decodedInfo = abi.decode(returnData, (SwapTokenInfo));
        assertEq(decodedInfo.inputToken, swapInfo.inputToken, "inputToken mismatch");
        assertEq(decodedInfo.inputAmount, swapInfo.inputAmount, "inputAmount mismatch");
        assertEq(decodedInfo.outputToken, swapInfo.outputToken, "outputToken mismatch");
        assertEq(decodedInfo.outputMin, swapInfo.outputMin, "outputMin mismatch");
    }

    function _setBalancesAndApprovals() internal {
        // User input token and Atlas approval
        if (args.nativeInput) {
            deal(userEOA, swapInfo.inputAmount + bundlerGasEth);
        } else {
            deal(userEOA, bundlerGasEth);
            deal(swapInfo.inputToken, userEOA, swapInfo.inputAmount);
            vm.prank(userEOA);
            IERC20(swapInfo.inputToken).approve(address(atlas), swapInfo.inputAmount);
        }

        // Give bidAmount of TREB to solver contract for each solverOp
        for (uint256 i = 0; i < args.solverOps.length; i++) {
            deal(TREB, args.solverOps[i].solver, args.solverOps[i].bidAmount);
        }
    }

    function _buildUserOp(bytes memory userOpData) internal {
        args.userOp = UserOperation({
            from: userEOA,
            to: address(atlas),
            value: args.nativeInput ? swapInfo.inputAmount : 0,
            gas: 1_000_000,
            maxFeePerGas: tx.gasprice,
            nonce: 1,
            deadline: args.blockBefore + 2,
            dapp: ODOS_ROUTER,
            control: address(trebleSwapControl),
            callConfig: trebleSwapControl.CALL_CONFIG(),
            sessionKey: address(0),
            data: userOpData,
            signature: new bytes(0)
        });
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount
    )
        internal
        returns (address solverContract)
    {
        vm.startPrank(solverEOA);
        // Make sure solver has 1 AtlETH bonded in Atlas
        uint256 bonded = atlas.balanceOfBonded(solverEOA);
        if (bonded < 1e18) {
            uint256 atlETHBalance = atlas.balanceOf(solverEOA);
            if (atlETHBalance < 1e18) {
                deal(solverEOA, 1e18 - atlETHBalance);
                atlas.deposit{ value: 1e18 - atlETHBalance }();
            }
            atlas.bond(1e18 - bonded);
        }

        // Deploy solver contract
        MockTrebleSolver solver = new MockTrebleSolver(bWETH, address(atlas));

        // Create signed solverOp
        SolverOperation memory solverOp = _buildSolverOp(solverEOA, solverPK, address(solver), bidAmount);
        vm.stopPrank();

        // add to solverOps array and return solver contract address
        args.solverOps.push(solverOp);
        return address(solver);
    }

    function _buildSolverOp(
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        solverOp = SolverOperation({
            from: solverEOA,
            to: address(atlas),
            value: 0,
            gas: 100_000,
            maxFeePerGas: args.userOp.maxFeePerGas,
            deadline: args.userOp.deadline,
            solver: solverContract,
            control: address(trebleSwapControl),
            userOpHash: atlasVerification.getUserOperationHash(args.userOp),
            bidToken: trebleSwapControl.getBidFormat(args.userOp),
            bidAmount: bidAmount,
            data: abi.encodeCall(MockTrebleSolver.solve, ()),
            signature: new bytes(0)
        });
        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function _buildDAppOp() internal {
        args.dAppOp = DAppOperation({
            from: governanceEOA,
            to: address(atlas),
            nonce: 1,
            deadline: args.blockBefore + 2,
            control: address(trebleSwapControl),
            bundler: address(0),
            userOpHash: atlasVerification.getUserOperationHash(args.userOp),
            callChainHash: CallVerification.getCallChainHash(args.userOp, args.solverOps),
            signature: new bytes(0)
        });

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(args.dAppOp));
        args.dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function _buildUserOpData(string memory swapType) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(abi.encodePacked(swapType));
        bytes memory calldataPart1;
        bytes memory calldataPart2;
        if (typeHash == keccak256("Erc20ToErc20")) {
            // Tx: https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
            calldataPart1 =
                hex"83bd37f9000400014da78059d97f155e18b37765e2e042270f4e0fc4040bc108800601d1d9f50a5a028f5c0001f73f77f9466da712590ae432a80f07fd50a7de600001616535324976f8dbcef19df0705b95ace86ebb480001";
            calldataPart2 =
                hex"0000000006020207003401000001020180000005020a0004040500000301010003060119ff0000000000000000000000000000000000000000000000000000000000000000616535324976f8dbcef19df0705b95ace86ebb48833589fcd6edb6e08f4c7c32d4f71b54bda02913569d81c17b5b4ac08929dc1769b8e39668d3ae29f6c0a374a483101e04ef5f7ac9bd15d9142bac95d9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca42000000000000000000000000000000000000060000000000000000";
        } else if (typeHash == keccak256("EthToErc20")) {
            // Tx: https://basescan.org/tx/0xe138def4155bea056936038b9374546a366828ab8bf1233056f9e2fe4c6af999
            calldataPart1 =
                hex"83bd37f9000000050801b505fc9226ffb80910d5345f06a9650000028f5c0001f73f77f9466da712590ae432a80f07fd50a7de6000000001";
            calldataPart2 =
                hex"000000000401020500040101020a000202030100340101000104007ffffffaff00000000005fb33b095c6e739be19364ab408cd8f102262bb672ab388e2e2f6facef59e3c3fa2c4e29011c2d384200000000000000000000000000000000000006833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000000000000";
        } else if (typeHash == keccak256("Erc20ToEth")) {
            // https://basescan.org/tx/0xaf26570fceddf2d21219a9e03f2cfee52c600a40ddfdfc5d82eff14f3d322f8f
            calldataPart1 =
                hex"83bd37f90001532f27101965dd16442e59d40670faf5ebb142e400000a05421c0933c565400000080aed2177322a39000041890001f73f77f9466da712590ae432a80f07fd50a7de6000000001";
            calldataPart2 =
                hex"0000000003010204010e6604680a0100010200000a0100030200020400000001ff0000000036a46dff597c5a444bbc521d26787f57867d2214532f27101965dd16442e59d40670faf5ebb142e44e829f8a5213c42535ab84aa40bd4adcce9cba0200000000";
        } else {
            revert("Invalid swap type");
        }
        return abi.encodePacked(calldataPart1, executionEnvironment, calldataPart2);
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == ETH) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }
}

// Just bids `bidAmount` in TREB token - doesn't do anything else
contract MockTrebleSolver is SolverBase {
    bool internal s_shouldSucceed;

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {
        s_shouldSucceed = true; // should succeed by default, can be set to false
    }

    function shouldSucceed() public view returns (bool) {
        return s_shouldSucceed;
    }

    function setShouldSucceed(bool succeed) public {
        s_shouldSucceed = succeed;
    }

    function solve() public view onlySelf {
        require(s_shouldSucceed, "Solver failed intentionally");

        // The solver bid representing user's minAmountUserBuys of tokenUserBuys is sent to the
        // Execution Environment in the payBids modifier logic which runs after this function ends.
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
