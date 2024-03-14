//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import { IExecutionEnvironment } from "../interfaces/IExecutionEnvironment.sol";
import { IDAppControl } from "../interfaces/IDAppControl.sol";
import { IAtlasVerification } from "../interfaces/IAtlasVerification.sol";

import { SafeTransferLib, ERC20 } from "solmate/utils/SafeTransferLib.sol";

import { Escrow } from "./Escrow.sol";
import { Factory } from "./Factory.sol";

import { AtlasEvents } from "src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "src/contracts/types/AtlasErrors.sol";

import "../types/SolverCallTypes.sol";
import "../types/UserCallTypes.sol";
import "../types/LockTypes.sol";
import "../types/DAppApprovalTypes.sol";
import "../types/ValidCallsTypes.sol";

import { CALLDATA_LENGTH_PREMIUM } from "../types/EscrowTypes.sol";

import { CallBits } from "../libraries/CallBits.sol";
import { SafetyBits } from "../libraries/SafetyBits.sol";

import "forge-std/Test.sol";

contract Atlas is Escrow, Factory {
    using CallBits for uint32;
    using SafetyBits for EscrowKey;

    constructor(
        uint256 _escrowDuration,
        address _verification,
        address _simulator,
        address _surchargeRecipient,
        address _executionTemplate
    )
        Escrow(_escrowDuration, _verification, _simulator, _surchargeRecipient)
        Factory(_executionTemplate)
    { }

    function metacall( // <- Entrypoint Function
        UserOperation calldata userOp, // set by user
        SolverOperation[] calldata solverOps, // supplied by ops relay
        DAppOperation calldata dAppOp // supplied by front end via atlas SDK
    )
        external
        payable
        returns (bool auctionWon)
    {
        uint256 gasMarker = gasleft(); // + 21_000 + (msg.data.length * CALLDATA_LENGTH_PREMIUM);
        bool isSimulation = msg.sender == SIMULATOR;

        // Get or create the execution environment
        address executionEnvironment;
        DAppConfig memory dConfig;
        (executionEnvironment, dConfig) = _getOrCreateExecutionEnvironment(userOp);

        // Gracefully return if not valid. This allows signature data to be stored, which helps prevent
        // replay attacks.
        // NOTE: Currently reverting instead of graceful return to help w/ testing.
        (bytes32 userOpHash, ValidCallsResult validCallsResult) = IAtlasVerification(VERIFICATION).validateCalls(
            dConfig, userOp, solverOps, dAppOp, msg.value, msg.sender, isSimulation
        );
        if (validCallsResult != ValidCallsResult.Valid) {
            // TODO group lines below into single revert line?
            if (isSimulation) revert VerificationSimFail(uint256(validCallsResult));
            else revert ValidCalls(validCallsResult);
        }

        // Initialize the lock
        _initializeEscrowLock(executionEnvironment, gasMarker, userOp.value);

        try this.execute{ value: msg.value }(dConfig, userOp, solverOps, executionEnvironment, msg.sender, userOpHash)
        returns (bool _auctionWon, uint256 winningSolverIndex) {
            auctionWon = _auctionWon;
            // Gas Refund to sender only if execution is successful
            _settle({ winningSolver: auctionWon ? solverOps[winningSolverIndex].from : msg.sender, bundler: msg.sender });

            emit MetacallResult(msg.sender, userOp.from, auctionWon ? solverOps[winningSolverIndex].from : address(0));
        } catch (bytes memory revertData) {
            // Bubble up some specific errors
            _handleErrors(revertData, dConfig.callConfig);

            // Refund the msg.value to sender if it errored
            if (msg.value != 0) SafeTransferLib.safeTransferETH(msg.sender, msg.value);
        }

        // Release the lock
        _releaseEscrowLock();

        console.log("total gas used", gasMarker - gasleft());
    }

    function execute(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        address executionEnvironment,
        address bundler,
        bytes32 userOpHash
    )
        external
        payable
        returns (bool auctionWon, uint256 winningSearcherIndex)
    {
        // This is a self.call made externally so that it can be used with try/catch
        if (msg.sender != address(this)) revert InvalidAccess();

        (bytes memory returnData, EscrowKey memory key) =
            _preOpsUserExecutionIteration(dConfig, userOp, solverOps, executionEnvironment, bundler);

        uint256 solverOutcomeResult;

        if (dConfig.callConfig.exPostBids()) {
            (auctionWon, winningSearcherIndex, key) = _bidFindingIteration(
                dConfig, userOp, solverOps, executionEnvironment, bundler, userOpHash, key, returnData
            );
        } else {
            for (; winningSearcherIndex < solverOps.length;) {
                // valid solverOps are packed from left of array - break at first invalid solverOp

                SolverOperation calldata solverOp = solverOps[winningSearcherIndex];

                (auctionWon, key, solverOutcomeResult) = _solverExecutionIteration(
                    dConfig,
                    userOp,
                    solverOp,
                    returnData,
                    executionEnvironment,
                    bundler,
                    userOpHash,
                    solverOp.bidAmount,
                    key
                );
                emit SolverExecution(solverOp.from, winningSearcherIndex, auctionWon);
                if (auctionWon) break;

                unchecked {
                    ++winningSearcherIndex;
                }
            }
        }

        // If no solver was successful, handle revert decision
        if (!auctionWon) {
            if (key.isSimulation) revert SolverSimFail(solverOutcomeResult);
            if (dConfig.callConfig.needsFulfillment()) {
                revert UserNotFulfilled(); // revert("ERR-E003 SolverFulfillmentFailure");
            }
        }

        if (dConfig.callConfig.needsPostOpsCall()) {
            // NOTE: key.addressPointer currently points at address(0) if all solvers fail.
            // TODO: point key.addressPointer at bundler if all fail.
            key = key.holdPostOpsLock(); // preserves addressPointer of winning solver

            bool callSuccessful = _executePostOpsCall(auctionWon, returnData, executionEnvironment, key.pack());
            if (!callSuccessful) {
                if (key.isSimulation) revert PostOpsSimFail();
                else revert PostOpsFail();
            }
        }
        return (auctionWon, winningSearcherIndex);
    }

    function _preOpsUserExecutionIteration(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        address executionEnvironment,
        address bundler
    )
        internal
        returns (bytes memory, EscrowKey memory)
    {
        bool callSuccessful;
        bool usePreOpsReturnData;
        bytes memory returnData;

        // Build the memory lock
        EscrowKey memory key =
            _buildEscrowLock(dConfig, executionEnvironment, uint8(solverOps.length), bundler == SIMULATOR);

        if (dConfig.callConfig.needsPreOpsCall()) {
            // CASE: Need PreOps Call
            key = key.holdPreOpsLock(dConfig.to);

            if (CallBits.needsPreOpsReturnData(dConfig.callConfig)) {
                // CASE: Need PreOps return data
                usePreOpsReturnData = true;
                (callSuccessful, returnData) = _executePreOpsCall(userOp, executionEnvironment, key.pack());
            } else {
                // CASE: Ignore PreOps return data
                (callSuccessful,) = _executePreOpsCall(userOp, executionEnvironment, key.pack());
            }

            if (!callSuccessful) {
                if (key.isSimulation) revert PreOpsSimFail();
                else revert PreOpsFail();
            }
        }

        key = key.holdUserLock(userOp.dapp);

        if (CallBits.needsUserReturnData(dConfig.callConfig)) {
            // CASE: Need User return data

            if (usePreOpsReturnData) {
                // CASE: Need PreOps return Data, Need User return data
                bytes memory userReturnData;
                (callSuccessful, userReturnData) = _executeUserOperation(userOp, executionEnvironment, key.pack());
                returnData = bytes.concat(returnData, userReturnData);
            } else {
                // CASE: Ignore PreOps return data, Need User return data
                (callSuccessful, returnData) = _executeUserOperation(userOp, executionEnvironment, key.pack());
            }
        } else {
            // CASE: Ignore User return data
            (callSuccessful,) = _executeUserOperation(userOp, executionEnvironment, key.pack());
        }

        if (!callSuccessful) {
            if (key.isSimulation) revert UserOpSimFail();
            else revert UserOpFail();
        }

        return (returnData, key);
    }

    function _bidFindingIteration(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        address executionEnvironment,
        address bundler,
        bytes32 userOpHash,
        EscrowKey memory key,
        bytes memory returnData
    )
        internal
        returns (
            bool auctionWon,
            uint256 i, // winningSolverIndex
            EscrowKey memory
        )
    {
        key.bidFind = true;

        uint256[] memory sortedOps = new uint256[](solverOps.length);
        uint256[] memory bidAmounts = new uint256[](solverOps.length);

        for (i; i < solverOps.length; i++) {
            SolverOperation calldata solverOp = solverOps[i];

            uint256 bidAmount = _getBidAmount(executionEnvironment, solverOp, returnData, key);

            if (bidAmount != 0) {
                bidAmounts[i] = bidAmount;

                for (uint256 j = i + 1; j > 0; j--) {
                    if (bidAmount > bidAmounts[sortedOps[j - 1]]) {
                        if (bidAmounts[sortedOps[j - 1]] != 0) {
                            sortedOps[j] = sortedOps[j - 1];
                        } else if (j - 1 == 0) {
                            sortedOps[0] = i;
                        }
                    } else {
                        sortedOps[j] = i;
                        break;
                    }
                }
            }
        }

        key.bidFind = false;
        i = 0;

        for (i; i < solverOps.length; i++) {
            // TODO: handle uint256 solverOutcomeResult
            (auctionWon, key,) = _solverExecutionIteration(
                dConfig,
                userOp,
                solverOps[sortedOps[i]],
                returnData,
                executionEnvironment,
                bundler,
                userOpHash,
                bidAmounts[sortedOps[i]],
                key
            );

            if (auctionWon) {
                i = sortedOps[i];
                break;
            }
        }
        return (auctionWon, i, key);
    }

    function _solverExecutionIteration(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation calldata solverOp,
        bytes memory dAppReturnData,
        address executionEnvironment,
        address bundler,
        bytes32 userOpHash,
        uint256 bidAmount,
        EscrowKey memory key
    )
        internal
        returns (bool auctionWon, EscrowKey memory, uint256 solverOutcomeResult)
    {
        (auctionWon, key, solverOutcomeResult) = _executeSolverOperation(
            dConfig, userOp, solverOp, dAppReturnData, executionEnvironment, bundler, userOpHash, bidAmount, key
        );

        if (auctionWon) {
            key = key.holdAllocateValueLock(solverOp.from);

            key.paymentsSuccessful =
                _allocateValue(dConfig, bidAmount, dAppReturnData, executionEnvironment, key.pack());
        }
        return (auctionWon, key, solverOutcomeResult);
    }

    function _handleErrors(bytes memory revertData, uint32 callConfig) internal view {
        bytes4 errorSwitch = bytes4(revertData);
        if (msg.sender == SIMULATOR) {
            // Simulation
            if (errorSwitch == PreOpsSimFail.selector) {
                revert PreOpsSimFail();
            } else if (errorSwitch == UserOpSimFail.selector) {
                revert UserOpSimFail();
            } else if (errorSwitch == SolverSimFail.selector) {
                // Expects revertData in form [bytes4, uint256]
                uint256 solverOutcomeResult;
                uint256 startIndex = revertData.length - 32;
                assembly {
                    solverOutcomeResult := mload(add(add(revertData, 0x20), startIndex))
                }
                revert SolverSimFail(solverOutcomeResult);
            } else if (errorSwitch == PostOpsSimFail.selector) {
                revert PostOpsSimFail();
            }
        }
        if (errorSwitch == UserNotFulfilled.selector) {
            revert UserNotFulfilled();
        }
        if (callConfig.allowsReuseUserOps()) {
            assembly {
                mstore(0, errorSwitch)
                revert(0, 4)
            }
        }
    }

    function _verifyCallerIsExecutionEnv(address user, address controller, uint32 callConfig) internal view override {
        if (msg.sender != _getExecutionEnvironmentCustom(user, controller.codehash, controller, callConfig)) {
            revert EnvironmentMismatch();
        }
    }
}
