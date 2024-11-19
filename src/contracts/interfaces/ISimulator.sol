//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../types/SolverOperation.sol";
import "../types/UserOperation.sol";
import "../types/ConfigTypes.sol";
import "../types/DAppOperation.sol";

enum Result {
    Unknown,
    VerificationSimFail,
    PreOpsSimFail,
    UserOpSimFail,
    SolverSimFail,
    AllocateValueSimFail,
    PostOpsSimFail,
    SimulationPassed
}

interface ISimulator {
    function simUserOperation(UserOperation calldata userOp)
        external
        payable
        returns (bool success, Result simResult, uint256);

    function simSolverCall(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp,
        DAppOperation calldata verification
    )
        external
        payable
        returns (bool success, Result simResult, uint256);

    function simSolverCalls(
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata verification
    )
        external
        payable
        returns (bool success, Result simResult, uint256);
}
