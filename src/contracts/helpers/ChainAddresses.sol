// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ChainAddresses {
    // Arbitrum One addresses
    address constant WETH_ADDRESS = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // Arbitrum One WETH
    address constant DAI_ADDRESS = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // Arbitrum One DAI
    address constant USDC_ADDRESS = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // Arbitrum One USDC
    address constant UNISWAP_V2_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; // SushiSwap router on Arbitrum

    address constant GOVERNANCE_TOKEN = 0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0; // Arbitrum One UNI
    address constant WETH_X_GOVERNANCE_POOL = 0xf4a6c89E06318717657D352D16cFC7739D9a8B85;

    address constant UNISWAP_POOL_ONE = 0x8dca5a5DBA32cA529594d43F86ED4210EaD2Ed83; // Uniswap V2 WETH/DAI
    address constant UNISWAP_POOL_TWO = 0x692a0B300366D1042679397e40f3d2cb4b8F7D30; // SushiSwap V2 WETH/DAI

    function getWETHAddress() internal pure returns (address) {
        return WETH_ADDRESS;
    }

    function getDAIAddress() internal pure returns (address) {
        return DAI_ADDRESS;
    }

    function getUSDCAddress() internal pure returns (address) {
        return USDC_ADDRESS;
    }

    function getUniswapV2RouterAddress() internal pure returns (address) {
        return UNISWAP_V2_ROUTER;
    }
}
