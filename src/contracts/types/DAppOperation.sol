//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

bytes32 constant DAPP_TYPEHASH = keccak256(
    "DAppOperation(address from,address to,uint256 nonce,uint256 deadline,address control,address bundler,bytes32 userOpHash,bytes32 callChainHash)"
);

struct DAppOperation {
    address from; // signer of the DAppOperation
    address to; // Atlas address
    uint256 nonce; // Atlas nonce of the DAppOperation available in the AtlasVerification contract
    uint256 deadline; // block.number deadline for the DAppOperation
    address control; // DAppControl address
    address bundler; // Signer of the atlas tx (msg.sender)
    bytes32 userOpHash; // keccak256 of userOp.to, userOp.data
    bytes32 callChainHash; // keccak256 of the solvers' txs
    bytes signature; // DAppOperation signed by DAppOperation.from
}
