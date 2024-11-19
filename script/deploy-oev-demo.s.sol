// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { ChainlinkDAppControl } from "../src/contracts/examples/oev-example/ChainlinkDAppControl.sol";
import { ChainlinkAtlasWrapper } from "../src/contracts/examples/oev-example/ChainlinkAtlasWrapper.sol";

import { Token } from "../src/contracts/helpers/DemoToken.sol";
import { DemoLendingProtocol } from "../src/contracts/helpers/DemoLendingProtocol.sol";

contract DeployOEVDemoScript is DeployBaseScript {
    address public constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // on Sepolia

    // To be deployed by Chainlink Gov
    ChainlinkDAppControl chainlinkDAppControl;
    address chainlinkExecutionEnv;

    // To be deployed by Lending Gov
    Token dai;
    DemoLendingProtocol lendingProtocol;
    ChainlinkAtlasWrapper lendingProtocolChainlinkWrapper;

    function run() external {
        console.log("\n=== DEPLOYING OEV DEMO ===\n");

        // Chainlink Gov actions:
        // - Deploy Chainlink DAppControl and initialize with Atlas
        // - Creates Execution Environment for Atlas OEV Metacalls
        uint256 chainlinkGovPrivateKey = vm.envUint("DAPP_GOV_PRIVATE_KEY");
        address chainlinkGov = vm.addr(chainlinkGovPrivateKey);

        // Lending Gov actions:
        // - Deploy DAI (acts as liquidatable collateral in Lending Protocol)
        // - Deploy Demo Lending Protocol
        // - Creates ChainlinkAtlasWrapper for ETH/USD
        // - Set ChainlinkAtlasWrapper as oracle in Demo Lending Protocol
        // - Set Chainlink Node's Execution Environment as transmitter in ChainlinkAtlasWrapper
        uint256 lendingGovPrivateKey = vm.envUint("LENDING_GOV_PRIVATE_KEY");
        address lendingGov = vm.addr(lendingGovPrivateKey);

        console.log("Chainlink Gov address: \t\t\t", chainlinkGov);
        console.log("Lending Gov address: \t\t\t\t", lendingGov);
        console.log("\n");

        // Atlas and AtlasVerification instances from latest deployment addresses
        atlas = Atlas(payable(_getAddressFromDeploymentsJson("ATLAS")));
        atlasVerification = AtlasVerification(payable(_getAddressFromDeploymentsJson("ATLAS_VERIFICATION")));

        console.log("Using Atlas deployed at: \t\t\t", address(atlas));
        console.log("Using AtlasVerification deployed at: \t\t", address(atlasVerification));
        console.log("\n");

        // ---------------------------------------------------- //
        //                   Chainlink Gov Txs                  //
        // ---------------------------------------------------- //

        vm.startBroadcast(chainlinkGovPrivateKey);
        console.log("Deploying from Chainlink Gov Account...");

        // Deploy and initialize Chainlink DAppControl with Atlas
        chainlinkDAppControl = new ChainlinkDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(chainlinkDAppControl));

        // Set Chainlink ETH/USD signers in DAppControl
        // TODO uncomment line below to use real Chainlink ETH/USD signers on Sepolia
        // chainlinkDAppControl.setSignersForBaseFeed(CHAINLINK_ETH_USD, getETHUSDSigners_Sepolia());

        // Create Execution Environment for Chainlink OEV Metacalls
        chainlinkExecutionEnv = atlas.createExecutionEnvironment(chainlinkGov, address(chainlinkDAppControl));

        vm.stopBroadcast();
        console.log("Contracts deployed by Chainlink Gov:");
        console.log("Chainlink DAppControl: \t\t\t", address(chainlinkDAppControl));
        console.log("Chainlink Execution Environment: \t\t", chainlinkExecutionEnv);
        console.log("\n");

        // ---------------------------------------------------- //
        //                    Lending Gov Txs                   //
        // ---------------------------------------------------- //

        vm.startBroadcast(lendingGovPrivateKey);
        console.log("Deploying from Lending Gov Account...");

        // Deploy token used in Demo Lending Protocol
        dai = new Token("DAI Stablecoin", "DAI", 18);

        // Deploy Demo Lending Protocol
        lendingProtocol = new DemoLendingProtocol(address(dai));

        // Create a new ChainlinkAtlasWrapper for ETH/USD for the Demo Lending Protocol
        lendingProtocolChainlinkWrapper =
            ChainlinkAtlasWrapper(payable(chainlinkDAppControl.createNewChainlinkAtlasWrapper(CHAINLINK_ETH_USD)));

        // Set the ChainlinkAtlasWrapper as the oracle of the Demo Lending Protocol
        lendingProtocol.setOracle(address(lendingProtocolChainlinkWrapper));

        // Set Chainlink Gov's Execution Environment as transmitter in Lending Protocol's ChainlinkAtlasWrapper
        lendingProtocolChainlinkWrapper.setTransmitterStatus(chainlinkExecutionEnv, true);

        vm.stopBroadcast();

        // EXTRA STEP: Lending Gov creates liquidatable position in Demo Lending Protocol
        // NOTE: Liquidatable positions created in other scripts now
        // createLiquidatablePosition(lendingGovPrivateKey, lendingGovPrivateKey, 100e18, 3000e8);

        console.log("Contracts deployed by Lending Gov:");
        console.log("DAI Token: \t\t\t\t\t", address(dai));
        console.log("Demo Lending Protocol: \t\t\t", address(lendingProtocol));
        console.log("ChainlinkAtlasWrapper for ETH/USD: \t\t", address(lendingProtocolChainlinkWrapper));
        console.log("\n");
    }

    // NOTE: `liquidationPrice` is specified with 8 decimals, as this is the price format reported by Chainlink oracles.
    // e.g. $5 = 500000000.
    function createLiquidatablePosition(
        uint256 lendingGovPK,
        uint256 depositorPK,
        uint256 amount,
        uint256 liquidationPrice
    )
        public
    {
        // Lending Gov mints DAI to depositor
        vm.startBroadcast(lendingGovPK);
        dai.mint(vm.addr(depositorPK), amount);
        vm.stopBroadcast();

        // Depositor deposits DAI into Demo Lending Protocol, sets liquidationPrice
        vm.startBroadcast(depositorPK);
        dai.approve(address(lendingProtocol), amount);
        lendingProtocol.deposit(amount, liquidationPrice);
        vm.stopBroadcast();
    }

    // Chainlink ETH/USD signers on Sepolia
    // Use https://github.com/BenSparksCode/chainlink-signer-reader to get signer array of any Chainlink Aggregator
    function getETHUSDSigners_Sepolia() public view returns (address[] memory) {
        address[] memory signers = new address[](4);
        signers[0] = 0xb4DC896090D778acC910db4D31f23d3667Add7Db;
        signers[1] = 0x1b178090f318c9Fd2322D52a5aC85ebBcE6Bf5E7;
        signers[2] = 0xB69dC0CaD9c739220A941f3D1C013ffd4CE7Dd6C;
        signers[3] = 0x8CACd95416d74702bccC9336Fc15F7dD0b533dDe;
        return signers;
    }
}
