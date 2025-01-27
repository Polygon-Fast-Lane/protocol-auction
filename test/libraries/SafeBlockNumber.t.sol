// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { ArbitrumTest } from "../arbitrum/ArbitrumTest.t.sol";
import "forge-std/Test.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";

contract SafeBlockNumberArbitrumTest is ArbitrumTest {
    function setUp() public override {
        super.setUp();
    }

    function testSafeBlockNumber() public {
        assertEq(SafeBlockNumber.get(), ArbitrumTest.ARBITRUM_BLOCK_NUMBER);
    }
}

contract SafeBlockNumberTest is Test {
    function testSafeBlockNumber() public {
        assertEq(SafeBlockNumber.get(), block.number);
    }
}
