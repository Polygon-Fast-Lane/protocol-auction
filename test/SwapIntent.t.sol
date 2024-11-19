// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";

import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { DAppConfig } from "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/DAppOperation.sol";

import {
    SwapIntentDAppControl,
    SwapIntent,
    Condition
} from "../src/contracts/examples/intents-example/SwapIntentDAppControl.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";

interface IUniV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        returns (uint256[] memory amounts);
}

contract SwapIntentTest is BaseTest {
    SwapIntentDAppControl public swapIntentControl;
    TxBuilder public txBuilder;
    Sig public sig;

    function setUp() public virtual override {
        BaseTest.setUp();

        // Deploy new SwapIntent Control from new gov and initialize in Atlas
        vm.startPrank(governanceEOA);
        swapIntentControl = new SwapIntentDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(swapIntentControl));
        vm.stopPrank();

        txBuilder = new TxBuilder({
            _control: address(swapIntentControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        deal(WETH_ADDRESS, userEOA, 10e18);
    }

    function testAtlasSwapIntentWithBasicRFQ_GasCheck_SkipCoverage() public {
        // Swap 10 WETH for 20 DAI
        UserCondition userCondition = new UserCondition();

        Condition[] memory conditions = new Condition[](2);
        conditions[0] =
            Condition({ antecedent: address(userCondition), context: abi.encodeCall(UserCondition.isLessThanFive, 3) });
        conditions[1] =
            Condition({ antecedent: address(userCondition), context: abi.encodeCall(UserCondition.isLessThanFive, 4) });

        SwapIntent memory swapIntent = SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: 20e18,
            tokenUserSells: WETH_ADDRESS,
            amountUserSells: 10e18,
            auctionBaseCurrency: address(0),
            conditions: conditions
        });

        // Solver deploys the RFQ solver contract (defined at bottom of this file)
        vm.startPrank(solverOneEOA);
        SimpleRFQSolver rfqSolver = new SimpleRFQSolver(WETH_ADDRESS, address(atlas));
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1 ether);
        vm.stopPrank();

        // Give 20 DAI to RFQ solver contract
        deal(DAI_ADDRESS, address(rfqSolver), swapIntent.amountUserBuys);
        assertEq(DAI.balanceOf(address(rfqSolver)), swapIntent.amountUserBuys, "Did not give enough DAI to solver");

        // Input params for Atlas.metacall() - will be populated below
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, txBuilder.control());
        console.log("executionEnvironment", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // userOpData is used in delegatecall from exec env to control, calling preOpsCall
        // first 4 bytes are "userSelector" param in preOpsCall in DAppControl - swap() selector
        // rest of data is "userData" param

        // swap(SwapIntent calldata) selector = 0x98434997
        bytes memory userOpData = abi.encodeCall(SwapIntentDAppControl.swap, swapIntent);

        // Builds the metaTx and to parts of userOp, signature still to be set
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(swapIntentControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: userOpData
        });
        userOp.sessionKey = governanceEOA;

        // User signs the userOp
        // user doees NOT sign the userOp for when they are bundling
        // (sig.v, sig.r, sig.s) = vm.sign(userPK, atlas.getUserOperationPayload(userOp));
        // userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Build solver calldata (function selector on solver contract and its params)
        bytes memory solverOpData = abi.encodeCall(SimpleRFQSolver.fulfillRFQ, (swapIntent, executionEnvironment));

        // Builds the SolverOperation
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(rfqSolver),
            bidAmount: 1e18,
            value: 0
        });

        // Solver signs the solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates dAppOp calldata after seeing rest of data
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // Frontend signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Check user token balances before
        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); // Burn all users WETH except 10 so logs are more readable
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.amountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);

        assertTrue(userWethBalanceBefore >= swapIntent.amountUserSells, "Not enough starting WETH");

        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(rfqSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(rfqSolver)));

        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");

        WETH.approve(address(atlas), swapIntent.amountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        uint256 gasLeftBefore = gasleft();

        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });

        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());
        vm.stopPrank();

        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(rfqSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(rfqSolver)));

        // Check user token balances after
        assertEq(
            WETH.balanceOf(userEOA), userWethBalanceBefore - swapIntent.amountUserSells, "Did not spend enough WETH"
        );
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function testAtlasSwapIntentWithUniswapSolver_SkipCoverage() public {
        // Swap 10 WETH for 20 DAI
        Condition[] memory conditions;

        SwapIntent memory swapIntent = SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: 20e18,
            tokenUserSells: WETH_ADDRESS,
            amountUserSells: 10e18,
            auctionBaseCurrency: address(0),
            conditions: conditions
        });

        // Solver deploys the RFQ solver contract (defined at bottom of this file)
        vm.startPrank(solverOneEOA);
        UniswapIntentSolver uniswapSolver = new UniswapIntentSolver(WETH_ADDRESS, address(atlas));
        deal(WETH_ADDRESS, address(uniswapSolver), 1e18); // 1 WETH to solver to pay bid
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1 ether);
        vm.stopPrank();

        // Input params for Atlas.metacall() - will be populated below
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, txBuilder.control());
        console.log("executionEnvironment a", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // userOpData is used in delegatecall from exec env to control, calling preOpsCall
        // first 4 bytes are "userSelector" param in preOpsCall in DAppControl - swap() selector
        // rest of data is "userData" param

        // swap(SwapIntent calldata) selector = 0x98434997
        bytes memory userOpData = abi.encodeCall(SwapIntentDAppControl.swap, swapIntent);

        // Builds the metaTx and to parts of userOp, signature still to be set
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(swapIntentControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: userOpData
        });
        userOp.sessionKey = governanceEOA;

        // User signs the userOp
        // user doees NOT sign the userOp when they are bundling
        // (sig.v, sig.r, sig.s) = vm.sign(userPK, atlas.getUserOperationPayload(userOp));
        // userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Build solver calldata (function selector on solver contract and its params)
        bytes memory solverOpData =
            abi.encodeCall(UniswapIntentSolver.fulfillWithSwap, (swapIntent, executionEnvironment));

        // Builds the SolverOperation
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(uniswapSolver),
            bidAmount: 1e18,
            value: 0
        });

        // Solver signs the solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates dAppOp calldata after seeing rest of data
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // Frontend signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Check user token balances before
        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); // Burn all users WETH except 10 so logs are more readable
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.amountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);

        assertTrue(userWethBalanceBefore >= swapIntent.amountUserSells, "Not enough starting WETH");

        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(uniswapSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(uniswapSolver)));

        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");

        WETH.approve(address(atlas), swapIntent.amountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");

        // Check solver does NOT have DAI - it must use Uniswap to get it during metacall
        assertEq(DAI.balanceOf(address(uniswapSolver)), 0, "Solver has DAI before metacall");

        // NOTE: Should metacall return something? Feels like a lot of data you might want to know about the tx
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });
        vm.stopPrank();

        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(uniswapSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(uniswapSolver)));

        // Check user token balances after
        assertEq(
            WETH.balanceOf(userEOA), userWethBalanceBefore - swapIntent.amountUserSells, "Did not spend enough WETH"
        );
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract SimpleRFQSolver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function fulfillRFQ(SwapIntent calldata swapIntent, address executionEnvironment) public {
        require(
            IERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= swapIntent.amountUserSells,
            "Did not receive enough tokenIn"
        );
        require(
            IERC20(swapIntent.tokenUserBuys).balanceOf(address(this)) >= swapIntent.amountUserBuys,
            "Not enough tokenOut to fulfill"
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

contract UniswapIntentSolver is SolverBase {
    IUniV2Router02 router = IUniV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function fulfillWithSwap(SwapIntent calldata swapIntent, address executionEnvironment) public onlySelf {
        // Checks recieved expected tokens from Atlas on behalf of user to swap
        require(
            IERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= swapIntent.amountUserSells,
            "Did not receive enough tokenIn"
        );

        address[] memory path = new address[](2);
        path[0] = swapIntent.tokenUserSells;
        path[1] = swapIntent.tokenUserBuys;

        // Attempt to sell all tokens for as many as possible of tokenUserBuys
        IERC20(swapIntent.tokenUserSells).approve(address(router), swapIntent.amountUserSells);
        router.swapExactTokensForTokens({
            amountIn: swapIntent.amountUserSells,
            amountOutMin: swapIntent.amountUserBuys, // will revert here if not enough to fulfill intent
            path: path,
            to: address(this),
            deadline: block.timestamp
        });

        // Send min tokens back to user to fulfill intent, rest are profit for solver
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

contract UserCondition {
    bool valid = true;

    function enable() external {
        valid = true;
    }

    function disable() external {
        valid = false;
    }

    function isLessThanFive(uint256 n) external view returns (bool) {
        return valid && n < 5;
    }
}
