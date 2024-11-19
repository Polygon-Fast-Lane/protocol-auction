//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../types/SolverOperation.sol";

import { Reputation } from "./FastLaneTypes.sol";

contract BaseStorage {
    error FLOnline_NotUnlocked();

    // OK hear me out
    // 1. We have to rake some of the congestion buyins to maintain incentive compatibility (a low rep solver smurfing
    // as a user to collect
    // congestion fees from competing solvers by bidding extremely high and knowing they'll get 100% of it back)
    // 2. Oval charges 50% of all OEV and we're just charging 33% of *only* the congestion fees - not MEV - which means
    // we're practically saints.
    uint256 internal constant _CONGESTION_RAKE = 33_000;
    uint256 internal constant _CONGESTION_BASE = 100_000;
    bytes32 private constant _USER_LOCK_SLOT = keccak256("FLO_USER_LOCK");
    bytes32 private constant _WINNING_SOLVER_SLOT = keccak256("FLO_WINNING_SOLVER");

    uint256 internal S_rake;

    //   SolverOpHash   SolverOperation
    mapping(bytes32 => SolverOperation) internal S_solverOpCache;

    //      UserOpHash  SolverOpHash[]
    mapping(bytes32 => bytes32[]) internal S_solverOpHashes;

    //      SolverOpHash  BidValue
    mapping(bytes32 => uint256) internal S_congestionBuyIn;

    //      UserOpHash  TotalBidValue
    mapping(bytes32 => uint256) internal S_aggCongestionBuyIn;

    //     SolverFrom  Reputation
    mapping(address => Reputation) internal S_solverReputations;

    //////////////////////////////////////////////
    /////          VIEW FUNCTIONS           //////
    //////////////////////////////////////////////

    function rake() external view returns (uint256) {
        return S_rake;
    }

    function solverOpCache(bytes32 solverOpHash) external view returns (SolverOperation memory) {
        return S_solverOpCache[solverOpHash];
    }

    function solverOpHashes(bytes32 userOpHash) external view returns (bytes32[] memory) {
        return S_solverOpHashes[userOpHash];
    }

    function congestionBuyIn(bytes32 solverOpHash) external view returns (uint256) {
        return S_congestionBuyIn[solverOpHash];
    }

    function aggCongestionBuyIn(bytes32 userOpHash) external view returns (uint256) {
        return S_aggCongestionBuyIn[userOpHash];
    }

    function solverReputation(address solver) external view returns (Reputation memory) {
        return S_solverReputations[solver];
    }

    //////////////////////////////////////////////
    /////            MODIFIERS              //////
    //////////////////////////////////////////////

    modifier withUserLock(address user) {
        if (_getUserLock() != address(0)) revert FLOnline_NotUnlocked();
        _setUserLock(user);
        _;
        _setUserLock(address(0));
    }

    //////////////////////////////////////////////
    /////           TSTORE HELPERS          //////
    //////////////////////////////////////////////

    function _setUserLock(address user) internal {
        _tstore(_USER_LOCK_SLOT, bytes32(uint256(uint160(user))));
    }

    function _getUserLock() internal view returns (address) {
        return address(uint160(uint256(_tload(_USER_LOCK_SLOT))));
    }

    function _setWinningSolver(address winningSolverFrom) internal {
        _tstore(_WINNING_SOLVER_SLOT, bytes32(uint256(uint160(winningSolverFrom))));
    }

    function _getWinningSolver() internal view returns (address) {
        return address(uint160(uint256(_tload(_WINNING_SOLVER_SLOT))));
    }

    function _tstore(bytes32 slot, bytes32 value) internal {
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) internal view returns (bytes32 value) {
        assembly {
            value := tload(slot)
        }
        return value;
    }
}
