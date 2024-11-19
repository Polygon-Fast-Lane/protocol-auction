//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// External representation of the swap intent
struct SwapIntent {
    address tokenUserBuys;
    uint256 minAmountUserBuys;
    address tokenUserSells;
    uint256 amountUserSells;
}

struct BaselineCall {
    address to; // Address to send the swap if there are no solvers / to get the baseline
    bytes data; // Calldata for the baseline swap
    uint256 value; // msg.value of the swap (native gas token)
}

struct Reputation {
    uint128 successCost;
    uint128 failureCost;
}
