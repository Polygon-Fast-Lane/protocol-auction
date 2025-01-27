// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ArbitrumGasCalculator } from "src/contracts/gasCalculator/ArbitrumGasCalculator.sol";
import { ArbGasInfoMock } from "../arbitrum/ArbGasInfoMock.sol";
import { ArbitrumTest } from "../arbitrum/ArbitrumTest.t.sol";

contract ArbitrumGasCalculatorTest is ArbitrumTest {
    ArbitrumGasCalculator public calculator;
    ArbGasInfoMock public arbGasInfoMock;

    function setUp() public override {
        super.setUp();
        // Deploy the calculator with initial values
        calculator = new ArbitrumGasCalculator(0, false);
    }

    function testGetCalldataCost() public {
        uint256 calldataLength = 100;
        uint256 cost = calculator.getCalldataCost(calldataLength);

        // Calculate expected cost based on our mock values and calculator logic
        uint256 perL2Tx = 224_423_613_120;
        uint256 perArbGasTotal = 10_000_000;
        uint256 l1BaseFee = 100_189_113;

        uint256 expectedL2Cost = calldataLength * 16 * perArbGasTotal;
        uint256 expectedL1Cost = calldataLength * 16 * l1BaseFee;
        uint256 expectedTotalCost = expectedL2Cost + expectedL1Cost + perL2Tx;

        assertEq(cost, expectedTotalCost, "Calldata cost calculation is incorrect");
    }

    function testInitialGasUsed() public {
        uint256 calldataLength = 100;
        uint256 gasUsed = calculator.initialGasUsed(calldataLength);

        // Calculate expected gas used based on our mock values and calculator logic
        uint256 perL1CalldataByte = 160;
        uint256 expectedGasUsed = 21_000 + (calldataLength * perL1CalldataByte);

        assertEq(gasUsed, expectedGasUsed, "Initial gas used calculation is incorrect");
    }

    function testArbitrumNovaCalculation() public {
        // Set calculator to Arbitrum Nova mode
        calculator.setArbitrumNetworkType(true);

        uint256 calldataLength = 100;
        uint256 cost = calculator.getCalldataCost(calldataLength);

        // Calculate expected cost for Nova
        uint256 perL2Tx = 224_423_613_120;
        uint256 perArbGasTotal = 10_000_000;
        uint256 l1BaseFee = 100_189_113;

        uint256 expectedL2Cost = calldataLength * 16 * perArbGasTotal;
        uint256 expectedL1Cost = calldataLength * l1BaseFee; // Note: No 16 multiplier for Nova
        uint256 expectedTotalCost = expectedL2Cost + expectedL1Cost + perL2Tx;

        assertEq(cost, expectedTotalCost, "Arbitrum Nova calldata cost calculation is incorrect");
    }

    function testSetCalldataLengthOffset() public {
        calculator.setCalldataLengthOffset(50);
        assertEq(calculator.calldataLengthOffset(), 50, "Calldata length offset was not set correctly");
    }

    function testSetArbitrumNetworkType() public {
        calculator.setArbitrumNetworkType(true);
        assertTrue(calculator.isArbitrumNova(), "Arbitrum network type was not set to Nova");

        calculator.setArbitrumNetworkType(false);
        assertFalse(calculator.isArbitrumNova(), "Arbitrum network type was not set to One");
    }
}
