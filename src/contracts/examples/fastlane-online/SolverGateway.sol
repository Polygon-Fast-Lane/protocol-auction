//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "../../dapp/DAppControl.sol";
import { DAppOperation } from "../../types/DAppOperation.sol";
import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";
import "../../types/EscrowTypes.sol";

// Interface Import
import { IAtlasVerification } from "../../interfaces/IAtlasVerification.sol";
import { IExecutionEnvironment } from "../../interfaces/IExecutionEnvironment.sol";
import { IAtlas } from "../../interfaces/IAtlas.sol";
import { ISimulator } from "../../interfaces/ISimulator.sol";

import { FastLaneOnlineControl } from "./FastLaneControl.sol";
import { OuterHelpers } from "./OuterHelpers.sol";

import { SwapIntent, BaselineCall, Reputation } from "./FastLaneTypes.sol";

contract SolverGateway is OuterHelpers {
    uint256 public constant USER_GAS_BUFFER = 350_000;
    uint256 public constant MAX_SOLVER_GAS = 500_000;

    uint256 internal constant _SLIPPAGE_BASE = 100;
    uint256 internal constant _GLOBAL_MAX_SLIPPAGE = 125; // A lower slippage set by user will override this.

    // bids > sqrt(type(uint256).max / 100) will cause overflow in _calculateBidFactor
    uint256 internal constant _MAX_SOLVER_BID = 34_028_236_692_093_846_346_337_460_743_176_821_145;

    constructor(address atlas, address protocolGuildWallet) OuterHelpers(atlas, protocolGuildWallet) { }

    function getSolverGasLimit() public pure override returns (uint32) {
        return uint32(MAX_SOLVER_GAS);
    }

    /////////////////////////////////////////////////////////
    //              CONTROL-LOCAL FUNCTIONS                //
    //                 (not delegated)                     //
    /////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////
    //              EXTERNAL INTERFACE FUNCS               //
    /////////////////////////////////////////////////////////
    //                  FOR SOLVERS                        //
    /////////////////////////////////////////////////////////

    // Note: this function involves calling the simulator, which has a few requirements which must be met for this
    // function to succeed:
    // - There must be at least 1 million (500k + 500k) gas left by the time `_executeSolverOperation()` is called. So
    // the make the gas limit of this function call high enough to allow for that. 1.5 million gas should be enough.
    function addSolverOp(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        external
        payable
        onlyAsControl
        withUserLock(solverOp.from)
    {
        if (msg.sender != solverOp.from) revert SolverGateway_AddSolverOp_SolverMustBeSender();
        if (solverOp.bidAmount > _MAX_SOLVER_BID) revert SolverGateway_AddSolverOp_BidTooHigh();

        if (S_solverOpHashes[solverOp.userOpHash].length == 0) {
            // First solverOp of each userOp deploys the user's Execution Environment
            IAtlas(ATLAS).createExecutionEnvironment(userOp.from, address(this));
        }

        // Simulate the SolverOp and make sure it's valid
        if (!_simulateSolverOp(userOp, solverOp)) revert SolverGateway_AddSolverOp_SimulationFail();

        bytes32 _solverOpHash = keccak256(abi.encode(solverOp));

        (bool _pushAsNew, bool _replaceExisting, uint256 _replacedIndex) = _evaluateForInclusion(userOp, solverOp);

        if (_pushAsNew) {
            _pushSolverOp(solverOp.userOpHash, _solverOpHash);
        } else if (_replaceExisting) {
            _replaceSolverOp(solverOp.userOpHash, _solverOpHash, _replacedIndex);
        } else {
            // revert if pushAsNew = false and replaceExisting = false
            revert SolverGateway_AddSolverOp_ScoreTooLow();
        }

        // Store the op
        S_solverOpCache[_solverOpHash] = solverOp;
    }

    function refundCongestionBuyIns(SolverOperation calldata solverOp)
        external
        withUserLock(solverOp.from)
        onlyAsControl
    {
        // NOTE: Anyone can call this on behalf of the solver
        // NOTE: the solverOp deadline cannot be before the userOp deadline, therefore if the
        // solverOp deadline is passed then we know the userOp deadline is passed.
        if (solverOp.deadline >= block.number) {
            revert SolverGateway_RefundCongestionBuyIns_DeadlineNotPassed();
        }

        bytes32 _solverOpHash = keccak256(abi.encode(solverOp));

        uint256 _congestionBuyIn = S_congestionBuyIn[_solverOpHash];
        uint256 _aggCongestionBuyIn = S_aggCongestionBuyIn[solverOp.userOpHash];

        // NOTE: On successful execution, the _aggCongestionBuyIn is set to zero
        // but the individual _congestionBuyIns are not, so verify both.
        if (_congestionBuyIn > 0 && _aggCongestionBuyIn >= _congestionBuyIn) {
            delete S_congestionBuyIn[_solverOpHash];
            S_aggCongestionBuyIn[solverOp.userOpHash] -= _congestionBuyIn;

            SafeTransferLib.safeTransferETH(solverOp.from, _congestionBuyIn);
        }
    }

    /////////////////////////////////////////////////////////
    //              EXTERNAL INTERFACE FUNCS               //
    //                  FOR DAPP CONTROL                   //
    /////////////////////////////////////////////////////////
    function getBidAmount(bytes32 solverOpHash) external view returns (uint256 bidAmount) {
        return S_solverOpCache[solverOpHash].bidAmount;
    }

    /////////////////////////////////////////////////////////
    //                   INTERNAL FUNCS                    //
    /////////////////////////////////////////////////////////
    function _pushSolverOp(bytes32 userOpHash, bytes32 solverOpHash) internal {
        // Push to array
        S_solverOpHashes[userOpHash].push(solverOpHash);

        // Accounting
        if (msg.value > 0) {
            S_aggCongestionBuyIn[userOpHash] += msg.value;
            S_congestionBuyIn[solverOpHash] = msg.value;
        }
    }

    function _replaceSolverOp(bytes32 userOpHash, bytes32 solverOpHash, uint256 replacedIndex) internal {
        // Handle the removed solverOp
        bytes32 _replacedHash = S_solverOpHashes[userOpHash][replacedIndex];
        uint256 _replacedCongestionBuyIn = S_congestionBuyIn[_replacedHash];

        // Handle xfer back
        if (_replacedCongestionBuyIn > 0) {
            // Accounting (remove balance before xfer)
            delete S_congestionBuyIn[_replacedHash];

            SolverOperation memory _replacedSolverOp = S_solverOpCache[solverOpHash];

            if (_replacedSolverOp.from.code.length == 0) {
                // Transfer their congestion buyin back
                SafeTransferLib.safeTransferETH(_replacedSolverOp.from, _replacedCongestionBuyIn);
            }
        }

        // Accounting
        if (_replacedCongestionBuyIn > msg.value) {
            S_aggCongestionBuyIn[userOpHash] -= (_replacedCongestionBuyIn - msg.value);
        } else if (_replacedCongestionBuyIn < msg.value) {
            S_aggCongestionBuyIn[userOpHash] += (msg.value - _replacedCongestionBuyIn);
        } // if they're equal, do nothing.

        if (msg.value > 0) {
            S_congestionBuyIn[solverOpHash] = msg.value;
        }

        S_solverOpHashes[userOpHash][replacedIndex] = solverOpHash;
    }

    function _getSolverOps(bytes32 userOpHash)
        internal
        view
        returns (SolverOperation[] memory solverOps, uint256 cumulativeGasReserved)
    {
        uint256 _totalSolvers = S_solverOpHashes[userOpHash].length;

        solverOps = new SolverOperation[](_totalSolvers);

        for (uint256 _j; _j < _totalSolvers; _j++) {
            bytes32 _solverOpHash = S_solverOpHashes[userOpHash][_j];
            SolverOperation memory _solverOp = S_solverOpCache[_solverOpHash];
            solverOps[_j] = _solverOp;
            cumulativeGasReserved += _solverOp.gas;
        }
    }

    function _evaluateForInclusion(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        internal
        view
        returns (bool pushAsNew, bool replaceExisting, uint256 /* replacedIndex */ )
    {
        (SolverOperation[] memory _solverOps, uint256 _cumulativeGasReserved) = _getSolverOps(solverOp.userOpHash);

        if (_solverOps.length == 0) {
            return (true, false, 0);
        }

        (SwapIntent memory swapIntent,) = abi.decode(userOp.data[4:], (SwapIntent, BaselineCall));

        (uint256 _cumulativeScore, uint256 _replacedIndex) =
            _getCumulativeScores(swapIntent, _solverOps, userOp.gas, userOp.maxFeePerGas);

        uint256 _score = _getWeightedScoreNewSolver(
            userOp.gas, userOp.maxFeePerGas, swapIntent.minAmountUserBuys, _solverOps.length, solverOp
        );

        // Check can be grokked more easily in the following format:
        //      solverOpScore     _cumulativeScore (unweighted)
        // if  -------------- >  ------------------------------ * 2
        //      solverOpGas              totalGas

        if (_score * userOp.gas > _cumulativeScore * solverOp.gas * 2) {
            if (_cumulativeGasReserved + USER_GAS_BUFFER + solverOp.gas < userOp.gas) {
                // If enough gas in metacall limit to fit new solverOp, add as new.
                return (true, false, 0);
            } else {
                // Otherwise replace the solverOp with lowest score.
                return (false, true, _replacedIndex);
            }
        }
        // If the new solverOp's score/gas ratio is too low, don't include it at all. This will result in a
        // SolverGateway_AddSolverOp_ScoreTooLow error in `addSolverOp()`.
        return (false, false, 0);
    }

    function _getCumulativeScores(
        SwapIntent memory swapIntent,
        SolverOperation[] memory solverOps,
        uint256 gas,
        uint256 maxFeePerGas
    )
        internal
        view
        returns (uint256 cumulativeScore, uint256 replacedIndex)
    {
        uint256 _lowestScore;
        uint256 _length = solverOps.length;
        for (uint256 _i; _i < _length; _i++) {
            SolverOperation memory _solverOp = solverOps[_i];

            uint256 _score = _getWeightedScore(gas, maxFeePerGas, swapIntent.minAmountUserBuys, _length, _solverOp);

            if (_i == 0 || _score < _lowestScore) {
                replacedIndex = _i;
                _lowestScore = _score;
            }

            cumulativeScore += _score;
        }
    }

    function _getWeightedScore(
        uint256 totalGas,
        uint256 maxFeePerGas,
        uint256 minAmountUserBuys,
        uint256 solverCount,
        SolverOperation memory solverOp
    )
        internal
        view
        returns (uint256 score)
    {
        bytes32 _solverOpHash = keccak256(abi.encode(solverOp));
        uint256 _congestionBuyIn = S_congestionBuyIn[_solverOpHash];
        uint256 _bidFactor = _calculateBidFactor(solverOp.bidAmount, minAmountUserBuys);

        score = _calculateWeightedScore({
            totalGas: totalGas,
            solverOpGas: solverOp.gas,
            maxFeePerGas: maxFeePerGas,
            congestionBuyIn: _congestionBuyIn,
            solverCount: solverCount,
            bidFactor: _bidFactor,
            rep: S_solverReputations[solverOp.from]
        });
    }

    function _getWeightedScoreNewSolver(
        uint256 totalGas,
        uint256 maxFeePerGas,
        uint256 minAmountUserBuys,
        uint256 solverCount,
        SolverOperation calldata solverOp
    )
        internal
        view
        returns (uint256 score)
    {
        uint256 _bidFactor = _calculateBidFactor(solverOp.bidAmount, minAmountUserBuys);

        score = _calculateWeightedScore({
            totalGas: totalGas,
            solverOpGas: solverOp.gas,
            maxFeePerGas: maxFeePerGas,
            congestionBuyIn: msg.value,
            solverCount: solverCount,
            bidFactor: _bidFactor,
            rep: S_solverReputations[solverOp.from]
        });
    }

    function _calculateWeightedScore(
        uint256 totalGas,
        uint256 solverOpGas,
        uint256 maxFeePerGas,
        uint256 congestionBuyIn,
        uint256 solverCount,
        uint256 bidFactor,
        Reputation memory rep
    )
        internal
        pure
        returns (uint256 score)
    {
        score = (
            (congestionBuyIn + (maxFeePerGas * totalGas)) // A solver typically has to pay maxFeePerGas * gas as a
                // requirement for winning.
                * totalGas / (totalGas + solverOpGas) // double count gas by doing this even in unweighted score (there's
                // value in packing more solutions)
                * (uint256(rep.successCost) + (maxFeePerGas * totalGas))
                / (uint256(rep.failureCost) + (maxFeePerGas * totalGas * (solverCount + 1))) // as solverCount increases,
                // the dilution of thin auction history increases.
                * bidFactor / solverOpGas
        );
    }

    function _calculateBidFactor(
        uint256 bidAmount,
        uint256 minAmountUserBuys
    )
        internal
        pure
        returns (uint256 bidFactor)
    {
        // To avoid truncating to zero, check and return the minimum slippage
        if (bidAmount < minAmountUserBuys + 1) return _SLIPPAGE_BASE;

        // NOTE: bidAmount is checked to be < _MAX_SOLVER_BID in addSolverOp to prevent overflow here
        bidFactor = (bidAmount ** 2) * _SLIPPAGE_BASE / (minAmountUserBuys + 1) ** 2;
        if (bidFactor > _GLOBAL_MAX_SLIPPAGE) bidFactor = _GLOBAL_MAX_SLIPPAGE;
    }
}
