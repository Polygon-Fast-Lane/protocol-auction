// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SafeCall
/// @author FastLane Labs
/// @author Modified from Optimism's SafeCall lib
/// (https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/libraries/SafeCall.sol)
/// @notice Perform low level safe calls
library SafeCall {
    /// @notice Perform a low level call without copying any returndata
    /// @param _target   Address to call
    /// @param _gas      Amount of gas to pass to the call
    /// @param _value    Amount of value to pass to the call
    /// @param _calldata Calldata to pass to the call
    function safeCall(address _target, uint256 _gas, uint256 _value, bytes memory _calldata) internal returns (bool) {
        bool _success;
        assembly {
            _success :=
                call(
                    _gas, // gas
                    _target, // recipient
                    _value, // ether value
                    add(_calldata, 32), // inloc
                    mload(_calldata), // inlen
                    0, // outloc
                    0 // outlen
                )
        }
        return _success;
    }
}
