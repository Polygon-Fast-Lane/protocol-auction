// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { Result } from "../src/contracts/helpers/Simulator.sol";
import { DAppConfig, CallConfig } from "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/DAppOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";
import { ValidCallsResult } from "../src/contracts/types/ValidCalls.sol";
import { SolverOutcome } from "../src/contracts/types/EscrowTypes.sol";
import { CallVerification } from "../src/contracts/libraries/CallVerification.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./base/builders/DAppOperationBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";

import { DummyDAppControl } from "./base/DummyDAppControl.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";


contract SimulatorTest is BaseTest {
    uint256 simBalanceBefore;
    DummyDAppControl dAppControl;
    
    struct ValidCallsCall {
        UserOperation userOp;
        SolverOperation[] solverOps;
        DAppOperation dAppOp;
        uint256 msgValue;
        address msgSender;
        bool isSimulation;
    }

    function setUp() public override {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().buildAndIntegrate(atlasVerification);
        simBalanceBefore = address(simulator).balance;
    }

    function test_simUserOperation_success_valid_SkipCoverage() public {
        UserOperation memory userOp = validUserOperation().build();

        (bool success, Result result, uint256 validCallsResult) = simulator.simUserOperation(userOp);

        assertEq(success, true);
        assertTrue(uint(result) > uint(Result.UserOpSimFail)); // Actually fails with SolverSimFail here
        assertEq(validCallsResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simUserOperation_success_valid_UserOpValue_SkipCoverage() public {
        UserOperation memory userOp = validUserOperation()
            .withValue(1e18)
            .signAndBuild(address(atlasVerification), userPK);

        (bool success, Result result, uint256 validCallsResult) = simulator.simUserOperation(userOp);

        assertEq(success, true);
        assertTrue(uint(result) > uint(Result.UserOpSimFail)); // Actually fails with SolverSimFail here
        assertEq(validCallsResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simUserOperation_fail_bubblesUpValidCallsResult() public {
        UserOperation memory userOp = validUserOperation().withMaxFeePerGas(1).signAndBuild(address(atlasVerification), userPK);
        (bool success, Result result, uint256 validCallsResult) = simulator.simUserOperation(userOp);

        assertEq(success, false);
        assertEq(uint(result), uint(Result.VerificationSimFail));
        assertEq(validCallsResult, uint256(ValidCallsResult.GasPriceHigherThanMax));
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCall_success_validSolverOutcome_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        atlas.bond(1e18);
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCall(userOp, solverOps[0], dAppOp);

        assertEq(success, true);
        assertEq(uint(result), uint(Result.SimulationPassed));
        assertEq(solverOutcomeResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCall_success_validSolverOutcome_UserOpValue_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        atlas.bond(1e18);
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation()
            .withValue(1e18)
            .signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCall(userOp, solverOps[0], dAppOp);

        assertEq(success, true);
        assertEq(uint(result), uint(Result.SimulationPassed));
        assertEq(solverOutcomeResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCall_fail_bubblesUpSolverOutcomeResult_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        // atlas.bond(1e18); - DO NOT BOND - Triggers InsufficientEscrow error
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCall(userOp, solverOps[0], dAppOp);

        assertEq(success, false);
        assertEq(uint(result), uint(Result.SolverSimFail));
        assertEq(solverOutcomeResult, 1 << uint256(SolverOutcome.InsufficientEscrow));
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCalls_success_validSolverOutcome_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        atlas.bond(1e18);
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCalls(userOp, solverOps, dAppOp);

        assertEq(success, true);
        assertEq(uint(result), uint(Result.SimulationPassed));
        assertEq(solverOutcomeResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCalls_success_validSolverOutcome_UserOpValue_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        atlas.bond(1e18);
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation()
            .withValue(1e18)
            .signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCalls(userOp, solverOps, dAppOp);

        assertEq(success, true);
        assertEq(uint(result), uint(Result.SimulationPassed));
        assertEq(solverOutcomeResult, 0);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCalls_fail_noSolverOps() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCalls(userOp, solverOps, dAppOp);

        assertEq(success, false);
        assertEq(uint(result), uint(Result.Unknown)); // Should return Unknown if no solverOps given
        assertEq(solverOutcomeResult, uint256(type(SolverOutcome).max) + 1);
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    function test_simSolverCalls_fail_bubblesUpSolverOutcomeResult_SkipCoverage() public {
        vm.startPrank(solverOneEOA);
        DummySolver solver = new DummySolver(WETH_ADDRESS, address(atlas));
        // atlas.bond(1e18); - DO NOT BOND - Triggers InsufficientEscrow error
        vm.stopPrank();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withData(abi.encodeWithSelector(solver.solverFunc.selector))
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dAppOp = validDAppOperation(userOp, solverOps).build();

        (bool success, Result result, uint256 solverOutcomeResult) = simulator.simSolverCalls(userOp, solverOps, dAppOp);

        assertEq(success, false);
        assertEq(uint(result), uint(Result.SolverSimFail));
        assertEq(solverOutcomeResult, 1 << uint256(SolverOutcome.InsufficientEscrow));
        assertEq(address(simulator).balance, simBalanceBefore, "Balance should not change");
    }

    // Deployer Function Tests

    function test_simulator_setAtlas() public {
        assertEq(simulator.atlas(), address(atlas));

        vm.expectRevert(AtlasErrors.Unauthorized.selector);
        simulator.setAtlas(address(0));
        assertEq(simulator.atlas(), address(atlas), "Should revert if not deployer");
        
        vm.prank(deployer);
        simulator.setAtlas(address(123));
        assertEq(simulator.atlas(), address(123), "Should set new atlas address");
    }

    function test_simulator_withdrawETH() public {
        address recipient = makeAddr("LuckyRecipient");
        uint256 recipientBalanceBefore = address(recipient).balance;
        simBalanceBefore = address(simulator).balance;
        

        vm.expectRevert(AtlasErrors.Unauthorized.selector);
        simulator.withdrawETH(recipient);
        assertEq(address(simulator).balance, simBalanceBefore, "Should revert if caller not deployer");

        vm.prank(deployer);
        simulator.withdrawETH(recipient);
        assertEq(address(simulator).balance, 0, "Should withdraw all balance");
        assertEq(address(recipient).balance, recipientBalanceBefore + simBalanceBefore, "Should send balance to recipient");
    }


    // Test Helpers

    function defaultCallConfig() public returns (CallConfigBuilder) {
        return new CallConfigBuilder();
    }

    function defaultDAppControl() public returns (DummyDAppControlBuilder) {
        return new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(defaultCallConfig().build());
    }

    function validUserOperation() public returns (UserOperationBuilder) {
        return new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withControl(address(dAppControl))
            .withSessionKey(address(0))
            .withData("")
            .sign(address(atlasVerification), userPK);
    }

    function validSolverOperation(UserOperation memory userOp) public returns (SolverOperationBuilder) {
        return new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withData("")
            .withUserOpHash(userOp)
            .sign(address(atlasVerification), solverOnePK);
    }

    function validSolverOperations(UserOperation memory userOp) public returns (SolverOperation[] memory) {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp).build();
        return solverOps;
    }

    function validDAppOperation(DAppConfig memory config, UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(callChainHash)
            .sign(address(atlasVerification), governancePK);
    }

    function validDAppOperation(UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK);
    }

}


contract DummySolver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }
    function solverFunc() public { }
    fallback() external payable { }
    receive() external payable { }
}
