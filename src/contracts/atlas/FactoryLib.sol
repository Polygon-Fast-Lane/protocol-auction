//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Mimic } from "../common/Mimic.sol";
import { AtlasEvents } from "../types/AtlasEvents.sol";

// NOTE: Do not call these functions directly. This contract should only ever be delegatecalled by the Atlas contract.

contract FactoryLib {
    address public immutable EXECUTION_ENV_TEMPLATE;

    /// @notice Initializes a new Factory contract instance by setting the immutable salt for deterministic deployment
    /// of Execution Environments and storing the execution template address.
    /// @dev The Execution Environment Template must be separately deployed using the same calculated salt.
    /// @param executionTemplate Address of the pre-deployed execution template contract for creating Execution
    /// Environment instances.
    constructor(address executionTemplate) {
        EXECUTION_ENV_TEMPLATE = executionTemplate;
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
    function getOrCreateExecutionEnvironment(
        address user,
        address control,
        uint32 callConfig,
        bytes32 salt
    )
        public
        payable
        returns (address executionEnvironment)
    {
        bytes memory _creationCode = _getMimicCreationCode({ user: user, control: control, callConfig: callConfig });

        executionEnvironment = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(abi.encodePacked(_creationCode)))
                    )
                )
            )
        );

        if (executionEnvironment.code.length == 0) {
            assembly {
                executionEnvironment := create2(0, add(_creationCode, 32), mload(_creationCode), salt)
            }
            emit AtlasEvents.ExecutionEnvironmentCreated(user, executionEnvironment);
        }
    }

    /// @notice Generates the address of a user's execution environment affected by deprecated callConfig changes in the
    /// DAppControl.
    /// @dev Calculates the deterministic address of the execution environment based on the user, control,
    /// callConfig, and controlCodeHash, ensuring consistency across changes in callConfig.
    /// @param user The address of the user for whom the execution environment's address is being generated.
    /// @param control The address of the DAppControl contract associated with the execution environment.
    /// @param callConfig The configuration flags defining the behavior of the execution environment.
    /// @return executionEnvironment The address of the user's execution environment.
    function getExecutionEnvironmentCustom(
        address user,
        address control,
        uint32 callConfig,
        bytes32 salt
    )
        public
        view
        returns (address executionEnvironment)
    {
        bytes memory _creationCode = _getMimicCreationCode({ user: user, control: control, callConfig: callConfig });

        executionEnvironment = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(abi.encodePacked(_creationCode)))
                    )
                )
            )
        );
    }

    /// @notice Generates the creation code for the execution environment contract.
    /// @param control The address of the DAppControl contract associated with the execution environment.
    /// @param callConfig The configuration flags defining the behavior of the execution environment.
    /// @param user The address of the user for whom the execution environment is being created, contributing to the
    /// uniqueness of the creation code.
    /// @return creationCode The bytecode representing the creation code of the execution environment contract.
    function _getMimicCreationCode(
        address user,
        address control,
        uint32 callConfig
    )
        internal
        view
        returns (bytes memory creationCode)
    {
        address _executionLib = EXECUTION_ENV_TEMPLATE;
        // NOTE: Changing compiler settings or solidity versions can break this.
        creationCode = type(Mimic).creationCode;

        assembly {
            // Insert the ExecutionEnvironment "Lib" address, into the AAAA placeholder in the creation code.
            mstore(
                add(creationCode, 79),
                or(
                    and(mload(add(creationCode, 79)), not(shl(96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))),
                    shl(96, _executionLib)
                )
            )

            // Insert the user address into the BBBB placeholder in the creation code.
            mstore(
                add(creationCode, 111),
                or(
                    and(mload(add(creationCode, 111)), not(shl(96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))),
                    shl(96, user)
                )
            )

            // Insert the control address into the CCCC placeholder in the creation code.
            mstore(
                add(creationCode, 132),
                or(
                    and(mload(add(creationCode, 132)), not(shl(96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))),
                    shl(96, control)
                )
            )

            // Insert the callConfig into the 2222 placeholder in the creation code.
            mstore(
                add(creationCode, 153),
                or(and(mload(add(creationCode, 153)), not(shl(224, 0xFFFFFFFF))), shl(224, callConfig))
            )
        }
    }
}
