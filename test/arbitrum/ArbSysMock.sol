// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ArbSysMock
/// @notice a mocked version of the Arbitrum system contract, add additional methods as needed
contract ArbSysMock {
    uint256 private _arbBlockNumber;

    /// @notice Get Arbitrum block number (distinct from L1 block number; Arbitrum genesis block has block number 0)
    /// @return block number as uint256
    function arbBlockNumber() external view returns (uint256) {
        return _arbBlockNumber;
    }

    /// @notice Set Arbitrum block number (distinct from L1 block number; Arbitrum genesis block has block number 0)
    /// @param blockNumber block number as uint256
    function setArbBlockNumber(uint256 blockNumber) external {
        _arbBlockNumber = blockNumber;
    }
}
