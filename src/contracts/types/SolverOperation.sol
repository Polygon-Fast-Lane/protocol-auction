//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

bytes32 constant SOLVER_TYPEHASH = keccak256(
    "SolverOperation(address from,address to,uint256 value,uint256 gas,uint256 maxFeePerGas,uint256 deadline,address solver,address control,bytes32 userOpHash,address bidToken,uint256 bidAmount,bytes data)"
);

// NOTE: The calldata length of this SolverOperation struct is 608 bytes when the `data` field is excluded. This value
// is stored in the `_SOLVER_OP_BASE_CALLDATA` constant in AtlasConstants.sol and must be kept up-to-date with any
// changes to this struct.
struct SolverOperation {
    address from; // Solver address
    address to; // Atlas address
    uint256 value; // Amount of ETH required for the solver operation (used in `value` field of the solver call)
    uint256 gas; // Gas limit for the solver operation
    uint256 maxFeePerGas; // maxFeePerGas solver is willing to pay.  This goes to validator, not dApp or user
    uint256 deadline; // block.number deadline for the solver operation
    address solver; // Nested "to" address (used in `to` field of the solver call)
    address control; // DAppControl address
    bytes32 userOpHash; // hash of User's Operation, for verification of user's tx (if not matched, solver wont be
        // charged for gas)
    address bidToken; // address(0) for ETH
    uint256 bidAmount; // Amount of bidToken that the solver bids
    bytes data; // Solver op calldata (used in `data` field of the solver call)
    bytes signature; // Solver operation signature signed by SolverOperation.from
}
