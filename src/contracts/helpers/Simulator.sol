//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import "../types/SolverOperation.sol";
import "../types/UserOperation.sol";
import "../types/LockTypes.sol";
import "../types/DAppOperation.sol";
import "../types/ConfigTypes.sol";
import "../types/ValidCalls.sol";
import "../types/EscrowTypes.sol";
import { AtlasErrors } from "../types/AtlasErrors.sol";
import { Result } from "../interfaces/ISimulator.sol";
import { IAtlas } from "../interfaces/IAtlas.sol";

contract Simulator is AtlasErrors {
    address public immutable deployer;
    address public atlas;

    event DeployerWithdrawal(address indexed to, uint256 amount);

    constructor() {
        deployer = msg.sender;
    }

    function simUserOperation(UserOperation calldata userOp)
        external
        payable
        returns (bool success, Result simResult, uint256)
    {
        if (userOp.value > address(this).balance) revert SimulatorBalanceTooLow();

        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dAppOp;
        dAppOp.to = atlas;
        dAppOp.control = userOp.control;

        (Result result, uint256 validCallsResult) = _errorCatcher(userOp, solverOps, dAppOp);
        success = uint8(result) > uint8(Result.UserOpSimFail);
        if (success) validCallsResult = uint256(ValidCallsResult.Valid);
        if (msg.value != 0) SafeTransferLib.safeTransferETH(msg.sender, msg.value);
        return (success, result, validCallsResult);
    }

    function simSolverCall(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp,
        DAppOperation calldata dAppOp
    )
        external
        payable
        returns (bool success, Result simResult, uint256)
    {
        if (userOp.value > address(this).balance) revert SimulatorBalanceTooLow();

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        (Result result, uint256 solverOutcomeResult) = _errorCatcher(userOp, solverOps, dAppOp);
        success = result == Result.SimulationPassed;
        if (success) solverOutcomeResult = 0; // discard additional error uint if solver stage was successful
        if (msg.value != 0) SafeTransferLib.safeTransferETH(msg.sender, msg.value);
        return (success, result, solverOutcomeResult);
    }

    function simSolverCalls(
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp
    )
        external
        payable
        returns (bool success, Result simResult, uint256)
    {
        if (userOp.value > address(this).balance) revert SimulatorBalanceTooLow();

        if (solverOps.length == 0) {
            // Returns number out of usual range of SolverOutcome enum to indicate no solverOps
            return (false, Result.Unknown, uint256(type(SolverOutcome).max) + 1);
        }
        (Result result, uint256 solverOutcomeResult) = _errorCatcher(userOp, solverOps, dAppOp);
        success = result == Result.SimulationPassed;
        if (success) solverOutcomeResult = 0; // discard additional error uint if solver stage was successful
        if (msg.value != 0) SafeTransferLib.safeTransferETH(msg.sender, msg.value);
        return (success, result, solverOutcomeResult);
    }

    function _errorCatcher(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps,
        DAppOperation memory dAppOp
    )
        internal
        returns (Result result, uint256 additionalErrorCode)
    {
        try this.metacallSimulation{ value: userOp.value }(userOp, solverOps, dAppOp) {
            revert Unreachable();
        } catch (bytes memory revertData) {
            bytes4 errorSwitch = bytes4(revertData);
            if (errorSwitch == VerificationSimFail.selector) {
                // revertData in form [bytes4, uint256] but reverts on abi.decode
                // This decodes the uint256 error code portion of the revertData
                uint256 validCallsResult;
                assembly {
                    let dataLocation := add(revertData, 0x20)
                    validCallsResult := mload(add(dataLocation, sub(mload(revertData), 32)))
                }
                result = Result.VerificationSimFail;
                additionalErrorCode = validCallsResult;
            } else if (errorSwitch == PreOpsSimFail.selector) {
                result = Result.PreOpsSimFail;
            } else if (errorSwitch == UserOpSimFail.selector) {
                result = Result.UserOpSimFail;
            } else if (errorSwitch == SolverSimFail.selector) {
                // Expects revertData in form [bytes4, uint256]
                uint256 solverOutcomeResult;
                assembly {
                    let dataLocation := add(revertData, 0x20)
                    solverOutcomeResult := mload(add(dataLocation, sub(mload(revertData), 32)))
                }
                result = Result.SolverSimFail;
                additionalErrorCode = solverOutcomeResult;
            } else if (errorSwitch == AllocateValueSimFail.selector) {
                result = Result.AllocateValueSimFail;
            } else if (errorSwitch == PostOpsSimFail.selector) {
                result = Result.PostOpsSimFail;
            } else if (errorSwitch == SimulationPassed.selector) {
                result = Result.SimulationPassed;
            } else {
                result = Result.Unknown;
            }

            return (result, additionalErrorCode);
        }
    }

    function metacallSimulation(
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp
    )
        external
        payable
    {
        if (msg.sender != address(this)) revert InvalidEntryFunction();
        if (!IAtlas(atlas).metacall{ value: msg.value }(userOp, solverOps, dAppOp, address(0))) {
            revert NoAuctionWinner(); // should be unreachable
        }
        revert SimulationPassed();
    }

    // ---------------------------------------------------- //
    //                   Deployer Functions                 //
    // ---------------------------------------------------- //

    function setAtlas(address _atlas) external {
        if (msg.sender != deployer) revert Unauthorized();
        atlas = _atlas;
    }

    function withdrawETH(address to) external {
        if (msg.sender != deployer) revert Unauthorized();
        uint256 _balance = address(this).balance;
        SafeTransferLib.safeTransferETH(to, _balance);
        emit DeployerWithdrawal(to, _balance);
    }

    receive() external payable { }
    fallback() external payable { }
}
