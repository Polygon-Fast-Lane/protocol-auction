//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ValidCallsResult
/// @notice Enum for ValidCallsResult
/// @dev A single ValidCallsResult is returned by `validateCalls` in AtlasVerification
enum ValidCallsResult {
    Valid,
    // Results below this line will cause metacall to revert
    UserFromInvalid,
    UserSignatureInvalid,
    DAppSignatureInvalid,
    UserNonceInvalid,
    InvalidDAppNonce,
    UnknownAuctioneerNotAllowed,
    InvalidAuctioneer,
    InvalidBundler,
    // Results above this line will cause metacall to revert
    InvertBidValueCannotBeExPostBids, // Threshold value (included in the revert range), any new reverting values should
        // be included above this line
    // Results below this line will cause metacall to gracefully return
    GasPriceHigherThanMax,
    TxValueLowerThanCallValue,
    TooManySolverOps,
    UserDeadlineReached,
    DAppDeadlineReached,
    ExecutionEnvEmpty,
    NoSolverOp,
    InvalidSequence,
    OpHashMismatch,
    DeadlineMismatch,
    InvalidControl,
    InvalidSolverGasLimit,
    InvalidCallConfig,
    CallConfigMismatch,
    DAppToInvalid,
    UserToInvalid,
    ControlMismatch,
    InvalidCallChainHash,
    DAppNotEnabled,
    BothUserAndDAppNoncesCannotBeSequential
}
