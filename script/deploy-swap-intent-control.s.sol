// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { SwapIntentDAppControl } from "../src/contracts/examples/intents-example/SwapIntentDAppControl.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";
import { Simulator } from "../src/contracts/helpers/Simulator.sol";

contract DeploySwapIntentControlScript is DeployBaseScript {
    function run() external {
        console.log("\n=== DEPLOYING SwapIntent DAppControl ===\n");
        console.log("And setting up with initializeGovernance and integrateDApp\n");

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        atlas = Atlas(payable(_getAddressFromDeploymentsJson("ATLAS")));
        atlasVerification = AtlasVerification(payable(_getAddressFromDeploymentsJson("ATLAS_VERIFICATION")));

        console.log("Deployer address: \t\t\t\t", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the SwapIntent DAppControl contract
        swapIntentControl = new SwapIntentDAppControl(address(atlas));

        // Integrate SwapIntent with Atlas
        atlasVerification.initializeGovernance(address(swapIntentControl));

        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("SWAP_INTENT_DAPP_CONTROL", address(swapIntentControl));

        console.log("\n");
        console.log("SwapIntent DAppControl deployed at: \t\t", address(swapIntentControl));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
