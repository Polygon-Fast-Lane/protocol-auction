//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract FastLaneOnlineErrors {
    // FastLaneControl.sol
    error FLOnlineControl_PreSolver_BuyTokenMismatch();
    error FLOnlineControl_PreSolver_SellTokenMismatch();
    error FLOnlineControl_PreSolver_BidBelowReserve();

    error FLOnlineControl_PostOpsCall_InsufficientBaseline();

    error FLOnlineControl_BaselineSwap_BaselineCallFail();
    error FLOnlineControl_BaselineSwap_NoBalanceIncrease();

    error FLOnlineControl_BalanceCheckFail();

    // FastLaneOnlineInner.sol
    error FLOnlineInner_Swap_OnlyAtlas();
    error FLOnlineInner_Swap_MustBeDelegated();
    error FLOnlineInner_Swap_BuyAndSellTokensAreSame();
    error FLOnlineInner_Swap_ControlNotBundler();
    error FLOnlineInner_Swap_UserOpValueTooLow();
    error FLOnlineInner_Swap_BaselineCallValueTooLow();

    // SolverGateway.sol
    error SolverGateway_AddSolverOp_SolverMustBeSender();
    error SolverGateway_AddSolverOp_BidTooHigh();
    error SolverGateway_AddSolverOp_SimulationFail();
    error SolverGateway_AddSolverOp_ScoreTooLow();

    error SolverGateway_RefundCongestionBuyIns_DeadlineNotPassed();

    // OuterHelpers.sol
    error OuterHelpers_NotMadJustDisappointed();

    // FLOnlineOuter.sol
    error FLOnlineOuter_FastOnlineSwap_NoFulfillment();

    error FLOnlineOuter_ValidateSwap_InvalidSender();
    error FLOnlineOuter_ValidateSwap_TxGasTooHigh();
    error FLOnlineOuter_ValidateSwap_TxGasTooLow();
    error FLOnlineOuter_ValidateSwap_GasLimitTooLow();
    error FLOnlineOuter_ValidateSwap_MsgValueTooLow();
    error FLOnlineOuter_ValidateSwap_UserOpValueTooLow();
    error FLOnlineOuter_ValidateSwap_UserOpBaselineValueMismatch();
}
