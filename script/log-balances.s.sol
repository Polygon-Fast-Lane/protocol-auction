// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

contract LogDemoBalancesScript is DeployBaseScript {
    function run() external {
        //TODO take input for User address and print balances

        // Governance
        uint256 privateKey = vm.envUint("GOV_PRIVATE_KEY");
        address account = vm.addr(privateKey);
        _logTokenBalances(account, "Governance");

        // Solver 1 EOA
        privateKey = vm.envUint("SOLVER1_PRIVATE_KEY");
        account = vm.addr(privateKey);
        _logTokenBalances(account, "Solver 1");

        // Atlas contract
        account = _getAddressFromDeploymentsJson("ATLAS");
        _logTokenBalances(account, "Atlas");

        // Simple RFQ Solver contract
        account = _getAddressFromDeploymentsJson("SIMPLE_RFQ_SOLVER");
        _logTokenBalances(account, "Simple RFQ Solver");
    }
}
