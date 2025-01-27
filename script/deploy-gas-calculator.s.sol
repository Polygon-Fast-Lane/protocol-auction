// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import { DeployBaseScript } from "script/base/deploy-base.s.sol";
import { ArbitrumGasCalculator } from "src/contracts/gasCalculator/ArbitrumGasCalculator.sol";

contract DeployGasCalculatorScript is DeployBaseScript {
    int256 private constant ARBITRUM_CALLDATA_LENGTH_OFFSET = 0;

    function run() external returns (address) {
        console.log("\n=== DEPLOYING Gas Calculator ===\n");
        console.log("Deploying to chain: \t\t", _getDeployChain());

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t", deployer);

        vm.startBroadcast(deployerPrivateKey);
        address deploymentAddr = deployL2GasCalculator();
        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("L2_GAS_CALCULATOR", deploymentAddr);

        console.log("\n");
        console.log("-------------------------------------------------------------------------------");
        console.log("| Contract                    | Address                                       |");
        console.log("-------------------------------------------------------------------------------");
        console.log("| L2_GAS_CALCULATOR           | ", deploymentAddr, "  |");
        console.log("-------------------------------------------------------------------------------");
        console.log("\n");
        console.log("You can find the contract address in deployments.json");

        return deploymentAddr;
    }

    function deployL2GasCalculator() public returns (address) {
        uint256 chainId = block.chainid;
        address deploymentAddr;

        if (chainId == 42_161 || chainId == 421_614) {
            // Arbitrum One or Arbitrum Sepolia
            ArbitrumGasCalculator gasCalculator = new ArbitrumGasCalculator({
                calldataLenOffset: ARBITRUM_CALLDATA_LENGTH_OFFSET,
                _isArbitrumNova: false
            });
            deploymentAddr = address(gasCalculator);
        } else if (chainId == 42_170) {
            // Arbitrum Nova
            ArbitrumGasCalculator gasCalculator =
                new ArbitrumGasCalculator({ calldataLenOffset: ARBITRUM_CALLDATA_LENGTH_OFFSET, _isArbitrumNova: true });
            deploymentAddr = address(gasCalculator);
        } else {
            revert("Error: Chain ID not supported for gas calculator deployment");
        }

        return deploymentAddr;
    }
}
