// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Sorter } from "../src/contracts/helpers/Sorter.sol";

contract DeploySorterScript is DeployBaseScript {
    function run() external {
        console.log("\n=== DEPLOYING Sorter ===\n");

        console.log("Deploying to chain: ", _getDeployChain());

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address: \t\t\t\t", deployer);

        address atlasAddress = _getAddressFromDeploymentsJson("ATLAS");

        vm.startBroadcast(deployerPrivateKey);

        sorter = new Sorter(atlasAddress);

        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("SORTER", address(sorter));

        console.log("\n");
        console.log("Sorter deployed at: \t\t\t", address(sorter));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
