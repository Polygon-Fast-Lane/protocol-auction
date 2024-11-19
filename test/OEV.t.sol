// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";
import { UserOperationBuilder } from "test/base/builders/UserOperationBuilder.sol";

import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { DAppConfig } from "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/DAppOperation.sol";

import { ChainlinkDAppControl, Oracle, Role } from "../src/contracts/examples/oev-example/ChainlinkDAppControl.sol";
import { ChainlinkAtlasWrapper } from "../src/contracts/examples/oev-example/ChainlinkAtlasWrapper.sol";
import { AggregatorV2V3Interface } from "../src/contracts/examples/oev-example/IChainlinkAtlasWrapper.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";


// Using this Chainlink update to ETHUSD feed as an example:
// Aggregator: https://etherscan.io/address/0xE62B71cf983019BFf55bC83B48601ce8419650CC
// Transmit tx: https://etherscan.io/tx/0x3645d1bc223efe0861e02aeb95d6204c5ebfe268b64a7d23d385520faf452bc0
// ETH/USD set to: $2941.02 == 294102000000

contract OEVTest is BaseTest {
    ChainlinkAtlasWrapper public chainlinkAtlasWrapper;
    ChainlinkDAppControl public chainlinkDAppControl;
    MockLiquidatable public mockLiquidatable;
    TxBuilder public txBuilder;
    Sig public sig;

    address chainlinkGovEOA;
    address aaveGovEOA;
    address executionEnvironment;
    
    address chainlinkETHUSD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 forkBlock = 19289829; // Block just before the transmit tx above
    uint256 targetOracleAnswer = 294102000000;
    uint256 liquidationReward = 10e18;
    uint256 solverWinningBid = 1e18;

    struct TransmitData {
        bytes report;
        bytes32[] rs;
        bytes32[] ss;
        bytes32 rawVs;
    }

    function setUp() public virtual override {
        BaseTest.setUp();
        vm.rollFork(forkBlock);
        vm.deal(solverOneEOA, 100e18);

        // Creating new gov address (SignatoryActive error if already registered with control)
        uint256 chainlinkGovPK = 11_112;
        uint256 aaveGovPK = 11_113;
        chainlinkGovEOA = vm.addr(chainlinkGovPK);
        aaveGovEOA = vm.addr(aaveGovPK);

        vm.startPrank(chainlinkGovEOA);
        // Chainlink's Gov address deploys the Chainlink DAppControl
        chainlinkDAppControl = new ChainlinkDAppControl(address(atlas));
        // Chainlink's Gov address initializes the Chainlink DAppControl in Atlas
        atlasVerification.initializeGovernance(address(chainlinkDAppControl));
        // Set Chainlink's ETHUSD feed signers in DAppControl for verification
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, getETHUSDSigners());
        vm.stopPrank();

        vm.startPrank(userEOA); // User is a Chainlink Node
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(chainlinkDAppControl));
        vm.stopPrank();
        
        vm.startPrank(aaveGovEOA);
        // Aave creates a Chainlink Atlas Wrapper for ETH/USD to capture OEV
        chainlinkAtlasWrapper = ChainlinkAtlasWrapper(payable(chainlinkDAppControl.createNewChainlinkAtlasWrapper(chainlinkETHUSD)));
        // OEV-generating protocols must use the Chainlink Atlas Wrapper for price feed in order to capture the OEV
        mockLiquidatable = new MockLiquidatable(address(chainlinkAtlasWrapper), targetOracleAnswer);
        // Aave sets the Chainlink Execution Environment as a trusted transmitter in the Chainlink Atlas Wrapper
        chainlinkAtlasWrapper.setTransmitterStatus(executionEnvironment, true);
        vm.stopPrank();

        deal(address(mockLiquidatable), liquidationReward); // Add 10 ETH as liquidation reward

        txBuilder = new TxBuilder({
            _control: address(chainlinkDAppControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        vm.label(chainlinkGovEOA, "Chainlink Gov");
        vm.label(aaveGovEOA, "Aave Gov");
        vm.label(address(executionEnvironment), "EXECUTION ENV");
        vm.label(address(chainlinkAtlasWrapper), "Chainlink Atlas Wrapper");
        vm.label(address(chainlinkDAppControl), "Chainlink DApp Control");
        vm.label(address(chainlinkETHUSD), "Chainlink Base ETH/USD Feed");
    }

    // ---------------------------------------------------- //
    //                  Full OEV Capture Test               //
    // ---------------------------------------------------- //

    function testChainlinkOEV_StandardVersion_GasCheck_SkipCoverage() public {
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        vm.startPrank(solverOneEOA);
        LiquidationOEVSolver liquidationSolver = new LiquidationOEVSolver(WETH_ADDRESS, address(atlas));
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);
        vm.stopPrank();

        assertTrue(chainlinkDAppControl.isChainlinkWrapper(address(chainlinkAtlasWrapper)), "Wrapper should be registered on DAppControl - otherwise will revert in allocateValue");

        // Basic userOp created but excludes oracle price update data
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(chainlinkAtlasWrapper), // Aave's ChainlinkAtlasWrapper for ETHUSD
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: "" // No userOp.data yet - only created after solverOps are signed
        });
        userOp.sessionKey = governanceEOA;

        bytes memory solverOpData =
            abi.encodeWithSelector(LiquidationOEVSolver.liquidate.selector, address(mockLiquidatable));

        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(liquidationSolver),
            bidAmount: solverWinningBid,
            value: 0
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // After solvers have signed their ops, Chainlink creates the userOp with price update data
        (bytes memory report, bytes32[] memory rs, bytes32[] memory ss, bytes32 rawVs) = getTransmitPayload();
        userOp.data = abi.encodeWithSelector(ChainlinkAtlasWrapper.transmit.selector, report, rs, ss, rawVs);

        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        assertEq(mockLiquidatable.canLiquidate(), false);
        assertTrue(uint(chainlinkAtlasWrapper.latestAnswer()) !=  targetOracleAnswer, "Wrapper answer should not be target yet");
        assertEq(uint(chainlinkAtlasWrapper.latestAnswer()), uint(AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer()), "Wrapper and base feed should report same answer");
        assertEq(address(chainlinkAtlasWrapper).balance, 0, "Wrapper should not have any ETH");

        // To show the signer verification checks cause metacall to pass/fail:
        uint256 snapshot = vm.snapshot();

        // 3rd signer in the ETHUSD transmit example tx used
        address signerToRemove = 0xCc1b49B86F79C7E50E294D3e3734fe94DB9A42F0;
        vm.prank(chainlinkGovEOA);
        chainlinkDAppControl.removeSignerOfBaseFeed(chainlinkETHUSD, signerToRemove);

        // Should Fail
        vm.prank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });

        assertEq(uint(chainlinkAtlasWrapper.latestAnswer()), uint(AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer()), "Metacall unexpectedly succeeded");

        // Go back to before removing the signer
        vm.revertTo(snapshot);

        uint256 gasLeftBefore = gasleft();

        // Should Succeed
        vm.prank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp, gasRefundBeneficiary: address(0) });

        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());

        assertEq(uint(chainlinkAtlasWrapper.latestAnswer()), targetOracleAnswer, "Wrapper did not update as expected");
        assertTrue(uint(chainlinkAtlasWrapper.latestAnswer()) != uint(AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer()), "Wrapper and base feed should report different answers");
        assertEq(address(chainlinkAtlasWrapper).balance, solverWinningBid, "Wrapper should hold winning bid as OEV");
    }

    // ---------------------------------------------------- //
    //               ChainlinkAtlasWrapper Tests            //
    // ---------------------------------------------------- //

    function testChainlinkAtlasWrapperViewFunctions() public {
        // Check wrapper and base start as expected
        assertEq(chainlinkAtlasWrapper.atlasLatestAnswer(), 0, "Wrapper stored latestAnswer should be 0");
        assertTrue(AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer() != 0, "Base latestAnswer should not be 0");
        assertEq(chainlinkAtlasWrapper.atlasLatestTimestamp(), 0, "Wrapper stored latestTimestamp should be 0");
        assertTrue(AggregatorV2V3Interface(chainlinkETHUSD).latestTimestamp() != 0, "Base latestTimestamp should not be 0");

        (uint80 roundIdAtlas, int256 answerAtlas, uint256 startedAtAtlas, uint256 updatedAtAtlas, uint80 answeredInRoundAtlas) = chainlinkAtlasWrapper.latestRoundData();
        (uint80 roundIdBase, int256 answerBase, uint256 startedAtBase, uint256 updatedAtBase, uint80 answeredInRoundBase) = AggregatorV2V3Interface(chainlinkETHUSD).latestRoundData();

        // Before Atlas price update, all view functions should fall back to base oracle
        assertEq(chainlinkAtlasWrapper.latestAnswer(), AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer(), "latestAnswer should be same as base");
        assertEq(chainlinkAtlasWrapper.latestTimestamp(), AggregatorV2V3Interface(chainlinkETHUSD).latestTimestamp(), "latestTimestamp should be same as base");
        assertEq(roundIdAtlas, roundIdBase, "roundId should be same as base");
        assertEq(answerAtlas, answerBase, "answer should be same as base");
        assertEq(startedAtAtlas, startedAtBase, "startedAt should be same as base");
        assertEq(updatedAtAtlas, updatedAtBase, "updatedAt should be same as base");
        assertEq(answeredInRoundAtlas, answeredInRoundBase, "answeredInRound should be same as base");

        // Update wrapper with new price by calling transmit from an approved EE
        TransmitData memory transmitData;
        (transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs) = getTransmitPayload();
        vm.prank(executionEnvironment);
        chainlinkAtlasWrapper.transmit(transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs);

        // After Atlas price update, latestAnswer and latestTimestamp should be different to base oracle
        assertEq(uint(chainlinkAtlasWrapper.latestAnswer()), targetOracleAnswer, "latestAnswer should be updated");
        assertTrue(uint(chainlinkAtlasWrapper.latestAnswer()) != uint(AggregatorV2V3Interface(chainlinkETHUSD).latestAnswer()), "latestAnswer should be different to base");
        assertEq(chainlinkAtlasWrapper.latestTimestamp(), block.timestamp, "latestTimestamp should be updated");
        assertTrue(chainlinkAtlasWrapper.latestTimestamp() > AggregatorV2V3Interface(chainlinkETHUSD).latestTimestamp(), "latestTimestamp should be later than base");

        (roundIdAtlas, answerAtlas, startedAtAtlas, updatedAtAtlas, answeredInRoundAtlas) = chainlinkAtlasWrapper.latestRoundData();
        (roundIdBase, answerBase, startedAtBase, updatedAtBase, answeredInRoundBase) = AggregatorV2V3Interface(chainlinkETHUSD).latestRoundData();

        assertEq(roundIdAtlas, roundIdBase, "roundId should still be same as base");
        assertTrue(answerAtlas == int(targetOracleAnswer) && answerAtlas != answerBase, "answer should be updated");
        assertEq(startedAtAtlas, startedAtBase, "startedAt should still be same as base");
        assertTrue(updatedAtAtlas > updatedAtBase, "updatedAt should be later than base");
        assertEq(answeredInRoundAtlas, answeredInRoundBase, "answeredInRound should still be same as base");
    }

    function testChainlinkAtlasWrapperWithdrawFunctions() public {
        uint256 startETH = 10e18;
        uint256 startDai = 5e18;
        deal(address(chainlinkAtlasWrapper), startETH); // Give wrapper 10 ETH
        deal(address(DAI), address(chainlinkAtlasWrapper), startDai); // Give wrapper 5 DAI

        assertEq(address(chainlinkAtlasWrapper).balance, startETH, "Wrapper should have 10 ETH");
        assertEq(DAI.balanceOf(address(chainlinkAtlasWrapper)), startDai, "Wrapper should have 5 DAI");
        assertEq(aaveGovEOA.balance, 0, "Aave Gov should have 0 ETH");
        assertEq(DAI.balanceOf(aaveGovEOA), 0, "Aave Gov should have 0 DAI");

        vm.startPrank(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, chainlinkGovEOA));
        chainlinkAtlasWrapper.withdrawETH(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, chainlinkGovEOA));
        chainlinkAtlasWrapper.withdrawERC20(address(DAI), chainlinkGovEOA);
        vm.stopPrank();

        assertEq(aaveGovEOA.balance, 0, "Aave Gov should still have 0 ETH");
        assertEq(DAI.balanceOf(aaveGovEOA), 0, "Aave Gov should still have 0 DAI");

        vm.startPrank(aaveGovEOA);
        chainlinkAtlasWrapper.withdrawETH(aaveGovEOA);
        chainlinkAtlasWrapper.withdrawERC20(address(DAI), aaveGovEOA);
        vm.stopPrank();

        assertEq(address(chainlinkAtlasWrapper).balance, 0, "Wrapper should have 0 ETH");
        assertEq(DAI.balanceOf(address(chainlinkAtlasWrapper)), 0, "Wrapper should have 0 DAI");
        assertEq(aaveGovEOA.balance, startETH, "Aave Gov should have 10 ETH");
        assertEq(DAI.balanceOf(aaveGovEOA), startDai, "Aave Gov should have 5 DAI");
    }

    function testChainlinkAtlasWrapperOwnableFunctionsEvents() public {
        address mockEE = makeAddr("Mock EE");

        // Wrapper emits event on deployment to show ownership transfer
        vm.expectEmit(true, false, false, true);
        emit Ownable.OwnershipTransferred(address(0), address(chainlinkAtlasWrapper.owner()));
        new ChainlinkAtlasWrapper(address(atlas), chainlinkETHUSD, aaveGovEOA);

        vm.prank(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, chainlinkGovEOA));
        chainlinkAtlasWrapper.setTransmitterStatus(mockEE, true);

        assertEq(chainlinkAtlasWrapper.transmitters(mockEE), false, "EE should not be trusted yet");

        vm.prank(aaveGovEOA);
        chainlinkAtlasWrapper.setTransmitterStatus(mockEE, true);

        assertEq(chainlinkAtlasWrapper.transmitters(mockEE), true, "EE should be trusted now");
    }

    function testChainlinkAtlasWrapperTransmit() public {
        TransmitData memory transmitData;
        (transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs) = getTransmitPayload();

        assertEq(chainlinkAtlasWrapper.atlasLatestAnswer(), 0, "Wrapper stored latestAnswer should be 0");
        
        vm.prank(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAtlasWrapper.TransmitterNotTrusted.selector, chainlinkGovEOA));
        chainlinkAtlasWrapper.transmit(transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs);

        assertEq(chainlinkAtlasWrapper.atlasLatestAnswer(), 0, "Wrapper stored latestAnswer should still be 0");

        // Check transmit reverts if rs and ss arrays are not the same length
        vm.prank(executionEnvironment);
        vm.expectRevert(ChainlinkAtlasWrapper.ArrayLengthMismatch.selector);
        chainlinkAtlasWrapper.transmit(transmitData.report, new bytes32[](0), transmitData.ss, transmitData.rawVs);

        // Check that transmit reverts if quorum is not met (uses rs array length for sig count)
        vm.prank(executionEnvironment);
        vm.expectRevert(ChainlinkAtlasWrapper.SignerVerificationFailed.selector);
        chainlinkAtlasWrapper.transmit(transmitData.report, new bytes32[](0), new bytes32[](0), transmitData.rawVs);

        vm.prank(executionEnvironment);
        chainlinkAtlasWrapper.transmit(transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs);

        assertEq(uint(chainlinkAtlasWrapper.atlasLatestAnswer()), targetOracleAnswer, "Wrapper stored latestAnswer should be updated");

        // Check that transmit reverts if called again with same data
        vm.prank(executionEnvironment);
        vm.expectRevert(ChainlinkAtlasWrapper.CannotReuseReport.selector);
        chainlinkAtlasWrapper.transmit(transmitData.report, transmitData.rs, transmitData.ss, transmitData.rawVs);
    }

    function testChainlinkAtlasWrapperCanReceiveETH() public {
        deal(userEOA, 2e18);

        assertEq(address(chainlinkAtlasWrapper).balance, 0, "Wrapper should have 0 ETH");

        vm.startPrank(userEOA);
        payable(address(chainlinkAtlasWrapper)).transfer(1e18);
        (bool success, ) = address(chainlinkAtlasWrapper).call{value: 1e18}("");
        vm.stopPrank();

        assertTrue(success, "Transfer should succeed");
        assertEq(address(chainlinkAtlasWrapper).balance, 2e18, "Wrapper should have 2 ETH");
    }

    // ---------------------------------------------------- //
    //               ChainlinkDAppControl Tests             //
    // ---------------------------------------------------- //

    function test_ChainlinkDAppControl_setSignersForBaseFeed() public {
        address[] memory signers = getETHUSDSigners();
        address[] memory signersFromDAppControl;

        vm.expectRevert(ChainlinkDAppControl.OnlyGovernance.selector);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, signers);

        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.SignersSetForBaseFeed(chainlinkETHUSD, signers);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, signers);

        signersFromDAppControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        assertEq(signersFromDAppControl.length, signers.length, "Signers length should be same as expected");
        for (uint i = 0; i < signers.length; i++) {
            assertEq(signersFromDAppControl[i], signers[i], "Signer should be same as expected");
        }

        address[] memory blankSigners = new address[](0);
        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.SignersSetForBaseFeed(chainlinkETHUSD, blankSigners);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, blankSigners);

        assertEq(chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD).length, 0, "Signers should be empty");

        // Should revert on too many signers
        address[] memory tooManySigners = new address[](chainlinkDAppControl.MAX_NUM_ORACLES() + 1);
        for (uint i = 0; i < signers.length; i++) {
            tooManySigners[i] = signers[i];
        }
        tooManySigners[chainlinkDAppControl.MAX_NUM_ORACLES()] = chainlinkGovEOA;

        vm.prank(chainlinkGovEOA);
        vm.expectRevert(ChainlinkDAppControl.TooManySigners.selector);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, tooManySigners);

        // Should revert on duplicate signers in the array
        address[] memory duplicateSigners = new address[](2);
        duplicateSigners[0] = chainlinkGovEOA;
        duplicateSigners[1] = chainlinkGovEOA;
        
        vm.prank(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkDAppControl.DuplicateSigner.selector, chainlinkGovEOA));
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, duplicateSigners);

        // Check properties set correctly on valid signer set
        address[] memory validSigners = new address[](2);
        validSigners[0] = chainlinkGovEOA;
        validSigners[1] = aaveGovEOA;

        Oracle memory oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);
        assertEq(uint(oracle.role), uint(Role.Unset), "Oracle role should be Unset");

        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.SignersSetForBaseFeed(chainlinkETHUSD, validSigners);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, validSigners);

        address[] memory signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);
        assertEq(signersFromDappControl.length, validSigners.length, "length mismatch");
        assertEq(signersFromDappControl[0], validSigners[0]);
        assertEq(signersFromDappControl[1], validSigners[1]);
        assertEq(uint(oracle.role), uint(Role.Signer), "Oracle role should be Signer");
        assertEq(oracle.index, 0, "Oracle index should be 0");
        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, aaveGovEOA);
        assertEq(uint(oracle.role), uint(Role.Signer), "Oracle role should be Signer");
        assertEq(oracle.index, 1, "Oracle index should be 1");
    }

    function test_ChainlinkDAppControl_addSignerForBaseFeed() public {
        vm.expectRevert(ChainlinkDAppControl.OnlyGovernance.selector);
        chainlinkDAppControl.addSignerForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);

        address[] memory signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        assertEq(signersFromDappControl.length, chainlinkDAppControl.MAX_NUM_ORACLES(), "Should have max signers");

        vm.prank(chainlinkGovEOA);
        vm.expectRevert(ChainlinkDAppControl.TooManySigners.selector);
        chainlinkDAppControl.addSignerForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);

        // clear signers so we can add individually
        address[] memory blankSigners = new address[](0);
        vm.prank(chainlinkGovEOA);
        chainlinkDAppControl.setSignersForBaseFeed(chainlinkETHUSD, blankSigners);
        assertEq(chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD).length, 0, "Signers should be empty");

        Oracle memory oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);
        assertEq(uint(oracle.role), uint(Role.Unset), "Oracle role should be Unset");

        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.SignerAddedForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);
        chainlinkDAppControl.addSignerForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);

        signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);
        assertEq(signersFromDappControl.length, 1, "Signers should have 1");
        assertEq(signersFromDappControl[0], chainlinkGovEOA, "Signer should be chainlinkGovEOA");
        assertEq(uint(oracle.role), uint(Role.Signer), "Oracle role should be Signer");

        vm.prank(chainlinkGovEOA);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkDAppControl.DuplicateSigner.selector, chainlinkGovEOA));
        chainlinkDAppControl.addSignerForBaseFeed(chainlinkETHUSD, chainlinkGovEOA);

        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, address(1));
        assertEq(uint(oracle.role), uint(Role.Unset), "Oracle role should be Unset");
        assertEq(oracle.index, 0, "Oracle index should be 0");

        vm.prank(chainlinkGovEOA);
        chainlinkDAppControl.addSignerForBaseFeed(chainlinkETHUSD, address(1));

        signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, address(1));
        assertEq(signersFromDappControl.length, 2, "Signers should have 2");
        assertEq(uint(oracle.role), uint(Role.Signer), "Oracle role should be Signer");
        assertEq(oracle.index, 1, "Oracle index should be 1");
    }

    function test_ChainlinkDAppControl_removeSignerOfBaseFeed() public {
        address[] memory realSigners = getETHUSDSigners();
        address signerToRemove = realSigners[10];
        address[] memory signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        Oracle memory oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, signerToRemove);
        assertEq(signersFromDappControl.length, 31, "Should have 31 signers at start");
        assertEq(signersFromDappControl[10], realSigners[10], "targeted signer still registered");
        assertEq(oracle.index, 10);
        assertEq(uint(oracle.role), uint(Role.Signer));

        vm.expectRevert(ChainlinkDAppControl.OnlyGovernance.selector);
        chainlinkDAppControl.removeSignerOfBaseFeed(chainlinkETHUSD, realSigners[30]);

        vm.prank(chainlinkGovEOA);
        vm.expectRevert(ChainlinkDAppControl.SignerNotFound.selector);
        chainlinkDAppControl.removeSignerOfBaseFeed(chainlinkETHUSD, address(1));

        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.SignerRemovedForBaseFeed(chainlinkETHUSD, signerToRemove);
        chainlinkDAppControl.removeSignerOfBaseFeed(chainlinkETHUSD, signerToRemove);

        signersFromDappControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, signerToRemove);
        assertEq(signersFromDappControl.length, realSigners.length - 1, "Should have 30 signers now");
        assertTrue(signersFromDappControl[10] != realSigners[10], "Idx 10 signers should be diff now");
        assertEq(oracle.index, 0);
        assertEq(uint(oracle.role), uint(Role.Unset));
    }

    function test_ChainlinkDAppControl_setObservationsQuorum() public {
        uint256 expectedDefaultQuorum = 1;
        uint256 newQuorum = 3;

        assertEq(chainlinkDAppControl.observationsQuorum(), expectedDefaultQuorum, "Default starting observations quorum not as expected");

        vm.expectRevert(ChainlinkDAppControl.OnlyGovernance.selector);
        chainlinkDAppControl.setObservationsQuorum(newQuorum);

        vm.prank(chainlinkGovEOA);
        vm.expectEmit(true, false, false, true);
        emit ChainlinkDAppControl.ObservationsQuorumSet(expectedDefaultQuorum, newQuorum);
        chainlinkDAppControl.setObservationsQuorum(newQuorum);

        assertEq(chainlinkDAppControl.observationsQuorum(), newQuorum, "Observations quorum not updated as expected");
    }

    function test_ChainlinkDAppControl_verifyTransmitSigners() public {
        // 3rd signer in the ETHUSD transmit example tx used
        address signerToRemove = 0xCc1b49B86F79C7E50E294D3e3734fe94DB9A42F0;
        (
            bytes memory report, bytes32[] memory rs,
            bytes32[] memory ss, bytes32 rawVs
        ) = getTransmitPayload();

        // All signers should be verified
        assertEq(chainlinkDAppControl.verifyTransmitSigners(chainlinkETHUSD, report, rs, ss, rawVs), true);

        // If quorum is not met, should return false
        uint256 quorum = chainlinkDAppControl.observationsQuorum();
        require(quorum > 0, "TEST: Quorum cant be 0 for this check");
        assertEq(chainlinkDAppControl.verifyTransmitSigners(chainlinkETHUSD, report, new bytes32[](0), ss, rawVs), false);

        // If a verified signer is removed from DAppControl, should return false
        vm.prank(chainlinkGovEOA);
        chainlinkDAppControl.removeSignerOfBaseFeed(chainlinkETHUSD, signerToRemove);
        assertEq(chainlinkDAppControl.verifyTransmitSigners(chainlinkETHUSD, report, rs, ss, rawVs), false);
    }

    function test_ChainlinkDAppControl_createNewChainlinkAtlasWrapper() public {
        MockBadChainlinkFeed mockBadFeed = new MockBadChainlinkFeed();

        // Should revert is base feed returns price of 0
        vm.expectRevert(ChainlinkDAppControl.InvalidBaseFeed.selector);
        chainlinkDAppControl.createNewChainlinkAtlasWrapper(address(mockBadFeed));

        address predictedWrapperAddr = vm.computeCreateAddress(address(chainlinkDAppControl), vm.getNonce(address(chainlinkDAppControl)));

        vm.prank(aaveGovEOA);
        vm.expectEmit(true, true, false, true);
        emit ChainlinkDAppControl.NewChainlinkWrapperCreated(predictedWrapperAddr, chainlinkETHUSD, aaveGovEOA);
        address wrapperAddr = chainlinkDAppControl.createNewChainlinkAtlasWrapper(chainlinkETHUSD);

        assertEq(predictedWrapperAddr, wrapperAddr, "wrapper addr not as predicted");
        assertEq(ChainlinkAtlasWrapper(payable(wrapperAddr)).owner(), aaveGovEOA, "caller is not wrapper owner");
    }

    // View Functions

    function test_ChainlinkDAppControl_getBidFormat() public view {
        UserOperation memory userOp;
        assertEq(chainlinkDAppControl.getBidFormat(userOp), address(0), "Bid format should be addr 0 for ETH");
    }

    function test_ChainlinkDAppControl_getBidValue() public view {
        SolverOperation memory solverOp;
        solverOp.bidAmount = 123;
        assertEq(chainlinkDAppControl.getBidValue(solverOp), 123, "Bid value should return solverOp.bidAmount");
    }

    function test_ChainlinkDAppControl_getSignersForBaseFeed() public view {
        address[] memory signersFromDAppControl = chainlinkDAppControl.getSignersForBaseFeed(chainlinkETHUSD);
        address[] memory signers = getETHUSDSigners();
        assertEq(signersFromDAppControl.length, signers.length, "Signers length should be same as expected");
        for (uint i = 0; i < signers.length; i++) {
            assertEq(signersFromDAppControl[i], signers[i], "Signer should be same as expected");
        }
    }

    function test_ChainlinkDAppControl_getOracleDataForBaseFeed() public view {
        address[] memory signers = getETHUSDSigners();
        for (uint i = 0; i < signers.length; i++) {
            Oracle memory oracle = chainlinkDAppControl.getOracleDataForBaseFeed(chainlinkETHUSD, signers[i]);
            assertEq(uint(oracle.role), uint(Role.Signer), "Oracle role should be Signer");
            assertEq(oracle.index, i, "Oracle index not as expected");
        }
    }

    function test_logUserOpTransmitData_Sepolia() public view {
        console.log("Sepolia Chainlink Transmit Data in userOp.data form:");
        console.log("Sets ETH/USD Price to $2979.36");
        console.log("\n");
        console.logBytes(getTransmitPayload_Sepolia());
    }

    // ---------------------------------------------------- //
    //                     OEV Test Utils                   //
    // ---------------------------------------------------- //

    // Returns calldata taken from a real Chainlink ETH/USD transmit tx
    function getTransmitPayload() public pure returns (
        bytes memory report,
        bytes32[] memory rs,
        bytes32[] memory ss,
        bytes32 rawVs
    ) {
        // From this ETHUSD transmit tx on mainnet:
        // https://etherscan.io/tx/0x3645d1bc223efe0861e02aeb95d6204c5ebfe268b64a7d23d385520faf452bc0
        // ETHUSD set to: $2941.02 == 294102000000
        // Block: 19289830

        report = hex"000000000000000000000047ddec946856fa8055ac2202f633de330001769d050a1718161a110212090c1d1b191c0b0e030001140f131e1508060d04100705000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000001f00000000000000000000000000000000000000000000000000000044759deacc0000000000000000000000000000000000000000000000000000004475d8ca020000000000000000000000000000000000000000000000000000004475d8ca020000000000000000000000000000000000000000000000000000004475d8ca100000000000000000000000000000000000000000000000000000004476517782000000000000000000000000000000000000000000000000000000447664840f0000000000000000000000000000000000000000000000000000004476a015190000000000000000000000000000000000000000000000000000004476a015190000000000000000000000000000000000000000000000000000004476a01519000000000000000000000000000000000000000000000000000000447779d953000000000000000000000000000000000000000000000000000000447914dd8f000000000000000000000000000000000000000000000000000000447914dd8f000000000000000000000000000000000000000000000000000000447914dd8f000000000000000000000000000000000000000000000000000000447914dd8f0000000000000000000000000000000000000000000000000000004479d861800000000000000000000000000000000000000000000000000000004479d861800000000000000000000000000000000000000000000000000000004479d861800000000000000000000000000000000000000000000000000000004479d861800000000000000000000000000000000000000000000000000000004479d861800000000000000000000000000000000000000000000000000000004479d9ce27000000000000000000000000000000000000000000000000000000447a9ebec0000000000000000000000000000000000000000000000000000000447a9ebec0000000000000000000000000000000000000000000000000000000447ad9a8c8000000000000000000000000000000000000000000000000000000447b281300000000000000000000000000000000000000000000000000000000447b281300000000000000000000000000000000000000000000000000000000447b281300000000000000000000000000000000000000000000000000000000447b3df490000000000000000000000000000000000000000000000000000000447b3df490000000000000000000000000000000000000000000000000000000447b5d3856000000000000000000000000000000000000000000000000000000447b5d3856000000000000000000000000000000000000000000000000000000447b5d3856";
        rs = new bytes32[](11);
        ss = new bytes32[](11);
        rawVs = 0x0100010101000000000001000000000000000000000000000000000000000000;

        rs[0] = 0x5bde6c6a1b27f1421400fba9850abcd4d9701d7178d2df1d469c693a9ab6389e;
        rs[1] = 0xf9518ba45aaf8fc019962dee3144087723bcac49ce1b3d12d075abc030ae51f1;
        rs[2] = 0x657ae99064988794f99b98dfdd6ebc9f5c0967f75e5ce61392d81d78e8434e0a;
        rs[3] = 0xfc4ef6fa4d47c3a8cb247799831c4db601387106cc9f80ef710fec5d06b07c53;
        rs[4] = 0x813516330ff60244a90a062f4ddcb18611711ed217cf146041439e26a6c1d687;
        rs[5] = 0x8aa23424c2fdd1d2f459fc901c3b21c611d17c07b0df51c48f17bd6bcc5d8c54;
        rs[6] = 0xe40ea4755faebccfccbf9ca25bd518427877c9155526db04458b9753034ad552;
        rs[7] = 0x44fbb6b9ab6f56f29d5d1943fa6d6b13c993e213ba3b20f6a5d20224cb3f942d;
        rs[8] = 0xe2a4e3529c077a128bc52d5e1b11cf64bc922100bafe6ebc95654fea49a5d355;
        rs[9] = 0x4588680888b56cda77a1b49b32807ba33e7009a182a048d33496d70987aebcbc;
        rs[10] = 0x7ad51d2aa5e792f46ac17784a3a362f0fff3dc7f805ef8f74324113d8b475249;

        ss[0] = 0x3eb07f321322b7d0ea0c90ca48af408e9b6daaaf0e33993436155ef83d1e7d0e;
        ss[1] = 0x5ff05d281bf7c1db924036e0123765adfef8b4f563d981da9c7011dc3b1e6c79;
        ss[2] = 0x7fdb65f4084636a904129a327d99a8ef5cdcadc3e6e266626823eb1adab4532d;
        ss[3] = 0x07025b9483f5ad5ee55f07b6cddbabc1411d9570ced7d11a3d504cf38853e8a3;
        ss[4] = 0x332a4b577c831d9dae5ea3eb4ee5832cdd6672c4bd7c97e5fb2dae3b4b99d02f;
        ss[5] = 0x45b4181c3b95f15fc40a40fb74344d1ef45c33dfbe99587237a1a4c875aae024;
        ss[6] = 0x2a2eb5e729343c2f093c6b6ec71f0b1eb07bf133ead806976672dcbf90abcaca;
        ss[7] = 0x54ca9bd4122a43f119d3d24072db5be9479f9271d32f332e76ff3a70feeb7fd3;
        ss[8] = 0x1a7aaeda65f1cabb53a43f080ab8d76337107b0e7bf013096eecdefcf88af56a;
        ss[9] = 0x7a1e1d7b9c865b34d966a94e21f0d2c73473a30bf03c1f8eff7b88b5c3183c31;
        ss[10] = 0x2768d43bca650e9a452db41730c4e31b600f5398c49490d66f4065a0b357707f;

        return (report, rs, ss, rawVs);
    }

    function getTransmitPayload_Sepolia() public pure returns (
        bytes memory userOpData
    ) {
        // From this ETHUSD transmit tx on sepolia:
        // https://sepolia.etherscan.io/tx/0xe0ed8968e815e61bda7689721c88cb90165b147cccbe8c488e08af9e9e3feef3
        // ETHUSD set to: $2979.36 == 297935851250
        // Block: 5810243

        bytes memory report = hex"0000000000000000000000ad329f62e1afb817fb5d7bd61a458fba00037a3503030002010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000455b1e0ad0000000000000000000000000000000000000000000000000000000455e5c4ef2000000000000000000000000000000000000000000000000000000455e5c4ef2000000000000000000000000000000000000000000000000000000455e901d52";

        bytes32[] memory rs = new bytes32[](2);
        rs[0] = 0x2ebc59983c9db753946c3ae099195c497dabfe5b5211605ed6ef8e6618113127;
        rs[1] = 0x39f66421121c8562f6de434b4a245fbb61f7c6a885b438d3ec4d6e94f9838ee6;

        bytes32[] memory ss = new bytes32[](2);
        ss[0] = 0x61478abeaf01232ce23a9251acff3d096bc9616c5979e59db2c68c27f4bead5e;
        ss[1] = 0x5b665f3a548debf55a275f7bc78e35f5db15aafb55cad6effc83d917d24c4b54;

        bytes32 rawVs = 0x0101000000000000000000000000000000000000000000000000000000000000;

        userOpData = abi.encodeCall(ChainlinkAtlasWrapper.transmit, (report, rs, ss, rawVs));
    }

    function getETHUSDSigners() public pure returns (address[] memory) {
        address[] memory signers = new address[](31);
        signers[0] = 0xCdEf689d3098A796F840A26f383CE19F4f023B5B;
        signers[1] = 0xb7bEA3A5d410F7c4eC2aa446ae4236F6Eed6b16A;
        signers[2] = 0x5ba2D2B875626901fed647411AD08009b1ee35e2;
        signers[3] = 0x21389cBcdb25c8859c704BD8Cd7252902384FceF;
        signers[4] = 0x03A67cD8467642a03d5ebd67F97157931D94fA32;
        signers[5] = 0x3650Da40Fe97A93bfC2623E0DcA3899a91Eca0e2;
        signers[6] = 0x1F31c45AE0605690D63D26d7CdA4035c3668D473;
        signers[7] = 0xCc1b49B86F79C7E50E294D3e3734fe94DB9A42F0;
        signers[8] = 0xA4EBE1e06dd0bf674B0757cd20b97Ee16b00aF1B;
        signers[9] = 0x8d4AE8b06701f53f7a34421461441E4492E1C578;
        signers[10] = 0x5007b477F939646b4E4416AFcEf6b00567F5F078;
        signers[11] = 0x55048BC9f3a3f373031fB32C0D0d5C1Bc6E10B3b;
        signers[12] = 0x8316e3Eb7eccfCAF0c1967903CcA8ECda3dF37E0;
        signers[13] = 0x503bd542a29F089319855cd9F6F6F937C7Be87c7;
        signers[14] = 0xbd34530f411130fd7aCB88b8251009A0829379aA;
        signers[15] = 0x54103390874885e164d69bf08B6db480E5E8fE5d;
        signers[16] = 0xC01465eBA4FA3A72309374bb67149A8FD14Cb687;
        signers[17] = 0xAF447dA1E8c277C41983B1732BECF39129BE5CA6;
        signers[18] = 0xbe15B23E9F03e3Bb44c5E35549354649fb25b87B;
        signers[19] = 0x1E15545b23B831fD39e1d9579427DeA61425DD47;
        signers[20] = 0xD1C8b1e58C1186597D1897054b738c551ec74BD4;
        signers[21] = 0x8EB664cD767f12507E7e3864Ba5B7E925090A0E5;
        signers[22] = 0x656Fc633eb33cF5daD0bCEa0E42cde85fb7A4Ab8;
        signers[23] = 0x076b12D219a32613cd370eA9649a860114D3015e;
        signers[24] = 0x0ac6c28B582016A55f6d4e3aC77b64749568Ffe1;
        signers[25] = 0xD3b9610534994aAb2777D8Af6C41d1e54F2ef33f;
        signers[26] = 0xbeB19b5EC84DdC9426d84e5cE7403AFB7BB56700;
        signers[27] = 0xd54DDB3A256a40061C41Eb6ADF4f412ca8e17c25;
        signers[28] = 0xdb69C372B30D7A663BDE45d31a4886385F50Ea51;
        signers[29] = 0x67a95e050d2E4200808A488628d55269dDeFC455;
        signers[30] = 0x080D263FAA8CBd848f0b9B24B40e1f23EA06b3A3;
        return signers;
    }
}

contract LiquidationOEVSolver is SolverBase {
    error NotSolverOwner();
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function liquidate(address liquidatable) public onlySelf {
        if(MockLiquidatable(liquidatable).canLiquidate()) {
            MockLiquidatable(liquidatable).liquidate();
        } else {
            console.log("Solver NOT able to liquidate.");
        }
    }

    function withdrawETH() public {
        if(msg.sender != _owner) revert NotSolverOwner();
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "Withdraw failed");
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}

// Super basic mock to represent a liquidation payout dependent on oracle price
contract MockLiquidatable {
    address public oracle;
    uint256 public liquidationPrice;

    constructor(address _oracle, uint256 _liquidationPrice) {
        oracle = _oracle;
        liquidationPrice = _liquidationPrice;
    }

    function liquidate() public {
        require(canLiquidate(), "Cannot liquidate");
        require(address(this).balance > 0, "No liquidation reward available");
        // If liquidated successfully, sends all the ETH in this contract to caller
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "Liquidation failed");
    }

    // Can only liquidate if the oracle price is exactly the liquidation price
    function canLiquidate() public view returns (bool) {
        return uint256(AggregatorV2V3Interface(oracle).latestAnswer()) == liquidationPrice;
    }
}

contract MockBadChainlinkFeed {
    function latestAnswer() external pure returns(int256) {
        return 0;
    }
}