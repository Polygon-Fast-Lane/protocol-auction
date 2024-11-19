// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { FastLaneOnlineOuter } from "../src/contracts/examples/fastlane-online/FastLaneOnlineOuter.sol";

contract DeployFLOnlineControlScript is DeployBaseScript {
    FastLaneOnlineOuter flOnline;

    function run() external {
        console.log("\n=== DEPLOYING FastLane Online DAppControl ===\n");

        uint256 deployerPrivateKey = vm.envUint("DAPP_GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address protocolGuild = _getUsefulContractAddress("PROTOCOL_GUILD");

        atlas = Atlas(payable(_getAddressFromDeploymentsJson("ATLAS")));
        atlasVerification = AtlasVerification(payable(_getAddressFromDeploymentsJson("ATLAS_VERIFICATION")));

        console.log("Deploying to chain: \t\t\t\t", _getDeployChain(), "\n");
        console.log("Deployer address: \t\t\t\t", deployer);
        console.log("Using Atlas deployed at: \t\t\t", address(atlas));
        console.log("Using AtlasVerification deployed at: \t\t", address(atlasVerification));
        console.log("Using Protocol Guild wallet: \t\t\t", protocolGuild);

        vm.startBroadcast(deployerPrivateKey);
        // Deploy the DAppControl contract
        flOnline = new FastLaneOnlineOuter(address(atlas), protocolGuild);
        // Integrate FLOnline with Atlas
        atlasVerification.initializeGovernance(address(flOnline));
        // FLOnline contract must be registered as its own signatory
        atlasVerification.addSignatory(address(flOnline), address(flOnline));
        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("FL_ONLINE_DAPP_CONTROL", address(flOnline));

        console.log("\n");
        console.log("FastLane Online DAppControl deployed at: \t", address(flOnline));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
