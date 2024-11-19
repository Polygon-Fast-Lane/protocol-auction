//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { GasAccounting } from "./GasAccounting.sol";

import { SAFE_USER_TRANSFER, SAFE_DAPP_TRANSFER } from "../libraries/SafetyBits.sol";
import "../types/LockTypes.sol";
import "../types/EscrowTypes.sol";

// NOTE: Permit69 only works inside of the Atlas environment - specifically
// inside of the custom ExecutionEnvironments that each user deploys when
// interacting with Atlas in a manner controlled by the DeFi dApp.

// The name comes from the reciprocal nature of the token transfers. Both
// the user and the DAppControl can transfer tokens from the User
// and the DAppControl contracts... but only if they each have granted
// token approval to the Atlas main contract, and only during specific phases
// of the Atlas execution process.

/// @title Permit69
/// @author FastLane Labs
/// @notice Permit69 manages ERC20 approvals and transfers between Atlas and Execution Environment contracts during
/// metacall transactions.
abstract contract Permit69 is GasAccounting {
    constructor(
        uint256 escrowDuration,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator
    )
        GasAccounting(
            escrowDuration,
            atlasSurchargeRate,
            bundlerSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator
        )
    { }

    /// @notice Verifies that the caller is an authorized Execution Environment contract.
    /// @dev This function is called internally to ensure that the caller is a legitimate Execution Environment contract
    /// controlled by the current DAppControl contract. It helps prevent unauthorized access and ensures that
    /// token transfers are performed within the context of Atlas's controlled environment. The implementation of this
    /// function can be found in Atlas.sol
    /// @param environment ExecutionEnvironment address
    /// @param user The address of the user invoking the function.
    /// @param control The address of the current DAppControl contract.
    /// @param callConfig The CallConfig of the DAppControl contract of the current transaction.
    function _verifyUserControlExecutionEnv(
        address environment,
        address user,
        address control,
        uint32 callConfig
    )
        internal
        virtual
        returns (bool)
    { }

    /// @notice Transfers ERC20 tokens from a user to a destination address, only callable by the expected Execution
    /// Environment.
    /// @param token The address of the ERC20 token contract.
    /// @param destination The address to which the tokens will be transferred.
    /// @param amount The amount of tokens to transfer.
    /// @param user The address of the user invoking the function.
    /// @param control The address of the current DAppControl contract.
    function transferUserERC20(
        address token,
        address destination,
        uint256 amount,
        address user,
        address control
    )
        external
    {
        // Validate that the transfer is legitimate
        _validateTransfer({ user: user, control: control, safeExecutionPhaseSet: SAFE_USER_TRANSFER });

        // Transfer token
        SafeTransferLib.safeTransferFrom(token, user, destination, amount);
    }

    /// @notice Transfers ERC20 tokens from the DAppControl contract to a destination address, only callable by the
    /// expected Execution Environment.
    /// @param token The address of the ERC20 token contract.
    /// @param destination The address to which the tokens will be transferred.
    /// @param amount The amount of tokens to transfer.
    /// @param user The address of the user invoking the function.
    /// @param control The address of the current DAppControl contract.
    function transferDAppERC20(
        address token,
        address destination,
        uint256 amount,
        address user,
        address control
    )
        external
    {
        // Validate that the transfer is legitimate
        _validateTransfer({ user: user, control: control, safeExecutionPhaseSet: SAFE_DAPP_TRANSFER });

        // Transfer token
        SafeTransferLib.safeTransferFrom(token, control, destination, amount);
    }

    /// @notice Verifies whether the lock state allows execution in the specified safe execution phase.
    /// @param user The address of the user invoking the function.
    /// @param control The address of the current DAppControl contract.
    /// @param safeExecutionPhaseSet The set of safe execution phases.
    function _validateTransfer(address user, address control, uint8 safeExecutionPhaseSet) internal {
        (address _activeEnv, uint32 _callConfig, uint8 _currentPhase) = _lock();

        // Verify that the ExecutionEnvironment's context is correct.
        if (_activeEnv != msg.sender) {
            revert InvalidEnvironment();
        }

        // Verify that the given user and control are the owners of this ExecutionEnvironment
        if (!_verifyUserControlExecutionEnv(msg.sender, user, control, _callConfig)) {
            revert EnvironmentMismatch();
        }

        // Verify that the current phase allows for transfers
        if (1 << _currentPhase & safeExecutionPhaseSet == 0) {
            revert InvalidLockState();
        }
    }
}
