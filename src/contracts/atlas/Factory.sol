//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { FactoryLib } from "./FactoryLib.sol";

import { IDAppControl } from "../interfaces/IDAppControl.sol";
import { DAppConfig } from "../types/ConfigTypes.sol";
import { UserOperation } from "../types/UserOperation.sol";
import { AtlasErrors } from "../types/AtlasErrors.sol";

abstract contract Factory {
    address public immutable FACTORY_LIB;
    bytes32 internal immutable _FACTORY_BASE_SALT;

    constructor(address factoryLib) {
        FACTORY_LIB = factoryLib;
        _FACTORY_BASE_SALT = keccak256(abi.encodePacked(block.chainid, address(this)));
    }

    /// @notice Creates a new Execution Environment for the caller, given a DAppControl contract address.
    /// @param user The address of the user for whom the execution environment is being created.
    /// @param control The address of the DAppControl contract for which the execution environment is being created.
    /// @return executionEnvironment The address of the newly created Execution Environment instance.
    function createExecutionEnvironment(
        address user,
        address control
    )
        external
        returns (address executionEnvironment)
    {
        if (msg.sender != user && msg.sender != control) revert AtlasErrors.Unauthorized();
        uint32 _callConfig = IDAppControl(control).CALL_CONFIG();
        executionEnvironment =
            _getOrCreateExecutionEnvironment({ user: user, control: control, callConfig: _callConfig });
    }

    /// @notice Retrieves the address and configuration of an existing execution environment for a given user and DApp
    /// control contract.
    /// @param user The address of the user for whom the execution environment is being queried.
    /// @param control The address of the DAppControl contract associated with the execution environment.
    /// @return executionEnvironment The address of the queried execution environment.
    /// @return callConfig The call configuration used by the execution environment, retrieved from the DAppControl
    /// contract.
    /// @return exists A boolean indicating whether the execution environment already exists (true) or not (false).
    function getExecutionEnvironment(
        address user,
        address control
    )
        external
        returns (address executionEnvironment, uint32 callConfig, bool exists)
    {
        callConfig = IDAppControl(control).CALL_CONFIG();
        executionEnvironment = _getExecutionEnvironmentCustom(user, control, callConfig);
        exists = executionEnvironment.code.length != 0;
    }

    /// @notice Gets an existing execution environment or creates a new one if it does not exist for the specified user
    /// operation.
    /// @param userOp The user operation containing details about the user and the DAppControl contract.
    /// @return executionEnvironment The address of the execution environment that was found or created.
    /// @return dConfig The DAppConfig for the execution environment, specifying how operations should be handled.
    function _getOrCreateExecutionEnvironment(UserOperation calldata userOp)
        internal
        returns (address executionEnvironment, DAppConfig memory dConfig)
    {
        dConfig = IDAppControl(userOp.control).getDAppConfig(userOp);
        executionEnvironment = _getOrCreateExecutionEnvironment({
            user: userOp.from,
            control: userOp.control,
            callConfig: dConfig.callConfig
        });
    }

    /// @notice Deploys a new execution environment or retrieves the address of an existing one based on the DApp
    /// control, user, and configuration.
    /// @dev Uses the `create2` opcode for deterministic deployment, allowing the calculation of the execution
    /// environment's address before deployment. The deployment uses a combination of the DAppControl address, user
    /// address, call configuration, and a unique salt to ensure the uniqueness and predictability of the environment's
    /// address.
    /// @param user The address of the user for whom the execution environment is being set.
    /// @param control The address of the DAppControl contract providing the operational context.
    /// @param callConfig CallConfig settings of the DAppControl contract.
    /// @return executionEnvironment The address of the newly created or already existing execution environment.
    function _getOrCreateExecutionEnvironment(
        address user,
        address control,
        uint32 callConfig
    )
        internal
        returns (address executionEnvironment)
    {
        bytes32 _salt = _computeSalt(user, control, callConfig);

        bytes memory returnData = _delegatecallFactoryLib(
            abi.encodeCall(FactoryLib.getOrCreateExecutionEnvironment, (user, control, callConfig, _salt))
        );

        return abi.decode(returnData, (address));
    }

    /// @notice Generates the address of a user's execution environment affected by deprecated callConfig changes in the
    /// DAppControl.
    /// @dev Calculates the deterministic address of the execution environment based on the user, control,
    /// callConfig, and controlCodeHash, ensuring consistency across changes in callConfig.
    /// @param user The address of the user for whom the execution environment's address is being generated.
    /// @param control The address of the DAppControl contract associated with the execution environment.
    /// @param callConfig The configuration flags defining the behavior of the execution environment.
    /// @return executionEnvironment The address of the user's execution environment.
    function _getExecutionEnvironmentCustom(
        address user,
        address control,
        uint32 callConfig
    )
        internal
        returns (address executionEnvironment)
    {
        bytes32 _salt = _computeSalt(user, control, callConfig);

        bytes memory returnData = _delegatecallFactoryLib(
            abi.encodeCall(FactoryLib.getExecutionEnvironmentCustom, (user, control, callConfig, _salt))
        );

        return abi.decode(returnData, (address));
    }

    function _computeSalt(address user, address control, uint32 callConfig) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_FACTORY_BASE_SALT, user, control, callConfig));
    }

    function _delegatecallFactoryLib(bytes memory data) internal returns (bytes memory) {
        (bool _success, bytes memory _result) = FACTORY_LIB.delegatecall(data);
        if (!_success) {
            assembly {
                revert(add(_result, 32), mload(_result))
            }
        }
        return _result;
    }
}
