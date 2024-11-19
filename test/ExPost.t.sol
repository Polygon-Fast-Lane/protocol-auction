// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IExecutionEnvironment } from "../src/contracts/interfaces/IExecutionEnvironment.sol";
import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { Result } from "../src/contracts/helpers/Simulator.sol";
import { V2ExPost } from "../src/contracts/examples/ex-post-mev-example/V2ExPost.sol";
import { SolverExPost } from "../src/contracts/solver/src/TestSolverExPost.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";

import "../src/contracts/types/UserOperation.sol";
import "../src/contracts/types/SolverOperation.sol";
import "../src/contracts/types/EscrowTypes.sol";
import "../src/contracts/types/LockTypes.sol";
import "../src/contracts/types/DAppOperation.sol";
import "../src/contracts/types/ConfigTypes.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { V2Helper } from "./V2Helper.sol";

contract ExPostTest is BaseTest {
    /// forge-config: default.gas_price = 15000000000
    V2ExPost public v2ExPost;
    V2Helper public helper;

    address FXS_ADDRESS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    IERC20 FXS = IERC20(FXS_ADDRESS);

    address V2_FXS_ETH = 0xecBa967D84fCF0405F6b32Bc45F4d36BfDBB2E81;
    address S2_FXS_ETH = 0x61eB53ee427aB4E007d78A9134AaCb3101A2DC23;

    address POOL_ONE = V2_FXS_ETH;
    address POOL_TWO = S2_FXS_ETH;
    address TOKEN_ZERO = FXS_ADDRESS;
    address TOKEN_ONE = WETH_ADDRESS;

    SolverExPost public solverOneXP;
    SolverExPost public solverTwoXP;

    function setUp() public virtual override {
        BaseTest.setUp();

        // Deal to user
        deal(TOKEN_ZERO, address(userEOA), 10e30);
        deal(TOKEN_ONE, address(userEOA), 10e30);

        vm.startPrank(governanceEOA);
        v2ExPost = new V2ExPost(address(atlas));
        atlasVerification.initializeGovernance(address(v2ExPost));
        vm.stopPrank();

        helper = new V2Helper(address(v2ExPost), address(atlas), address(atlasVerification));

        // Deposit ETH from Searcher1 signer to pay for searcher's gas
        vm.startPrank(solverOneEOA);
        solverOneXP = new SolverExPost(WETH_ADDRESS, address(atlas), solverOneEOA, 60);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        deal(TOKEN_ZERO, address(solverOneXP), 10e24);
        deal(TOKEN_ONE, address(solverOneXP), 10e24);

        // Deposit ETH from Searcher2 signer to pay for searcher's gas
        vm.startPrank(solverTwoEOA);
        solverTwoXP = new SolverExPost(WETH_ADDRESS, address(atlas), solverTwoEOA, 80);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        deal(TOKEN_ZERO, address(solverTwoXP), 10e24);
        deal(TOKEN_ONE, address(solverTwoXP), 10e24);
        
    }

    function test_ExPostMEV_SkipCoverage() public {

        Sig memory sig;

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        userOp.control = address(v2ExPost);
        userOp.callConfig = v2ExPost.CALL_CONFIG();

        // user does not sign their own operation when bundling
        // (v, r, s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        // userOp.signature = abi.encodePacked(r, s, v);

        SolverOperation[] memory solverOps = new SolverOperation[](2);
        bytes memory solverOpData;

        console.log("solverOneEOA WETH:", WETH.balanceOf(address(solverOneEOA)));
        console.log("solverOneXP  WETH:", WETH.balanceOf(address(solverOneXP)));

        vm.prank(address(solverOneEOA));
        atlas.bond(1 ether);

        vm.prank(address(solverTwoEOA));
        atlas.bond(1 ether);

        // First SolverOperation
        solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
        solverOps[1] = helper.buildSolverOperation(
            userOp, solverOpData, solverOneEOA, address(solverOneXP), 0, 0
        );

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[1]));
        solverOps[1].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        console.log("solverTwoEOA WETH:", WETH.balanceOf(address(solverTwoEOA)));
        console.log("solverTwoXP  WETH:", WETH.balanceOf(address(solverTwoXP)));
        
        // Second SolverOperation
        solverOpData = helper.buildV2SolverOperationData(POOL_ONE, POOL_TWO);
        solverOps[0] = helper.buildSolverOperation(
            userOp, solverOpData, solverTwoEOA, address(solverTwoXP), 0, 0
        );

        (sig.v, sig.r, sig.s) = vm.sign(solverTwoPK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        console.log("topBid before sorting", solverOps[0].bidAmount);

        solverOps = sorter.sortBids(userOp, solverOps);

        console.log("topBid after sorting ", solverOps[0].bidAmount);

        // DAppOperation call
        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));

        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        vm.startPrank(userEOA);

        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, userOp.control);
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // User must approve Atlas
        IERC20(TOKEN_ZERO).approve(address(atlas), type(uint256).max);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);

        vm.stopPrank();

        // Simulate the UserOp
        (bool simSuccess, Result simResult,) = simulator.simUserOperation(userOp);
        assertTrue(simSuccess, "userOp should succeed in simulator");

        // Simulate the first SolverOp
        SolverOperation[] memory tempSolverOps = new SolverOperation[](1);
        tempSolverOps[0] = solverOps[0];
        dAppOp = helper.buildDAppOperation(governanceEOA, userOp, tempSolverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        (simSuccess, simResult,) = simulator.simSolverCall(userOp, solverOps[0], dAppOp);
        assertEq(simSuccess, false, "solverOps[0] should fail in sim due to swap path");

        // Simulate the second SolverOp
        tempSolverOps[0] = solverOps[1];
        dAppOp = helper.buildDAppOperation(governanceEOA, userOp, tempSolverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        (simSuccess, simResult,) = simulator.simSolverCall(userOp, solverOps[1], dAppOp);
        assertEq(simSuccess, true, "solverOps[1] should succeed in simulator");

        // Simulate all SolverOps together
        dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        (simSuccess, simResult,) = simulator.simSolverCalls(userOp, solverOps, dAppOp);
        assertTrue(simSuccess, "all solverOps together should succeed in simulator");

        // address bundler = userEOA;
        vm.startPrank(userEOA);

        // uint256 userEOABalance = userEOA.balance;
        // uint256 userAtlEthBalance = atlas.balanceOf(userEOA);

        // uint256 bundlerEOABalance = bundler.balance;
        // uint256 bundlerAtlEthBalance = atlas.balanceOf(bundler);

        // uint256 solverOneEOABalance = solverOneEOA.balance;
        // uint256 solverOneAtlEthBalance = atlas.balanceOf(solverOneEOA);

        // uint256 solverTwoEOABalance = solverTwoEOA.balance;
        // uint256 solverTwoAtlEthBalance = atlas.balanceOf(solverTwoEOA);

        (bool success,) =
            address(atlas).call(abi.encodeCall(atlas.metacall, (userOp, solverOps, dAppOp, address(0))));

        if (success) {
            console.log("success!");
        } else {
            console.log("failure");
        }

        assertTrue(success);

        vm.stopPrank();

        /*
        console.log("--");
        console.log("BUNDLER:");

        uint256 newBundlerBalance = bundler.balance + atlas.balanceOf(bundler);
        uint256 bundlerTotalBalance = bundlerEOABalance + bundlerAtlEthBalance;

        if (bundler.balance >= bundlerEOABalance) {
            console.log("bundler eoa balance delta: +", bundler.balance - bundlerEOABalance);
        } else {
            console.log("bundler eoa balance delta: -", bundlerEOABalance - bundler.balance);
        }

        if (atlas.balanceOf(bundler) >= bundlerAtlEthBalance) {
            console.log("bundler atlETH balance delta: +", atlas.balanceOf(bundler) - bundlerAtlEthBalance);
        } else {
            console.log("bundler atlETH balance delta: -", bundlerAtlEthBalance - atlas.balanceOf(bundler));
        }

        if (newBundlerBalance >= bundlerTotalBalance) {
            console.log("combined bundler balance delta: +", newBundlerBalance - bundlerTotalBalance);
        } else {
            console.log("combined balance delta: -", bundlerTotalBalance - newBundlerBalance);
        }
        */

        // console.log("--");
        // console.log("USER:");

        // uint256 newUserBalance = userEOA.balance + atlas.balanceOf(userEOA);
        // uint256 userTotalBalance = userEOABalance + userAtlEthBalance;

        // if (userEOA.balance >= userEOABalance) {
        //     console.log("user eoa balance delta   : +", userEOA.balance - userEOABalance);
        // } else {
        //     console.log("user eoa balance delta   : -", userEOABalance - userEOA.balance);
        // }

        // if (atlas.balanceOf(userEOA) >= userAtlEthBalance) {
        //     console.log("user atlETH balance delta: +", atlas.balanceOf(userEOA) - userAtlEthBalance);
        // } else {
        //     console.log("user atlETH balance delta: -", userAtlEthBalance - atlas.balanceOf(userEOA));
        // }

        // if (newUserBalance >= userTotalBalance) {
        //     console.log("user total balance delta : +", newUserBalance - userTotalBalance);
        // } else {
        //     console.log("user total balance delta : -", userTotalBalance - newUserBalance);
        // }

        // console.log("--");
        // console.log("SOLVER ONE:");

        // uint256 newSolverOneBalance = solverOneEOA.balance + atlas.balanceOf(solverOneEOA);
        // uint256 solverOneTotalBalance = solverOneEOABalance + solverOneAtlEthBalance;

        // if (solverOneEOA.balance >= solverOneEOABalance) {
        //     console.log("solverOne eoa balance delta   : +", solverOneEOA.balance - solverOneEOABalance);
        // } else {
        //     console.log("solverOne eoa balance delta   : -", solverOneEOABalance - solverOneEOA.balance);
        // }

        // if (atlas.balanceOf(solverOneEOA) >= solverOneAtlEthBalance) {
        //     console.log("solverOne atlETH balance delta: +", atlas.balanceOf(solverOneEOA) - solverOneAtlEthBalance);
        // } else {
        //     console.log("solverOne atlETH balance delta: -", solverOneAtlEthBalance - atlas.balanceOf(solverOneEOA));
        // }

        // if (newSolverOneBalance >= solverOneTotalBalance) {
        //     console.log("solverOne total balance delta : +", newSolverOneBalance - solverOneTotalBalance);
        // } else {
        //     console.log("solverOne total balance delta : -", solverOneTotalBalance - newSolverOneBalance);
        // }

        // console.log("--");
        // console.log("SOLVER TWO:");

        // uint256 newSolverTwoBalance = solverTwoEOA.balance + atlas.balanceOf(solverTwoEOA);
        // uint256 solverTwoTotalBalance = solverTwoEOABalance + solverTwoAtlEthBalance;

        // if (solverTwoEOA.balance >= solverTwoEOABalance) {
        //     console.log("solverTwo eoa balance delta   : +", solverTwoEOA.balance - solverTwoEOABalance);
        // } else {
        //     console.log("solverTwo eoa balance delta   : -", solverTwoEOABalance - solverTwoEOA.balance);
        // }

        // if (atlas.balanceOf(solverTwoEOA) >= solverTwoAtlEthBalance) {
        //     console.log("solverTwo atlETH balance delta: +", atlas.balanceOf(solverTwoEOA) - solverTwoAtlEthBalance);
        // } else {
        //     console.log("solverTwo atlETH balance delta: -", solverTwoAtlEthBalance - atlas.balanceOf(solverTwoEOA));
        // }

        // if (newSolverTwoBalance >= solverTwoTotalBalance) {
        //     console.log("solverTwo total balance delta : +", newSolverTwoBalance - solverTwoTotalBalance);
        // } else {
        //     console.log("solverTwo total balance delta : -", solverTwoTotalBalance - newSolverTwoBalance);
        // }
    }

    // Shoutout to rholterhus for the test
    function test_ExPostOrdering_GasCheck_SkipCoverage() public {
        uint256 NUM_SOLVE_OPS = 3;
        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        userOp.control = address(v2ExPost);
        userOp.callConfig = v2ExPost.CALL_CONFIG();
        SolverOperation[] memory solverOps = new SolverOperation[](NUM_SOLVE_OPS);
        bytes memory solverOpData;
        address[] memory solverEOAs = new address[](NUM_SOLVE_OPS);
        address[] memory solverXPs = new address[](NUM_SOLVE_OPS);
        uint256[] memory solverPKs = new uint256[](NUM_SOLVE_OPS);
        for (uint256 i; i < NUM_SOLVE_OPS; ++i) {
            (solverEOAs[i], solverPKs[i]) = makeAddrAndKey(string(abi.encodePacked("SOLVER", i)));
            solverXPs[i] = address(new SolverExPost(WETH_ADDRESS, address(atlas), solverEOAs[i], 60 + i));
            vm.deal(solverEOAs[i], 100e18);
            deal(TOKEN_ZERO, address(solverXPs[i]), 10e24);
            deal(TOKEN_ONE, address(solverXPs[i]), 10e24);
            vm.startPrank(address(solverEOAs[i]));
            atlas.deposit{ value: 1e18 }();
            atlas.bond(1 ether);
            vm.stopPrank();
        }
        uint8 v;
        bytes32 r;
        bytes32 s;
        for (uint256 i; i < NUM_SOLVE_OPS; ++i) {
            solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
            solverOps[i] = helper.buildSolverOperation(userOp, solverOpData, solverEOAs[i], address(solverXPs[i]), 0, 0);
            (v, r, s) = vm.sign(solverPKs[i], atlasVerification.getSolverPayload(solverOps[i]));
            solverOps[i].signature = abi.encodePacked(r, s, v);
        }
        solverOps = sorter.sortBids(userOp, solverOps);
        // DAppOperation call
        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);
        vm.startPrank(userEOA);
        // User must approve Atlas
        IERC20(TOKEN_ZERO).approve(address(atlas), type(uint256).max);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);
        vm.stopPrank();

        // Simulate the UserOp
        {
            (bool simSuccess, Result simResult,) = simulator.simUserOperation(userOp);
            assertTrue(simSuccess, "userOp fails in simulator");

            // Simulate the SolverOps
            (simSuccess, simResult,) = simulator.simSolverCalls(userOp, solverOps, dAppOp);
            assertTrue(simSuccess, "solverOps fail in simulator");
        }

        vm.startPrank(userEOA);
        uint256 gasLeftBefore = gasleft(); // reusing var because stack too deep
        (bool success,) =
            address(atlas).call(abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dAppOp));
        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());
        assertTrue(success);
        vm.stopPrank();
    }
}