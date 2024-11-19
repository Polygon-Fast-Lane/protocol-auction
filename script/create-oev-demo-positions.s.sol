// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { ChainlinkDAppControl } from "../src/contracts/examples/oev-example/ChainlinkDAppControl.sol";
import { ChainlinkAtlasWrapper } from "../src/contracts/examples/oev-example/ChainlinkAtlasWrapper.sol";

import { Token } from "../src/contracts/helpers/DemoToken.sol";
import { DemoLendingProtocol } from "../src/contracts/helpers/DemoLendingProtocol.sol";

// Sets up a few liquidatable positions in the Lending Protocol. ETH for gas fees distributed by Lending Gov.
contract CreateOEVDemoPositionsScript is DeployBaseScript {
    address public constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // on Sepolia

    // Existing contracts - owned by Chainlink Gov address
    ChainlinkDAppControl chainlinkDAppControl = ChainlinkDAppControl(0x3952bF1A206595381dA7322803bB322B14C964b6);

    // Existing contracts - owned by Lending Gov address
    ChainlinkAtlasWrapper lendingProtocolChainlinkWrapper =
        ChainlinkAtlasWrapper(payable(0x2d17fae534eb635e6A8f7733Cc9e83042A14dDB8));
    DemoLendingProtocol lendingProtocol = DemoLendingProtocol(0x145Be20fb2E37AA57c082DddEE04933ecedD1509);
    Token dai = Token(0x5989c008695e955f8048E7972dd40B5960999002);

    // TODO tweak the 2 values below if gas price is going crazy
    uint256 public constant ETH_FOR_GAS_FEES = 0.08e18;
    uint256 public constant MIN_ETH_NEEDED_FOR_FEES = 0.04e18;

    // Amount of DAI to deposit into the Lending Protocol, creating liquidatable position
    uint256 public constant POSITION_AMOUNT = 100e18;
    // Price at which the position in Lending Protocol will be liquidatable.
    uint256 public constant LIQUIDATION_PRICE = 3000e8;

    address signerAddress;
    uint256 signerPK;

    function run() external {
        console.log("\n=== Create OEV Demo Positions ===\n");

        uint256 lendingGovPrivateKey = vm.envUint("LENDING_GOV_PRIVATE_KEY");
        address lendingGov = vm.addr(lendingGovPrivateKey);

        string[5] memory signerNames = ["Alice", "Bob", "Charlie", "David", "Eve"];

        console.log("Lending Gov address: \t\t\t\t\t", lendingGov, "\n");

        console.log("Creating this liquidatable position from each account:\n");
        console.log("DAI Amount: \t\t\t\t\t\t", POSITION_AMOUNT / 1e18);
        console.log("Liquidation Price (ETH/USD): \t\t\t\t", LIQUIDATION_PRICE / 1e8);
        console.log("\n");

        for (uint256 i = 0; i < 5; i++) {
            (signerAddress, signerPK) = makeAddrAndKey(signerNames[i]);

            // If account already has a position, withdraw before creating new one
            (, uint256 prevLiqPrice) = lendingProtocol.positions(signerAddress);
            if (prevLiqPrice == LIQUIDATION_PRICE) {
                console.log(signerAddress, "'s position already exists at liquidation price. Skipping...");
                continue;
            }

            console.log("Giving ETH and DAI to: \t\t\t\t", signerAddress);

            // Lending Gov gives ETH and DAI to the current signer
            vm.startBroadcast(lendingGovPrivateKey);
            if (signerAddress.balance < MIN_ETH_NEEDED_FOR_FEES) {
                payable(signerAddress).transfer(ETH_FOR_GAS_FEES);
            } else {
                console.log(signerAddress, "already has enough ETH for gas fees.");
            }
            dai.mint(signerAddress, POSITION_AMOUNT);
            vm.stopBroadcast();

            console.log("Creating liquidatable position for: \t\t\t", signerAddress);

            // Signer approves DAI and creates liquidatable position
            vm.startBroadcast(signerPK);

            // If account already has a position, withdraw before creating new one
            if (prevLiqPrice > 0) lendingProtocol.withdraw();

            dai.approve(address(lendingProtocol), POSITION_AMOUNT);
            lendingProtocol.deposit(POSITION_AMOUNT, LIQUIDATION_PRICE);
            vm.stopBroadcast();
        }

        console.log("\n");
        console.log("Accounts with new liquidatable positions:\n");
        for (uint256 i = 0; i < signerNames.length; i++) {
            (signerAddress, signerPK) = makeAddrAndKey(signerNames[i]);
            console.log(signerNames[i]);
            console.log("Address: \t", signerAddress);
            console.log("Private Key: \t", signerPK);
            console.log("\n");
        }
    }
}
