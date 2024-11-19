// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { CallVerification } from "../../src/contracts/libraries/CallVerification.sol";
import "../../src/contracts/types/UserOperation.sol";
import "../base/TestUtils.sol";

contract CallVerificationTest is Test {
    using CallVerification for UserOperation;

    function buildUserOperation() internal pure returns (UserOperation memory) {
        return UserOperation({
            from: address(0x1),
            to: address(0x0),
            deadline: 12,
            gas: 34,
            nonce: 56,
            maxFeePerGas: 78,
            value: 90,
            dapp: address(0x2),
            control: address(0x3),
            callConfig: 321,
            sessionKey: address(0),
            data: "data",
            signature: "signature"
        });
    }

    function builderSolverOperation() internal view returns (SolverOperation memory) {
        return SolverOperation({
            from: address(0x1),
            to: address(0x0),
            value: 12,
            gas: 34,
            maxFeePerGas: 78,
            deadline: block.number + 2,
            solver: address(0x2),
            control: address(0x3),
            userOpHash: "userCallHash",
            bidToken: address(0x4),
            bidAmount: 5,
            data: "data",
            signature: "signature"
        });
    }

    function testGetCallChainHash() public view {
        DAppConfig memory dConfig = DAppConfig({ to: address(0x1), callConfig: 1, bidToken: address(0), solverGasLimit: 1_000_000 });
        UserOperation memory userOp = buildUserOperation();
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = builderSolverOperation();
        solverOps[1] = builderSolverOperation();
        this._testGetCallChainHash(userOp, solverOps);
    }

    function _testGetCallChainHash(
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps
    )
        external pure
    {
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        assertEq(
            callChainHash,
            TestUtils.computeCallChainHash(userOp, solverOps),
            "callChainHash different to TestUtils reproduction"
        );
    }
}
