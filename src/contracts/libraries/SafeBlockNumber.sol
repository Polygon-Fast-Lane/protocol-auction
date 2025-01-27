// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ArbSys } from "nitro-contracts/src/precompiles/ArbSys.sol";

library SafeBlockNumber {
    ArbSys internal constant ARB_SYS = ArbSys(address(0x0000000000000000000000000000000000000064));

    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    uint256 internal constant ARBITRUM_NOVA_CHAIN_ID = 42_170;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    function get() internal view returns (uint256) {
        uint256 chainId = block.chainid;
        if (
            chainId == ARBITRUM_ONE_CHAIN_ID || chainId == ARBITRUM_NOVA_CHAIN_ID
                || chainId == ARBITRUM_SEPOLIA_CHAIN_ID
        ) {
            // Arbitrum One or Nova chain
            return ARB_SYS.arbBlockNumber();
        } else {
            return block.number;
        }
    }
}
