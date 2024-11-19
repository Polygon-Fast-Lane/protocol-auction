//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../types/LockTypes.sol";

// NOTE: No user transfers allowed during AllocateValue
uint8 constant SAFE_USER_TRANSFER = uint8(
    1 << (uint8(ExecutionPhase.PreOps)) | 1 << (uint8(ExecutionPhase.UserOperation))
        | 1 << (uint8(ExecutionPhase.PreSolver)) | 1 << (uint8(ExecutionPhase.PostSolver))
        | 1 << (uint8(ExecutionPhase.PostOps))
);

// NOTE: No Dapp transfers allowed during UserOperation
uint8 constant SAFE_DAPP_TRANSFER = uint8(
    1 << (uint8(ExecutionPhase.PreOps)) | 1 << (uint8(ExecutionPhase.PreSolver))
        | 1 << (uint8(ExecutionPhase.PostSolver)) | 1 << (uint8(ExecutionPhase.AllocateValue))
        | 1 << (uint8(ExecutionPhase.PostOps))
);

library SafetyBits {
    function setAndPack(Context memory self, ExecutionPhase phase) internal pure returns (bytes memory packedCtx) {
        self.phase = uint8(phase);
        packedCtx = abi.encodePacked(
            self.bundler,
            self.solverSuccessful,
            self.paymentsSuccessful,
            self.solverIndex,
            self.solverCount,
            uint8(phase),
            self.solverOutcome,
            self.bidFind,
            self.isSimulation,
            uint8(1) // callDepth
        );
    }
}
