// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { Atlas } from "src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "src/contracts/atlas/AtlasVerification.sol";
import { SwapIntentDAppControl } from "src/contracts/examples/intents-example/SwapIntentDAppControl.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { Simulator } from "src/contracts/helpers/Simulator.sol";
import { Sorter } from "src/contracts/helpers/Sorter.sol";
import { SimpleRFQSolver } from "test/SwapIntent.t.sol";

import { Utilities } from "src/contracts/helpers/Utilities.sol";

contract DeployBaseScript is Script {
    using stdJson for string;

    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    Atlas public atlas;
    AtlasVerification public atlasVerification;
    Simulator public simulator;
    Sorter public sorter;
    SwapIntentDAppControl public swapIntentControl;
    TxBuilder public txBuilder;
    SimpleRFQSolver public rfqSolver;

    Utilities public u;

    // Uses block.chainid to determine current chain to update deployments.json
    function _getDeployChain() internal view returns (string memory) {
        uint256 chainId = block.chainid;

        if (chainId == 31_337) {
            return "LOCAL";
        } else if (chainId == 1) {
            return "MAINNET";
        } else if (chainId == 11_155_111) {
            return "SEPOLIA";
        } else if (chainId == 17_000) {
            return "HOLESKY";
        } else if (chainId == 137) {
            return "POLYGON";
        } else if (chainId == 80_002) {
            return "AMOY";
        } else if (chainId == 56) {
            return "BSC";
        } else if (chainId == 97) {
            return "BSC TESTNET";
        } else if (chainId == 10) {
            return "OP MAINNET";
        } else if (chainId == 11_155_420) {
            return "OP SEPOLIA";
        } else if (chainId == 42_161) {
            return "ARBITRUM";
        } else if (chainId == 42_170) {
            return "ARBITRUM_NOVA";
        } else if (chainId == 421_614) {
            return "ARBITRUM_SEPOLIA";
        } else if (chainId == 8453) {
            return "BASE";
        } else if (chainId == 84_532) {
            return "BASE SEPOLIA";
        } else {
            revert(string.concat("Error: Chain ID not recognized: ", vm.toString(chainId)));
        }
    }

    // NOTE: When handling JSON with StdJson, prefix keys with '.' e.g. '.ATLAS'
    // These 2 functions abstract away the '.' thing though.
    // Pass in a key like 'ATLAS', and the current chain will be detected via `block.chainid` in `_getDeployChain()`
    function _getAddressFromDeploymentsJson(string memory key) internal view returns (address) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");
        string memory json = vm.readFile(path);

        // Get target chain using `block.chainid` and use to form full key
        string memory fullKey = string.concat(".", _getDeployChain(), ".", key);

        // console.log("Getting", fullKey, "from deployments.json");

        // NOTE: Use fullKey method above for safety
        return json.readAddress(fullKey);
    }

    function _writeAddressToDeploymentsJson(string memory key, address addr) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");

        // Get target chain using `block.chainid` and use to form full key
        string memory fullKey = string.concat(".", _getDeployChain(), ".", key);

        // console.log(string.concat("Writing \t\t'", fullKey), "': '", addr, "'\t\t to deployments.json");

        // NOTE: Use fullKey method above for safety
        vm.writeJson(vm.toString(addr), path, fullKey);
    }

    function _getUsefulContractAddress(string memory key) internal view returns (address) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/useful-addresses.json");
        string memory json = vm.readFile(path);
        string memory fullKey = string.concat(".", _getDeployChain(), ".", key);

        address res = json.readAddress(fullKey);
        if (res == address(0x20) || res == address(0)) {
            revert(string.concat(fullKey, " not found in useful-addresses.json"));
        }
        return res;
    }

    function _logTokenBalances(address account, string memory accountLabel) internal view {
        console.log("Balances for", accountLabel);
        console.log("WETH balance: \t\t\t\t", WETH.balanceOf(account));
        console.log("DAI balance: \t\t\t\t\t", DAI.balanceOf(account));
        console.log("\n");
    }
}
