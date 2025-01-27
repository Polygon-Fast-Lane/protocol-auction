// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract ArbGasInfoMock {
    /// @notice Get gas prices.
    /// @return return gas prices in wei
    ///        (
    ///            per L2 tx,
    ///            per L1 calldata byte
    ///            per storage allocation,
    ///            per ArbGas base,
    ///            per ArbGas congestion,
    ///            per ArbGas total
    ///        )
    function getPricesInWei() external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        // Realistic values for testing
        return (224_423_613_120, 1_603_025_808, 200_000_000_000, 10_000_000, 0, 10_000_000);
    }

    /// @notice Get prices in ArbGas.
    /// @return (per L2 tx, per L1 calldata byte, per storage allocation)
    function getPricesInArbGas() external pure returns (uint256, uint256, uint256) {
        // Realistic values for testing
        return (22_442, 160, 20_000);
    }

    /// @notice Get ArbOS's estimate of the L1 basefee in wei
    function getL1BaseFeeEstimate() external pure returns (uint256) {
        return 100_189_113;
    }

    // Implement other functions from ArbGasInfo interface as needed, returning static values
}
