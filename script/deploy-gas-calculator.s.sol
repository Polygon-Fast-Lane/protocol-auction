// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";
import { BaseGasCalculator } from "src/contracts/gasCalculator/BaseGasCalculator.sol";

contract DeployGasCalculatorScript is DeployBaseScript {
    // NOTE: Adjust the constructor parameters as needed here:
    // - BASE_GAS_PRICE_ORACLE: The address of the gas price oracle contract
    // - BASE_CALLDATA_LENGTH_OFFSET: The offset to be applied to the calldata length (can be negative or positive)
    // -----------------------------------------------------------------------------------------------
    address constant BASE_GAS_PRICE_ORACLE = address(0x420000000000000000000000000000000000000F);
    int256 constant BASE_CALLDATA_LENGTH_OFFSET = 0; // can be negative or positive
    // -----------------------------------------------------------------------------------------------

    function run() external {
        console.log("\n=== DEPLOYING GasCalculator ===\n");

        console.log("Deploying to chain: \t\t", _getDeployChain());

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t", deployer);

        uint256 chainId = block.chainid;
        address deploymentAddr;

        vm.startBroadcast(deployerPrivateKey);

        if (chainId == 8453 || chainId == 84_532) {
            // Base or Base Sepolia
            BaseGasCalculator gasCalculator = new BaseGasCalculator({
                gasPriceOracle: BASE_GAS_PRICE_ORACLE,
                calldataLenOffset: BASE_CALLDATA_LENGTH_OFFSET
            });
            deploymentAddr = address(gasCalculator);
        } else {
            revert("Error: Chain ID not supported");
        }

        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("L2_GAS_CALCULATOR", deploymentAddr);

        console.log("\n");
        console.log("-------------------------------------------------------------------------------");
        console.log("| Contract                    | Address                                       |");
        console.log("-------------------------------------------------------------------------------");
        console.log("| L2_GAS_CALCULATOR (Base)    | ", address(deploymentAddr), "  |");
        console.log("-------------------------------------------------------------------------------");
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
