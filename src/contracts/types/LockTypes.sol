//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

struct Context {
    bytes32 userOpHash; // not packed
    address executionEnvironment; // not packed
    uint24 solverOutcome;
    uint8 solverIndex;
    uint8 solverCount;
    uint8 callDepth;
    uint8 phase;
    bool solverSuccessful;
    bool paymentsSuccessful;
    bool bidFind;
    bool isSimulation;
    address bundler;
    Reimbursement[] reimbursements; // array of reimbursements
}

struct Reimbursement {
    uint256 gasUsed;
    address reimburser;
}

enum ExecutionPhase {
    Uninitialized,
    PreOps,
    UserOperation,
    PreSolver,
    SolverOperation,
    PostSolver,
    AllocateValue,
    PostOps,
    FullyLocked
}
