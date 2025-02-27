//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IAtlas } from "../interfaces/IAtlas.sol";
import { IDAppControl } from "../interfaces/IDAppControl.sol";
import { IAtlasVerification } from "../interfaces/IAtlasVerification.sol";

import { CallBits } from "../libraries/CallBits.sol";
import { AccountingMath } from "../libraries/AccountingMath.sol";
import { CallVerification } from "../libraries/CallVerification.sol";
import { AtlasConstants } from "../types/AtlasConstants.sol";

import "../types/SolverOperation.sol";
import "../types/UserOperation.sol";
import "../types/ConfigTypes.sol";

contract Sorter is AtlasConstants {
    using CallBits for uint32;
    using CallVerification for UserOperation;

    IAtlas public immutable ATLAS;
    IAtlasVerification public immutable VERIFICATION;

    struct SortingData {
        uint256 amount;
        bool valid;
    }

    constructor(address _atlas) {
        ATLAS = IAtlas(_atlas);
        VERIFICATION = IAtlasVerification(ATLAS.VERIFICATION());
    }

    function sortBids(
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps
    )
        external
        view
        returns (SolverOperation[] memory)
    {
        DAppConfig memory dConfig = IDAppControl(userOp.control).getDAppConfig(userOp);

        uint256 count = solverOps.length;

        (SortingData[] memory sortingData, uint256 invalid) = _getSortingData(dConfig, userOp, solverOps, count);

        uint256[] memory sorted = _sort(sortingData, count, invalid);

        count -= invalid;
        SolverOperation[] memory solverOpsSorted = new SolverOperation[](count);

        for (uint256 i; i < count; ++i) {
            solverOpsSorted[i] = solverOps[sorted[i]];
        }

        return solverOpsSorted;
    }

    function _verifyBidFormat(address bidToken, SolverOperation calldata solverOp) internal pure returns (bool) {
        return solverOp.bidToken == bidToken;
    }

    /// @dev Verifies that the solver is eligible
    /// @dev Does not check solver signature as it might be trusted (solverOp.from == bundler)
    /// @dev Checks other than signature are same as those done in `verifySolverOp()` in AtlasVerification and
    /// `_validateSolverOpGasAndValue()` and `_validateSolverOpDeadline()` in Atlas
    function _verifySolverEligibility(
        DAppConfig memory dConfig,
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        internal
        view
        returns (bool)
    {
        // Make sure the solver has enough funds bonded
        uint256 solverBalance = IAtlas(address(ATLAS)).balanceOfBonded(solverOp.from);

        uint256 gasLimit =
            AccountingMath.solverGasLimitScaledDown(solverOp.gas, dConfig.solverGasLimit) + _FASTLANE_GAS_BUFFER;

        uint256 calldataCost =
            (solverOp.data.length + _SOLVER_OP_BASE_CALLDATA) * _CALLDATA_LENGTH_PREMIUM_HALVED * solverOp.maxFeePerGas;
        uint256 gasCost = (solverOp.maxFeePerGas * gasLimit) + calldataCost;
        if (solverBalance < gasCost) {
            return false;
        }

        // solverOp.to must be the atlas address
        if (solverOp.to != address(ATLAS)) {
            return false;
        }

        // Solvers can only do one tx per block - this prevents double counting bonded balances
        uint256 solverLastActiveBlock = IAtlas(address(ATLAS)).accountLastActiveBlock(solverOp.from);
        if (solverLastActiveBlock >= block.number) {
            return false;
        }

        // Ensure the solver control address matches the configured dApp control address
        if (dConfig.to != solverOp.control) {
            return false;
        }

        // Make sure that the solver's maxFeePerGas matches or exceeds the user's
        if (solverOp.maxFeePerGas < userOp.maxFeePerGas) {
            return false;
        }

        // solverOp.solver must not be the atlas or verification address
        if (solverOp.solver == address(ATLAS) || solverOp.solver == address(VERIFICATION)) {
            return false;
        }

        // solverOp.deadline must be in the future
        if (solverOp.deadline != 0 && block.number > solverOp.deadline) {
            return false;
        }

        return true;
    }

    function _getSortingData(
        DAppConfig memory dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        uint256 count
    )
        internal
        view
        returns (SortingData[] memory, uint256)
    {
        address bidToken = IDAppControl(dConfig.to).getBidFormat(userOp);

        SortingData[] memory sortingData = new SortingData[](count);

        bytes32 userOpHash = VERIFICATION.getUserOperationHash(userOp);

        uint256 invalid;
        for (uint256 i; i < count; ++i) {
            if (
                solverOps[i].userOpHash == userOpHash && _verifyBidFormat(bidToken, solverOps[i])
                    && _verifySolverEligibility(dConfig, userOp, solverOps[i])
            ) {
                sortingData[i] = SortingData({ amount: solverOps[i].bidAmount, valid: true });
            } else {
                sortingData[i] = SortingData({ amount: 0, valid: false });
                unchecked {
                    ++invalid;
                }
            }
        }

        return (sortingData, invalid);
    }

    function _sort(
        SortingData[] memory sortingData,
        uint256 count,
        uint256 invalid
    )
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory sorted = new uint256[](count - invalid);
        if (sorted.length == 0) {
            return sorted;
        }

        int256 topBidAmount;
        int256 topBidIndex;

        for (uint256 i; i < sorted.length; ++i) {
            topBidAmount = -1;
            topBidIndex = -1;

            for (uint256 j; j < count; ++j) {
                if (sortingData[j].valid && int256(sortingData[j].amount) > topBidAmount) {
                    topBidAmount = int256(sortingData[j].amount);
                    topBidIndex = int256(j);
                }
            }

            if (topBidIndex == -1) {
                // all indices in sorting data are invalid
                break;
            }

            sortingData[uint256(topBidIndex)].valid = false;
            sorted[i] = uint256(topBidIndex);
        }

        return sorted;
    }
}
