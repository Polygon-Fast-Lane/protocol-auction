// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { SolverOperation } from "src/contracts/types/SolverOperation.sol";
import { UserOperation } from "src/contracts/types/UserOperation.sol";
import { DAppConfig } from "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/DAppOperation.sol";

import { SolverBase } from "src/contracts/solver/SolverBase.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import { TrebleSwapDAppControl } from "src/contracts/examples/trebleswap/TrebleSwapDAppControl.sol";

// Odos Test Txs on Base:
// 1. USDC -> WUF https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
// 2. ETH -> USDC https://basescan.org/tx/0x3f090e4dacb80f592a5d4e4c9fee23fdca1f3011b893740b4cb441256887d486

contract TrebleSwapTest is BaseTest {
    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct SwapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputMin;
    }

    struct Args {
        UserOperation userOp;
    }

    TrebleSwapDAppControl public trebleSwapControl;
    Sig public sig;
    Args public args;

    // Odos Router v2 on Base
    address public constant ODOS_ROUTER = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

    // Base ERC20 addresses
    IERC20 bWETH = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 WUF = IERC20(0x4da78059D97f155E18B37765e2e042270f4E0fC4);

    address executionEnvironment;

    function setUp() public virtual override {
        // Fork Base
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 18_906_794);

        _BaseTest_DeployAtlasContracts();

        // TODO refactor how BaseTest handles forking chains and deploying Atlas.

        vm.startPrank(governanceEOA);
        trebleSwapControl = new TrebleSwapDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(trebleSwapControl));
        vm.stopPrank();

        vm.prank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(trebleSwapControl));
    }

    function testTrebleSwap_swapUsdcToWuf() public {
        // Based on: https://basescan.org/tx/0x0ef4a9c24bbede2b39e12f5e5417733fa8183f372e41ee099c2c7523064c1b55
        // Swaps 197.2 USDC for 200,064,568.9293 WUF

        // Fork Base at block before USDC -> WUF swap on Odos

        // USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        // WUF: 0x4da78059D97f155E18B37765e2e042270f4E0fC4

        // Original calldata from tx above:
        // 0x83bd37f9 -> swapCompact selector
        // 0004 -> input token -> address list [USDC]
        // 0001 4da78059d97f155e18b37765e2e042270f4e0fc4 -> output token -> calldata address [WUF]
        // 04 0bc10880 -> input amount -> length = 4 bytes, value = 197200000
        // 0601d1d9f50a5a028f5c0001f73f77f9466da712590ae432a80f07fd50a7de600001616535324976f8dbcef19df0705b95ace86ebb480001a4a9220de44d699f453ddf7f7630a96cdedf64630000000006020207003401000001020180000005020a0004040500000301010003060119ff0000000000000000000000000000000000000000000000000000000000000000616535324976f8dbcef19df0705b95ace86ebb48833589fcd6edb6e08f4c7c32d4f71b54bda02913569d81c17b5b4ac08929dc1769b8e39668d3ae29f6c0a374a483101e04ef5f7ac9bd15d9142bac95d9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca42000000000000000000000000000000000000060000000000000000

        // Replace caller address   (0xa4a9220dE44D699f453DdF7F7630A96cDEdf6463)
        // with EE address:         (0x736F6980876FDa51A610AB79E2856528a62Bf80e)
        // Build userOp.data for swapCompact call
        bytes memory swapCompactCalldata =
            hex"83bd37f9000400014da78059d97f155e18b37765e2e042270f4e0fc4040bc108800601d1d9f50a5a028f5c0001f73f77f9466da712590ae432a80f07fd50a7de600001616535324976f8dbcef19df0705b95ace86ebb480001736F6980876FDa51A610AB79E2856528a62Bf80e0000000006020207003401000001020180000005020a0004040500000301010003060119ff0000000000000000000000000000000000000000000000000000000000000000616535324976f8dbcef19df0705b95ace86ebb48833589fcd6edb6e08f4c7c32d4f71b54bda02913569d81c17b5b4ac08929dc1769b8e39668d3ae29f6c0a374a483101e04ef5f7ac9bd15d9142bac95d9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca42000000000000000000000000000000000000060000000000000000";

        bytes memory encodedCall = abi.encodePacked(this.decodeSwapCompactCalldata.selector, swapCompactCalldata);
        (bool res, bytes memory returnData) = address(this).call(encodedCall);

        console.log("res", res);

        SwapTokenInfo memory swapInfo = abi.decode(returnData, (SwapTokenInfo));

        // SwapTokenInfo memory swapInfo = decodeSwapCompactCalldata(swapCompactCalldata);

        console.log("swapInfo.inputToken", swapInfo.inputToken);
        console.log("swapInfo.inputAmount", swapInfo.inputAmount);
        console.log("swapInfo.outputToken", swapInfo.outputToken);
        console.log("swapInfo.outputMin", swapInfo.outputMin);

        // Build userOp
        args.userOp = UserOperation({
            from: userEOA,
            to: address(atlas),
            value: 0,
            gas: 1_000_000,
            maxFeePerGas: 1e9, // 1 gwei
            nonce: 1,
            deadline: 18_906_796, // 1 block after tx happened
            dapp: ODOS_ROUTER,
            control: address(trebleSwapControl),
            callConfig: trebleSwapControl.CALL_CONFIG(),
            sessionKey: address(0),
            data: swapCompactCalldata,
            signature: new bytes(0)
        });
    }

    // struct swapTokenInfo {
    //     address inputToken;
    //     uint256 inputAmount;
    //     address outputToken;
    //     uint256 outputMin;
    // }

    // TODO once this works, move to TrebleSwapDAppControl
    function decodeSwapCompactCalldata() public returns (SwapTokenInfo memory swapTokenInfo) {
        assembly {
            // helper function to get address either from storage or calldata
            function getAddress(currPos) -> result, newPos {
                let inputPos := shr(240, calldataload(currPos))

                switch inputPos
                // Reserve the null address as a special case that can be specified with 2 null bytes
                case 0x0000 { newPos := add(currPos, 2) }
                // This case means that the address is encoded in the calldata directly following the code
                case 0x0001 {
                    result := and(shr(80, calldataload(currPos)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    newPos := add(currPos, 22)
                }
                default {
                    // 0000 and 0001 are reserved for cases above, so offset by 2 for addressList index
                    let arg := sub(inputPos, 2)
                    let selector := 0xb810fb43 // function selector for "addressList(uint256)"
                    let ptr := mload(0x40) // get the free memory pointer
                    mstore(ptr, shl(224, selector)) // shift selector to left of slot and store
                    mstore(add(ptr, 4), arg) // store the uint256 argument after the selector

                    // Perform the external call
                    let success :=
                        staticcall(
                            gas(), // gas remaining
                            0x19cEeAd7105607Cd444F5ad10dd51356436095a1, // Odos v2 Router on Base
                            ptr, // input location
                            0x24, // input size (4 byte selector + uint256 arg)
                            ptr, // output location
                            0x20 // output size (32 bytes for the address)
                        )

                    if eq(success, 0) { revert(0, 0) }

                    result := mload(ptr)
                    newPos := add(currPos, 2)
                }
            }

            let result := 0
            let pos := 8 // starts at 4 to skip the selector

            // swapTokenInfo.inputToken (slot 0)
            result, pos := getAddress(pos)
            mstore(swapTokenInfo, result)

            // swapTokenInfo.outputToken (slot 2)
            result, pos := getAddress(pos)
            mstore(add(swapTokenInfo, 0x40), result)

            // swapTokenInfo.inputAmount (slot 1)
            let inputAmountLength := shr(248, calldataload(pos))
            pos := add(pos, 1)
            if inputAmountLength {
                mstore(add(swapTokenInfo, 0x20), shr(mul(sub(32, inputAmountLength), 8), calldataload(pos)))
                pos := add(pos, inputAmountLength)
            }

            // swapTokenInfo.outputMin (slot 3)
            // get outputQuote and slippageTolerance from calldata, then calculate outputMin
            let quoteAmountLength := shr(248, calldataload(pos))
            pos := add(pos, 1)
            let outputQuote := shr(mul(sub(32, quoteAmountLength), 8), calldataload(pos))
            pos := add(pos, quoteAmountLength)
            {
                let slippageTolerance := shr(232, calldataload(pos))
                mstore(add(swapTokenInfo, 0x60), div(mul(outputQuote, sub(0xFFFFFF, slippageTolerance)), 0xFFFFFF))
            }
        }
    }
}

interface IOdosRouterV2 {
    function swapCompact() external payable returns (uint256);
}
