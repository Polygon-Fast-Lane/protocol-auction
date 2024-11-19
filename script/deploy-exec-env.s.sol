// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { ExecutionEnvironment } from "../src/contracts/common/ExecutionEnvironment.sol";

contract DeployExecEnvScript is DeployBaseScript {
    ExecutionEnvironment public execEnv;

    function run() external {
        console.log("\n=== DEPLOYING Execution Environment ===\n");

        console.log("Deploying to chain: ", _getDeployChain());

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address: \t\t\t\t", deployer);

        vm.startBroadcast(deployerPrivateKey);

        address atlasAddress = _getAddressFromDeploymentsJson("ATLAS");
        execEnv = new ExecutionEnvironment(atlasAddress);

        vm.stopBroadcast();

        console.log("\n");
        console.log("Execution Environment deployed at: \t\t\t\t", address(execEnv));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
