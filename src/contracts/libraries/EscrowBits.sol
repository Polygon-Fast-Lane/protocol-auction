//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../types/EscrowTypes.sol";

library EscrowBits {
    // Bundler's Fault - solver doesn't owe any gas refund. SolverOp isn't executed
    uint256 internal constant _NO_REFUND = (
        1 << uint256(SolverOutcome.InvalidSignature) // <- detected by verification
            | 1 << uint256(SolverOutcome.InvalidUserHash) // <- detected by verification
            | 1 << uint256(SolverOutcome.DeadlinePassedAlt) // <- detected by escrow
            | 1 << uint256(SolverOutcome.GasPriceBelowUsersAlt) // <- detected by verification
            | 1 << uint256(SolverOutcome.InvalidTo) // <- detected by verification
            | 1 << uint256(SolverOutcome.UserOutOfGas) // <- detected by escrow
            | 1 << uint256(SolverOutcome.AlteredControl) // <- detected by EE
            | 1 << uint256(SolverOutcome.AltOpHashMismatch)
    ); // <- detected by escrow

    // Solver's Fault - solver *does* owe gas refund, SolverOp isn't executed
    uint256 internal constant _PARTIAL_REFUND = (
        1 << uint256(SolverOutcome.DeadlinePassed) // <- detected by escrow
            | 1 << uint256(SolverOutcome.GasPriceOverCap) // <- detected by verification
            | 1 << uint256(SolverOutcome.InvalidSolver) // <- detected by verification
            | 1 << uint256(SolverOutcome.InvalidBidToken) // <- detected by escrow
            | 1 << uint256(SolverOutcome.PerBlockLimit) // <- detected by escrow
            | 1 << uint256(SolverOutcome.InsufficientEscrow) // <- detected by escrow
            | 1 << uint256(SolverOutcome.GasPriceBelowUsers) // <- detected by verification
            | 1 << uint256(SolverOutcome.CallValueTooHigh) // <- detected by escrow
            | 1 << uint256(SolverOutcome.PreSolverFailed)
    ); // <- detected by EE

    // Solver's Fault - solver *does* owe gas refund, SolverOp *was* executed
    uint256 internal constant _FULL_REFUND = (
        1 << uint256(SolverOutcome.SolverOpReverted) // <- detected by Escrow
            | 1 << uint256(SolverOutcome.PostSolverFailed) // <- detected by EE
            | 1 << uint256(SolverOutcome.BidNotPaid) // <- detected by EE
            | 1 << uint256(SolverOutcome.InvertedBidExceedsCeiling) // <- detected by EE
            | 1 << uint256(SolverOutcome.BalanceNotReconciled) // <- detected by Escrow
            | 1 << uint256(SolverOutcome.CallbackNotCalled) // <- detected by Escrow
            | 1 << uint256(SolverOutcome.EVMError)
    ); // <- default if err by EE

    function canExecute(uint256 result) internal pure returns (bool) {
        return (result == 0);
    }

    // NOTE: PartialRefunds mean that the tx isn't executed but solver is still liable
    // for some gas costs.
    function partialRefund(uint256 result) internal pure returns (bool) {
        return ((result & _PARTIAL_REFUND) != 0);
    }

    function executionSuccessful(uint256 result) internal pure returns (bool) {
        return (result == 0);
    }

    function executedWithError(uint256 result) internal pure returns (bool) {
        return (result & _FULL_REFUND) != 0;
    }

    function bundlersFault(uint256 result) internal pure returns (bool) {
        // Only update solver escrow if failure is not due to bundler's fault
        // returns true if bundler blamed and no solver refund required
        return (result & _NO_REFUND != 0);
    }
}
