// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { DummyDAppControl } from "../base/DummyDAppControl.sol";
import { CallConfig } from "../../src/contracts/types/ConfigTypes.sol";
import { AtlasVerification } from "../../src/contracts/atlas/AtlasVerification.sol";

import "forge-std/Test.sol";

contract DummyDAppControlBuilder is Test {
    address public atlas;
    address public governance;
    CallConfig callConfig;

    function withEscrow(address _atlas) public returns (DummyDAppControlBuilder) {
        atlas = _atlas;
        return this;
    }

    function withGovernance(address _governance) public returns (DummyDAppControlBuilder) {
        governance = _governance;
        return this;
    }

    function withCallConfig(CallConfig memory _callConfig) public returns (DummyDAppControlBuilder) {
        callConfig = _callConfig;
        return this;
    }

    function build() public returns (DummyDAppControl) {
        return new DummyDAppControl(atlas, governance, callConfig);
    }

    /*
    * @notice Builds a DummyDAppControl contract and integrates it with the AtlasVerification contract.
    * @param verification The AtlasVerification contract to integrate with.
    * @return The DummyDAppControl contract.
    */
    function buildAndIntegrate(AtlasVerification verification) public returns (DummyDAppControl) {
        vm.startPrank(governance);
        DummyDAppControl control = build();
        verification.initializeGovernance(address(control));
        vm.stopPrank();
        return control;
    }
}
