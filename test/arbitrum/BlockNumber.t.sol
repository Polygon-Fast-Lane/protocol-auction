// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "forge-std/Test.sol";
import { ArbitrumTest } from "./ArbitrumTest.t.sol";

import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";

contract BlockNumberTest is ArbitrumTest {
    function setUp() public override {
        super.setUp();
    }

    function testBlockNumber() public {
        uint256 currentBlockNumber = block.number;
        uint256 arbBlockNumber = SafeBlockNumber.get();
        console.log("Current block number:", currentBlockNumber);
        console.log("Arbitrum block number:", arbBlockNumber);

        // You can add assertions here if needed
        // For example:
        // assertGt(currentBlockNumber, 0, "Block number should be greater than 0");
    }
}
