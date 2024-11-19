// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { V2RewardDAppControl } from "../src/contracts/examples/v2-example-router/V2RewardDAppControl.sol";

contract DeployV2RewardControlScript is DeployBaseScript {
    V2RewardDAppControl v2RewardControl;

    // NOTE: Change these to the relevant addresses on the target chain if not Sepolia.
    address public constant UNISWAP_V2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008; // on Sepolia
    // NOTE: Reward token must be the bidToken in the DAppControl. So it should be very accessible to solvers on the
    // target chain.
    address public constant REWARD_TOKEN = payable(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9); // real WETH on Sepolia
    // NOTE: Needs to be WETH recognized by the Uniswap V2 Router on the target chain for ETH <> WETH frontend demo to
    // work.

    function run() external {
        console.log("\n=== DEPLOYING V2Reward DAppControl ===\n");

        uint256 deployerPrivateKey = vm.envUint("DAPP_GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        atlas = Atlas(payable(_getAddressFromDeploymentsJson("ATLAS")));
        atlasVerification = AtlasVerification(payable(_getAddressFromDeploymentsJson("ATLAS_VERIFICATION")));

        console.log("Deployer address: \t\t\t\t", deployer);
        console.log("Using Atlas deployed at: \t\t\t", address(atlas));
        console.log("Using AtlasVerification deployed at: \t\t", address(atlasVerification));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the DAppControl contract
        v2RewardControl = new V2RewardDAppControl(address(atlas), REWARD_TOKEN, UNISWAP_V2_ROUTER);

        // Integrate SwapIntent with Atlas
        atlasVerification.initializeGovernance(address(v2RewardControl));

        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("V2_REWARD_DAPP_CONTROL", address(v2RewardControl));

        console.log("\n");
        console.log("V2Reward DAppControl deployed at: \t\t", address(v2RewardControl));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
