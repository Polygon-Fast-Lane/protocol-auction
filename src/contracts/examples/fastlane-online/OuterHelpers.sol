//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { LibSort } from "solady/utils/LibSort.sol";
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
import { FastLaneOnlineInner } from "./FastLaneOnlineInner.sol";

import { SwapIntent, BaselineCall, Reputation } from "./FastLaneTypes.sol";

contract OuterHelpers is FastLaneOnlineInner {
    // NOTE: Any funds collected in excess of the therapy bills required for the Cardano engineering team
    // will go towards buying stealth drones programmed to apply deodorant to coders at solana hackathons.
    address public immutable CARDANO_ENGINEER_THERAPY_FUND;
    address public immutable PROTOCOL_GUILD_WALLET;
    address public immutable SIMULATOR;

    uint256 internal constant _BITS_FOR_INDEX = 16;

    constructor(address atlas, address protocolGuildWallet) FastLaneOnlineInner(atlas) {
        CARDANO_ENGINEER_THERAPY_FUND = msg.sender;
        PROTOCOL_GUILD_WALLET = protocolGuildWallet;
        SIMULATOR = IAtlas(atlas).SIMULATOR();
    }

    /////////////////////////////////////////////////////////
    //              CONTROL-LOCAL FUNCTIONS                //
    //                 (not delegated)                     //
    /////////////////////////////////////////////////////////

    function setWinningSolver(address winningSolver) external {
        // Only valid time this can be called is during the PostOps phase of a FLOnline metacall. When a user initiates
        // that metacall with `fastOnlineSwap()` they are set as the user lock address. So the only time the check below
        // will pass is when the caller of this function is the Execution Environment created for the currently active
        // user and the FLOnline DAppControl.

        (address expectedCaller,,) = IAtlas(ATLAS).getExecutionEnvironment(_getUserLock(), CONTROL);
        if (msg.sender == expectedCaller && _getWinningSolver() == address(0)) {
            // Set winning solver in transient storage, to be used in `_updateSolverReputation()`
            _setWinningSolver(winningSolver);
        }

        // If check above did not pass, gracefully return without setting the winning solver, to not cause the solverOp
        // simulation to fail in `addSolverOp()`.
    }

    function getUserOperationAndHash(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas,
        uint256 msgValue
    )
        external
        view
        returns (UserOperation memory userOp, bytes32 userOpHash)
    {
        userOp = _getUserOperation(swapper, swapIntent, baselineCall, deadline, gas, maxFeePerGas, msgValue);
        userOpHash = _getUserOperationHash(userOp);
    }

    function getUserOpHash(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas,
        uint256 msgValue
    )
        external
        view
        returns (bytes32 userOpHash)
    {
        userOpHash = _getUserOperationHash(
            _getUserOperation(swapper, swapIntent, baselineCall, deadline, gas, maxFeePerGas, msgValue)
        );
    }

    function getUserOperation(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas,
        uint256 msgValue
    )
        external
        view
        returns (UserOperation memory userOp)
    {
        userOp = _getUserOperation(swapper, swapIntent, baselineCall, deadline, gas, maxFeePerGas, msgValue);
    }

    function makeThogardsWifeHappy() external onlyAsControl withUserLock(msg.sender) {
        if (msg.sender != CARDANO_ENGINEER_THERAPY_FUND) {
            revert OuterHelpers_NotMadJustDisappointed();
        }
        uint256 _rake = S_rake;
        S_rake = 0;
        SafeTransferLib.safeTransferETH(CARDANO_ENGINEER_THERAPY_FUND, _rake);
    }

    function _simulateSolverOp(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        internal
        returns (bool valid)
    {
        DAppOperation memory _dAppOp = _getDAppOp(solverOp.userOpHash, userOp.deadline);

        // NOTE: Valid is false when the solver fails even if postOps is successful
        (valid,,) = ISimulator(SIMULATOR).simSolverCall(userOp, solverOp, _dAppOp);
    }

    function _getUserOperation(
        address swapper,
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall,
        uint256 deadline,
        uint256 gas,
        uint256 maxFeePerGas,
        uint256 msgValue
    )
        internal
        view
        returns (UserOperation memory userOp)
    {
        userOp = UserOperation({
            from: swapper,
            to: ATLAS,
            gas: gas,
            maxFeePerGas: maxFeePerGas,
            nonce: _getNextUserNonce(swapper),
            deadline: deadline,
            value: msgValue,
            dapp: CONTROL,
            control: CONTROL,
            callConfig: CALL_CONFIG,
            sessionKey: address(0),
            data: abi.encodeCall(this.swap, (swapIntent, baselineCall)),
            signature: new bytes(0) // User must sign
         });
    }

    function _getUserOperationHash(UserOperation memory userOp) internal view returns (bytes32 userOpHash) {
        userOpHash = IAtlasVerification(ATLAS_VERIFICATION).getUserOperationHash(userOp);
    }

    function _getDAppOp(bytes32 userOpHash, uint256 deadline) internal view returns (DAppOperation memory dAppOp) {
        dAppOp = DAppOperation({
            from: CONTROL, // signer of the DAppOperation
            to: ATLAS, // Atlas address
            nonce: 0, // Atlas nonce of the DAppOperation available in the AtlasVerification contract
            deadline: deadline, // block.number deadline for the DAppOperation
            control: CONTROL, // DAppControl address
            bundler: CONTROL, // Signer of the atlas tx (msg.sender)
            userOpHash: userOpHash, // keccak256 of userOp.to, userOp.data
            callChainHash: bytes32(0), // keccak256 of the solvers' txs
            signature: new bytes(0) // NOTE: Control must be registered as signatory of itself, in AtlasVerification.
                // Then no signature is required here as control is bundler.
         });
    }

    function _processCongestionRake(
        uint256 startingBalance,
        bytes32 userOpHash,
        bool solversSuccessful
    )
        internal
        returns (uint256 netGasRefund)
    {
        // Bundler gas rebate from Atlas
        uint256 _grossGasRefund = address(this).balance - startingBalance;
        // Total congestion buyins for the current userOpHash/metacall
        uint256 _congestionBuyIns = S_aggCongestionBuyIn[userOpHash];

        if (_congestionBuyIns > 0) {
            if (solversSuccessful) {
                _grossGasRefund += _congestionBuyIns;
            }
            delete S_aggCongestionBuyIn[userOpHash];
        }

        uint256 _netRake = _grossGasRefund * _CONGESTION_RAKE / _CONGESTION_BASE;

        if (solversSuccessful) {
            // If there was a winning solver, increase the FLOnline rake
            S_rake += _netRake;
        } else {
            // NOTE: We do not refund the congestion buyins to the user because we do not want to create a
            // scenario in which the user can profit from Solvers failing. We also shouldn't give these to the
            // validator for the same reason, nor to the authors of this contract as they should also be credibly
            // neutral.

            // So if there is no winning solver, congestion buyins are sent to protocol guild.
            SafeTransferLib.safeTransferETH(PROTOCOL_GUILD_WALLET, _congestionBuyIns);
            S_rake += _netRake; // rake is only taken on bundler gas rebate from Atlas
        }

        // Return the netGasRefund to be sent back to the user
        netGasRefund = _grossGasRefund - _netRake;
    }

    function _sortSolverOps(SolverOperation[] memory unsortedSolverOps)
        internal
        pure
        returns (SolverOperation[] memory sortedSolverOps)
    {
        uint256 _length = unsortedSolverOps.length;
        if (_length == 0) return unsortedSolverOps;
        if (_length == 1 && unsortedSolverOps[0].bidAmount != 0) return unsortedSolverOps;

        uint256[] memory _bidsAndIndices = new uint256[](_length);
        uint256 _bidsAndIndicesLastIndex = _length;
        uint256 _bidAmount;

        // First encode each solver's bid and their index in the original solverOps array into a single uint256. Build
        // an array of these uint256s.
        for (uint256 i; i < _length; ++i) {
            _bidAmount = unsortedSolverOps[i].bidAmount;

            // skip zero and overflow bid's
            if (_bidAmount != 0 && _bidAmount <= type(uint240).max) {
                // Set to _length, and decremented before use here to avoid underflow
                unchecked {
                    --_bidsAndIndicesLastIndex;
                }

                // Non-zero bids are packed with their original solverOps index.
                // The array is filled with non-zero bids from the right.
                _bidsAndIndices[_bidsAndIndicesLastIndex] = uint256(_bidAmount << _BITS_FOR_INDEX | uint16(i));
            }
        }

        // Create new SolverOps array, large enough to hold all valid bids.
        uint256 _sortedSolverOpsLength = _length - _bidsAndIndicesLastIndex;
        if (_sortedSolverOpsLength == 0) return sortedSolverOps; // return early if no valid bids
        sortedSolverOps = new SolverOperation[](_sortedSolverOpsLength);

        // Reinitialize _bidsAndIndicesLastIndex to the last index of the array
        _bidsAndIndicesLastIndex = _length - 1;

        // Sort the array of packed bids and indices in-place, in ascending order of bidAmount.
        LibSort.insertionSort(_bidsAndIndices);

        // Finally, iterate through sorted bidsAndIndices array in descending order of bidAmount.
        for (uint256 i = _bidsAndIndicesLastIndex;; /* breaks when 0 */ --i) {
            // Isolate the bidAmount from the packed uint256 value
            _bidAmount = _bidsAndIndices[i] >> _BITS_FOR_INDEX;

            // If we reach the zero bids on the left of array, break as all valid bids already checked.
            if (_bidAmount == 0) break;

            // Recover the original index of the SolverOperation
            uint256 _index = uint256(uint16(_bidsAndIndices[i]));

            // Add the SolverOperation to the sorted array
            sortedSolverOps[_bidsAndIndicesLastIndex - i] = unsortedSolverOps[_index];

            if (i == 0) break; // break to prevent underflow in next loop
        }

        return sortedSolverOps;
    }

    function _updateSolverReputation(SolverOperation[] memory solverOps, uint128 magnitude) internal {
        uint256 _length = solverOps.length;
        address _winningSolver = _getWinningSolver();
        address _solverFrom;

        for (uint256 i; i < _length; i++) {
            _solverFrom = solverOps[i].from;

            // winningSolver will be address(0) unless a winning solver fulfilled the swap intent.
            if (_solverFrom == _winningSolver) {
                S_solverReputations[_solverFrom].successCost += magnitude;
                // break out of loop to avoid incrementing failureCost for solvers that did not execute due to being
                // after the winning solver in the sorted array.
                break;
            } else {
                S_solverReputations[_solverFrom].failureCost += magnitude;
            }
        }

        // Clear winning solver, in case `fastOnlineSwap()` is called multiple times in the same tx.
        _setWinningSolver(address(0));
    }

    //////////////////////////////////////////////
    /////            GETTERS                //////
    //////////////////////////////////////////////
    function _getNextUserNonce(address owner) internal view returns (uint256 nonce) {
        nonce = IAtlasVerification(ATLAS_VERIFICATION).getUserNextNonce(owner, false);
    }

    function isUserNonceValid(address owner, uint256 nonce) external view returns (bool valid) {
        valid = _isUserNonceValid(owner, nonce);
    }

    function _isUserNonceValid(address owner, uint256 nonce) internal view returns (bool valid) {
        uint248 _wordIndex = uint248(nonce >> 8);
        uint8 _bitPos = uint8(nonce);
        uint256 _bitmap = IAtlasVerification(ATLAS_VERIFICATION).userNonSequentialNonceTrackers(owner, _wordIndex);
        valid = _bitmap & 1 << _bitPos != 1;
    }

    //////////////////////////////////////////////
    /////            MODIFIERS              //////
    //////////////////////////////////////////////
    modifier onlyAsControl() {
        if (address(this) != CONTROL) revert();
        _;
    }
}
