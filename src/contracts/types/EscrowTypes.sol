//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// bonded = total - unbonding
struct EscrowAccountBalance {
    uint112 balance;
    uint112 unbonding;
}

struct EscrowAccountAccessData {
    uint112 bonded;
    uint32 lastAccessedBlock;
    uint24 auctionWins;
    uint24 auctionFails;
    uint64 totalGasValueUsed; // The cumulative ETH value spent on gas in metacalls. Measured in gwei.
}

// Additional struct to avoid Stack Too Deep while tracking variables related to the solver call.
struct SolverTracker {
    uint256 bidAmount;
    uint256 floor;
    uint256 ceiling;
    bool etherIsBidToken;
    bool invertsBidValue;
}

/// @title SolverOutcome
/// @notice Enum for SolverOutcome
/// @dev Multiple SolverOutcomes can be used to represent the outcome of a solver call
/// @dev Typical usage looks like solverOutcome = (1 << SolverOutcome.InvalidSignature) | (1 <<
/// SolverOutcome.InvalidUserHash) to indicate SolverOutcome.InvalidSignature and SolverOutcome.InvalidUserHash
enum SolverOutcome {
    // No Refund (relay error or hostile user)
    InvalidSignature,
    InvalidUserHash,
    DeadlinePassedAlt,
    GasPriceBelowUsersAlt,
    InvalidTo,
    UserOutOfGas,
    AlteredControl,
    AltOpHashMismatch,
    // Partial Refund but no execution
    DeadlinePassed,
    GasPriceOverCap,
    InvalidSolver,
    InvalidBidToken,
    PerBlockLimit, // solvers can only send one tx per block
    // if they sent two we wouldn't be able to flag builder censorship
    InsufficientEscrow,
    GasPriceBelowUsers,
    CallValueTooHigh,
    PreSolverFailed,
    // execution, with Full Refund
    SolverOpReverted,
    PostSolverFailed,
    BidNotPaid,
    InvertedBidExceedsCeiling,
    BalanceNotReconciled,
    CallbackNotCalled,
    EVMError,
    MultipleSolvers
}
