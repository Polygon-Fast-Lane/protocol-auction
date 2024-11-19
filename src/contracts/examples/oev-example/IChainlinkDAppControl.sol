//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IChainlinkDAppControl {
    function verifyTransmitSigners(
        address baseChainlinkFeed,
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        external
        view
        returns (bool verified);
}
