// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { EscrowBits } from "../../src/contracts/libraries/EscrowBits.sol";
import "../../src/contracts/types/EscrowTypes.sol";
import "../base/TestUtils.sol";

contract EscrowBitsTest is Test {
    using EscrowBits for uint256;

    function testConstants() public pure {
        string memory expectedBitMapString =
            "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000011111111";
        assertEq(TestUtils.uint256ToBinaryString(EscrowBits._NO_REFUND), expectedBitMapString, "_NO_REFUND incorrect");

        expectedBitMapString =
            "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000011111111100000000";
        assertEq(
            TestUtils.uint256ToBinaryString(EscrowBits._PARTIAL_REFUND),
            expectedBitMapString,
            "_PARTIAL_REFUND incorrect"
        );

        expectedBitMapString =
            "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001111111100000000000000000";
        assertEq(
            TestUtils.uint256ToBinaryString(EscrowBits._FULL_REFUND), expectedBitMapString, "_FULL_REFUND incorrect"
        );
    }

    function testLogEscrowConstants() public view {
        console.log("EscrowBits._NO_REFUND", EscrowBits._NO_REFUND);
        console.log("EscrowBits._PARTIAL_REFUND", EscrowBits._PARTIAL_REFUND);
        console.log("EscrowBits._FULL_REFUND", EscrowBits._FULL_REFUND);
    }

    function testCanExecute() public pure {
        uint256 valid = 0;
        assertEq(valid.canExecute(), true);

        uint256 invalid = 1 << 1;
        assertEq(invalid.canExecute(), false);
        invalid = 1 << 2;
        assertEq(invalid.canExecute(), false);
    }

    function testExecutionSuccessful() public pure {
        uint256 valid = 0;
        assertEq(valid.executionSuccessful(), true);

        // NO REFUND group
        uint256 invalid = 1 << uint256(SolverOutcome.InvalidSignature);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidUserHash);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.DeadlinePassedAlt);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceBelowUsersAlt);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidTo);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.UserOutOfGas);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.AlteredControl);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.AltOpHashMismatch);
        assertEq(invalid.executionSuccessful(), false);

        // PARTIAL REFUND group
        invalid = 1 << uint256(SolverOutcome.DeadlinePassed);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceOverCap);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidSolver);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidBidToken);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.PerBlockLimit);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InsufficientEscrow);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceBelowUsers);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.CallValueTooHigh);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.PreSolverFailed);
        assertEq(invalid.executionSuccessful(), false);

        // FULL REFUND group
        invalid = 1 << uint256(SolverOutcome.SolverOpReverted);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.PostSolverFailed);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.BidNotPaid);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.InvertedBidExceedsCeiling);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.BalanceNotReconciled);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.CallbackNotCalled);
        assertEq(invalid.executionSuccessful(), false);
        invalid = 1 << uint256(SolverOutcome.EVMError);
        assertEq(invalid.executionSuccessful(), false);
    }

    function testExecutedWithError() public pure {
        // FULL REFUND group
        uint256 valid = 1 << uint256(SolverOutcome.SolverOpReverted);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.PostSolverFailed);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.BidNotPaid);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.InvertedBidExceedsCeiling);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.BalanceNotReconciled);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.CallbackNotCalled);
        assertEq(valid.executedWithError(), true);
        valid = 1 << uint256(SolverOutcome.EVMError);
        assertEq(valid.executedWithError(), true);

        // NO REFUND group
        uint256 invalid = 0;
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidSignature);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidUserHash);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.DeadlinePassedAlt);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceBelowUsersAlt);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidTo);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.UserOutOfGas);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.AlteredControl);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.AltOpHashMismatch);
        assertEq(invalid.executedWithError(), false);

        // PARTIAL REFUND group
        invalid = 1 << uint256(SolverOutcome.DeadlinePassed);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceOverCap);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidSolver);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidBidToken);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.PerBlockLimit);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.InsufficientEscrow);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceBelowUsers);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.CallValueTooHigh);
        assertEq(invalid.executedWithError(), false);
        invalid = 1 << uint256(SolverOutcome.PreSolverFailed);
        assertEq(invalid.executedWithError(), false);
    }

    function testBundlersFault() public pure {
        // SUCCESS
        uint256 invalid = 0;
        assertEq(invalid.bundlersFault(), false);

        // NO REFUND group - Should all be bundlers fault      
        uint256 valid = 1 << uint256(SolverOutcome.InvalidSignature);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.InvalidUserHash);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.DeadlinePassedAlt);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.GasPriceBelowUsersAlt);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.InvalidTo);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.UserOutOfGas);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.AlteredControl);
        assertEq(valid.bundlersFault(), true);
        valid = 1 << uint256(SolverOutcome.AltOpHashMismatch);
        assertEq(valid.bundlersFault(), true);

        // PARTIAL REFUND group
        invalid = 1 << uint256(SolverOutcome.DeadlinePassed);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceOverCap);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidSolver);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.InvalidBidToken);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.PerBlockLimit);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.InsufficientEscrow);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.GasPriceBelowUsers);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.CallValueTooHigh);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.PreSolverFailed);
        assertEq(invalid.bundlersFault(), false);

        // FULL REFUND group
        invalid = 1 << uint256(SolverOutcome.SolverOpReverted);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.PostSolverFailed);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.BidNotPaid);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.InvertedBidExceedsCeiling);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.BalanceNotReconciled);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.CallbackNotCalled);
        assertEq(invalid.bundlersFault(), false);
        invalid = 1 << uint256(SolverOutcome.EVMError);
        assertEq(invalid.bundlersFault(), false);
    }
}
