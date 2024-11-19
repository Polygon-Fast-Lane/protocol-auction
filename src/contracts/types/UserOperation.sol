//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Default UserOperation typehash
bytes32 constant USER_TYPEHASH_DEFAULT = keccak256(
    "UserOperation(address from,address to,uint256 value,uint256 gas,uint256 maxFeePerGas,uint256 nonce,uint256 deadline,address dapp,address control,uint32 callConfig,address sessionKey,bytes data)"
);

// Trusted UserOperation typehash
// NOTE: This is explicitly for the 'trustedOpHash' configuration option meant so that solvers can submit
// SolverOperations
// prior to seeing the UserOperation or its hash. In this scenario, the Solvers should trust the signer of the
// UserOperation.
bytes32 constant USER_TYPEHASH_TRUSTED = keccak256(
    "UserOperation(address from,address to,address dapp,address control,uint32 callConfig,address sessionKey)"
);

struct UserOperation {
    address from; // User address
    address to; // Atlas address
    uint256 value; // Amount of ETH required for the user operation (used in `value` field of the user call)
    uint256 gas; // Gas limit for the user operation
    uint256 maxFeePerGas; // Max fee per gas for the user operation
    uint256 nonce; // Atlas nonce of the user operation available in the AtlasVerification contract
    uint256 deadline; // block.number deadline for the user operation
    address dapp; // Nested "to" for user's call (used in `to` field of the user call)
    address control; // Address of the DAppControl contract
    uint32 callConfig; // Call configuration expected by user, refer to
        // `src/contracts/types/ConfigTypes.sol:CallConfig`
    address sessionKey; // Address of the temporary session key which is used to sign the DappOperation
    bytes data; // User operation calldata (used in `data` field of the user call)
    bytes signature; // User operation signature signed by UserOperation.from
}
