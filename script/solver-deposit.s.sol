// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";

// NOTE: When handling JSON with StdJson, prefix keys with '.' e.g. '.ATLAS'

contract SolverAtlasDepositScript is DeployBaseScript {
    function run() external {
        console.log("\n=== Solver 1 Deposits Into Atlas ===\n");

        uint256 privateKey = vm.envUint("SOLVER1_PRIVATE_KEY");
        address solver = vm.addr(privateKey);

        address atlasAddress = _getAddressFromDeploymentsJson(".ATLAS");
        Atlas atlas = Atlas(payable(atlasAddress));

        console.log("Solver address: \t\t\t\t", solver);
        console.log("Atlas address: \t\t\t\t", atlasAddress);

        vm.startBroadcast(privateKey);

        // Solver deposits 1 ETH into Atlas on his own behalf
        atlas.deposit{ value: 1 ether }();

        vm.stopBroadcast();

        console.log("\n");
        console.log("Solver 1's new Atlas locked balance: \t\t", atlas.balanceOf(solver));
    }
}
