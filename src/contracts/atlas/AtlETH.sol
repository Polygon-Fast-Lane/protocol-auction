//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { Permit69 } from "./Permit69.sol";
import "../types/EscrowTypes.sol";

/// @author FastLane Labs
/// @dev Do not manually set balances without updating totalSupply, as the sum of all user balances must not exceed it.
abstract contract AtlETH is Permit69 {
    constructor(
        uint256 escrowDuration,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator
    )
        Permit69(
            escrowDuration,
            atlasSurchargeRate,
            bundlerSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator
        )
    { }

    /*//////////////////////////////////////////////////////////////
                                ATLETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the unbonded AtlETH balance of the specified account.
    /// @param account The address for which to query the unbonded AtlETH balance.
    /// @return The unbonded AtlETH balance of the specified account.
    function balanceOf(address account) external view returns (uint256) {
        return uint256(s_balanceOf[account].balance);
    }

    /// @notice Returns the bonded AtlETH balance of the specified account.
    /// @param account The address for which to query the bonded AtlETH balance.
    /// @return The bonded AtlETH balance of the specified account.
    function balanceOfBonded(address account) external view returns (uint256) {
        return uint256(S_accessData[account].bonded);
    }

    /// @notice Returns the unbonding AtlETH balance of the specified account.
    /// @param account The address for which to query the unbonding AtlETH balance.
    /// @return The unbonding AtlETH balance of the specified account.
    function balanceOfUnbonding(address account) external view returns (uint256) {
        return uint256(s_balanceOf[account].unbonding);
    }

    /// @notice Returns the last active block of the specified account in the escrow contract.
    /// @param account The address for which to query the last active block.
    /// @return The last active block of the specified account in the escrow contract.
    function accountLastActiveBlock(address account) external view returns (uint256) {
        return uint256(S_accessData[account].lastAccessedBlock);
    }

    /// @notice Returns the block number at which the unbonding process of the specified account will be completed.
    /// @param account The address for which to query the completion block of unbonding.
    /// @return The block number at which the unbonding process of the specified account will be completed.
    function unbondingCompleteBlock(address account) external view returns (uint256) {
        uint256 _lastAccessedBlock = uint256(S_accessData[account].lastAccessedBlock);
        if (_lastAccessedBlock == 0) return 0;
        return _lastAccessedBlock + ESCROW_DURATION;
    }

    /// @notice Deposits ETH to receive atlETH tokens in return.
    /// @dev Mints atlETH tokens to the caller in exchange for the deposited ETH.
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Redeems atlETH tokens for ETH.
    /// @dev Burns the specified amount of atlETH tokens from the caller's balance and transfers the equivalent amount
    /// of ETH to the caller.
    /// @param amount The amount of atlETH tokens to redeem for ETH.
    function withdraw(uint256 amount) external {
        _checkIfUnlocked();
        _burn(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints new atlETH tokens and assigns them to the specified account.
    /// @param to The address to which the newly minted atlETH tokens will be assigned.
    /// @param amount The amount of atlETH tokens to mint and assign to the specified account.
    function _mint(address to, uint256 amount) internal {
        S_totalSupply += amount;
        s_balanceOf[to].balance += SafeCast.toUint112(amount);
        emit Mint(to, amount);
    }

    /// @notice Burns atlETH tokens from the specified account.
    /// @param from The address from which the atlETH tokens will be burned.
    /// @param amount The amount of atlETH tokens to burn from the specified account.
    function _burn(address from, uint256 amount) internal {
        _deduct(from, amount);
        S_totalSupply -= amount;
        emit Burn(from, amount);
    }

    /// @notice Deducts atlETH tokens from the specified account.
    /// @dev This function deducts the specified amount of atlETH tokens from the balance of the specified account.
    /// If the deduction results in a negative balance, it handles the shortfall differently depending on whether the
    /// account has passed the unbonding lock period. If the account has passed the lock period, the shortfall is
    /// considered as unbonding, and the total supply is adjusted accordingly. Otherwise, if the account is still within
    /// the lock period, the function reverts due to insufficient balance for deduction.
    /// @param account The address from which to deduct atlETH tokens.
    /// @param amount The amount of atlETH tokens to deduct from the specified account.
    function _deduct(address account, uint256 amount) internal {
        uint112 _amt = SafeCast.toUint112(amount);

        EscrowAccountBalance storage s_aData = s_balanceOf[account];

        uint112 _balance = s_aData.balance;

        if (_amt <= _balance) {
            s_aData.balance = _balance - _amt;
        } else if (block.number > S_accessData[account].lastAccessedBlock + ESCROW_DURATION) {
            uint112 _shortfall = _amt - _balance;
            s_aData.balance = 0;
            s_aData.unbonding -= _shortfall; // underflow here to revert if insufficient balance

            uint256 _shortfall256 = uint256(_shortfall);
            S_totalSupply += _shortfall256; // add the released supply back to atleth.
            S_bondedTotalSupply -= _shortfall256; // subtract the unbonded, freed amount
        } else {
            // Reverts because amount > account's balance
            revert InsufficientBalanceForDeduction(uint256(_balance), amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL BOND/UNBOND LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Puts a "hold" on a solver's AtlETH, enabling it to be used in Atlas transactions.
    /// @dev This function locks the specified amount of AtlETH tokens for the sender, making them bonded.
    /// Bonded AtlETH tokens must first be unbonded before they can be transferred or withdrawn.
    /// @param amount The amount of AtlETH tokens to bond.
    function bond(uint256 amount) external {
        _bond(msg.sender, amount);
    }

    /// @notice Deposits the caller's ETH and mints AtlETH, then bonds a specified amount of that AtlETH.
    /// @param amountToBond The amount of AtlETH tokens to bond after the deposit.
    function depositAndBond(uint256 amountToBond) external payable {
        _mint(msg.sender, msg.value);
        _bond(msg.sender, amountToBond);
    }

    /// @notice Starts the unbonding wait time for the specified amount of AtlETH tokens.
    /// @dev This function initiates the unbonding process for the specified amount of AtlETH tokens
    /// held by the sender. Unbonding AtlETH tokens can still be used by solvers while the unbonding
    /// process is ongoing, but adjustments may be made at withdrawal to ensure solvency.
    /// @param amount The amount of AtlETH tokens to unbond.
    function unbond(uint256 amount) external {
        _checkIfUnlocked();
        _unbond(msg.sender, amount);
    }

    /// @notice Redeems the specified amount of AtlETH tokens for withdrawal.
    /// @param amount The amount of AtlETH tokens to redeem for withdrawal.
    function redeem(uint256 amount) external {
        _checkIfUnlocked();
        _redeem(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL BOND/UNBOND LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Puts a hold on a solver's AtlETH tokens, enabling them to be used in Atlas transactions.
    /// @dev This internal function puts a hold on a solver's AtlETH tokens, enabling them to be used
    /// in Atlas transactions. The specified amount of AtlETH tokens is deducted from the owner's balance
    /// and added to the bonded balance. The total supply and bonded total supply are updated accordingly.
    /// @param owner The address of the account to put a hold on AtlETH tokens for.
    /// @param amount The amount of AtlETH tokens to put a hold on.
    function _bond(address owner, uint256 amount) internal {
        uint112 _amt = SafeCast.toUint112(amount);

        s_balanceOf[owner].balance -= _amt;
        S_totalSupply -= amount;

        S_accessData[owner].bonded += _amt;
        S_bondedTotalSupply += amount;

        emit Bond(owner, amount);
    }

    /// @notice Starts the unbonding wait time for a specified amount of AtlETH tokens.
    /// @dev This internal function starts the unbonding wait time for a specified amount of AtlETH tokens.
    /// The specified amount of AtlETH tokens is deducted from the owner's bonded balance and added to the
    /// unbonding balance. The last accessed block for the owner is updated to the current block number.
    /// @param owner The address of the account to start the unbonding wait time for.
    /// @param amount The amount of AtlETH tokens to start the unbonding wait time for.
    function _unbond(address owner, uint256 amount) internal {
        uint112 _amt = SafeCast.toUint112(amount);

        // totalSupply and totalBondedSupply are unaffected; continue to count the
        // unbonding amount as bonded total supply since it is still inaccessible
        // for atomic xfer.

        EscrowAccountAccessData storage s_aData = S_accessData[owner];

        s_aData.bonded -= _amt;
        s_aData.lastAccessedBlock = uint32(block.number);

        s_balanceOf[owner].unbonding += _amt;

        emit Unbond(owner, amount, block.number + ESCROW_DURATION + 1);
    }

    /// @notice Redeems the specified amount of AtlETH tokens for withdrawal.
    /// @dev This function allows the owner to redeem a specified amount of AtlETH tokens
    /// for withdrawal. If the unbonding process is active for the specified account, the
    /// function will revert. Otherwise, the specified amount of AtlETH tokens will be added
    /// back to the account's balance, and the total supply will be updated accordingly.
    /// @param owner The address of the account redeeming AtlETH tokens for withdrawal.
    /// @param amount The amount of AtlETH tokens to redeem for withdrawal.
    function _redeem(address owner, uint256 amount) internal {
        if (block.number <= uint256(S_accessData[owner].lastAccessedBlock) + ESCROW_DURATION) {
            revert EscrowLockActive();
        }

        uint112 _amt = SafeCast.toUint112(amount);

        EscrowAccountBalance storage s_bData = s_balanceOf[owner];

        s_bData.unbonding -= _amt;
        S_bondedTotalSupply -= amount;

        s_bData.balance += _amt;
        S_totalSupply += amount;

        emit Redeem(owner, amount);
    }

    /// @notice Allows the current surcharge recipient to withdraw the accumulated surcharge. NOTE: If the only ETH in
    /// Atlas is the surcharge, be mindful that withdrawing this ETH may limit solvers' liquidity to flashloan ETH from
    /// Atlas in their solverOps.
    /// @dev This function can only be called by the current surcharge recipient.
    /// It transfers the accumulated surcharge amount to the surcharge recipient's address.
    function withdrawSurcharge() external {
        _onlySurchargeRecipient();

        uint256 _paymentAmount = S_cumulativeSurcharge;
        S_cumulativeSurcharge = 0; // Clear before transfer to prevent reentrancy
        SafeTransferLib.safeTransferETH(msg.sender, _paymentAmount);
        emit SurchargeWithdrawn(msg.sender, _paymentAmount);
    }

    /// @notice Starts the transfer of the surcharge recipient designation to a new address.
    /// @dev This function can only be called by the current surcharge recipient.
    /// It sets the `pendingSurchargeRecipient` to the specified `newRecipient` address,
    /// allowing the new recipient to claim the surcharge recipient designation by calling `becomeSurchargeRecipient`.
    /// If the caller is not the current surcharge recipient, it reverts with an `InvalidAccess` error.
    /// @param newRecipient The address of the new surcharge recipient.
    function transferSurchargeRecipient(address newRecipient) external {
        _onlySurchargeRecipient();

        address _surchargeRecipient = S_surchargeRecipient;

        S_pendingSurchargeRecipient = newRecipient;
        emit SurchargeRecipientTransferStarted(_surchargeRecipient, newRecipient);
    }

    /// @notice Finalizes the transfer of the surcharge recipient designation to a new address.
    /// @dev This function can only be called by the pending surcharge recipient,
    /// and it completes the transfer of the surcharge recipient designation to the address
    /// stored in `pendingSurchargeRecipient`.
    /// If the caller is not the pending surcharge recipient, it reverts with an `InvalidAccess` error.
    function becomeSurchargeRecipient() external {
        if (msg.sender != S_pendingSurchargeRecipient) {
            revert InvalidAccess();
        }

        S_surchargeRecipient = msg.sender;
        S_pendingSurchargeRecipient = address(0);
        emit SurchargeRecipientTransferred(msg.sender);
    }

    function _checkIfUnlocked() internal view {
        if (!_isUnlocked()) revert InvalidLockState();
    }
}
