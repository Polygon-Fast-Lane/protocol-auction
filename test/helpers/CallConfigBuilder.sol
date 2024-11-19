// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CallConfig } from "../../src/contracts/types/ConfigTypes.sol";

import "forge-std/Test.sol";

contract CallConfigBuilder is Test {
    bool userNoncesSequential;
    bool dappNoncesSequential;
    bool requirePreOps;
    bool trackPreOpsReturnData;
    bool trackUserReturnData;
    bool delegateUser;
    bool requirePreSolver;
    bool requirePostSolver;
    bool requirePostOps;
    bool zeroSolvers;
    bool reuseUserOp;
    bool userAuctioneer;
    bool solverAuctioneer;
    bool unknownAuctioneer;
    bool verifyCallChainHash;
    bool forwardReturnData;
    bool requireFulfillment;
    bool trustedOpHash;
    bool invertBidValue;
    bool exPostBids;
    bool allowAllocateValueFailure;

    function withUserNoncesSequential(bool _sequential) public returns (CallConfigBuilder) {
        userNoncesSequential = _sequential;
        return this;
    }

    function withDappNoncesSequential(bool _sequential) public returns (CallConfigBuilder) {
        dappNoncesSequential = _sequential;
        return this;
    }

    function withRequirePreOps(bool _requirePreOps) public returns (CallConfigBuilder) {
        requirePreOps = _requirePreOps;
        return this;
    }

    function withTrackPreOpsReturnData(bool _trackPreOpsReturnData) public returns (CallConfigBuilder) {
        trackPreOpsReturnData = _trackPreOpsReturnData;
        return this;
    }

    function withTrackUserReturnData(bool _trackUserReturnData) public returns (CallConfigBuilder) {
        trackUserReturnData = _trackUserReturnData;
        return this;
    }

    function withDelegateUser(bool _delegateUser) public returns (CallConfigBuilder) {
        delegateUser = _delegateUser;
        return this;
    }

    function withRequirePreSolver(bool _requirePreSolver) public returns (CallConfigBuilder) {
        requirePreSolver = _requirePreSolver;
        return this;
    }

    function withRequirePostSolver(bool _requirePostSolver) public returns (CallConfigBuilder) {
        requirePostSolver = _requirePostSolver;
        return this;
    }

    function withRequirePostOps(bool _requirePostOps) public returns (CallConfigBuilder) {
        requirePostOps = _requirePostOps;
        return this;
    }

    function withZeroSolvers(bool _zeroSolvers) public returns (CallConfigBuilder) {
        zeroSolvers = _zeroSolvers;
        return this;
    }

    function withReuseUserOp(bool _reuseUserOp) public returns (CallConfigBuilder) {
        reuseUserOp = _reuseUserOp;
        return this;
    }

    function withUserAuctioneer(bool _userAuctioneer) public returns (CallConfigBuilder) {
        userAuctioneer = _userAuctioneer;
        return this;
    }

    function withSolverAuctioneer(bool _solverAuctioneer) public returns (CallConfigBuilder) {
        solverAuctioneer = _solverAuctioneer;
        return this;
    }

    function withUnknownAuctioneer(bool _unknownAuctioneer) public returns (CallConfigBuilder) {
        unknownAuctioneer = _unknownAuctioneer;
        return this;
    }

    function withVerifyCallChainHash(bool _verifyCallChainHash) public returns (CallConfigBuilder) {
        verifyCallChainHash = _verifyCallChainHash;
        return this;
    }

    function withForwardReturnData(bool _forwardReturnData) public returns (CallConfigBuilder) {
        forwardReturnData = _forwardReturnData;
        return this;
    }

    function withRequireFulfillment(bool _requireFulfillment) public returns (CallConfigBuilder) {
        requireFulfillment = _requireFulfillment;
        return this;
    }

    function withTrustedOpHash(bool _allowTrustedOpHash) public returns (CallConfigBuilder) {
        trustedOpHash = _allowTrustedOpHash;
        return this;
    }

    function withinvertBidValue(bool _invertBidValue) public returns (CallConfigBuilder) {
        invertBidValue = _invertBidValue;
        return this;
    }

    function withExPostBids(bool _exPostBids) public returns (CallConfigBuilder) {
        exPostBids = _exPostBids;
        return this;
    }

    function withAllowAllocateValueFailure(bool _allowAllocateValueFailure) public returns (CallConfigBuilder) {
        allowAllocateValueFailure = _allowAllocateValueFailure;
        return this;
    }

    function build() public view returns (CallConfig memory) {
        return CallConfig(
            userNoncesSequential,
            dappNoncesSequential,
            requirePreOps,
            trackPreOpsReturnData,
            trackUserReturnData,
            delegateUser,
            requirePreSolver,
            requirePostSolver,
            requirePostOps,
            zeroSolvers,
            reuseUserOp,
            userAuctioneer,
            solverAuctioneer,
            unknownAuctioneer,
            verifyCallChainHash,
            forwardReturnData,
            requireFulfillment,
            trustedOpHash,
            invertBidValue,
            exPostBids,
            allowAllocateValueFailure
        );
    }
}
