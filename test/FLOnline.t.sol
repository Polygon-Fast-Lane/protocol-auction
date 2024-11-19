// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";

import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";

import { FastLaneOnlineOuter } from "../src/contracts/examples/fastlane-online/FastLaneOnlineOuter.sol";
import { FastLaneOnlineInner } from "../src/contracts/examples/fastlane-online/FastLaneOnlineInner.sol";
import { SwapIntent, BaselineCall, Reputation } from "../src/contracts/examples/fastlane-online/FastLaneTypes.sol";
import { FastLaneOnlineErrors } from "../src/contracts/examples/fastlane-online/FastLaneOnlineErrors.sol";

import { IUniswapV2Router02 } from "./base/interfaces/IUniswapV2Router.sol";

contract FastLaneOnlineTest is BaseTest {
    struct FastOnlineSwapArgs {
        UserOperation userOp;
        SwapIntent swapIntent;
        BaselineCall baselineCall;
        uint256 deadline;
        uint256 gas;
        uint256 maxFeePerGas;
        uint256 msgValue;
        bytes32 userOpHash;
    }

    struct BeforeAndAfterVars {
        uint256 userTokenOutBalance;
        uint256 userTokenInBalance;
        uint256 solverTokenOutBalance;
        uint256 solverTokenInBalance;
        uint256 atlasGasSurcharge;
        Reputation solverOneRep;
        Reputation solverTwoRep;
        Reputation solverThreeRep;
        Reputation solverFourRep;
    }

    // defaults to true when solver calls `addSolverOp()`, set to false if the solverOp is expected to not be included
    // in the final solverOps array, or if the solverOp is not attempted as it has a higher index in the sorted array
    // than the winning solverOp.
    struct ExecutionAttemptedInMetacall {
        bool solverOne;
        bool solverTwo;
        bool solverThree;
        bool solverFour;
    }

    // Only Atlas surcharge kept if all fail, bundler surcharge paid to bundler
    uint256 constant SURCHARGE_PER_SOLVER_IF_ALL_FAIL = 14_000e9; // 14k Gwei (avg, differs for ERC20/native in/out)
    uint256 constant ERR_MARGIN = 0.22e18; // 22% error margin
    address internal constant NATIVE_TOKEN = address(0);

    address protocolGuildWallet = 0x25941dC771bB64514Fc8abBce970307Fb9d477e9;

    IUniswapV2Router02 routerV2 = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    uint256 goodSolverBidETH = 1.2 ether; // more than baseline swap amountOut if tokenOut is WETH/ETH
    uint256 goodSolverBidDAI = 3100e18; // more than baseline swap amountOut if tokenOut is DAI
    uint256 defaultGasLimit = 2_000_000;
    uint256 defaultGasPrice;
    uint256 defaultDeadlineBlock;
    uint256 defaultDeadlineTimestamp;

    // 3200 DAI for 1 WETH (no native tokens)
    SwapIntent defaultSwapIntent = SwapIntent({
        tokenUserBuys: address(WETH),
        minAmountUserBuys: 1e18,
        tokenUserSells: DAI_ADDRESS,
        amountUserSells: 3200e18
    });

    FastLaneOnlineOuter flOnline;
    MockFastLaneOnline flOnlineMock;
    address executionEnvironment;

    Sig sig;
    FastOnlineSwapArgs args;
    BeforeAndAfterVars beforeVars;
    ExecutionAttemptedInMetacall attempted;

    function setUp() public virtual override {
        BaseTest.setUp();
        vm.rollFork(20_385_779); // ETH was just under $3100 at this block

        defaultDeadlineBlock = block.number + 1;
        defaultDeadlineTimestamp = block.timestamp + 1;
        defaultGasPrice = tx.gasprice;

        vm.startPrank(governanceEOA);
        flOnlineMock = new MockFastLaneOnline{ salt: bytes32("1") }(address(atlas), protocolGuildWallet);
        flOnline = new FastLaneOnlineOuter(address(atlas), protocolGuildWallet);
        atlasVerification.initializeGovernance(address(flOnline));
        // FLOnline contract must be registered as its own signatory
        atlasVerification.addSignatory(address(flOnline), address(flOnline));
        // Once set up, burn gov role - only the contract itself should be a signatory
        flOnline.transferGovernance(address(govBurner));
        govBurner.burnGovernance(address(flOnline));
        vm.stopPrank();

        // Get but do not deploy user's EE - first solver registered will deploy it
        (executionEnvironment,,) = atlas.getExecutionEnvironment(userEOA, address(flOnline));

        // NOTE: `_setUpUser()` MUST be called at the start of each end-to-end test.
    }

    // ---------------------------------------------------- //
    //                     Scenario Tests                   //
    // ---------------------------------------------------- //

    function testFLOnline_Swap_OneSolverFulfills_Success() public {
        _setUpUser(defaultSwapIntent);

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address winningSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverOneEOA,
            winningSolver: winningSolver,
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFulfills_NativeIn_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: DAI_ADDRESS,
                minAmountUserBuys: 3000e18,
                tokenUserSells: NATIVE_TOKEN,
                amountUserSells: 1e18
            })
        );

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address winningSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidDAI);

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverOneEOA,
            winningSolver: winningSolver,
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFulfills_NativeOut_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: NATIVE_TOKEN,
                minAmountUserBuys: 1e18,
                tokenUserSells: DAI_ADDRESS,
                amountUserSells: 3200e18
            })
        );

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address winningSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverOneEOA,
            winningSolver: winningSolver,
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFails_BaselineCallFulfills_Success() public {
        _setUpUser(defaultSwapIntent);

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address failingSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Set failingSolver to fail during metacall
        FLOnlineRFQSolver(payable(failingSolver)).setShouldSucceed(false);

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFails_BaselineCallFulfills_NativeIn_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: DAI_ADDRESS,
                minAmountUserBuys: 3000e18,
                tokenUserSells: NATIVE_TOKEN,
                amountUserSells: 1e18
            })
        );

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address failingSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidDAI);

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Set failingSolver to fail during metacall
        FLOnlineRFQSolver(payable(failingSolver)).setShouldSucceed(false);

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFails_BaselineCallFulfills_NativeOut_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: NATIVE_TOKEN,
                minAmountUserBuys: 1e18,
                tokenUserSells: DAI_ADDRESS,
                amountUserSells: 3200e18
            })
        );

        // Set up the solver contract and register the solverOp in the FLOnline contract
        address failingSolver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Set failingSolver to fail during metacall
        FLOnlineRFQSolver(payable(failingSolver)).setShouldSucceed(false);

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_OneSolverFails_BaselineCallReverts_Failure() public {
        _setUpUser(defaultSwapIntent);

        // Set baselineCall incorrectly to intentionally fail
        _setBaselineCallToRevert();

        address solver = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        // Check BaselineCall struct is formed correctly and can revert, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: false });

        // Set solver contract to fail during metacall
        FLOnlineRFQSolver(payable(solver)).setShouldSucceed(false);

        // fastOnlineSwap should revert if all solvers fail AND the baseline call also fails
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 1,
            swapCallShouldSucceed: false // fastOnlineSwap should revert
         });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallFulfills_Success() public {
        _setUpUser(defaultSwapIntent);

        // No solverOps at all
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallFulfills_NativeIn_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: DAI_ADDRESS,
                minAmountUserBuys: 3000e18,
                tokenUserSells: NATIVE_TOKEN,
                amountUserSells: 1e18
            })
        );

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallFulfills_NativeOut_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: NATIVE_TOKEN,
                minAmountUserBuys: 1e18,
                tokenUserSells: DAI_ADDRESS,
                amountUserSells: 3200e18
            })
        );

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallReverts_Failure() public {
        _setUpUser(defaultSwapIntent);

        // Set baselineCall incorrectly to intentionally fail
        _setBaselineCallToRevert();

        // Check BaselineCall struct is formed correctly and can revert, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: false });

        // fastOnlineSwap should revert if all solvers fail AND the baseline call also fails
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: false // fastOnlineSwap should revert
         });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallReverts_NativeIn_Failure() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: DAI_ADDRESS,
                minAmountUserBuys: 3000e18,
                tokenUserSells: NATIVE_TOKEN,
                amountUserSells: 1e18
            })
        );

        // Set baselineCall incorrectly to intentionally fail
        _setBaselineCallToRevert();

        // Check BaselineCall struct is formed correctly and can revert, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: false });

        // fastOnlineSwap should revert if all solvers fail AND the baseline call also fails
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: false // fastOnlineSwap should revert
         });
    }

    function testFLOnline_Swap_ZeroSolvers_BaselineCallReverts_NativeOut_Failure() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: NATIVE_TOKEN,
                minAmountUserBuys: 1e18,
                tokenUserSells: DAI_ADDRESS,
                amountUserSells: 3200e18
            })
        );

        // Set baselineCall incorrectly to intentionally fail
        _setBaselineCallToRevert();

        // Check BaselineCall struct is formed correctly and can revert, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: false });

        // fastOnlineSwap should revert if all solvers fail AND the baseline call also fails
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 0,
            swapCallShouldSucceed: false // fastOnlineSwap should revert
         });
    }

    function testFLOnline_Swap_ThreeSolvers_ThirdFulfills_Success() public {
        _setUpUser(defaultSwapIntent);

        // Set up the solver contracts and register the solverOps in the FLOnline contract
        _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);
        _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH + 1e17);
        address winningSolver = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH + 2e17);

        // solverOne does not get included in the sovlerOps array
        attempted.solverOne = false;
        // solverTwo has a lower bid than winner (solverThree) so is not attempted
        attempted.solverTwo = false;

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverThreeEOA,
            winningSolver: winningSolver,
            solverCount: 3,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ThreeSolvers_ThirdFulfills_NativeIn_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: DAI_ADDRESS,
                minAmountUserBuys: 3000e18,
                tokenUserSells: NATIVE_TOKEN,
                amountUserSells: 1e18
            })
        );

        // Set up the solver contracts and register the solverOps in the FLOnline contract
        _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidDAI);
        _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidDAI + 1e17);
        address winningSolver = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidDAI + 2e17);

        // solverOne does not get included in the sovlerOps array
        attempted.solverOne = false;
        // solverTwo has a lower bid than winner (solverThree) so is not attempted
        attempted.solverTwo = false;

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverThreeEOA,
            winningSolver: winningSolver,
            solverCount: 3,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ThreeSolvers_ThirdFulfills_NativeOut_Success() public {
        _setUpUser(
            SwapIntent({
                tokenUserBuys: NATIVE_TOKEN,
                minAmountUserBuys: 1e18,
                tokenUserSells: DAI_ADDRESS,
                amountUserSells: 3200e18
            })
        );

        // Set up the solver contracts and register the solverOps in the FLOnline contract
        _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);
        _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH + 1e17);
        address winningSolver = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH + 2e17);

        // solverOne does not get included in the sovlerOps array
        attempted.solverOne = false;
        // solverTwo has a lower bid than winner (solverThree) so is not attempted
        attempted.solverTwo = false;

        // User calls fastOnlineSwap, do checks that user and solver balances changed as expected
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverThreeEOA,
            winningSolver: winningSolver,
            solverCount: 3,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ThreeSolvers_AllFail_BaselineCallFulfills_Success() public {
        _setUpUser(defaultSwapIntent);

        // Set up the solver contracts and register the solverOps in the FLOnline contract
        address solver1 = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);
        address solver2 = _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH + 1e17);
        address solver3 = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH + 2e17);
        // all 3 solvers will be included and attempted but fail

        // Check BaselineCall struct is formed correctly and can succeed, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // Set all solvers to fail during metacall
        FLOnlineRFQSolver(payable(solver1)).setShouldSucceed(false);
        FLOnlineRFQSolver(payable(solver2)).setShouldSucceed(false);
        FLOnlineRFQSolver(payable(solver3)).setShouldSucceed(false);

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 3,
            swapCallShouldSucceed: true
        });
    }

    function testFLOnline_Swap_ThreeSolvers_AllFail_BaselineCallReverts_Failure() public {
        _setUpUser(defaultSwapIntent);

        // Set up the solver contracts and register the solverOps in the FLOnline contract
        address solver1 = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);
        address solver2 = _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH + 1e17);
        address solver3 = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH + 2e17);

        // solverOne does not get included in the sovlerOps array
        attempted.solverOne = false;
        // solverTwo and solverThree will be attempted but fail

        // Set baselineCall incorrectly to intentionally fail
        _setBaselineCallToRevert();

        // Check BaselineCall struct is formed correctly and can revert, revert changes after
        _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: false });

        // Set all solvers to fail during metacall
        FLOnlineRFQSolver(payable(solver1)).setShouldSucceed(false);
        FLOnlineRFQSolver(payable(solver2)).setShouldSucceed(false);
        FLOnlineRFQSolver(payable(solver3)).setShouldSucceed(false);

        // fastOnlineSwap should revert if all solvers fail AND the baseline call also fails
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: address(0),
            winningSolver: address(0), // No winning solver expected
            solverCount: 3,
            swapCallShouldSucceed: false // fastOnlineSwap should revert
         });
    }

    function testFLOnline_Swap_SolverBidsSameAsBaselineCall_Success() public {
        _setUpUser(defaultSwapIntent);

        uint256 baselineAmountOut = _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        // If solver bids below baseline amountOut, addSolverOp will revert
        bytes4 expectedErr = FastLaneOnlineErrors.SolverGateway_AddSolverOp_SimulationFail.selector;
        _setUpSolver(solverOneEOA, solverOnePK, baselineAmountOut - 1, expectedErr);

        // But if solver bids equal to baseline amountOut, solver will win if no higher bids
        address winningSolver = _setUpSolver(solverOneEOA, solverOnePK, baselineAmountOut);

        // Now fastOnlineSwap should succeed using BaselineCall for fulfillment, with gas + Atlas gas surcharge paid for
        // by ETH sent as msg.value by user.
        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverOneEOA,
            winningSolver: winningSolver,
            solverCount: 1,
            swapCallShouldSucceed: true
        });
    }

    // ---------------------------------------------------- //
    //                addSolverOp() Tests                   //
    // ---------------------------------------------------- //

    function testFLOnline_addSolverOp_FirstSolverCreatesEE() public {
        bool isDeployed;
        _setUpUser(defaultSwapIntent);

        (,, isDeployed) = atlas.getExecutionEnvironment(userEOA, address(flOnline));
        assertEq(isDeployed, false, "EE should not be deployed yet");

        // First solver to call addSolverOp() deploys EE
        _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        (,, isDeployed) = atlas.getExecutionEnvironment(userEOA, address(flOnline));
        assertEq(isDeployed, true, "EE should be deployed");
    }

    function testFLOnline_addSolverOp_WrongCaller_Fails() public {
        _setUpUser(defaultSwapIntent);
        SolverOperation memory solverOp = _buildSolverOp(solverOneEOA, solverOnePK, address(123), 1);

        vm.prank(userEOA); // Should revert if caller not solverOneEOA
        vm.expectRevert(FastLaneOnlineErrors.SolverGateway_AddSolverOp_SolverMustBeSender.selector);
        flOnline.addSolverOp(args.userOp, solverOp);
    }

    function testFLOnline_addSolverOp_SimFail_Fails() public {
        _setUpUser(defaultSwapIntent);

        vm.startPrank(solverOneEOA); // standard solver set up
        FLOnlineRFQSolver solver = new FLOnlineRFQSolver{ salt: keccak256("salt") }(WETH_ADDRESS, address(atlas));
        SolverOperation memory solverOp = _buildSolverOp(solverOneEOA, solverOnePK, address(solver), goodSolverBidETH);

        // Set solver contract to revert, causing sim to fail
        solver.setShouldSucceed(false);

        vm.expectRevert(FastLaneOnlineErrors.SolverGateway_AddSolverOp_SimulationFail.selector);
        flOnline.addSolverOp(args.userOp, solverOp);
    }

    function testFLOnline_addSolverOp_ThreeNew() public {
        _setUpUser(defaultSwapIntent);
        uint256 buyInAmount = 1e17;
        deal(solverOneEOA, buyInAmount);
        deal(solverTwoEOA, buyInAmount);
        deal(solverThreeEOA, buyInAmount);

        bytes32[] memory solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 0, "solverOpHashes should start empty");

        SolverOperation memory solverOp1 = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH, buyInAmount);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 1, "solverOpHashes should have 1 element");
        assertEq(solverOpHashes[0], keccak256(abi.encode(solverOp1)), "solverOpHashes[0] should be keccak(solverOp1)");
        assertEq(
            flOnline.congestionBuyIn(keccak256(abi.encode(solverOp1))),
            buyInAmount,
            "solverOp1 buy in should be buyInAmount"
        );
        assertEq(
            flOnline.aggCongestionBuyIn(args.userOpHash), buyInAmount, "aggCongestionBuyIn should be 1x buyInAmount"
        );

        SolverOperation memory solverOp2 = _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH, buyInAmount);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 2, "solverOpHashes should have 2 elements");
        assertEq(solverOpHashes[1], keccak256(abi.encode(solverOp2)), "solverOpHashes[1] should be keccak(solverOp2)");
        assertEq(
            flOnline.congestionBuyIn(keccak256(abi.encode(solverOp2))),
            buyInAmount,
            "solverOp2 buy in should be buyInAmount"
        );
        assertEq(
            flOnline.aggCongestionBuyIn(args.userOpHash), 2 * buyInAmount, "aggCongestionBuyIn should be 2x buyInAmount"
        );

        SolverOperation memory solverOp3 = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH, buyInAmount);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 3, "solverOpHashes should have 3 elements");
        assertEq(solverOpHashes[2], keccak256(abi.encode(solverOp3)), "solverOpHashes[2] should be keccak(solverOp3)");
        assertEq(
            flOnline.congestionBuyIn(keccak256(abi.encode(solverOp3))),
            buyInAmount,
            "solverOp3 buy in should be buyInAmount"
        );
        assertEq(
            flOnline.aggCongestionBuyIn(args.userOpHash), 3 * buyInAmount, "aggCongestionBuyIn should be 3x buyInAmount"
        );
    }

    function testFLOnline_addSolverOp_ThreeNew_FourthBidsHigher_ReplacesFirst() public {
        // Similar to test above, but here the 4th solver will not fit into the userOp.gas limit imposed on the
        // metacall. When it has a higher congestion buy-in than the others it should replace solverOp1.
        _setUpUser(defaultSwapIntent);
        uint256 buyInAmount = 1e17;
        deal(solverOneEOA, buyInAmount);
        deal(solverTwoEOA, buyInAmount);
        deal(solverThreeEOA, buyInAmount);
        deal(solverFourEOA, buyInAmount * 2); // double normal buy-in

        bytes32[] memory solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 0, "solverOpHashes should start empty");

        SolverOperation memory solverOp1 = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH, buyInAmount);
        SolverOperation memory solverOp2 = _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH, buyInAmount);
        SolverOperation memory solverOp3 = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH, buyInAmount);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 3, "solverOpHashes should have 3 elements");
        assertEq(solverOpHashes[0], keccak256(abi.encode(solverOp1)), "solverOpHashes[0] should be keccak(solverOp1)");
        assertEq(solverOpHashes[1], keccak256(abi.encode(solverOp2)), "solverOpHashes[1] should be keccak(solverOp2)");
        assertEq(solverOpHashes[2], keccak256(abi.encode(solverOp3)), "solverOpHashes[2] should be keccak(solverOp3)");
        assertEq(flOnline.aggCongestionBuyIn(args.userOpHash), 3 * buyInAmount, "total buy in expected buyInAmountx3");

        // Now add 4th solverOp with higher congestion buy-in - should replace 1st solverOp
        SolverOperation memory solverOp4 = _setUpSolver(solverFourEOA, solverFourPK, goodSolverBidETH, buyInAmount * 2);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 3, "solverOpHashes should still have 3 elements");
        assertEq(solverOpHashes[0], keccak256(abi.encode(solverOp4)), "solverOpHashes[0] should be keccak(solverOp4)");
        assertEq(solverOpHashes[1], keccak256(abi.encode(solverOp2)), "solverOpHashes[1] should be keccak(solverOp2)");
        assertEq(solverOpHashes[2], keccak256(abi.encode(solverOp3)), "solverOpHashes[2] should be keccak(solverOp3)");
        assertEq(flOnline.aggCongestionBuyIn(args.userOpHash), 4 * buyInAmount, "total buy in expected buyInAmountx4");
    }

    function testFLOnline_addSolverOp_ThreeNew_FourthBidsLower_Fails() public {
        // Similar to test above, but here the 4th solver sends a lower congestion buy-in, does not get included at all,
        // and addSolverOp reverts.
        _setUpUser(defaultSwapIntent);
        uint256 buyInAmount = 1e17;
        deal(solverOneEOA, buyInAmount);
        deal(solverTwoEOA, buyInAmount);
        deal(solverThreeEOA, buyInAmount);
        deal(solverFourEOA, buyInAmount / 2); // half normal buy-in

        bytes32[] memory solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 0, "solverOpHashes should start empty");

        SolverOperation memory solverOp1 = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH, buyInAmount);
        SolverOperation memory solverOp2 = _setUpSolver(solverTwoEOA, solverTwoPK, goodSolverBidETH, buyInAmount);
        SolverOperation memory solverOp3 = _setUpSolver(solverThreeEOA, solverThreePK, goodSolverBidETH, buyInAmount);

        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 3, "solverOpHashes should have 3 elements");
        assertEq(solverOpHashes[0], keccak256(abi.encode(solverOp1)), "solverOpHashes[0] should be keccak(solverOp1)");
        assertEq(solverOpHashes[1], keccak256(abi.encode(solverOp2)), "solverOpHashes[1] should be keccak(solverOp2)");
        assertEq(solverOpHashes[2], keccak256(abi.encode(solverOp3)), "solverOpHashes[2] should be keccak(solverOp3)");
        assertEq(flOnline.aggCongestionBuyIn(args.userOpHash), 3 * buyInAmount, "total buy in expected buyInAmountx3");

        // Now add 4th solverOp with lower congestion buy-in - should fail
        bytes4 expectedErr = FastLaneOnlineErrors.SolverGateway_AddSolverOp_ScoreTooLow.selector;
        _setUpSolver(solverFourEOA, solverFourPK, goodSolverBidETH, buyInAmount / 2, expectedErr);

        // Registered solverOp state same as before 4th solver attempt
        solverOpHashes = flOnline.solverOpHashes(args.userOpHash);
        assertEq(solverOpHashes.length, 3, "solverOpHashes should have 3 elements");
        assertEq(solverOpHashes[0], keccak256(abi.encode(solverOp1)), "solverOpHashes[0] should be keccak(solverOp1)");
        assertEq(solverOpHashes[1], keccak256(abi.encode(solverOp2)), "solverOpHashes[1] should be keccak(solverOp2)");
        assertEq(solverOpHashes[2], keccak256(abi.encode(solverOp3)), "solverOpHashes[2] should be keccak(solverOp3)");
        assertEq(flOnline.aggCongestionBuyIn(args.userOpHash), 3 * buyInAmount, "total buy in expected buyInAmountx3");
    }

    // ---------------------------------------------------- //
    //                  Reputation Tests                    //
    // ---------------------------------------------------- //

    function testFLOnline_CalculateBidFactor() public {
        // bidFactor measured with scale = 100. I.e. 100% = 100
        uint256 BASE_FACTOR = flOnlineMock.SLIPPAGE_BASE();
        uint256 MAX_FACTOR = flOnlineMock.GLOBAL_MAX_SLIPPAGE();
        uint256 bidFactor;

        // Case: solver bids minAmountUserBuys + 1 ==> bidFactor should be 100 (floor)
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 1e18 + 1, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, BASE_FACTOR, "bidFactor should be floor (+1 bid)");

        // Case: solver bids under minAmountUserBuys ==> bidFactor should be 100 (floor)
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 1e18 - 1, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, BASE_FACTOR, "bidFactor should be floor (underbid)");

        // Case: solver bids minAmountUserBuys ==> bidFactor should be 100 (floor)
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 1e18, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, BASE_FACTOR, "bidFactor should be floor (match)");

        // Case: still returns floor if minAmountUserBuys is sqrt(type(uint256).max)
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 1e18, minAmountUserBuys: sqrt(type(uint256).max) });
        assertEq(bidFactor, BASE_FACTOR, "bidFactor should be floor (max minAmountUserBuys)");

        // Case: solver bids 2x minAmountUserBuys ==> bidFactor should be 125 (cap)
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 2e18, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, MAX_FACTOR, "bidFactor should be max (cap)");

        // Case: still returns max if bidAmount is sqrt(type(uint256).max) / 100
        bidFactor =
            flOnlineMock.calculateBidFactor({ bidAmount: sqrt(type(uint256).max) / 100, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, MAX_FACTOR, "bidFactor should be max (max bidAmount)");

        // Case: solver bids 1.1x minAmountUserBuys ==> bidFactor should be 120
        bidFactor = flOnlineMock.calculateBidFactor({ bidAmount: 1.1e18, minAmountUserBuys: 1e18 });
        assertEq(bidFactor, 120, "bidFactor should be 120");

        // Case: reverts if bidAmount > sqrt(type(uint256).max / 100)
        // NOTE: This is caught in addSolverOp before revert can happen
        vm.expectRevert();
        flOnlineMock.calculateBidFactor({ bidAmount: sqrt(type(uint256).max / 100) + 1, minAmountUserBuys: 1e18 });
    }

    function testFLOnline_CalculateWeightedScore() public {
        Reputation memory rep;
        uint256 highScore;
        uint256 lowScore;

        rep = Reputation({
            successCost: 1e16, // 0.01 ETH on winning solverOps
            failureCost: 0 // no failing solverOps
         });

        // Case: totalGas (userOp.gas) positively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit / 2,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "totalGas should positively impact score");

        // Case: solverOpGas negatively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: 200_000,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: 300_000,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "solverOpGas should negatively impact score");

        // Case: maxFeePerGas positively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: 20e9, // 20 gwei
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: 5e9, // 5 gwei
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "maxFeePerGas should positively impact score");

        // Case: congestionBuyIn positively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 1e17, // 0.1 ETH
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "congestionBuyIn should positively impact score");

        // Case: solverCount negatively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 2,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "solverCount should negatively impact score");

        // Case: bidFactor positively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 120,
            rep: rep
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: rep
        });
        assertTrue(highScore > lowScore, "bidFactor should positively impact score");

        // Case: rep.successCost positively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: Reputation({
                successCost: 1e17, // 0.1 ETH on winning solverOps
                failureCost: 0 // no failing solverOps
             })
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: Reputation({
                successCost: 0, // 0 ETH on winning solverOps
                failureCost: 0 // no failing solverOps
             })
        });
        assertTrue(highScore > lowScore, "rep.successCost should positively impact score");

        // Case: rep.failureCost negatively impacts score
        highScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: Reputation({
                successCost: 0, // 0 ETH on winning solverOps
                failureCost: 0 // no failing solverOps
             })
        });
        lowScore = flOnlineMock.calculateWeightedScore({
            totalGas: defaultGasLimit,
            solverOpGas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            congestionBuyIn: 0,
            solverCount: 1,
            bidFactor: 100,
            rep: Reputation({
                successCost: 0, // 0 ETH on winning solverOps
                failureCost: 1e17 // 0.1 ETH on failing solverOps
             })
        });
        assertTrue(highScore > lowScore, "rep.failureCost should negatively impact score");
    }

    // ---------------------------------------------------- //
    //               Congestion Buy-In Tests                //
    // ---------------------------------------------------- //

    function testFLOnline_RefundCongestionBuyIns() public {
        uint256 congestionBuyIn = 1e17;
        _setUpUser(defaultSwapIntent);

        // Solver registers with 1e17 congestion buy-in
        SolverOperation memory solverOp = _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH, congestionBuyIn);
        uint256 solverBalanceBefore = address(solverOneEOA).balance;

        assertTrue(block.number < solverOp.deadline, "should not be past solverOp.deadline");

        vm.prank(solverOneEOA);
        vm.expectRevert(FastLaneOnlineErrors.SolverGateway_RefundCongestionBuyIns_DeadlineNotPassed.selector);
        flOnline.refundCongestionBuyIns(solverOp);

        uint256 snapshotId = vm.snapshot();

        _doFastOnlineSwapWithChecks({
            winningSolverEOA: solverOneEOA,
            winningSolver: solverOp.solver,
            solverCount: 1,
            swapCallShouldSucceed: true
        });

        // Skip forward past solverOp.deadline
        vm.roll(solverOp.deadline + 1);
        assertTrue(block.number > solverOp.deadline, "now should be past solverOp.deadline");

        vm.prank(solverOneEOA);
        flOnline.refundCongestionBuyIns(solverOp);

        assertEq(address(solverOneEOA).balance, solverBalanceBefore, "solver should not get refund if executed");

        vm.revertTo(snapshotId); // go back to before the swap

        // Skip forward past solverOp.deadline
        vm.roll(solverOp.deadline + 1);
        assertTrue(block.number > solverOp.deadline, "now should be past solverOp.deadline");

        vm.prank(solverOneEOA);
        flOnline.refundCongestionBuyIns(solverOp);

        assertEq(address(solverOneEOA).balance, solverBalanceBefore + congestionBuyIn, "cbi not refunded");
    }

    function testFLOnline_ProcessCongestionRake() public {
        bytes32 userOpHash = keccak256("userOpHash");
        uint256 aggCongestionBuyIn = 5e17; // 0.5 ETH
        uint256 atlasBundlerRebate = 1e17; // 0.1 ETH
        uint256 snapshotId;
        uint256 netGasRefund;
        uint256 expectedRake;
        uint256 protocolGuildBefore = protocolGuildWallet.balance;

        // Scenario setup for mock testing:
        // - Solver gave a congestion buy-in of 0.5 ETH, which is also the FLO starting balance
        // - FLOnline received a 0.1 ETH gas rebate after the metacall from Atlas

        flOnlineMock.setAggCongestionBuyIn(userOpHash, aggCongestionBuyIn);
        deal(address(flOnlineMock), aggCongestionBuyIn + atlasBundlerRebate);
        assertEq(flOnlineMock.rake(), 0, "rake should start at 0");
        assertEq(flOnlineMock.aggCongestionBuyIn(userOpHash), aggCongestionBuyIn, "aggCongestionBuyIn should be set");

        snapshotId = vm.snapshot(); // checkpoint to start tests from

        // Case: solverSuccessful = true
        // -> rake increases by: (atlasGasRebate + aggCongestionBuyIn) * rake cut
        // -> netGasRefund should be: atlasGasRebate + aggCongestionBuyIn - rake from both
        // -> aggCongestionBuyIn[userOpHash] set to 0
        // -> no funds sent to protocol guild

        netGasRefund = flOnlineMock.processCongestionRake({
            startingBalance: aggCongestionBuyIn,
            userOpHash: userOpHash,
            solversSuccessful: true
        });

        expectedRake = (aggCongestionBuyIn + atlasBundlerRebate) * 33 / 100; // 33% rake cut
        assertEq(flOnlineMock.rake(), expectedRake, "rake should increase correctly");
        assertEq(
            netGasRefund,
            aggCongestionBuyIn + atlasBundlerRebate - expectedRake,
            "netGasRefund expected: gas rebate + aggCongestionBuyIn - rake"
        );
        assertEq(flOnlineMock.aggCongestionBuyIn(userOpHash), 0, "aggCongestionBuyIn should be set to 0");
        assertEq(protocolGuildWallet.balance, protocolGuildBefore, "no funds should be sent to protocol guild");

        vm.revertTo(snapshotId); // restart from checkpoint

        // Case: solverSuccessful = false
        // -> rake increases by: (atlasGasRebate only) * rake cut
        // -> netGasRefund should be: atlasGasRebate - rake
        // -> aggCongestionBuyIn[userOpHash] set to 0
        // -> protocol guild gets congestionBuyIn funds

        netGasRefund = flOnlineMock.processCongestionRake({
            startingBalance: aggCongestionBuyIn,
            userOpHash: userOpHash,
            solversSuccessful: false
        });

        expectedRake = atlasBundlerRebate * 33 / 100; // 33% rake cut
        assertEq(flOnlineMock.rake(), expectedRake, "rake should increase correctly");
        assertEq(netGasRefund, atlasBundlerRebate - expectedRake, "netGasRefund expected: gas rebate - rake");
        assertEq(flOnlineMock.aggCongestionBuyIn(userOpHash), 0, "aggCongestionBuyIn should be set to 0");
        assertEq(
            protocolGuildWallet.balance, protocolGuildBefore + aggCongestionBuyIn, "protocol guild should get funds"
        );
    }

    // ---------------------------------------------------- //
    //                  Other Unit Tests                    //
    // ---------------------------------------------------- //

    function testFLOnline_SortSolverOps_SortsInDescendingOrderOfBid() public {
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        SolverOperation[] memory solverOpsOut;

        // Empty array should return empty array
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut.length, 0, "Not length 0");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "Empty array, not sorted");

        // 1 solverOp array should return same array
        solverOps = new SolverOperation[](1);
        solverOps[0].bidAmount = 1;
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut[0].bidAmount, solverOps[0].bidAmount, "1 solverOp array, not same array");
        assertEq(solverOpsOut.length, 1, "Not length 1");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "1 solverOp array, not sorted");

        // 2 solverOps array should return same array if already sorted
        solverOps = new SolverOperation[](2);
        solverOps[0].bidAmount = 2;
        solverOps[1].bidAmount = 1;
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut[0].bidAmount, solverOps[0].bidAmount, "2 solverOps array, [0] bid mismatch");
        assertEq(solverOpsOut[1].bidAmount, solverOps[1].bidAmount, "2 solverOps array, [1] bid mismatch");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "2 solverOps array, not sorted");

        // 2 solverOps array should return sorted array if not sorted
        solverOps[0].bidAmount = 1;
        solverOps[1].bidAmount = 2;
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut[0].bidAmount, solverOps[1].bidAmount, "2 solverOps array, [1] should be in [0]");
        assertEq(solverOpsOut[1].bidAmount, solverOps[0].bidAmount, "2 solverOps array, [0] should be in [1]");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "2 solverOps array, not sorted");

        // 5 solverOps already sorted (descending) should return same array
        solverOps = new SolverOperation[](5);
        for (uint256 i = 0; i < 5; i++) {
            solverOps[i].bidAmount = 5 - i;
        }
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(solverOpsOut[i].bidAmount, solverOps[i].bidAmount, "5 solverOps sorted, bid mismatch");
        }
        assertEq(solverOpsOut.length, 5, "Not length 5, sorted");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "5 solverOps array, not sorted");

        // 5 solverOps in ascending order should return sorted (descending) array
        for (uint256 i = 0; i < 5; i++) {
            solverOps[i].bidAmount = i + 1;
        }
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(solverOpsOut[i].bidAmount, 5 - i, "5 solverOps opposite order, bid mismatch");
        }
        assertEq(solverOpsOut.length, 5, "Not length 5, opposite order");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "5 solverOps opposite order, not sorted");

        // 5 solverOps in random order should return sorted (descending) array
        solverOps[0].bidAmount = 3;
        solverOps[1].bidAmount = 1;
        solverOps[2].bidAmount = 5;
        solverOps[3].bidAmount = 2;
        solverOps[4].bidAmount = 4;
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut.length, 5, "Not length 5, random order");
        assertTrue(_isSolverOpsSorted(solverOpsOut), "5 solverOps random order, not sorted");
    }

    function testFLOnline_SortSolverOps_DropsZeroBids() public {
        SolverOperation[] memory solverOps = new SolverOperation[](5);
        SolverOperation[] memory solverOpsOut;

        // 5 solverOps with 0 bid should return empty array
        for (uint256 i = 0; i < 5; i++) {
            solverOps[i].bidAmount = 0;
        }
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);
        assertEq(solverOpsOut.length, 0, "5 solverOps with 0 bid, not empty");

        // 5 solverOps with 0 bid mixed with non-zero bids should return sorted array with 0 bids dropped
        solverOps[0].bidAmount = 0;
        solverOps[1].bidAmount = 1;
        solverOps[2].bidAmount = 0;
        solverOps[3].bidAmount = 2;
        solverOps[4].bidAmount = 0;
        solverOpsOut = flOnlineMock.sortSolverOps(solverOps);

        assertEq(solverOpsOut.length, 2, "5 solverOps with 0 bid mixed, not length 2");
        assertEq(solverOpsOut[0].bidAmount, 2, "5 solverOps with 0 bid mixed, [0] bid mismatch");
        assertEq(solverOpsOut[1].bidAmount, 1, "5 solverOps with 0 bid mixed, [1] bid mismatch");
    }

    function testFLOnline_SetWinningSolver_DoesNotUpdateForUnexpectedCaller() public {
        (address userEE,,) = atlas.getExecutionEnvironment(userEOA, address(flOnlineMock));
        assertEq(flOnlineMock.getWinningSolver(), address(0), "winningSolver should start empty");

        vm.prank(userEOA);
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 1 - winningSolver should be empty");

        vm.prank(governanceEOA);
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 2 - winningSolver should be empty");

        vm.prank(solverOneEOA);
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 3 - winningSolver should be empty");

        vm.prank(address(flOnlineMock));
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 4 - winningSolver should be empty");

        vm.prank(address(atlas));
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 5 - winningSolver should be empty");

        vm.prank(userEE); // userEE is valid caller, but still wont set if userEOA is not in userLock
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), address(0), "err 6 - winningSolver should be empty");

        // Only valid caller: the user's EE when userEOA is stored in userLock
        flOnlineMock.setUserLock(userEOA);
        assertEq(flOnlineMock.getUserLock(), userEOA, "userLock should be userEOA");
        vm.prank(userEE);
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), solverOneEOA, "winningSolver should be solverOneEOA");
    }

    function testFLOnline_SetWinningSolver_DoesNotUpdateIfAlreadySet() public {
        (address userEE,,) = atlas.getExecutionEnvironment(userEOA, address(flOnlineMock));
        assertEq(flOnlineMock.getWinningSolver(), address(0), "winningSolver should start empty");

        flOnlineMock.setUserLock(userEOA);
        vm.prank(userEE);
        flOnlineMock.setWinningSolver(solverOneEOA);
        assertEq(flOnlineMock.getWinningSolver(), solverOneEOA, "winningSolver should be solverOneEOA");

        // winningSolver already set, should not update
        vm.prank(userEE);
        flOnlineMock.setWinningSolver(address(1));
        assertEq(flOnlineMock.getWinningSolver(), solverOneEOA, "winningSolver should still be solverOneEOA");
    }

    function testFLOnline_WithdrawRake() public {
        deal(address(flOnlineMock), 1e18);
        flOnlineMock.setRake(1e18);
        uint256 rakeBefore = flOnlineMock.rake();
        uint256 callerBalanceBefore;
        assertEq(rakeBefore, 1e18, "rake should start at 1 ETH");

        callerBalanceBefore = address(userEOA).balance;
        vm.prank(userEOA);
        vm.expectRevert(FastLaneOnlineErrors.OuterHelpers_NotMadJustDisappointed.selector);
        flOnlineMock.makeThogardsWifeHappy();

        assertEq(flOnlineMock.rake(), rakeBefore, "rake should not change if withdraw fails");
        assertEq(address(userEOA).balance, callerBalanceBefore, "caller balance should not change if withdraw fails");

        callerBalanceBefore = address(governanceEOA).balance;
        vm.prank(governanceEOA);
        flOnlineMock.makeThogardsWifeHappy();

        assertEq(flOnlineMock.rake(), 0, "rake should be 0 after withdraw");
        assertEq(address(governanceEOA).balance, callerBalanceBefore + rakeBefore, "governance balance should increase");
    }

    function testFLOnline_BaselineEstablishedEvent() public {
        _setUpUser(defaultSwapIntent);
        _setUpSolver(solverOneEOA, solverOnePK, goodSolverBidETH);

        uint256 expectedBaselineAmountOut = _doBaselineCallWithChecksThenRevertChanges({ shouldSucceed: true });

        vm.startPrank(userEOA);
        vm.expectEmit(false, false, false, true, address(executionEnvironment));
        emit FastLaneOnlineInner.BaselineEstablished(defaultSwapIntent.minAmountUserBuys, expectedBaselineAmountOut);
        (bool result,) = address(flOnline).call{ gas: args.gas + 1000, value: args.msgValue }(
            abi.encodeCall(flOnline.fastOnlineSwap, (args.userOp))
        );
        assertTrue(result, "fastOnlineSwap should have succeeded");
        vm.stopPrank();
    }

    // ---------------------------------------------------- //
    //                        Helpers                       //
    // ---------------------------------------------------- //

    function _doFastOnlineSwapWithChecks(
        address winningSolverEOA,
        address winningSolver,
        uint256 solverCount,
        bool swapCallShouldSucceed
    )
        internal
    {
        bool nativeTokenIn = args.swapIntent.tokenUserSells == NATIVE_TOKEN;
        bool solverWon = winningSolver != address(0);

        beforeVars.userTokenOutBalance = _balanceOf(args.swapIntent.tokenUserBuys, userEOA);
        beforeVars.userTokenInBalance = _balanceOf(args.swapIntent.tokenUserSells, userEOA);
        beforeVars.solverTokenOutBalance = _balanceOf(args.swapIntent.tokenUserBuys, winningSolver);
        beforeVars.solverTokenInBalance = _balanceOf(args.swapIntent.tokenUserSells, winningSolver);
        beforeVars.atlasGasSurcharge = atlas.cumulativeSurcharge();
        beforeVars.solverOneRep = flOnline.solverReputation(solverOneEOA);
        beforeVars.solverTwoRep = flOnline.solverReputation(solverTwoEOA);
        beforeVars.solverThreeRep = flOnline.solverReputation(solverThreeEOA);

        uint256 txGasUsed;
        uint256 estAtlasGasSurcharge = gasleft(); // Reused below during calculations

        // Do the actual fastOnlineSwap call
        vm.prank(userEOA);
        (bool result,) = address(flOnline).call{ gas: args.gas + 1000, value: args.msgValue }(
            abi.encodeCall(flOnline.fastOnlineSwap, (args.userOp))
        );

        // Calculate estimated Atlas gas surcharge taken from call above
        txGasUsed = estAtlasGasSurcharge - gasleft();
        estAtlasGasSurcharge = txGasUsed * defaultGasPrice * atlas.ATLAS_SURCHARGE_RATE() / atlas.SCALE();

        assertTrue(
            result == swapCallShouldSucceed,
            swapCallShouldSucceed ? "fastOnlineSwap should have succeeded" : "fastOnlineSwap should have reverted"
        );

        // Return early if transaction expected to revert. Balance checks below would otherwise fail.
        if (!swapCallShouldSucceed) return;

        if (solverCount == 0) {
            // If zero solvers, no surcharge taken
            assertEq(atlas.cumulativeSurcharge(), beforeVars.atlasGasSurcharge, "Atlas gas surcharge should not change");
        } else if (solverWon) {
            // Check Atlas gas surcharge earned is within 15% of the estimated gas surcharge
            assertApproxEqRel(
                atlas.cumulativeSurcharge() - beforeVars.atlasGasSurcharge,
                estAtlasGasSurcharge,
                ERR_MARGIN,
                "Atlas gas surcharge not within estimated range (solver won)"
            );
        } else {
            // If all solvers fail, surcharge taken only on gas cost of solverOps failed due to solver fault
            assertApproxEqRel(
                atlas.cumulativeSurcharge() - beforeVars.atlasGasSurcharge,
                SURCHARGE_PER_SOLVER_IF_ALL_FAIL * solverCount,
                ERR_MARGIN,
                "Atlas gas surcharge not within estimated range (solvers failed)"
            );
        }

        // Check user's balances changed as expected
        assertTrue(
            _balanceOf(args.swapIntent.tokenUserBuys, userEOA)
                >= beforeVars.userTokenOutBalance + args.swapIntent.minAmountUserBuys,
            "User did not recieve enough tokenOut"
        );

        if (nativeTokenIn && solverWon) {
            // Allow for small error margin due to gas refund from winning solver
            uint256 buffer = 1e17; // 0.1 ETH buffer as base for error margin comparison
            uint256 expectedBalanceAfter = beforeVars.userTokenInBalance - args.swapIntent.amountUserSells;

            assertApproxEqRel(
                _balanceOf(args.swapIntent.tokenUserSells, userEOA) + buffer,
                expectedBalanceAfter + buffer,
                0.01e18, // error marin: 1% of the 0.1 ETH buffer
                "User did not send enough native tokenIn"
            );
        } else {
            assertEq(
                _balanceOf(args.swapIntent.tokenUserSells, userEOA),
                beforeVars.userTokenInBalance - args.swapIntent.amountUserSells,
                "User did not send enough ERC20 tokenIn"
            );
        }

        // If winning solver, check balances changed as expected
        if (winningSolver != address(0)) {
            assertTrue(
                _balanceOf(args.swapIntent.tokenUserBuys, winningSolver)
                    <= beforeVars.solverTokenOutBalance - args.swapIntent.minAmountUserBuys,
                "Solver did not send enough tokenOut"
            );
            assertEq(
                _balanceOf(args.swapIntent.tokenUserSells, winningSolver),
                beforeVars.solverTokenInBalance + args.swapIntent.amountUserSells,
                "Solver did not recieve enough tokenIn"
            );
        }

        // Check reputation of all solvers involved
        if (solverCount > 0) {
            _checkReputationChanges({
                name: "solverOneEOA",
                repBefore: beforeVars.solverOneRep,
                repAfter: flOnline.solverReputation(solverOneEOA),
                won: winningSolverEOA == solverOneEOA,
                executionAttempted: attempted.solverOne
            });
        }
        if (solverCount > 1) {
            _checkReputationChanges({
                name: "solverTwoEOA",
                repBefore: beforeVars.solverTwoRep,
                repAfter: flOnline.solverReputation(solverTwoEOA),
                won: winningSolverEOA == solverTwoEOA,
                executionAttempted: attempted.solverTwo
            });
        }
        if (solverCount > 2) {
            _checkReputationChanges({
                name: "solverThreeEOA",
                repBefore: beforeVars.solverThreeRep,
                repAfter: flOnline.solverReputation(solverThreeEOA),
                won: winningSolverEOA == solverThreeEOA,
                executionAttempted: attempted.solverThree
            });
        }
    }

    // NOTE: This MUST be called at the start of each end-to-end test, to set up args
    function _setUpUser(SwapIntent memory swapIntent) internal {
        // always start with 0.01 ETH for gas/bundler fees
        uint256 userStartNativeTokenBalance = 1e16;

        // Add tokens if user is selling native token
        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            userStartNativeTokenBalance += swapIntent.amountUserSells;
        } else {
            // Otherwise deal user the ERC20 they are selling, and approve Atlas to take it
            deal(swapIntent.tokenUserSells, userEOA, swapIntent.amountUserSells);
            vm.prank(userEOA);
            IERC20(swapIntent.tokenUserSells).approve(address(atlas), swapIntent.amountUserSells);
        }

        // Burn all user's tokens they are buying, for clearer balance checks
        // Exception: if user is buying native token, they still need some to pay gas
        if (swapIntent.tokenUserBuys != NATIVE_TOKEN) {
            deal(swapIntent.tokenUserBuys, userEOA, 0);
        }

        // Give user the net amount of native token they need to start with
        deal(userEOA, userStartNativeTokenBalance);

        // Build the other args data around the user's SwapIntent
        args = _buildFastOnlineSwapArgs(swapIntent);
    }

    function _buildFastOnlineSwapArgs(SwapIntent memory swapIntent)
        internal
        returns (FastOnlineSwapArgs memory newArgs)
    {
        bool nativeTokenIn = swapIntent.tokenUserSells == NATIVE_TOKEN;
        newArgs.swapIntent = swapIntent;
        newArgs.baselineCall = _buildBaselineCall(swapIntent, true); // should succeed

        (newArgs.userOp, newArgs.userOpHash) = flOnline.getUserOperationAndHash({
            swapper: userEOA,
            swapIntent: newArgs.swapIntent,
            baselineCall: newArgs.baselineCall,
            deadline: defaultDeadlineBlock,
            gas: defaultGasLimit,
            maxFeePerGas: defaultGasPrice,
            msgValue: nativeTokenIn ? swapIntent.amountUserSells : 0
        });

        // User signs userOp
        (sig.v, sig.r, sig.s) = vm.sign(userPK, newArgs.userOpHash);
        newArgs.userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        newArgs.deadline = defaultDeadlineBlock;
        newArgs.gas = defaultGasLimit;
        newArgs.maxFeePerGas = defaultGasPrice;

        // Add amountUserSells of ETH to the msg.value of the fastOnlineSwap call
        if (nativeTokenIn) newArgs.msgValue = swapIntent.amountUserSells;
    }

    function _buildBaselineCall(
        SwapIntent memory swapIntent,
        bool shouldSucceed
    )
        internal
        view
        returns (BaselineCall memory)
    {
        bytes memory baselineData;
        uint256 value;
        uint256 amountOutMin = swapIntent.minAmountUserBuys;
        address[] memory path = new address[](2);
        path[0] = swapIntent.tokenUserSells;
        path[1] = swapIntent.tokenUserBuys;

        // Make amountOutMin way too high to cause baseline call to fail
        if (!shouldSucceed) amountOutMin *= 100; // 100x original amountOutMin

        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            path[0] = WETH_ADDRESS;
            value = swapIntent.amountUserSells;
            baselineData = abi.encodeCall(
                routerV2.swapExactETHForTokens,
                (
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    defaultDeadlineTimestamp // deadline
                )
            );
        } else if (swapIntent.tokenUserBuys == NATIVE_TOKEN) {
            path[1] = WETH_ADDRESS;
            baselineData = abi.encodeCall(
                routerV2.swapExactTokensForETH,
                (
                    swapIntent.amountUserSells, // amountIn
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    defaultDeadlineTimestamp // deadline
                )
            );
        } else {
            baselineData = abi.encodeCall(
                routerV2.swapExactTokensForTokens,
                (
                    swapIntent.amountUserSells, // amountIn
                    amountOutMin, // amountOutMin
                    path, // path = [tokenUserSells, tokenUserBuys]
                    executionEnvironment, // to
                    defaultDeadlineTimestamp // deadline
                )
            );
        }

        return BaselineCall({ to: address(routerV2), data: baselineData, value: value });
    }

    function _setUpSolver(address solverEOA, uint256 solverPK, uint256 bidAmount) internal returns (address solver) {
        (solver,) = _setUpSolver(solverEOA, solverPK, bidAmount, 0, bytes4(0));
        return solver;
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        uint256 congestionBuyIn
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        (, solverOp) = _setUpSolver(solverEOA, solverPK, bidAmount, congestionBuyIn, bytes4(0));
        return solverOp;
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        bytes4 addSolverOpError
    )
        internal
        returns (address solver)
    {
        (solver,) = _setUpSolver(solverEOA, solverPK, bidAmount, 0, addSolverOpError);
        return solver;
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        uint256 congestionBuyIn,
        bytes4 addSolverOpError
    )
        internal
        returns (address solverContract, SolverOperation memory solverOp)
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

        // Deploy RFQ solver contract
        bytes32 salt = keccak256(abi.encodePacked(address(flOnline), solverEOA, bidAmount, vm.getNonce(solverEOA)));
        FLOnlineRFQSolver solver = new FLOnlineRFQSolver{ salt: salt }(WETH_ADDRESS, address(atlas));

        // Create signed solverOp
        solverOp = _buildSolverOp(solverEOA, solverPK, address(solver), bidAmount);

        // Give solver contract enough tokenOut to fulfill user's SwapIntent
        if (args.swapIntent.tokenUserBuys != NATIVE_TOKEN) {
            deal(args.swapIntent.tokenUserBuys, address(solver), bidAmount);
        } else {
            deal(address(solver), bidAmount);
        }
        if (congestionBuyIn > 0) deal(solverEOA, congestionBuyIn);

        // Register solverOp in FLOnline in frontrunning tx
        if (addSolverOpError != bytes4(0)) vm.expectRevert(addSolverOpError);
        flOnline.addSolverOp{ value: congestionBuyIn }({ userOp: args.userOp, solverOp: solverOp });

        // Return early if addSolverOp expected to revert
        if (addSolverOpError != bytes4(0)) return (address(0), solverOp);
        vm.stopPrank();

        if (solverEOA == solverOneEOA) attempted.solverOne = true;
        if (solverEOA == solverTwoEOA) attempted.solverTwo = true;
        if (solverEOA == solverThreeEOA) attempted.solverThree = true;

        // Returns the address of the solver contract deployed here
        return (address(solver), solverOp);
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
            gas: flOnline.MAX_SOLVER_GAS() - 1,
            maxFeePerGas: defaultGasPrice,
            deadline: defaultDeadlineBlock,
            solver: solverContract,
            control: address(flOnline),
            userOpHash: args.userOpHash,
            bidToken: args.swapIntent.tokenUserBuys,
            bidAmount: bidAmount,
            data: abi.encodeCall(FLOnlineRFQSolver.fulfillRFQ, (args.swapIntent)),
            signature: new bytes(0)
        });
        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    // Returns the amount of tokensOut received, which forms the baseline solvers should beat
    function _doBaselineCallWithChecksThenRevertChanges(bool shouldSucceed) internal returns (uint256) {
        uint256 snapshotId = vm.snapshot(); // Everything below this gets reverted after function ends

        uint256 eeTokenInBefore = _balanceOf(args.swapIntent.tokenUserSells, executionEnvironment);
        uint256 eeTokenOutBefore = _balanceOf(args.swapIntent.tokenUserBuys, executionEnvironment);
        uint256 eeTokenOutAfter;

        if (eeTokenInBefore < args.swapIntent.amountUserSells) {
            if (args.swapIntent.tokenUserSells == NATIVE_TOKEN) {
                deal(executionEnvironment, args.swapIntent.amountUserSells);
            } else {
                deal(args.swapIntent.tokenUserSells, executionEnvironment, args.swapIntent.amountUserSells);
            }

            eeTokenInBefore = _balanceOf(args.swapIntent.tokenUserSells, executionEnvironment);
        }

        bool success;
        vm.startPrank(executionEnvironment);

        if (args.swapIntent.tokenUserSells != NATIVE_TOKEN) {
            IERC20(args.swapIntent.tokenUserSells).approve(args.baselineCall.to, args.swapIntent.amountUserSells);
            (success,) = args.baselineCall.to.call(args.baselineCall.data);
        } else {
            (success,) = args.baselineCall.to.call{ value: args.swapIntent.amountUserSells }(args.baselineCall.data);
        }

        vm.stopPrank();

        assertTrue(
            success == shouldSucceed,
            shouldSucceed ? "Baseline call should have succeeded" : "Baseline call should have reverted"
        );

        if (!shouldSucceed) {
            vm.revertTo(snapshotId);
            return 0;
        }

        eeTokenOutAfter = _balanceOf(args.swapIntent.tokenUserBuys, executionEnvironment);
        assertTrue(
            eeTokenOutAfter >= eeTokenOutBefore + args.swapIntent.minAmountUserBuys,
            "EE did not recieve expected tokenOut in baseline call"
        );
        assertEq(
            _balanceOf(args.swapIntent.tokenUserSells, executionEnvironment),
            eeTokenInBefore - args.swapIntent.amountUserSells,
            "EE did not send expected tokenIn in baseline call"
        );
        //Revert back to state before baseline call was done
        vm.revertTo(snapshotId);
        return eeTokenOutAfter - eeTokenOutBefore;
    }

    function _setBaselineCallToRevert() internal {
        // should not succeed
        args.baselineCall = _buildBaselineCall(args.swapIntent, false);

        // Need to update the userOp with changes to baseline call
        (args.userOp, args.userOpHash) = flOnline.getUserOperationAndHash({
            swapper: userEOA,
            swapIntent: args.swapIntent,
            baselineCall: args.baselineCall,
            deadline: defaultDeadlineBlock,
            gas: defaultGasLimit,
            maxFeePerGas: defaultGasPrice,
            msgValue: 0
        });

        // User signs userOp
        (sig.v, sig.r, sig.s) = vm.sign(userPK, args.userOpHash);
        args.userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    // Checks the solverOps array is sorted in descending order of bidAmount
    function _isSolverOpsSorted(SolverOperation[] memory solverOps) internal pure returns (bool) {
        if (solverOps.length < 2) return true;
        for (uint256 i = 0; i < solverOps.length - 1; i++) {
            if (solverOps[i].bidAmount < solverOps[i + 1].bidAmount) {
                return false;
            }
        }
        return true;
    }

    function _checkReputationChanges(
        string memory name,
        Reputation memory repBefore,
        Reputation memory repAfter,
        bool won,
        bool executionAttempted
    )
        internal
        pure
    {
        if (executionAttempted) {
            if (won) {
                assertGt(
                    repAfter.successCost,
                    repBefore.successCost,
                    string.concat(name, " successCost not updated correctly")
                );
                assertEq(
                    repAfter.failureCost,
                    repBefore.failureCost,
                    string.concat(name, " failureCost should not have changed")
                );
            } else {
                assertGt(
                    repAfter.failureCost,
                    repBefore.failureCost,
                    string.concat(name, " failureCost not updated correctly")
                );
                assertEq(
                    repAfter.successCost,
                    repBefore.successCost,
                    string.concat(name, " successCost should not have changed")
                );
            }
        } else {
            // not attempted due to not being included in solverOps, or due to having a lower bid than the winning
            // solver and thus a higher index in the sorted array. No change in reputation expected.
            assertEq(
                repAfter.successCost, repBefore.successCost, string.concat(name, " successCost should not have changed")
            );
            assertEq(
                repAfter.failureCost, repBefore.failureCost, string.concat(name, " failureCost should not have changed")
            );
        }
    }

    // balanceOf helper that supports ERC20 and native token
    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract FLOnlineRFQSolver is SolverBase {
    address internal constant NATIVE_TOKEN = address(0);
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

    function fulfillRFQ(SwapIntent calldata swapIntent) public view onlySelf {
        require(s_shouldSucceed, "Solver failed intentionally");

        if (swapIntent.tokenUserSells == NATIVE_TOKEN) {
            require(
                address(this).balance >= swapIntent.amountUserSells, "Did not receive expected amount of tokenUserBuys"
            );
        } else {
            require(
                IERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= swapIntent.amountUserSells,
                "Did not receive expected amount of tokenUserSells"
            );
        }
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

// Mock contract to expose internal FLOnline functions for unit testing
contract MockFastLaneOnline is FastLaneOnlineOuter {
    constructor(address atlas, address protocolGuildWallet) FastLaneOnlineOuter(atlas, protocolGuildWallet) { }

    // ---------------------------------------------------- //
    //                  OuterHelpers.sol                    //
    // ---------------------------------------------------- //

    function sortSolverOps(SolverOperation[] memory solverOps) external pure returns (SolverOperation[] memory) {
        return _sortSolverOps(solverOps);
    }

    function processCongestionRake(
        uint256 startingBalance,
        bytes32 userOpHash,
        bool solversSuccessful
    )
        external
        returns (uint256 netGasRefund)
    {
        netGasRefund = _processCongestionRake(startingBalance, userOpHash, solversSuccessful);
    }

    function setAggCongestionBuyIn(bytes32 userOpHash, uint256 newAggCongestionBuyIn) external {
        S_aggCongestionBuyIn[userOpHash] = newAggCongestionBuyIn;
    }

    function setRake(uint256 newRake) external {
        S_rake = newRake;
    }

    // ---------------------------------------------------- //
    //                 SolverGateway.sol                    //
    // ---------------------------------------------------- //

    function SLIPPAGE_BASE() external pure returns (uint256) {
        return _SLIPPAGE_BASE;
    }

    function GLOBAL_MAX_SLIPPAGE() external pure returns (uint256) {
        return _GLOBAL_MAX_SLIPPAGE;
    }

    function calculateBidFactor(uint256 bidAmount, uint256 minAmountUserBuys) external pure returns (uint256) {
        return _calculateBidFactor(bidAmount, minAmountUserBuys);
    }

    function calculateWeightedScore(
        uint256 totalGas,
        uint256 solverOpGas,
        uint256 maxFeePerGas,
        uint256 congestionBuyIn,
        uint256 solverCount,
        uint256 bidFactor,
        Reputation memory rep
    )
        external
        pure
        returns (uint256)
    {
        return
            _calculateWeightedScore(totalGas, solverOpGas, maxFeePerGas, congestionBuyIn, solverCount, bidFactor, rep);
    }

    function pushSolverOp(bytes32 userOpHash, bytes32 solverOpHash) external {
        _pushSolverOp(userOpHash, solverOpHash);
    }

    function replaceSolverOp(bytes32 userOpHash, bytes32 solverOpHash, uint256 replacedIndex) external {
        _replaceSolverOp(userOpHash, solverOpHash, replacedIndex);
    }

    function evaluateForInclusion(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        external
        view
        returns (bool pushAsNew, bool replaceExisting, uint256)
    {
        return _evaluateForInclusion(userOp, solverOp);
    }

    // ---------------------------------------------------- //
    //                  BaseStorage.sol                     //
    // ---------------------------------------------------- //

    function getUserLock() external view returns (address) {
        return _getUserLock();
    }

    function setUserLock(address user) external {
        _setUserLock(user);
    }

    function getWinningSolver() external view returns (address) {
        return _getWinningSolver();
    }
}
