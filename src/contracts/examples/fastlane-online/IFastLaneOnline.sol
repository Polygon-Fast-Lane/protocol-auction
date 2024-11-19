//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import { SwapIntent, BaselineCall, Reputation } from "./FastLaneTypes.sol";

interface IFastLaneOnline {
    // User entrypoint

    function fastOnlineSwap(UserOperation calldata userOp) external payable;

    // Solver functions

    function addSolverOp(UserOperation calldata userOp, SolverOperation calldata solverOp) external payable;

    function refundCongestionBuyIns(SolverOperation calldata solverOp) external;

    // DApp functions

    function setWinningSolver(address winningSolver) external;

    // Other functions

    function makeThogardsWifeHappy() external;

    // View Functions

    function getUserOperationAndHash(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas
    )
        external
        view
        returns (UserOperation memory userOp, bytes32 userOpHash);

    function getUserOpHash(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas
    )
        external
        view
        returns (bytes32 userOpHash);

    function getUserOperation(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas
    )
        external
        view
        returns (UserOperation memory userOp);

    function isUserNonceValid(address owner, uint256 nonce) external view returns (bool valid);
}
