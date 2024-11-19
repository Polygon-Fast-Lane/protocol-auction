//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./ValidCalls.sol";

contract AtlasErrors {
    // Simulator
    error SimulatorBalanceTooLow();
    error Unauthorized();
    error Unreachable();
    error NoAuctionWinner();
    error InvalidEntryFunction();
    error SimulationPassed();

    error UserSimulationFailed();
    error UserSimulationSucceeded();
    error UserUnexpectedSuccess();
    error UserNotFulfilled();

    error BidFindSuccessful(uint256 bidAmount);
    error UnexpectedNonRevert();

    error InvalidSolver();
    error BidNotPaid();
    error InvertedBidExceedsCeiling();
    error BalanceNotReconciled();
    error SolverOpReverted();
    error AlteredControl();
    error InvalidEntry();
    error CallbackNotCalled();
    error PreSolverFailed();
    error PostSolverFailed();
    error InsufficientEscrow();

    error VerificationSimFail(ValidCallsResult);
    error PreOpsSimFail();
    error UserOpSimFail();
    error SolverSimFail(uint256 solverOutcomeResult); // uint param is result returned in `verifySolverOp`
    error AllocateValueSimFail();
    error PostOpsSimFail();
    error ValidCalls(ValidCallsResult);

    // Execution Environment
    error InvalidUser();
    error InvalidTo();
    error InvalidCodeHash();
    error PreOpsDelegatecallFail();
    error UserOpValueExceedsBalance();
    error UserWrapperDelegatecallFail();
    error UserWrapperCallFail();
    error PostOpsDelegatecallFail();
    error PostOpsDelegatecallReturnedFalse();
    error AllocateValueDelegatecallFail();
    error NotEnvironmentOwner();
    error ExecutionEnvironmentBalanceTooLow();

    // Atlas
    error PreOpsFail();
    error UserOpFail();
    // error SolverFail(); // Only sim version of err is used
    error AllocateValueFail();
    error PostOpsFail();
    error InvalidAccess();

    // Escrow
    error UncoveredResult();
    error InvalidEscrowDuration();

    // AtlETH
    error EscrowLockActive();
    error InsufficientBalanceForDeduction(uint256 balance, uint256 requested);

    // DAppIntegration
    error OnlyGovernance();
    error SignatoryActive();
    error InvalidCaller();
    error InvalidDAppControl();
    error DAppNotEnabled();
    error AtlasLockActive();
    error InvalidSignatory();

    // Permit69
    error InvalidEnvironment();
    error EnvironmentMismatch();
    error InvalidLockState();

    // GasAccounting
    error LedgerFinalized(uint8 id);
    error LedgerBalancing(uint8 id);
    error MissingFunds(uint8 id);
    error InsufficientFunds();
    error NoUnfilledRequests();
    error SolverMustReconcile();
    error DoubleReconcile();
    error InvalidExecutionEnvironment(address correctEnvironment);
    error InvalidSolverFrom(address solverFrom);
    error InsufficientSolverBalance(uint256 actual, uint256 msgValue, uint256 holds, uint256 needed);
    error InsufficientAtlETHBalance(uint256 actual, uint256 needed);
    error InsufficientTotalBalance(uint256 shortfall);
    error UnbalancedAccounting();

    // SafetyLocks
    error NotInitialized();
    error AlreadyInitialized();

    // AtlasVerification
    error NoUnusedNonceInBitmap();

    // DAppControl
    error BothUserAndDAppNoncesCannotBeSequential();
    error BothPreOpsAndUserReturnDataCannotBeTracked();
    error InvalidControl();
    error NoDelegatecall();
    error MustBeDelegatecalled();
    error OnlyAtlas();
    error WrongPhase();
    error WrongDepth();
    error InsufficientLocalFunds();
    error NotImplemented();
    error InvertBidValueCannotBeExPostBids();
}
