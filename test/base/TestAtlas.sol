//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../src/contracts/atlas/Atlas.sol";

/// @title TestAtlas
/// @author FastLane Labs
/// @notice A test version of the Atlas contract that just exposes internal transient storage helpers.
contract TestAtlas is Atlas {
    constructor(
        uint256 escrowDuration,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator,
        address factoryLib
    )
        Atlas(
            escrowDuration,
            atlasSurchargeRate,
            bundlerSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator,
            factoryLib
        )
    { }

    // Public functions to expose internal transient helpers for testing

    function clearTransientStorage() public {
        _setLock(address(0), 0, 0);
        t_solverLock = 0;
        t_solverTo = address(0);
        t_claims = 0;
        t_fees = 0;
        t_writeoffs = 0;
        t_withdrawals = 0;
        t_deposits = 0;
        t_solverSurcharge = 0;
    }

    function setLock(address activeEnvironment, uint32 callConfig, uint8 phase) public {
        _setLock(activeEnvironment, callConfig, phase);
    }

    function setLockPhase(ExecutionPhase newPhase) public {
        _setLockPhase(uint8(newPhase));
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
}
