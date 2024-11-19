//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "../../dapp/DAppControl.sol";
import { DAppOperation } from "../../types/DAppOperation.sol";
import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";

// Interface Import
import { IAtlasVerification } from "../../interfaces/IAtlasVerification.sol";
import { IExecutionEnvironment } from "../../interfaces/IExecutionEnvironment.sol";
import { IAtlas } from "../../interfaces/IAtlas.sol";

import { FastLaneOnlineControl } from "./FastLaneControl.sol";
import { FastLaneOnlineInner } from "./FastLaneOnlineInner.sol";
import { SolverGateway } from "./SolverGateway.sol";

import { SwapIntent, BaselineCall } from "./FastLaneTypes.sol";

contract FastLaneOnlineOuter is SolverGateway {
    constructor(address atlas, address protocolGuildWallet) SolverGateway(atlas, protocolGuildWallet) { }

    //////////////////////////////////////////////
    // THIS IS WHAT THE USER INTERACTS THROUGH.
    //////////////////////////////////////////////
    function fastOnlineSwap(UserOperation calldata userOp) external payable withUserLock(msg.sender) onlyAsControl {
        // Calculate the magnitude of the impact of this tx on reputation
        uint256 _repMagnitude = gasleft() * tx.gasprice;

        // Track the gas token balance to repay the swapper with
        uint256 _gasRefundTracker = address(this).balance - msg.value;

        // Get the userOpHash
        bytes32 _userOpHash = IAtlasVerification(ATLAS_VERIFICATION).getUserOperationHash(userOp);

        // Run gas limit checks on the userOp
        _validateSwap(userOp);

        // Get and sortSolverOperations
        (SolverOperation[] memory _solverOps, uint256 _gasReserved) = _getSolverOps(_userOpHash);
        _solverOps = _sortSolverOps(_solverOps);

        // Build dApp operation
        DAppOperation memory _dAppOp = _getDAppOp(_userOpHash, userOp.deadline);

        // Atlas call
        (bool _success,) = ATLAS.call{ value: msg.value, gas: _metacallGasLimit(_gasReserved, userOp.gas, gasleft()) }(
            abi.encodeCall(IAtlas.metacall, (userOp, _solverOps, _dAppOp, address(0)))
        );

        // Revert if the metacall failed - neither solvers nor baseline call fulfilled swap intent
        if (!_success) revert FLOnlineOuter_FastOnlineSwap_NoFulfillment();

        // Find out if any of the solvers were successful
        _success = _getWinningSolver() != address(0);

        // Update Reputation
        _updateSolverReputation(_solverOps, uint128(_repMagnitude));

        // Handle gas token balance reimbursement (reimbursement from Atlas and the congestion buy ins)
        _gasRefundTracker = _processCongestionRake(_gasRefundTracker, _userOpHash, _success);

        // Transfer the appropriate gas tokens
        if (_gasRefundTracker > 0) SafeTransferLib.safeTransferETH(msg.sender, _gasRefundTracker);
    }

    function _validateSwap(UserOperation calldata userOp) internal {
        if (msg.sender != userOp.from) revert FLOnlineOuter_ValidateSwap_InvalidSender();

        if (userOp.gas <= MAX_SOLVER_GAS * 2) {
            revert FLOnlineOuter_ValidateSwap_GasLimitTooLow();
        }

        (SwapIntent memory _swapIntent, BaselineCall memory _baselineCall) =
            abi.decode(userOp.data[4:], (SwapIntent, BaselineCall));

        // Verify that if we're dealing with the native token that the balances add up
        if (_swapIntent.tokenUserSells == _NATIVE_TOKEN) {
            if (msg.value < userOp.value) revert FLOnlineOuter_ValidateSwap_MsgValueTooLow();
            if (userOp.value < _swapIntent.amountUserSells) revert FLOnlineOuter_ValidateSwap_UserOpValueTooLow();
            if (userOp.value != _baselineCall.value) revert FLOnlineOuter_ValidateSwap_UserOpBaselineValueMismatch();
        }
    }

    function _metacallGasLimit(
        uint256 cumulativeGasReserved,
        uint256 totalGas,
        uint256 gasLeft
    )
        internal
        pure
        returns (uint256 metacallGasLimit)
    {
        // Reduce any unnecessary gas to avoid Atlas's excessive gas bundler penalty

        // About 850k gas extra required to pass Atlas internal checks
        cumulativeGasReserved += 850_000;

        // Sets metacallGasLimit to the minimum of {totalGas, gasLeft, cumulativeGasReserved}
        metacallGasLimit = totalGas > gasLeft
            ? (gasLeft > cumulativeGasReserved ? cumulativeGasReserved : gasLeft)
            : (totalGas > cumulativeGasReserved ? cumulativeGasReserved : totalGas);
    }

    fallback() external payable { }

    receive() external payable { }
}
