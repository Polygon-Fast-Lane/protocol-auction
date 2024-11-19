// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IExecutionEnvironment } from "../src/contracts/interfaces/IExecutionEnvironment.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { Mimic } from "../src/contracts/common/Mimic.sol";

import { V2DAppControl } from "../src/contracts/examples/v2-example/V2DAppControl.sol";

import { Solver } from "../src/contracts/solver/src/TestSolver.sol";

import "../src/contracts/types/UserOperation.sol";
import "../src/contracts/types/SolverOperation.sol";
import "../src/contracts/types/EscrowTypes.sol";
import "../src/contracts/types/LockTypes.sol";
import "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/DAppOperation.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { V2Helper } from "./V2Helper.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";

import "forge-std/Test.sol";

contract MainTest is BaseTest {
    /// forge-config: default.gas_price = 15000000000
    V2DAppControl public v2DAppControl;
    V2Helper public helper;

    address FXS_ADDRESS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    IERC20 FXS = IERC20(FXS_ADDRESS);

    address V2_FXS_ETH = 0xecBa967D84fCF0405F6b32Bc45F4d36BfDBB2E81;
    address S2_FXS_ETH = 0x61eB53ee427aB4E007d78A9134AaCb3101A2DC23;

    address POOL_ONE = V2_FXS_ETH;
    address POOL_TWO = S2_FXS_ETH;
    address TOKEN_ZERO = FXS_ADDRESS;
    address TOKEN_ONE = WETH_ADDRESS;

    Solver public solverOne;
    Solver public solverTwo;

    function setUp() public virtual override {
        BaseTest.setUp();

        // Deal to user
        deal(TOKEN_ZERO, address(userEOA), 10e30);
        deal(TOKEN_ONE, address(userEOA), 10e30);

        vm.startPrank(governanceEOA);
        v2DAppControl = new V2DAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(v2DAppControl));
        vm.stopPrank();

        helper = new V2Helper(address(v2DAppControl), address(atlas), address(atlasVerification));

        // Deposit ETH from Searcher1 signer to pay for searcher's gas
        vm.startPrank(solverOneEOA);
        solverOne = new Solver(WETH_ADDRESS, address(atlas), solverOneEOA);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        deal(TOKEN_ZERO, address(solverOne), 10e24);
        deal(TOKEN_ONE, address(solverOne), 10e24);

        // Deposit ETH from Searcher2 signer to pay for searcher's gas
        vm.startPrank(solverTwoEOA);
        solverTwo = new Solver(WETH_ADDRESS, address(atlas), solverTwoEOA);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        deal(TOKEN_ZERO, address(solverTwo), 10e24);
        deal(TOKEN_ONE, address(solverTwo), 10e24);
    }

    function testMain() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);

        // user does not sign their own operation when bundling
        // (v, r, s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        // userOp.signature = abi.encodePacked(r, s, v);

        SolverOperation[] memory solverOps = new SolverOperation[](2);
        bytes memory solverOpData;

        console.log("solverOneEOA WETH:", WETH.balanceOf(address(solverOneEOA)));
        console.log("solverOne    WETH:", WETH.balanceOf(address(solverOne)));

        vm.prank(address(solverOneEOA));
        atlas.bond(1 ether);

        vm.prank(address(solverTwoEOA));
        atlas.bond(1 ether);

        // First SolverOperation
        solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
        solverOps[1] = helper.buildSolverOperation(
            userOp, solverOpData, solverOneEOA, address(solverOne), WETH.balanceOf(address(solverOne)) / 20, 0
        );

        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[1]));
        solverOps[1].signature = abi.encodePacked(r, s, v);

        console.log("solverTwoEOA WETH:", WETH.balanceOf(address(solverTwoEOA)));
        console.log("solverTwo    WETH:", WETH.balanceOf(address(solverTwo)));
        // Second SolverOperation
        solverOpData = helper.buildV2SolverOperationData(POOL_ONE, POOL_TWO);
        solverOps[0] = helper.buildSolverOperation(
            userOp, solverOpData, solverTwoEOA, address(solverTwo), WETH.balanceOf(address(solverTwo)) / 3000, 0
        );

        (v, r, s) = vm.sign(solverTwoPK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);

        console.log("topBid before sorting", solverOps[0].bidAmount);

        solverOps = sorter.sortBids(userOp, solverOps);

        console.log("topBid after sorting ", solverOps[0].bidAmount);

        // DAppOperation call
        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);

        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));

        dAppOp.signature = abi.encodePacked(r, s, v);

        vm.startPrank(userEOA);

        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, userOp.control);
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        console.log("userEOA", userEOA);
        console.log("atlas", address(atlas));
        console.log("v2DAppControl", address(v2DAppControl));
        console.log("executionEnvironment", executionEnvironment);

        // User must approve Atlas
        IERC20(TOKEN_ZERO).approve(address(atlas), type(uint256).max);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);

        vm.stopPrank();

        // address bundler = userEOA;
        vm.startPrank(userEOA);

        uint256 userEOABalance = userEOA.balance;
        uint256 userAtlEthBalance = atlas.balanceOf(userEOA);

        // uint256 bundlerEOABalance = bundler.balance;
        // uint256 bundlerAtlEthBalance = atlas.balanceOf(bundler);

        uint256 solverOneEOABalance = solverOneEOA.balance;
        uint256 solverOneAtlEthBalance = atlas.balanceOf(solverOneEOA);

        uint256 solverTwoEOABalance = solverTwoEOA.balance;
        uint256 solverTwoAtlEthBalance = atlas.balanceOf(solverTwoEOA);

        (bool success,) =
            address(atlas).call(abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dAppOp));

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

        console.log("--");
        console.log("USER:");

        uint256 newUserBalance = userEOA.balance + atlas.balanceOf(userEOA);
        uint256 userTotalBalance = userEOABalance + userAtlEthBalance;

        if (userEOA.balance >= userEOABalance) {
            console.log("user eoa balance delta   : +", userEOA.balance - userEOABalance);
        } else {
            console.log("user eoa balance delta   : -", userEOABalance - userEOA.balance);
        }

        if (atlas.balanceOf(userEOA) >= userAtlEthBalance) {
            console.log("user atlETH balance delta: +", atlas.balanceOf(userEOA) - userAtlEthBalance);
        } else {
            console.log("user atlETH balance delta: -", userAtlEthBalance - atlas.balanceOf(userEOA));
        }

        if (newUserBalance >= userTotalBalance) {
            console.log("user total balance delta : +", newUserBalance - userTotalBalance);
        } else {
            console.log("user total balance delta : -", userTotalBalance - newUserBalance);
        }

        console.log("--");
        console.log("SOLVER ONE:");

        uint256 newSolverOneBalance = solverOneEOA.balance + atlas.balanceOf(solverOneEOA);
        uint256 solverOneTotalBalance = solverOneEOABalance + solverOneAtlEthBalance;

        if (solverOneEOA.balance >= solverOneEOABalance) {
            console.log("solverOne eoa balance delta   : +", solverOneEOA.balance - solverOneEOABalance);
        } else {
            console.log("solverOne eoa balance delta   : -", solverOneEOABalance - solverOneEOA.balance);
        }

        if (atlas.balanceOf(solverOneEOA) >= solverOneAtlEthBalance) {
            console.log("solverOne atlETH balance delta: +", atlas.balanceOf(solverOneEOA) - solverOneAtlEthBalance);
        } else {
            console.log("solverOne atlETH balance delta: -", solverOneAtlEthBalance - atlas.balanceOf(solverOneEOA));
        }

        if (newSolverOneBalance >= solverOneTotalBalance) {
            console.log("solverOne total balance delta : +", newSolverOneBalance - solverOneTotalBalance);
        } else {
            console.log("solverOne total balance delta : -", solverOneTotalBalance - newSolverOneBalance);
        }

        console.log("--");
        console.log("SOLVER TWO:");

        uint256 newSolverTwoBalance = solverTwoEOA.balance + atlas.balanceOf(solverTwoEOA);
        uint256 solverTwoTotalBalance = solverTwoEOABalance + solverTwoAtlEthBalance;

        if (solverTwoEOA.balance >= solverTwoEOABalance) {
            console.log("solverTwo eoa balance delta   : +", solverTwoEOA.balance - solverTwoEOABalance);
        } else {
            console.log("solverTwo eoa balance delta   : -", solverTwoEOABalance - solverTwoEOA.balance);
        }

        if (atlas.balanceOf(solverTwoEOA) >= solverTwoAtlEthBalance) {
            console.log("solverTwo atlETH balance delta: +", atlas.balanceOf(solverTwoEOA) - solverTwoAtlEthBalance);
        } else {
            console.log("solverTwo atlETH balance delta: -", solverTwoAtlEthBalance - atlas.balanceOf(solverTwoEOA));
        }

        if (newSolverTwoBalance >= solverTwoTotalBalance) {
            console.log("solverTwo total balance delta : +", newSolverTwoBalance - solverTwoTotalBalance);
        } else {
            console.log("solverTwo total balance delta : -", solverTwoTotalBalance - newSolverTwoBalance);
        }

        /*
        console.log("");
        console.log("-");
        console.log("-");

        // Second attempt

        userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);

        // First SolverOperation
        solverOps[0] =
            helper.buildSolverOperation(userOp, solverOneEOA, address(solverOne), POOL_ONE, POOL_TWO, 2e17);

        (v, r, s) = vm.sign(solverOnePK, atlas.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);

        // Second SolverOperation
        solverOps[1] =
            helper.buildSolverOperation(userOp, solverTwoEOA, address(solverTwo), POOL_TWO, POOL_ONE, 1e17);

        (v, r, s) = vm.sign(solverTwoPK, atlas.getSolverPayload(solverOps[1]));
        solverOps[1].signature = abi.encodePacked(r, s, v);

        // DAppOperation call
        dAppOp =
            helper.buildDAppOperation(governanceEOA, userOp, solverOps);

        (v, r, s) = vm.sign(governancePK, atlas.getDAppOperationPayload(dAppOp));

        dAppOp.signature = abi.encodePacked(r, s, v);

        vm.startPrank(userEOA);

        executionEnvironment = atlas.getExecutionEnvironment(userOp.from, address(control));
        
        userBalance = userEOA.balance;

        (success,) = address(atlas).call(
            abi.encodeWithSelector(
                atlas.metacall.selector, userOp, solverOps, dAppOp
            )
        );

        assertTrue(success);
        console.log("user gas refund received",userEOA.balance - userBalance);
        console.log("user refund equivalent gas usage", (userEOA.balance - userBalance)/tx.gasprice);

        vm.stopPrank();
        */
    }

    function testMimic_SkipCoverage() public {
        // uncomment to debug if this test is broken
        /*
        address aaaaa = atlas.executionTemplate();
        address bbbbb = msg.sender;
        address ccccc = address(this);
        uint32 ddddd = uint32(0x11111111);
        bytes32 eeeee = keccak256(abi.encodePacked(uint256(0x2222)));
        // Mimic mimic = new Mimic();
        //console.log("----");
        //console.log("runtime code:");
        //console.logBytes(address(mimic).code);
        
        console.log("aaaaa", aaaaa);
        console.log("bbbbb", bbbbb);
        console.log("ccccc", ccccc);
        console.logBytes32(eeeee);
        console.log("----");
        console.log("creation code:");
        console.logBytes(type(Mimic).creationCode);
        console.log("----");

        bytes memory creationCode = type(Mimic).creationCode;
        //bytes memory creationCode = new bytes(790);
        creationCode = atlas.getMimicCreationCode(aaaaa, ddddd, bbbbb, eeeee);
        
        
        console.log("assembly modified code:");
        console.logBytes(creationCode);
        console.log("----");
        */

        vm.startPrank(userEOA);
        address newEnvironment = atlas.createExecutionEnvironment(userEOA, address(v2DAppControl));
        vm.stopPrank();

        assertTrue(IExecutionEnvironment(newEnvironment).getUser() == userEOA, "Mimic Error - User Mismatch");
        assertTrue(
            IExecutionEnvironment(newEnvironment).getControl() == address(v2DAppControl), "Mimic Error - Control Mismatch"
        );
        assertTrue(
            IExecutionEnvironment(newEnvironment).getConfig() == v2DAppControl.CALL_CONFIG(),
            "Mimic Error - CallConfig Mismatch"
        );
        assertTrue(
            IExecutionEnvironment(newEnvironment).getEscrow() == address(atlas),
            "Mimic Error - Escrow/Atlas Address Mismatch"
        );
    }

    function testExecutionEnvironmentAutoCreation() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        vm.prank(solverOneEOA);
        atlas.bond(1 ether);

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        // User does not sign their own operation when bundling

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        bytes memory solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
        solverOps[0] = helper.buildSolverOperation(userOp, solverOpData, solverOneEOA, address(solverOne), 2e17, 0);
        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);

        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);

        // Execution environment should not exist yet
        (,, bool exists) = atlas.getExecutionEnvironment(userEOA, address(v2DAppControl));
        assertFalse(exists, "ExecutionEnvironment already exists");

        vm.startPrank(userEOA);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);
        atlas.metacall(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        // Execution environment should exist now
        (,, exists) = atlas.getExecutionEnvironment(userEOA, address(v2DAppControl));
        assertTrue(exists, "ExecutionEnvironment wasn't created");
    }

    function testUserOperation_SkipCoverage() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        (v, r, s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(r, s, v);

        vm.startPrank(userEOA);
        atlas.createExecutionEnvironment(userEOA, userOp.control);

        // Failure case, user hasn't approved Atlas for TOKEN_ONE, operation must fail
        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true");

        // Success case
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false");

        vm.stopPrank();
    }

    function testSolverCalls_SkipCoverage() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        console.log("TOKEN_ONE", TOKEN_ONE);

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        (v, r, s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(r, s, v);

        SolverOperation[] memory solverOps = new SolverOperation[](1);

        // Success case

        vm.prank(address(solverOneEOA));
        atlas.bond(1 ether);

        vm.prank(address(solverTwoEOA));
        atlas.bond(1 ether);

        bytes memory solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
        solverOps[0] = helper.buildSolverOperation(userOp, solverOpData, solverOneEOA, address(solverOne), 2e17, 0);
        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);
        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);
        vm.startPrank(userEOA);
        atlas.createExecutionEnvironment(userEOA, userOp.control);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);
        (bool success, bytes memory data) = address(simulator).call(
            abi.encodeWithSelector(simulator.simSolverCalls.selector, userOp, solverOps, dAppOp)
        );

        assertTrue(success, "Success case tx reverted unexpectedly");
        assertTrue(abi.decode(data, (bool)), "Success case tx did not return true");
        vm.stopPrank();

        // Failure case
        solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_TWO); // this will make the solver operation
            // revert
        solverOps[0] = helper.buildSolverOperation(userOp, solverOpData, solverOneEOA, address(solverOne), 2e17, 0);
        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);
        dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);
        vm.startPrank(userEOA);
        (success, data) = address(simulator).call(
            abi.encodeWithSelector(simulator.simSolverCalls.selector, userOp, solverOps, dAppOp)
        );

        assertTrue(success, "Failure case tx reverted unexpectedly");
        assertFalse(abi.decode(data, (bool)), "Failure case did not return false");
        vm.stopPrank();
    }

    function testGasRefundBeneficiarySolverSucceeds() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        address beneficiary = makeAddr("beneficiary");

        vm.prank(solverOneEOA);
        atlas.bond(1 ether);

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        // User does not sign their own operation when bundling

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        bytes memory solverOpData = helper.buildV2SolverOperationData(POOL_TWO, POOL_ONE);
        solverOps[0] = helper.buildSolverOperation(userOp, solverOpData, solverOneEOA, address(solverOne), 2e17, 0);
        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);

        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);

        uint256 bondedBalanceBefore = atlas.balanceOfBonded(beneficiary);

        console.log("Beneficiary's balance before metacall", beneficiary.balance);
        console.log("Beneficiary's AtlETH bonded balance before metacall", bondedBalanceBefore);

        assertEq(beneficiary.balance, 0, "Beneficiary should start with 0 balance");
        assertEq(bondedBalanceBefore, 0, "Beneficiary's AtlETH bonded balance should start with 0");

        vm.startPrank(userEOA);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);
        atlas.metacall(userOp, solverOps, dAppOp, beneficiary);
        vm.stopPrank();

        uint256 bondedBalanceAfter = atlas.balanceOfBonded(beneficiary);

        console.log("Beneficiary's balance after metacall", beneficiary.balance);
        console.log("Beneficiary's AtlETH bonded balance after metacall", bondedBalanceAfter);

        assertGt(beneficiary.balance, 0, "Beneficiary should have received some ETH");
        assertEq(bondedBalanceAfter, 0, "Beneficiary's AtlETH bonded balance should still be 0");
    }

    function testGasRefundBeneficiarySolverFails() public {
        uint8 v;
        bytes32 r;
        bytes32 s;

        address beneficiary = makeAddr("beneficiary");

        vm.prank(solverOneEOA);
        atlas.bond(1 ether);

        UserOperation memory userOp = helper.buildUserOperation(POOL_ONE, POOL_TWO, userEOA, TOKEN_ONE);
        // User does not sign their own operation when bundling

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        bytes memory solverOpData = helper.buildV2SolverOperationData(POOL_ONE, POOL_ONE); // will fail
        solverOps[0] = helper.buildSolverOperation(userOp, solverOpData, solverOneEOA, address(solverOne), 2e17, 0);
        (v, r, s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(r, s, v);

        DAppOperation memory dAppOp = helper.buildDAppOperation(governanceEOA, userOp, solverOps);
        (v, r, s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(r, s, v);

        uint256 bondedBalanceBefore = atlas.balanceOfBonded(beneficiary);

        console.log("Beneficiary's balance before metacall", beneficiary.balance);
        console.log("Beneficiary's AtlETH bonded balance before metacall", bondedBalanceBefore);

        assertEq(beneficiary.balance, 0, "Beneficiary should start with 0 balance");
        assertEq(bondedBalanceBefore, 0, "Beneficiary's AtlETH bonded balance should start with 0");

        vm.startPrank(userEOA);
        IERC20(TOKEN_ONE).approve(address(atlas), type(uint256).max);
        atlas.metacall(userOp, solverOps, dAppOp, beneficiary);
        vm.stopPrank();

        uint256 bondedBalanceAfter = atlas.balanceOfBonded(beneficiary);
        console.log("Beneficiary's balance after metacall", beneficiary.balance);
        console.log("Beneficiary's AtlETH bonded balance after metacall", bondedBalanceAfter);

        assertEq(beneficiary.balance, 0, "Beneficiary should still have 0 balance");
        assertGt(bondedBalanceAfter, 0, "Beneficiary's AtlETH bonded balance should be greater than 0");
    }
}
