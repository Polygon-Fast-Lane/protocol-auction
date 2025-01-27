// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { BaseTest } from "../base/BaseTest.t.sol";
import { ArbSysMock } from "./ArbSysMock.sol";
import { ArbGasInfoMock } from "./ArbGasInfoMock.sol";

abstract contract ArbitrumTest is BaseTest {
    ArbSysMock internal constant ARBSYS = ArbSysMock(address(0x64));
    ArbGasInfoMock internal constant ARB_GAS_INFO_MOCK = ArbGasInfoMock(address(0x6c));

    // Arbitrum block number
    uint256 public constant ARBITRUM_BLOCK_NUMBER = 260_145_837;

    function setUp() public virtual override {
        super.setUpChain("ARBITRUM_RPC_URL", ARBITRUM_BLOCK_NUMBER);
        vm.etch(address(0x64), type(ArbSysMock).runtimeCode);
        vm.etch(address(0x6c), type(ArbGasInfoMock).runtimeCode);

        // Set Arbitrum block number
        ARBSYS.setArbBlockNumber(ARBITRUM_BLOCK_NUMBER);
    }
}


