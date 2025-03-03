//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

struct DAppConfig {
    address to; // Address of the DAppControl contract
    uint32 callConfig; // Configuration
    address bidToken; // address(0) for ETH
    uint32 solverGasLimit; // Max gas limit for solverOps
}

struct CallConfig {
    // userNoncesSequential: The userOp nonce must be the next sequential nonce for that user’s address in Atlas’
    // nonce system. If false, the userOp nonces are allowed to be non-sequential (unordered), as long as they are
    // unique.
    bool userNoncesSequential;
    // dappNoncesSequential: The dappOp nonce must be the next sequential nonce for that dApp signer’s address in
    // Atlas’ nonce system. If false, the dappOp nonce is not checked, as the dAppOp is tied to its userOp's nonce via
    // the callChainHash.
    bool dappNoncesSequential;
    // requirePreOps: The preOps hook is executed before the userOp is executed. If false, the preOps hook is skipped.
    // the dapp control should check the validity of the user operation (whether its dapps can support userOp.dapp and
    // userOp.data) in the preOps hook.
    bool requirePreOps;
    // trackPreOpsReturnData: The return data from the preOps hook is passed to the next call phase. If false preOps
    // return data is discarded. If both trackPreOpsReturnData and trackUserReturnData are true, they are concatenated.
    bool trackPreOpsReturnData;
    // trackUserReturnData: The return data from the userOp call is passed to the next call phase. If false userOp
    // return data is discarded. If both trackPreOpsReturnData and trackUserReturnData are true, they are concatenated.
    bool trackUserReturnData;
    // delegateUser: The userOp call is made using delegatecall from the Execution Environment. If false, userOp is
    // called using call.
    bool delegateUser;
    // requirePreSolver: The preSolver hook is executed before the solverOp is executed. If false, the preSolver hook is
    // skipped.
    bool requirePreSolver;
    // requirePostSolver: The postSolver hook is executed after the solverOp is executed. If false, the postSolver hook
    // is skipped.
    bool requirePostSolver;
    // requirePostOps: The postOps hook is executed as the last step of the metacall. If false, the postOps hook is
    // skipped.
    bool requirePostOps;
    // zeroSolvers: Allow the metacall to proceed even if there are no solverOps. The solverOps do not necessarily need
    // to be successful, but at least 1 must exist.
    bool zeroSolvers;
    // reuseUserOp: If true, the metacall will revert if unsuccessful so as not to store nonce data, so the userOp can
    // be reused.
    bool reuseUserOp;
    // userAuctioneer: The user is allowed to be the auctioneer (the signer of the dAppOp). More than one auctioneer
    // option can be set to true for the same DAppControl.
    bool userAuctioneer;
    // solverAuctioneer: The solver is allowed to be the auctioneer (the signer of the dAppOp). If the solver is the
    // auctioneer then their solverOp must be the only one. More than one auctioneer option can be set to true for the
    // same DAppControl.
    bool solverAuctioneer;
    // unknownAuctioneer: Anyone is allowed to be the auctioneer - dAppOp.from must be the signer of the dAppOp, but the
    // usual signatory[] checks are skipped. More than one auctioneer option can be set to true for the same
    // DAppControl.
    bool unknownAuctioneer;
    // verifyCallChainHash: Check that the dAppOp callChainHash matches the actual callChainHash as calculated in
    // AtlasVerification.
    bool verifyCallChainHash;
    // forwardReturnData: The return data from previous steps is included as calldata in the call from the Execution
    // Environment to the solver contract. If false, return data is not passed to the solver contract.
    bool forwardReturnData;
    // requireFulfillment: If true, a winning solver must be found, otherwise the metacall will fail.
    bool requireFulfillment;
    // trustedOpHash: If true, the userOpHash excludes some userOp inputs such as `value`, `gas`, `maxFeePerGas`,
    // `nonce`, `deadline`, and `data`, implying solvers trust changes made to these parts of the userOp after signing
    // their associated solverOps.
    bool trustedOpHash;
    // invertBidValue: If true, the solver with the lowest successful bid wins.
    bool invertBidValue;
    // exPostBids: Bids are found on-chain using `_getBidAmount` in Atlas, and solverOp.bidAmount is used as the max
    // bid. If solverOp.bidAmount is 0, then there is no max bid limit for that solver.
    bool exPostBids;
    // allowAllocateValueFailure: If true, the metacall will proceed even if the value allocation fails. If false, the
    // metacall will revert if the value allocation fails.
    bool allowAllocateValueFailure;
    // multipleSolvers: If true, the metacall will proceed even if a solver successfully pays their bid, and will be
    // charged in gas as if it was reverted. If false, the auction ends after the first successful solver.
    bool multipleSuccessfulSolvers;
}

enum CallConfigIndex {
    UserNoncesSequential,
    DAppNoncesSequential,
    RequirePreOps,
    TrackPreOpsReturnData,
    TrackUserReturnData,
    DelegateUser,
    RequirePreSolver,
    RequirePostSolver,
    RequirePostOpsCall,
    ZeroSolvers,
    ReuseUserOp,
    UserAuctioneer,
    SolverAuctioneer,
    UnknownAuctioneer,
    // Default = DAppAuctioneer
    VerifyCallChainHash,
    ForwardReturnData,
    RequireFulfillment,
    TrustedOpHash,
    InvertBidValue,
    ExPostBids,
    AllowAllocateValueFailure,
    MultipleSuccessfulSolvers
}
