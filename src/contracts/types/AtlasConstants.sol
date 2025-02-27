//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./ValidCalls.sol";

// NOTE: Internal constants that are defined but not used in the logic of a smart contract, will NOT be included in the
// bytecode of the smart contract when compiled. However, public constants will be included in every inheriting contract
// as they are part of the ABI. As such, only internal constants are defined in this shared contract.

contract AtlasConstants {
    // ------------------------------------------------------- //
    //                      ATLAS CONSTANTS                    //
    // ------------------------------------------------------- //

    // Atlas constants
    uint256 internal constant _GAS_VALUE_DECIMALS_TO_DROP = 1e9; // measured in gwei
    uint256 internal constant _UNLOCKED = 0;

    // Atlas constants used in `_bidFindingIteration()`
    uint256 internal constant _BITS_FOR_INDEX = 16;
    uint256 internal constant _FIRST_16_BITS_TRUE_MASK = uint256(0xFFFF);

    // Escrow constants
    uint256 internal constant _VALIDATION_GAS_LIMIT = 500_000;
    uint256 internal constant _FASTLANE_GAS_BUFFER = 125_000; // integer amount
    uint256 internal constant _GRACEFUL_RETURN_GAS_OFFSET = 40_000;

    // Gas Accounting constants
    uint256 internal constant _CALLDATA_LENGTH_PREMIUM_HALVED = 8; // Half of the upper gas cost per byte of calldata
        // (16 gas). Multiplied by msg.data.length. Equivalent to `msg.data.length / 2 * 16` because 2 hex chars per
        // byte.
    uint256 internal constant _BASE_TRANSACTION_GAS_USED = 21_000;
    uint256 internal constant _SOLVER_OP_BASE_CALLDATA = 608; // SolverOperation calldata length excluding solverOp.data
    uint256 internal constant _SOLVER_BASE_GAS_USED = 5000; // Base gas charged to solver in `_handleSolverAccounting()`
    uint256 internal constant _BUNDLER_GAS_PENALTY_BUFFER = 500_000;

    // First 160 bits of _solverLock are the address of the current solver.
    // The 161st bit represents whether the solver has called back via `reconcile`.
    // The 162nd bit represents whether the solver's outstanding debt has been repaid via `reconcile`.
    uint256 internal constant _SOLVER_CALLED_BACK_MASK = 1 << 161;
    uint256 internal constant _SOLVER_FULFILLED_MASK = 1 << 162;

    // Used to set Lock phase without changing the activeEnvironment or callConfig.
    uint256 internal constant _LOCK_PHASE_MASK =
        uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00);

    // ValidCalls error threshold before which the metacall reverts, and after which it returns gracefully to store
    // nonces as used.
    uint8 internal constant _GRACEFUL_RETURN_THRESHOLD = uint8(ValidCallsResult.InvertBidValueCannotBeExPostBids) + 1;

    // ------------------------------------------------------- //
    //               ATLAS VERIFICATION CONSTANTS              //
    // ------------------------------------------------------- //

    uint8 internal constant _MAX_SOLVERS = type(uint8).max - 1;
}
