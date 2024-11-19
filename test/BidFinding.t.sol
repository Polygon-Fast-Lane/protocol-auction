// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { LibSort } from "solady/utils/LibSort.sol";
import { BaseTest } from "./base/BaseTest.t.sol";

contract BidFindingTest is BaseTest {
    function test_bidFindingIteration_sortingOrder() public pure {
        // Test order of bidsAndIndices after insertionSort

        // 3 items. [200, 0, 100] --> [0, 100, 200]
        uint256[] memory bidsAndIndices = new uint256[](3);
        bidsAndIndices[0] = 100;
        bidsAndIndices[1] = 0;
        bidsAndIndices[2] = 300;

        LibSort.insertionSort(bidsAndIndices);
        assertEq(bidsAndIndices[0], 0);
        assertEq(bidsAndIndices[1], 100);
        assertEq(bidsAndIndices[2], 300);

        // 1 item. [100] --> [100]
        bidsAndIndices = new uint256[](1);
        bidsAndIndices[0] = 100;

        LibSort.insertionSort(bidsAndIndices);
        assertEq(bidsAndIndices[0], 100);

        // 2 items. [100, 0] --> [0, 100]
        bidsAndIndices = new uint256[](2);
        bidsAndIndices[0] = 100;
        bidsAndIndices[1] = 0;

        LibSort.insertionSort(bidsAndIndices);
        assertEq(bidsAndIndices[0], 0);
        assertEq(bidsAndIndices[1], 100);
    }

    function test_bidFindingIteration_packBidAndIndex() public pure {
        uint256 bid = 12_345;
        uint256 index = 2;

        uint256 packed = _packBidAndIndex(bid, index);
        (uint256 unpackedBid, uint256 unpackedIndex) = _unpackBidAndIndex(packed);
        assertEq(unpackedBid, bid);
        assertEq(unpackedIndex, index);

        bid = type(uint240).max - 1;
        index = 7;

        packed = _packBidAndIndex(bid, index);
        (unpackedBid, unpackedIndex) = _unpackBidAndIndex(packed);
        assertEq(unpackedBid, bid);
        assertEq(unpackedIndex, index);

        bid = 0;
        index = 1;

        packed = _packBidAndIndex(bid, index);
        (unpackedBid, unpackedIndex) = _unpackBidAndIndex(packed);
        assertEq(unpackedBid, bid);
        assertEq(unpackedIndex, index);

        bid = 1;
        index = 0;

        packed = _packBidAndIndex(bid, index);
        (unpackedBid, unpackedIndex) = _unpackBidAndIndex(packed);
        assertEq(unpackedBid, bid);
        assertEq(unpackedIndex, index);
    }

    // Packs bid and index into a single uint256, replicates logic used in `_bidFindingIteration()`
    function _packBidAndIndex(uint256 bid, uint256 index) internal pure returns (uint256) {
        return uint256(bid << 16 | uint16(index));
    }

    // Unpacks bid and index from a single uint256, replicates logic used in `_bidFindingIteration()`
    function _unpackBidAndIndex(uint256 packed) internal pure returns (uint256 bid, uint256 index) {
        // bidAmountFound = (bidsAndIndices[i] >> BITS_FOR_INDEX) & FIRST_240_BITS_MASK;
        bid = (packed >> 16) & uint256(0x0000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);

        // uint256 solverOpsIndex = bidsAndIndices[i] & FIRST_16_BITS_MASK;
        index = packed & uint256(0xFFFF);
    }
}
