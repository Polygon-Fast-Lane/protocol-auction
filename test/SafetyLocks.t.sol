// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { SafetyLocks } from "../src/contracts/atlas/SafetyLocks.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";

import "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/LockTypes.sol";

contract MockSafetyLocks is SafetyLocks {
    constructor() SafetyLocks(0, 1000000, 1000000, address(0), address(0), address(0), address(0)) { }

    function initializeLock(
        address executionEnvironment,
        uint256 gasMarker,
        uint256 userOpValue
    )
        external
        payable
    {
        DAppConfig memory dConfig;
        _setEnvironmentLock(dConfig, executionEnvironment);
        // _initializeAccountingValues(gasMarker);
    }

    function buildEscrowLock(
        address executionEnvironment,
        bytes32 userOpHash,
        address bundler,
        uint8 solverOpCount,
        bool isSimulation
    )
        external
        pure
        returns (Context memory ctx)
    {
        return _buildContext(executionEnvironment, userOpHash, bundler, solverOpCount, isSimulation);
    }

    function setLock(address _activeEnvironment) external {
        _setLock({
            activeEnvironment: _activeEnvironment,
            phase: uint8(ExecutionPhase.Uninitialized),
            callConfig: uint32(0)
        });
    }

    function releaseLock() external {
        _releaseLock();
    }

    function setLockPhase(uint8 newPhase) external {
        _setLockPhase(newPhase);
    }

    function setSolverLock(uint256 newSolverLock) public {
        t_solverLock = newSolverLock;
    }

    function setSolverTo(address newSolverTo) public {
        t_solverTo = newSolverTo;
    }

    function setClaims(uint256 newClaims) public {
        t_claims = newClaims;
    }

    function setFees(uint256 newFees) public {
        t_fees = newFees;
    }

    function setWriteoffs(uint256 newWriteoffs) public {
        t_writeoffs = newWriteoffs;
    }

    function setWithdrawals(uint256 newWithdrawals) public {
        t_withdrawals = newWithdrawals;
    }

    function setDeposits(uint256 newDeposits) public {
        t_deposits = newDeposits;
    }

    // Transient Var View Functions

    function claims() external view returns (uint256) {
        return t_claims;
    }

    function fees() external view returns (uint256) {
        return t_fees;
    }

    function writeoffs() external view returns (uint256) {
        return t_writeoffs;
    }

    function withdrawals() external view returns (uint256) {
        return t_withdrawals;
    }

    function deposits() external view returns (uint256) {
        return t_deposits;
    }

    function solverTo() external view returns (address) {
        return t_solverTo;
    }
}

contract SafetyLocksTest is Test {
    MockSafetyLocks public safetyLocks;
    address executionEnvironment = makeAddr("executionEnvironment");

    function setUp() public {
        safetyLocks = new MockSafetyLocks();
    }

    function test_setEnvironmentLock() public {
        uint256 gasMarker = 222;
        uint256 userOpValue = 333;
        uint256 msgValue = 444;

        safetyLocks.setLock(address(2));
        vm.expectRevert(AtlasErrors.AlreadyInitialized.selector);
        safetyLocks.initializeLock{ value: msgValue }(executionEnvironment, gasMarker, userOpValue);

        safetyLocks.releaseLock(); // Reset to UNLOCKED
        safetyLocks.initializeLock{ value: msgValue }(executionEnvironment, gasMarker, userOpValue);

        (address activeEnv, uint32 callConfig, uint8 phase) = safetyLocks.lock();

        assertEq(activeEnv, executionEnvironment);
        assertEq(phase, uint8(ExecutionPhase.PreOps));
        assertEq(callConfig, uint32(0));
    }

    function test_buildContext() public {
        safetyLocks.initializeLock(executionEnvironment, 0, 0);
        Context memory ctx = safetyLocks.buildEscrowLock(executionEnvironment, bytes32(0), address(0), 0, false);
        assertEq(executionEnvironment, ctx.executionEnvironment);
    }

    function test_setLockPhase() public {
        uint8 newPhase = uint8(ExecutionPhase.SolverOperation);

        safetyLocks.setLockPhase(newPhase);

        (, , uint8 phase) = safetyLocks.lock();
        assertEq(phase, newPhase);
    }

    function test_setClaims() public {
        uint256 newClaims = 5e10;

        safetyLocks.setClaims(newClaims);

        uint256 claims = safetyLocks.claims();
        assertEq(claims, newClaims);
    }

    function test_setWithdrawals() public {
        uint256 newWithdrawals = 5e10;

        safetyLocks.setWithdrawals(newWithdrawals);

        uint256 withdrawals = safetyLocks.withdrawals();
        assertEq(withdrawals, newWithdrawals);
    }

    function test_setDeposits() public {
        uint256 newDeposits = 5e10;

        safetyLocks.setDeposits(newDeposits);

        uint256 deposits = safetyLocks.deposits();
        assertEq(deposits, newDeposits);
    }

    function test_setFees() public {
        uint256 newFees = 5e10;

        safetyLocks.setFees(newFees);

        uint256 fees = safetyLocks.fees();
        assertEq(fees, newFees);
    }

    function test_setWriteoffs() public {
        uint256 newWriteoffs = 5e10;

        safetyLocks.setWriteoffs(newWriteoffs);

        uint256 writeoffs = safetyLocks.writeoffs();
        assertEq(writeoffs, newWriteoffs);
    }

    function test_setSolverLock() public {
        uint256 newSolverLock = 98234723414317349817948719;

        safetyLocks.setSolverLock(newSolverLock);

        (address currentSolver, bool calledBack, bool fulfilled) = safetyLocks.solverLockData();
        assertEq(currentSolver, address(uint160(newSolverLock)));
    }

    function test_setSolverTo() public {
        address newSolverTo = address(0x123);

        safetyLocks.setSolverTo(newSolverTo);

        address solverTo = safetyLocks.solverTo();
        assertEq(solverTo, newSolverTo);
    }

    function test_isUnlocked() public {
        safetyLocks.setLock(address(2));
        assertEq(safetyLocks.isUnlocked(), false);        
        safetyLocks.releaseLock();
        assertEq(safetyLocks.isUnlocked(), true);
    }

    function test_combinedOperations() public {
        address ee = makeAddr("anotherExecutionEnvironment");
        uint256 gasMarker = 222;
        uint256 userOpValue = 333;
        uint256 msgValue = 444;

        safetyLocks.setLock(address(2));
        assertEq(safetyLocks.isUnlocked(), false);
        vm.expectRevert(AtlasErrors.AlreadyInitialized.selector);
        safetyLocks.initializeLock{ value: msgValue }(ee, gasMarker, userOpValue);
        safetyLocks.releaseLock();
        assertEq(safetyLocks.isUnlocked(), true);
        safetyLocks.initializeLock{ value: msgValue }(ee, gasMarker, userOpValue);
        safetyLocks.setClaims(1000);
        safetyLocks.setWithdrawals(500);
        safetyLocks.setDeposits(2000);
        safetyLocks.setFees(888);
        safetyLocks.setWriteoffs(666);
        safetyLocks.setLockPhase(uint8(ExecutionPhase.SolverOperation));
        safetyLocks.setSolverLock(0x456);

        (address activeEnv, uint32 callConfig, uint8 phase) = safetyLocks.lock();
        uint256 claims = safetyLocks.claims();
        uint256 withdrawals = safetyLocks.withdrawals();
        uint256 deposits = safetyLocks.deposits();
        uint256 fees = safetyLocks.fees();
        uint256 writeoffs = safetyLocks.writeoffs();
        (address solverTo,,) = safetyLocks.solverLockData();

        assertEq(safetyLocks.isUnlocked(), false);
        assertEq(activeEnv, ee);
        assertEq(phase, uint8(ExecutionPhase.SolverOperation));
        assertEq(callConfig, uint32(0));
        assertEq(claims, 1000);
        assertEq(withdrawals, 500);
        assertEq(deposits, 2000);
        assertEq(fees, 888);
        assertEq(writeoffs, 666);
        assertEq(solverTo, address(0x456));
    }
}
