//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IL2GasCalculator {
    /// @notice Calculate the cost of calldata in ETH on a L2 with a different fee structure than mainnet
    function getCalldataCost(uint256 calldataLength) external view returns (uint256 calldataCost);
    /// @notice Gets the cost of initial gas used for a transaction with a different calldata fee than mainnet
    function initialGasUsed(uint256 calldataLength) external view returns (uint256 gasUsed);
}
