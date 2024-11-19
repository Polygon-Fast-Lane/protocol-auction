// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { FactoryLib } from "../src/contracts/atlas/FactoryLib.sol";
import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { ExecutionEnvironment } from "../src/contracts/common/ExecutionEnvironment.sol";
import { DAppIntegration } from "../src/contracts/atlas/DAppIntegration.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";

import { DummyDAppControl, CallConfigBuilder } from "./base/DummyDAppControl.sol";

contract MockDAppIntegration is DAppIntegration {
    constructor(address _atlas) DAppIntegration(_atlas) { }
}

contract DAppIntegrationTest is Test {
    uint256 DEFAULT_ATLAS_SURCHARGE_RATE = 1_000_000; // 10%
    uint256 DEFAULT_BUNDLER_SURCHARGE_RATE = 1_000_000; // 10%

    Atlas public atlas;
    MockDAppIntegration public dAppIntegration;
    DummyDAppControl public dAppControl;
    AtlasVerification atlasVerification;
    FactoryLib factoryLib;

    address atlasDeployer = makeAddr("atlas deployer");
    address governance = makeAddr("governance");
    address signatory = makeAddr("signatory");
    address invalid = makeAddr("invalid");

    function setUp() public {
        vm.startPrank(atlasDeployer);
        
        // Compute expected addresses for Atlas
        address expectedAtlasAddr = vm.computeCreateAddress(atlasDeployer, vm.getNonce(atlasDeployer) + 3);

        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        // Deploy the AtlasVerification contract
        atlasVerification = new AtlasVerification(expectedAtlasAddr);
        factoryLib = new FactoryLib(address(execEnvTemplate));

        // Deploy the Atlas contract with correct parameters
        atlas = new Atlas({
            escrowDuration: 64,
            atlasSurchargeRate: DEFAULT_ATLAS_SURCHARGE_RATE,
            bundlerSurchargeRate: DEFAULT_BUNDLER_SURCHARGE_RATE,
            verification: address(atlasVerification),
            simulator: address(0),
            factoryLib: address(factoryLib),
            initialSurchargeRecipient: atlasDeployer,
            l2GasCalculator: address(0)
        });

        assertEq(address(atlas), expectedAtlasAddr, "Atlas address should be as expected");

        // Deploy the MockDAppIntegration contract
        dAppIntegration = new MockDAppIntegration(address(atlas));
        vm.stopPrank();

        // Deploy the DummyDAppControl contract
        dAppControl = new DummyDAppControl(address(atlas), governance, CallConfigBuilder.allFalseCallConfig());
    }

    function test_initializeGovernance_successfullyInitialized() public {
        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), governance));
        vm.prank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        assertTrue(
            dAppIntegration.signatories(signatoryKey), "signatories[signatoryKey] should be true when initialized"
        );
    }

    function test_initializeGovernance_notInitialized() public view {
        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), governance));
        assertFalse(
            dAppIntegration.signatories(signatoryKey), "signatories[signatoryKey] should be false when not initialized"
        );
    }

    function test_initializeGovernance_onlyGovernanceAllowed() public {
        vm.prank(invalid);
        vm.expectRevert(AtlasErrors.OnlyGovernance.selector);
        dAppIntegration.initializeGovernance(address(dAppControl));
    }

    function test_initializeGovernance_alreadyInitialized() public {
        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        vm.expectRevert(AtlasErrors.SignatoryActive.selector);
        dAppIntegration.initializeGovernance(address(dAppControl));
        vm.stopPrank();
    }

    function test_addSignatory_successfullyAdded() public {
        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), signatory));

        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        assertTrue(dAppIntegration.signatories(signatoryKey), "signatories[signatoryKey] should be true when added");
        vm.stopPrank();
    }

    function test_addSignatory_notSignatory() public {
        vm.prank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));

        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), signatory));
        assertFalse(
            dAppIntegration.signatories(signatoryKey), "signatories[signatoryKey] should be false when not added"
        );
    }

    function test_addSignatory_onlyGovernanceAllowed() public {
        vm.prank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));

        vm.prank(invalid);
        vm.expectRevert(AtlasErrors.OnlyGovernance.selector);
        dAppIntegration.addSignatory(address(dAppControl), signatory);
    }

    function test_addSignatory_alreadyActive() public {
        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        vm.expectRevert(AtlasErrors.SignatoryActive.selector);
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        vm.stopPrank();
    }

    function test_removeSignatory_successfullyRemovedByGovernance() public {
        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), signatory));

        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        dAppIntegration.removeSignatory(address(dAppControl), signatory);
        vm.stopPrank();

        assertFalse(
            dAppIntegration.signatories(signatoryKey),
            "signatories[signatoryKey] should be false when governance removes a signatory"
        );
    }

    function test_removeSignatory_successfullyRemovedBySignatoryItself() public {
        bytes32 signatoryKey = keccak256(abi.encodePacked(address(dAppControl), signatory));

        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        vm.stopPrank();

        vm.prank(signatory);
        dAppIntegration.removeSignatory(address(dAppControl), signatory);

        assertFalse(
            dAppIntegration.signatories(signatoryKey),
            "signatories[signatoryKey] should be false when a signatory removes itself"
        );
    }

    function test_removeSignatory_invalidCaller() public {
        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        dAppIntegration.addSignatory(address(dAppControl), signatory);
        vm.stopPrank();

        vm.prank(invalid);
        vm.expectRevert(AtlasErrors.InvalidCaller.selector);
        dAppIntegration.removeSignatory(address(dAppControl), signatory);
    }

    function test_disableDApp_successfullyDisabled() public {
        assertEq(dAppIntegration.isDAppSignatory(address(dAppControl), governance), false);

        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        assertEq(dAppIntegration.isDAppSignatory(address(dAppControl), governance), true);
        dAppIntegration.disableDApp(address(dAppControl));
        vm.stopPrank();

        assertEq(dAppIntegration.isDAppSignatory(address(dAppControl), governance), false);
    }

    function test_disableDApp_onlyGovernanceAllowed() public {
        vm.startPrank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        vm.stopPrank();

        vm.prank(invalid);
        vm.expectRevert(AtlasErrors.OnlyGovernance.selector);
        dAppIntegration.disableDApp(address(dAppControl));
    }

    function test_getGovFromControl() public {
        vm.prank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));
        assertEq(
            dAppIntegration.getGovFromControl(address(dAppControl)), governance, "should return correct governance"
        );
    }

    function test_getGovFromControl_dAppNotEnabled() public {
        vm.expectRevert(AtlasErrors.DAppNotEnabled.selector);
        dAppIntegration.getGovFromControl(address(dAppControl));
    }

    function test_dAppSignatories() public {
        assertEq(new address[](0), dAppIntegration.dAppSignatories(address(dAppControl)), "should start as empty array");

        vm.prank(governance);
        dAppIntegration.initializeGovernance(address(dAppControl));

        address[] memory signatories = dAppIntegration.dAppSignatories(address(dAppControl));
        assertEq(signatories.length, 1, "should return 1 signatory");
        assertEq(signatories[0], governance, "gov should be a signatory");

        vm.prank(governance);
        dAppIntegration.addSignatory(address(dAppControl), signatory);

        signatories = dAppIntegration.dAppSignatories(address(dAppControl));
        assertEq(signatories.length, 2, "should return 2 signatories");
        assertEq(signatories[1], signatory, "should return correct 2nd signatory");

        address anotherSignatory = makeAddr("anotherSignatory");
        vm.prank(governance);
        dAppIntegration.addSignatory(address(dAppControl), anotherSignatory);

        signatories = dAppIntegration.dAppSignatories(address(dAppControl));
        assertEq(signatories.length, 3, "should return 3 signatories");
        assertEq(signatories[2], anotherSignatory, "should return correct 3rd signatory");
    }
}
