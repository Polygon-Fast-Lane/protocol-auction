// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { UserOperation } from "../../../src/contracts/types/UserOperation.sol";
import { CallConfig } from "../../../src/contracts/types/ConfigTypes.sol";
import { CallBits } from "../../../src/contracts/libraries/CallBits.sol";

import { IAtlasVerification } from "../../../src/contracts/interfaces/IAtlasVerification.sol";

contract UserOperationBuilder is Test {
    using CallBits for uint32;

    UserOperation userOperation;

    function withFrom(address from) public returns (UserOperationBuilder) {
        userOperation.from = from;
        return this;
    }

    function withTo(address to) public returns (UserOperationBuilder) {
        userOperation.to = to;
        return this;
    }

    function withValue(uint256 value) public returns (UserOperationBuilder) {
        userOperation.value = value;
        return this;
    }

    function withGas(uint256 gas) public returns (UserOperationBuilder) {
        userOperation.gas = gas;
        return this;
    }

    function withMaxFeePerGas(uint256 maxFeePerGas) public returns (UserOperationBuilder) {
        userOperation.maxFeePerGas = maxFeePerGas;
        return this;
    }

    function withNonce(uint256 nonce) public returns (UserOperationBuilder) {
        userOperation.nonce = nonce;
        return this;
    }

    function withNonce(address atlasVerification) public returns (UserOperationBuilder) {
        // Assumes sequential = false. Use withNonce(address, bool) to specify sequential.
        userOperation.nonce = IAtlasVerification(atlasVerification).getUserNextNonce(userOperation.from, false);
        return this;
    }

    function withNonce(address atlasVerification, bool sequential) public returns (UserOperationBuilder) {
        userOperation.nonce = IAtlasVerification(atlasVerification).getUserNextNonce(userOperation.from, sequential);
        return this;
    }

    function withNonce(address atlasVerification, address account) public returns (UserOperationBuilder) {
        // Assumes sequential = false. Use withNonce(address, address, bool) to specify sequential.
        userOperation.nonce = IAtlasVerification(atlasVerification).getUserNextNonce(account, false);
        return this;
    }

    function withNonce(
        address atlasVerification,
        address account,
        bool sequential
    )
        public
        returns (UserOperationBuilder)
    {
        userOperation.nonce = IAtlasVerification(atlasVerification).getUserNextNonce(account, sequential);
        return this;
    }

    function withDeadline(uint256 deadline) public returns (UserOperationBuilder) {
        userOperation.deadline = deadline;
        return this;
    }

    function withDapp(address dapp) public returns (UserOperationBuilder) {
        userOperation.dapp = dapp;
        return this;
    }

    function withControl(address control) public returns (UserOperationBuilder) {
        userOperation.control = control;
        return this;
    }

    function withCallConfig(CallConfig memory callConfig) public returns (UserOperationBuilder) {
        userOperation.callConfig = CallBits.encodeCallConfig(callConfig);
        return this;
    }

    function withCallConfig(uint32 callConfig) public returns (UserOperationBuilder) {
        userOperation.callConfig = callConfig;
        return this;
    }

    function withSessionKey(address sessionKey) public returns (UserOperationBuilder) {
        userOperation.sessionKey = sessionKey;
        return this;
    }

    function withData(bytes memory data) public returns (UserOperationBuilder) {
        userOperation.data = data;
        return this;
    }

    function withSignature(bytes memory signature) public returns (UserOperationBuilder) {
        userOperation.signature = signature;
        return this;
    }

    function sign(address atlasVerification, uint256 privateKey) public returns (UserOperationBuilder) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(privateKey, IAtlasVerification(atlasVerification).getUserOperationPayload(userOperation));
        userOperation.signature = abi.encodePacked(r, s, v);
        return this;
    }

    function build() public view returns (UserOperation memory) {
        return userOperation;
    }

    function signAndBuild(address atlasVerification, uint256 privateKey) public returns (UserOperation memory) {
        sign(atlasVerification, privateKey);
        return userOperation;
    }
}
