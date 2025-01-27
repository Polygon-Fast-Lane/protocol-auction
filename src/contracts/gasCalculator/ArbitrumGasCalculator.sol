// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ArbGasInfo } from "nitro-contracts/src/precompiles/ArbGasInfo.sol";
import { IL2GasCalculator } from "src/contracts/interfaces/IL2GasCalculator.sol";

/// @title ArbitrumGasCalculator
/// @notice Calculates gas costs for transactions on Arbitrum
contract ArbitrumGasCalculator is IL2GasCalculator, Ownable {
    // Constants for gas calculations
    uint256 internal constant _CALLDATA_LENGTH_PREMIUM = 16;
    uint256 internal constant _BASE_TRANSACTION_GAS_USED = 21_000;

    // Interface to interact with Arbitrum's gas info precompile
    ArbGasInfo public immutable ARB_GAS_INFO;

    // Offset applied to calldata length for custom adjustments
    int256 public calldataLengthOffset;

    // Flag to indicate if this is Arbitrum Nova (true) or Arbitrum One (false)
    bool public isArbitrumNova;

    /// @notice Constructor
    /// @param calldataLenOffset Initial offset for calldata length calculations
    /// @param _isArbitrumNova Flag to indicate if this is Arbitrum Nova
    constructor(int256 calldataLenOffset, bool _isArbitrumNova) Ownable(msg.sender) {
        ARB_GAS_INFO = ArbGasInfo(address(0x6c));
        calldataLengthOffset = calldataLenOffset;
        isArbitrumNova = _isArbitrumNova;
    }

    /// @notice Calculate the cost of calldata in ETH
    /// @param calldataLength Length of the calldata
    /// @return calldataCostETH The cost of the calldata in ETH
    function getCalldataCost(uint256 calldataLength) external view override returns (uint256 calldataCostETH) {
        // Get gas prices from Arbitrum
        (uint256 perL2Tx,,,,, uint256 perArbGasTotal) = ARB_GAS_INFO.getPricesInWei();

        // Get L1 base fee estimate
        uint256 l1BaseFee = ARB_GAS_INFO.getL1BaseFeeEstimate();

        // Calculate L2 execution cost
        uint256 l2Cost = calldataLength * _CALLDATA_LENGTH_PREMIUM * perArbGasTotal;

        // Calculate L1 data cost
        uint256 l1Cost;
        if (isArbitrumNova) {
            // Nova doesn't distinguish between zero and non-zero bytes
            l1Cost = calldataLength * l1BaseFee;
        } else {
            // For Arbitrum One, we keep the original calculation
            // This assumes Arbitrum One might distinguish between zero and non-zero bytes
            // If it doesn't, this calculation might need adjustment
            l1Cost = calldataLength * _CALLDATA_LENGTH_PREMIUM * l1BaseFee;
        }

        // Apply calldata length offset
        int256 _calldataLenOffset = calldataLengthOffset;
        if (_calldataLenOffset < 0 && calldataLength < uint256(-_calldataLenOffset)) {
            return l2Cost;
        }
        l1Cost = l1Cost * uint256(int256(calldataLength) + _calldataLenOffset) / calldataLength;

        // Calculate total cost including per-transaction fee
        calldataCostETH = l2Cost + l1Cost + perL2Tx;
    }

    /// @notice Calculate the initial gas used for a transaction
    /// @param calldataLength Length of the calldata
    /// @return gasUsed The amount of gas used
    function initialGasUsed(uint256 calldataLength) external view override returns (uint256 gasUsed) {
        // Get the price per L1 calldata byte in ArbGas
        (, uint256 perL1CalldataByte,) = ARB_GAS_INFO.getPricesInArbGas();
        // Calculate initial gas used
        return _BASE_TRANSACTION_GAS_USED + (calldataLength * perL1CalldataByte);
    }

    /// @notice Set the calldata length offset
    /// @param calldataLenOffset New offset value
    function setCalldataLengthOffset(int256 calldataLenOffset) external onlyOwner {
        calldataLengthOffset = calldataLenOffset;
    }

    /// @notice Set the Arbitrum network type
    /// @param _isArbitrumNova Flag to indicate if this is Arbitrum Nova
    function setArbitrumNetworkType(bool _isArbitrumNova) external onlyOwner {
        isArbitrumNova = _isArbitrumNova;
    }
}
