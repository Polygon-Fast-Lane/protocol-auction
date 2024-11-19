//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AtlasConstants } from "../types/AtlasConstants.sol";

contract NonceManager is AtlasConstants {
    // address => last used sequential nonce
    mapping(address => uint256) internal S_userSequentialNonceTrackers;
    mapping(address => uint256) internal S_dAppSequentialNonceTrackers;

    // address => word index => bitmap
    mapping(address => mapping(uint248 => uint256)) internal S_userNonSequentialNonceTrackers;

    // NOTE: Non-sequential nonces are only enabled for users. If dApps nonces are not set to be sequential, their
    // validation is not enforced.

    // ---------------------------------------------------- //
    //                                                      //
    //                     VALIDATION                       //
    //       Below functions ensure nonces validity         //
    //                                                      //
    // ---------------------------------------------------- //

    /// @notice The _handleUserNonces internal function handles the verification of user nonces for both sequential and
    /// non-sequential nonce systems.
    /// @param user The address of the user to verify the nonce for.
    /// @param nonce The nonce to verify.
    /// @param sequential A boolean indicating if the nonce mode is sequential (true) or not (false)
    /// @param isSimulation A boolean indicating if the execution is a simulation.
    /// @return validNonce A boolean indicating if the nonce is valid.
    function _handleUserNonces(
        address user,
        uint256 nonce,
        bool sequential,
        bool isSimulation
    )
        internal
        returns (bool validNonce)
    {
        // 0 Nonces are not allowed. Nonces start at 1 for both sequential and non-sequential.
        if (nonce == 0) return false;

        if (sequential) {
            uint256 _lastUsedNonce = S_userSequentialNonceTrackers[user];
            (validNonce, _lastUsedNonce) = _handleSequentialNonces(_lastUsedNonce, nonce);
            if (validNonce && !isSimulation) {
                // Update storage only if valid and not in simulation
                S_userSequentialNonceTrackers[user] = _lastUsedNonce;
            }
        } else {
            (uint248 _wordIndex, uint8 _bitPos) = _bitmapPositions(nonce);
            uint256 _bitmap = S_userNonSequentialNonceTrackers[user][_wordIndex];
            (validNonce, _bitmap) = _handleNonSequentialNonces(_bitmap, _bitPos);
            if (validNonce && !isSimulation) {
                // Update storage only if valid and not in simulation
                S_userNonSequentialNonceTrackers[user][_wordIndex] = _bitmap;
            }
        }
    }

    /// @notice The _handleDAppNonces internal function handles the verification of dApp signatory nonces for sequential
    /// nonce systems.
    /// @param dAppSignatory The address of the dApp to verify the nonce for.
    /// @param nonce The nonce to verify.
    /// @param isSimulation A boolean indicating if the execution is a simulation.
    /// @return validNonce A boolean indicating if the nonce is valid.
    /// @dev DApps nonces are only handled in sequential mode.
    function _handleDAppNonces(
        address dAppSignatory,
        uint256 nonce,
        bool isSimulation
    )
        internal
        returns (bool validNonce)
    {
        // 0 Nonces are not allowed. Nonces start at 1 for both sequential and non-sequential.
        if (nonce == 0) return false;

        uint256 _lastUsedNonce = S_dAppSequentialNonceTrackers[dAppSignatory];
        (validNonce, _lastUsedNonce) = _handleSequentialNonces(_lastUsedNonce, nonce);
        if (validNonce && !isSimulation) {
            // Update storage only if valid and not in simulation
            S_dAppSequentialNonceTrackers[dAppSignatory] = _lastUsedNonce;
        }
    }

    /// @notice The _handleSequentialNonces internal function handles the verification of sequential nonces.
    /// @param lastUsedNonce The last used nonce.
    /// @param nonce The nonce to verify.
    /// @return A boolean indicating if the nonce is valid.
    /// @return The updated last used nonce.
    function _handleSequentialNonces(uint256 lastUsedNonce, uint256 nonce) internal pure returns (bool, uint256) {
        // Nonces must increase by 1 if sequential
        if (nonce != lastUsedNonce + 1) return (false, lastUsedNonce);
        return (true, nonce);
    }

    /// @notice The _handleNonSequentialNonces internal function handles the verification of non-sequential nonces.
    /// @param bitmap The bitmap to verify the nonce bit position against.
    /// @param bitPos The bit position of the nonce to verify.
    /// @return A boolean indicating if the nonce is valid.
    /// @return The updated bitmap.
    function _handleNonSequentialNonces(uint256 bitmap, uint8 bitPos) internal pure returns (bool, uint256) {
        uint256 _bit = 1 << bitPos;
        uint256 _flipped = bitmap ^ _bit;

        // Nonce has already been used
        if (_flipped & _bit == 0) return (false, bitmap);

        return (true, _flipped);
    }

    // ---------------------------------------------------- //
    //                                                      //
    //                    ACQUISITION                       //
    //        Below functions retrieve valid nonces         //
    //                                                      //
    // ---------------------------------------------------- //

    /// @notice Returns the next nonce for the given user, in sequential or non-sequential mode.
    /// @param user The address of the user for which to retrieve the next nonce.
    /// @param sequential A boolean indicating if the nonce should be sequential (true) or non-sequential (false).
    /// @return nextNonce The next nonce for the given user.
    function getUserNextNonce(address user, bool sequential) external view returns (uint256 nextNonce) {
        if (sequential) {
            nextNonce = S_userSequentialNonceTrackers[user] + 1;
        } else {
            // Set the starting position to 1 to skip the 0 nonce
            nextNonce = _getNextNonSequentialNonce(user, 0, 1);
        }
    }

    /// @notice Returns the next valid nonce after `refNonce` for the given user, in non-sequential mode.
    /// @param user The address of the user for which to retrieve the next nonce.
    /// @param refNonce The nonce to start the search from.
    /// @return The next nonce for the given user.
    function getUserNextNonSeqNonceAfter(address user, uint256 refNonce) external view returns (uint256) {
        (uint248 _wordIndex, uint8 _bitPos) = _nextNonceBitmapPositions(refNonce);
        return _getNextNonSequentialNonce(user, _wordIndex, _bitPos);
    }

    /// @notice Returns the next nonce for the given dApp signatory, in sequential mode.
    /// @param dApp The address of the dApp signatory for which to retrieve the next nonce.
    /// @return nextNonce The next nonce for the given dApp.
    /// @dev DApps nonces are only handled in sequential mode.
    function getDAppNextNonce(address dApp) external view returns (uint256 nextNonce) {
        nextNonce = S_dAppSequentialNonceTrackers[dApp] + 1;
    }

    /// @notice Returns the next nonce for the given account, in non-sequential mode.
    /// @param user The user to get the next nonce for.
    /// @param wordIndex The word index to start the search from.
    /// @param bitPos The bit position to start the search from.
    /// @return nextNonce The next nonce for the given account.
    /// @dev Non-sequential nonces are only enabled for users.
    function _getNextNonSequentialNonce(
        address user,
        uint248 wordIndex,
        uint8 bitPos
    )
        internal
        view
        returns (uint256 nextNonce)
    {
        while (true) {
            uint256 _bitmap = S_userNonSequentialNonceTrackers[user][wordIndex];

            // Compensate for missing nonce 0
            if (wordIndex == 0) {
                _bitmap |= 1;
            }

            if (_bitmap == type(uint256).max) {
                // Full bitmap, move to the next word
                ++wordIndex;
                bitPos = 0;
                continue;
            }

            if (bitPos != 0) {
                // If the position is not 0, shift the bitmap to ignore the bits before position
                _bitmap >>= bitPos;
            }

            bool nextWord;

            // Find the first zero bit in the bitmap
            while (_bitmap & 1 == 1) {
                if (bitPos == type(uint8).max) {
                    // End of the bitmap, move to the next word
                    nextWord = true;
                    ++wordIndex;
                    bitPos = 0;
                    break;
                }

                _bitmap >>= 1;
                ++bitPos;
            }

            if (nextWord) {
                continue;
            }

            nextNonce = _nonceFromWordAndPos(wordIndex, bitPos);
            break;
        }
    }

    // ---------------------------------------------------- //
    //                                                      //
    //                       HELPERS                        //
    //                 Utility functions                    //
    //                                                      //
    // ---------------------------------------------------- //

    /// @notice Returns the index of the bitmap and the bit position within the bitmap for the next nonce.
    /// @param refNonce The nonce to get the next nonce positions from.
    /// @return wordIndex The word position or index into the bitmap of the next nonce.
    /// @return bitPos The bit position of the next nonce.
    function _nextNonceBitmapPositions(uint256 refNonce) internal pure returns (uint248 wordIndex, uint8 bitPos) {
        (wordIndex, bitPos) = _bitmapPositions(refNonce);
        if (bitPos == type(uint8).max) {
            // End of the bitmap, move to the next word
            ++wordIndex;
            bitPos = 0;
        } else {
            // Otherwise, just move to the next bit
            ++bitPos;
        }
    }

    /// @notice Returns the index of the bitmap and the bit position within the bitmap. Used for non-sequenced nonces.
    /// @param nonce The nonce to get the associated word and bit positions.
    /// @return wordIndex The word position or index into the bitmap.
    /// @return bitPos The bit position.
    /// @dev The first 248 bits of the nonce value is the index of the desired bitmap.
    /// @dev The last 8 bits of the nonce value is the position of the bit in the bitmap.
    function _bitmapPositions(uint256 nonce) internal pure returns (uint248 wordIndex, uint8 bitPos) {
        wordIndex = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }

    /// @notice Constructs a nonce from a word and a position inside the word.
    /// @param wordIndex The word position or index into the bitmap.
    /// @param bitPos The bit position.
    /// @return nonce The nonce constructed from the word and position.
    /// @dev The first 248 bits of the nonce value is the index of the desired bitmap.
    /// @dev The last 8 bits of the nonce value is the position of the bit in the bitmap.
    function _nonceFromWordAndPos(uint248 wordIndex, uint8 bitPos) internal pure returns (uint256 nonce) {
        nonce = uint256(wordIndex) << 8;
        nonce |= bitPos;
    }

    // ---------------------------------------------------- //
    //                                                      //
    //                       GETTERS                        //
    //                                                      //
    // ---------------------------------------------------- //

    /// @notice Returns the last used sequential nonce for a user.
    /// @param account The address of the account to get the last used sequential nonce for.
    /// @return lastUsedSeqNonce The last used sequential nonce for the account.
    function userSequentialNonceTrackers(address account) external view returns (uint256 lastUsedSeqNonce) {
        lastUsedSeqNonce = S_userSequentialNonceTrackers[account];
    }

    /// @notice Returns the last used sequential nonce for a dApp signatory.
    /// @param account The address of the account to get the last used sequential nonce for.
    /// @return lastUsedSeqNonce The last used sequential nonce for the account.
    function dAppSequentialNonceTrackers(address account) external view returns (uint256 lastUsedSeqNonce) {
        lastUsedSeqNonce = S_dAppSequentialNonceTrackers[account];
    }

    /// @notice Returns the non-sequential nonce bitmap for a user.
    /// @param account The address of the account to get the non-sequential nonce bitmap for.
    /// @param wordIndex The word index to get the bitmap from.
    /// @return bitmap The non-sequential nonce bitmap for the account.
    function userNonSequentialNonceTrackers(
        address account,
        uint248 wordIndex
    )
        external
        view
        returns (uint256 bitmap)
    {
        bitmap = S_userNonSequentialNonceTrackers[account][wordIndex];
    }
}
