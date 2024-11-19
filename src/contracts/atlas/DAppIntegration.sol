//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IDAppControl } from "../interfaces/IDAppControl.sol";
import { IAtlas } from "../interfaces/IAtlas.sol";
import { CallBits } from "../libraries/CallBits.sol";
import { AtlasErrors } from "../types/AtlasErrors.sol";
import { AtlasEvents } from "../types/AtlasEvents.sol";

/// @title DAppIntegration
/// @author FastLane Labs
/// @notice DAppIntegration handles the integration of dApps and their signatories within the Atlas protocol.
contract DAppIntegration {
    using CallBits for uint32;

    address public immutable ATLAS;

    // map for tracking which accounts are approved for a given dApp
    // keccak256(governance, signor)  => enabled
    mapping(bytes32 => bool) internal S_signatories;

    // map that lists all signatories for a given dApp
    // DAppControl => signatories
    mapping(address => address[]) internal S_dAppSignatories;

    constructor(address atlas) {
        ATLAS = atlas;
    }

    // ---------------------------------------------------- //
    //                DApp Integration Functions            //
    // ---------------------------------------------------- //

    /// @notice Permissionlessly integrates a new dApp into the Atlas protocol.
    /// @param control The address of the DAppControl contract.
    function initializeGovernance(address control) external {
        _checkAtlasIsUnlocked();
        address _govAddress = IDAppControl(control).getDAppSignatory();
        if (msg.sender != _govAddress) revert AtlasErrors.OnlyGovernance();

        // Add DAppControl gov as a signatory
        _addSignatory(control, msg.sender);

        uint32 _callConfig = IDAppControl(control).CALL_CONFIG();
        emit AtlasEvents.NewDAppSignatory(control, _govAddress, msg.sender, _callConfig);
    }

    /// @notice Adds a new signatory to a dApp's list of approved signatories.
    /// @param control The address of the DAppControl contract.
    /// @param signatory The address of the new signatory.
    function addSignatory(address control, address signatory) external {
        _checkAtlasIsUnlocked();
        address _dAppGov = IDAppControl(control).getDAppSignatory();
        if (msg.sender != _dAppGov) revert AtlasErrors.OnlyGovernance();

        _addSignatory(control, signatory);

        uint32 _callConfig = IDAppControl(control).CALL_CONFIG();
        emit AtlasEvents.NewDAppSignatory(control, _dAppGov, signatory, _callConfig);
    }

    /// @notice Removes a signatory from a dApp's list of approved signatories.
    /// @param control The address of the DAppControl contract.
    function removeSignatory(address control, address signatory) external {
        _checkAtlasIsUnlocked();
        address _dAppGov = IDAppControl(control).getDAppSignatory();
        if (msg.sender != _dAppGov && msg.sender != signatory) {
            revert AtlasErrors.InvalidCaller();
        }

        _removeSignatory(control, signatory);

        uint32 _callConfig = IDAppControl(control).CALL_CONFIG();
        emit AtlasEvents.RemovedDAppSignatory(control, _dAppGov, signatory, _callConfig);
    }

    /// @notice Called by the DAppControl contract on acceptGovernance when governance is transferred.
    /// @dev Must be called by the DAppControl contract concerned and Atlas must be in an unlocked state.
    /// @param oldGovernance The address of the old governance.
    /// @param newGovernance The address of the new governance.
    function changeDAppGovernance(address oldGovernance, address newGovernance) external {
        _checkAtlasIsUnlocked();
        address _control = msg.sender;

        _removeSignatory(_control, oldGovernance);
        _addSignatory(_control, newGovernance);

        uint32 _callConfig = IDAppControl(_control).CALL_CONFIG();
        emit AtlasEvents.DAppGovernanceChanged(_control, oldGovernance, newGovernance, _callConfig);
    }

    /// @notice Disables a dApp from the Atlas protocol.
    /// @param control The address of the DAppControl contract.
    function disableDApp(address control) external {
        _checkAtlasIsUnlocked();
        address _dAppGov = IDAppControl(control).getDAppSignatory();
        if (msg.sender != _dAppGov) revert AtlasErrors.OnlyGovernance();

        // Remove the signatory
        _removeSignatory(control, _dAppGov);

        uint32 callConfig = IDAppControl(control).CALL_CONFIG();
        emit AtlasEvents.DAppDisabled(control, _dAppGov, callConfig);
    }

    // ---------------------------------------------------- //
    //                   Internal Functions                 //
    // ---------------------------------------------------- //

    /// @notice Returns whether a specified address is a signatory for a specified DAppControl contract.
    /// @param control The address of the DAppControl contract.
    /// @param signatory The address to check.
    /// @return A boolean indicating whether the specified address is a signatory for the specified DAppControl
    /// contract.
    function _isDAppSignatory(address control, address signatory) internal view returns (bool) {
        bytes32 _signatoryKey = keccak256(abi.encodePacked(control, signatory));
        return S_signatories[_signatoryKey];
    }

    /// @notice Adds a new signatory to a dApp's list of approved signatories.
    /// @param control The address of the DAppControl contract.
    /// @param signatory The address of the new signatory.
    function _addSignatory(address control, address signatory) internal {
        bytes32 _signatoryKey = keccak256(abi.encodePacked(control, signatory));
        if (S_signatories[_signatoryKey]) revert AtlasErrors.SignatoryActive();
        S_signatories[_signatoryKey] = true;
        S_dAppSignatories[control].push(signatory);
    }

    /// @notice Removes a signatory from a dApp's list of approved signatories.
    /// @param control The address of the DAppControl contract.
    /// @param signatory The address of the signatory to be removed.
    function _removeSignatory(address control, address signatory) internal {
        bytes32 _signatoryKey = keccak256(abi.encodePacked(control, signatory));

        // Check if the signatory exists
        if (!S_signatories[_signatoryKey]) revert AtlasErrors.InvalidSignatory();

        // Remove the signatory from the mapping
        delete S_signatories[_signatoryKey];

        // Iterate through the list of signatories and remove the specified signatory
        for (uint256 i; i < S_dAppSignatories[control].length; i++) {
            if (S_dAppSignatories[control][i] == signatory) {
                // Replace the signatory with the last element and pop the last element
                S_dAppSignatories[control][i] = S_dAppSignatories[control][S_dAppSignatories[control].length - 1];
                S_dAppSignatories[control].pop();
                return;
            }
        }

        // Revert if the signatory was not found in the list
        revert AtlasErrors.InvalidSignatory();
    }

    /// @notice Checks if the Atlas protocol is in an unlocked state. Will revert if not.
    function _checkAtlasIsUnlocked() internal view {
        if (!IAtlas(ATLAS).isUnlocked()) revert AtlasErrors.AtlasLockActive();
    }

    // ---------------------------------------------------- //
    //                     View Functions                   //
    // ---------------------------------------------------- //

    /// @notice Returns the governance address of a specified DAppControl contract.
    /// @param control The address of the DAppControl contract.
    /// @return The governance address of the specified DAppControl contract.
    function getGovFromControl(address control) external view returns (address) {
        address _dAppGov = IDAppControl(control).getDAppSignatory();
        if (!_isDAppSignatory(control, _dAppGov)) revert AtlasErrors.DAppNotEnabled();
        return _dAppGov;
    }

    /// @notice Returns whether a specified address is a signatory for a specified DAppControl contract.
    /// @param control The address of the DAppControl contract.
    /// @param signatory The address to check.
    /// @return A boolean indicating whether the specified address is a signatory for the specified DAppControl
    /// contract.
    function isDAppSignatory(address control, address signatory) external view returns (bool) {
        return _isDAppSignatory(control, signatory);
    }

    // ---------------------------------------------------- //
    //                      Storage Getters                 //
    // ---------------------------------------------------- //

    function signatories(bytes32 key) external view returns (bool) {
        return S_signatories[key];
    }

    /// @notice Returns an array of signatories for a specified DAppControl contract.
    /// @param control The address of the DAppControl contract.
    /// @return address[] An array of signatories for the specified DAppControl contract.
    function dAppSignatories(address control) external view returns (address[] memory) {
        return S_dAppSignatories[control];
    }
}
