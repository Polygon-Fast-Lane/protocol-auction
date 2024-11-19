// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "./base/deploy-base.s.sol";

import { ChainlinkDAppControl } from "../src/contracts/examples/oev-example/ChainlinkDAppControl.sol";
import { ChainlinkAtlasWrapper } from "../src/contracts/examples/oev-example/ChainlinkAtlasWrapper.sol";

import { Token } from "../src/contracts/helpers/DemoToken.sol";
import { DemoLendingProtocol } from "../src/contracts/helpers/DemoLendingProtocol.sol";

// For the Chainlink OEV demo, when its difficult to find a real `transmit()` tx with a low enough ETH price.
// We replace the real Sepolia Chainlink ETH/USD signers with a set of test signers, in ChainlinkDAppControl.
// Then, we create the `transmit()` calldata with a useful price update, signed by the test signers.
contract SetOEVDemoSignersScript is DeployBaseScript {
    address public constant CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // on Sepolia

    // Existing contracts - owned by Chainlink Gov address
    ChainlinkDAppControl chainlinkDAppControl = ChainlinkDAppControl(0x1fD3aC12c1953497d36e09c6913d68341f5D254f);

    // Existing contracts - owned by Lending Gov address
    ChainlinkAtlasWrapper lendingProtocolChainlinkWrapper =
        ChainlinkAtlasWrapper(payable(0xCeE84a9495E7A8496963E7c305cAff7139D72e13));
    DemoLendingProtocol lendingProtocol = DemoLendingProtocol(0xd9f3e8Df1Af528ECA41c3C78e3aE939015505278);
    Token dai = Token(0x89D9eF51dbF7aCFFcD0b3E430acE2471608a088c);

    // Amount of DAI to deposit into the Lending Protocol, creating liquidatable position
    uint256 public constant POSITION_AMOUNT = 100e18;
    // Price at which the position in Lending Protocol will be liquidatable. Should be below real ETH/USD price but
    // above the mock ETH/USD price set below.
    uint256 public constant LIQUIDATION_PRICE = 2500e8;
    // ETH/USD Price (8 decimals) that will be extracted from the `transmit()` data
    uint256 public constant ETH_USD_PRICE = 2000e8;

    // Mock Signers and PKs
    address alice;
    address bob;
    uint256 alicePK;
    uint256 bobPK;

    function run() external {
        console.log("\n=== SET OEV DEMO SIGNERS ===\n");

        _setMockSigners();

        uint256 chainlinkGovPrivateKey = vm.envUint("DAPP_GOV_PRIVATE_KEY");
        address chainlinkGov = vm.addr(chainlinkGovPrivateKey);

        uint256 lendingGovPrivateKey = vm.envUint("LENDING_GOV_PRIVATE_KEY");
        address lendingGov = vm.addr(lendingGovPrivateKey);

        console.log("Chainlink Gov address: \t\t\t\t", chainlinkGov);
        console.log("Lending Gov address: \t\t\t\t\t", lendingGov);

        // ---------------------------------------------------- //
        //                   Chainlink Gov Txs                  //
        // ---------------------------------------------------- //

        console.log("\nTxs from Chainlink Gov Account...\n");
        vm.startBroadcast(chainlinkGovPrivateKey);

        // Set mock signers in ChainlinkDAppControl
        _setMockSignersInChainlinkDAppControl();
        console.log("Set mock signers in ChainlinkDAppControl");
        vm.stopBroadcast();

        _logMockSigners();

        // ---------------------------------------------------- //
        //                    Lending Gov Txs                   //
        // ---------------------------------------------------- //

        console.log("\nTxs from Lending Gov Account...\n");
        vm.startBroadcast(lendingGovPrivateKey);

        // If Lending Gov already has position, withdraw before creating new one
        (uint256 prevAmount,) = lendingProtocol.positions(lendingGov);
        if (prevAmount > 0) {
            lendingProtocol.withdraw();
            console.log("Withdrew Lending Gov's previous position");
        } else {
            console.log("No Lending Gov previous position found");
        }

        // Create a new liquidatable position in the Lending Protocol
        dai.mint(lendingGov, POSITION_AMOUNT);
        dai.approve(address(lendingProtocol), POSITION_AMOUNT);
        lendingProtocol.deposit(POSITION_AMOUNT, LIQUIDATION_PRICE);
        vm.stopBroadcast();

        console.log("\n");
        console.log("Created new liquidatable position:");
        console.log("DAI Amount: \t\t\t\t\t\t", POSITION_AMOUNT / 1e18);
        console.log("Liquidation Price (ETH/USD): \t\t\t\t", LIQUIDATION_PRICE / 1e8);
        console.log("\n");

        console.log("Building transmit calldata...");

        // Lastly, create the `transmit()` calldata with mock signers to set the ETH/USD price
        (bytes memory report, bytes32[] memory rs, bytes32[] memory ss, bytes32 rawVs) = _buildTransmitCalldataParams();

        // Check that the calldata built above verifies correctly in the ChainlinkDAppControl
        bool verified = chainlinkDAppControl.verifyTransmitSigners(CHAINLINK_ETH_USD, report, rs, ss, rawVs);
        if (verified) {
            console.log("Transmit calldata verified successfully!");
        } else {
            console.log("Transmit calldata verification failed!");
        }

        console.log("\n");
        console.log("Calldata to set ETH/USD price to: \t\t\t", ETH_USD_PRICE);
        console.log("\n");

        _logTransmitParams(report, rs, ss, rawVs);

        console.log("userOp.data form:");
        console.logBytes(_convertTransmitParamsToUserOpData(report, rs, ss, rawVs));
    }

    function _setMockSigners() internal {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
    }

    function _logMockSigners() internal {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
        console.log("Mock Signers:");
        console.log("Alice: \t\t\t\t\t\t", alice);
        console.log("Bob: \t\t\t\t\t\t\t", bob);
    }

    function _setMockSignersInChainlinkDAppControl() internal {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        chainlinkDAppControl.setSignersForBaseFeed(CHAINLINK_ETH_USD, signers);
    }

    function _buildTransmitCalldataParams()
        internal
        view
        returns (bytes memory report, bytes32[] memory rs, bytes32[] memory ss, bytes32 rawVs)
    {
        int192[] memory observations = new int192[](2);
        observations[0] = int192(int256(ETH_USD_PRICE));
        observations[1] = int192(int256(ETH_USD_PRICE));

        // NOTE: Must be `abi.encode()` and not `abi.encodePacked()` otherwise decode breaks
        report = abi.encode(
            bytes32(uint256(0)), // padding
            bytes32(uint256(0)), // padding
            observations
        );

        bytes32 reportHash = keccak256(report);

        rs = new bytes32[](2);
        ss = new bytes32[](2);
        rawVs = bytes32(0);
        uint8 tempV = 0;

        (tempV, rs[0], ss[0]) = vm.sign(alicePK, reportHash);
        rawVs |= bytes32(uint256(tempV - 27) << (31 * 8));

        (tempV, rs[1], ss[1]) = vm.sign(bobPK, reportHash);
        rawVs |= bytes32(uint256(tempV - 27) << (30 * 8));

        return (report, rs, ss, rawVs);
    }

    function _convertTransmitParamsToUserOpData(
        bytes memory report,
        bytes32[] memory rs,
        bytes32[] memory ss,
        bytes32 rawVs
    )
        internal
        view
        returns (bytes memory userOpData)
    {
        userOpData = abi.encodeCall(ChainlinkAtlasWrapper.transmit, (report, rs, ss, rawVs));
    }

    function _logTransmitParams(
        bytes memory report,
        bytes32[] memory rs,
        bytes32[] memory ss,
        bytes32 rawVs
    )
        internal
    {
        console.log("Transmit Params:");
        console.log("report: ");
        console.logBytes(report);
        console.log("rs: ");

        for (uint256 i = 0; i < rs.length; i++) {
            console.logBytes32(rs[i]);
        }

        console.log("ss: ");

        for (uint256 i = 0; i < ss.length; i++) {
            console.logBytes32(ss[i]);
        }

        console.log("rawVs: ");
        console.logBytes32(rawVs);
        console.log("\n");
    }
}
