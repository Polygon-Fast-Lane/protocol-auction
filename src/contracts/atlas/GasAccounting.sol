//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { SafetyLocks } from "src/contracts/atlas/SafetyLocks.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";
import { EscrowBits } from "src/contracts/libraries/EscrowBits.sol";
import { AccountingMath } from "src/contracts/libraries/AccountingMath.sol";
import { SolverOperation } from "src/contracts/types/SolverOperation.sol";
import { DAppConfig } from "src/contracts/types/ConfigTypes.sol";
import { IL2GasCalculator } from "src/contracts/interfaces/IL2GasCalculator.sol";
import "src/contracts/types/EscrowTypes.sol";
import "src/contracts/types/LockTypes.sol";

/// @title GasAccounting
/// @author FastLane Labs
/// @notice GasAccounting manages the accounting of gas surcharges and escrow balances for the Atlas protocol.
abstract contract GasAccounting is SafetyLocks {
    using EscrowBits for uint256;
    using AccountingMath for uint256;

    constructor(
        uint256 escrowDuration,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator
    )
        SafetyLocks(escrowDuration, verification, simulator, initialSurchargeRecipient, l2GasCalculator)
    { }

    /// @notice Sets the initial accounting values for the metacall transaction.
    /// @param gasMarker The gas marker used to calculate the initial accounting values.
    function _initializeAccountingValues(uint256 gasMarker) internal {
        uint256 _rawClaims = (FIXED_GAS_OFFSET + gasMarker) * tx.gasprice;

        // Set any withdraws or deposits
        _setClaims(_rawClaims.withBundlerSurcharge());

        // Atlas surcharge is based on the raw claims value.
        _setFees(_rawClaims.getAtlasSurcharge());
        _setDeposits(msg.value);

        // Explicitly set writeoffs and withdrawals to 0 in case multiple metacalls in single tx.
        _setWriteoffs(0);
        _setWithdrawals(0);

        // Explicitly clear solverLock and solverTo in case multiple metacalls in single tx.
        _setSolverLock(0);
        _setSolverTo(address(0));

        // The Lock slot is cleared at the end of the metacall, so no need to zero again here.
    }

    /// @notice Contributes ETH to the contract, increasing the deposits if a non-zero value is sent.
    function contribute() external payable {
        address _activeEnv = _activeEnvironment();
        if (_activeEnv != msg.sender) revert InvalidExecutionEnvironment(_activeEnv);
        _contribute();
    }

    /// @notice Borrows ETH from the contract, transferring the specified amount to the caller if available.
    /// @dev Borrowing is only available until the end of the SolverOperation phase, for solver protection.
    /// @param amount The amount of ETH to borrow.
    function borrow(uint256 amount) external payable {
        if (amount == 0) return;

        // borrow() can only be called by the Execution Environment (by delegatecalling a DAppControl hook), and only
        // during or before the SolverOperation phase.
        (address _activeEnv,, uint8 _currentPhase) = _lock();
        if (_activeEnv != msg.sender) revert InvalidExecutionEnvironment(_activeEnv);
        if (_currentPhase > uint8(ExecutionPhase.SolverOperation)) revert WrongPhase();

        // borrow() will revert if called after solver calls reconcile()
        (, bool _calledBack,) = _solverLockData();
        if (_calledBack) revert WrongPhase();

        if (_borrow(amount)) {
            SafeTransferLib.safeTransferETH(msg.sender, amount);
        } else {
            revert InsufficientAtlETHBalance(address(this).balance, amount);
        }
    }

    /// @notice Calculates the current shortfall currently owed by the winning solver.
    /// @dev The shortfall is calculated `(claims + withdrawals + fees - writeoffs) - deposits`. If this value is less
    /// than zero, shortfall returns 0 as there is no shortfall because the solver is in surplus.
    /// @return uint256 The current shortfall amount, or 0 if there is no shortfall.
    function shortfall() external view returns (uint256) {
        uint256 _currentDeficit = _deficit();
        uint256 _deposits = deposits();
        return (_currentDeficit > _deposits) ? (_currentDeficit - _deposits) : 0;
    }

    function _deficit() internal view returns (uint256) {
        return claims() + withdrawals() + fees() - writeoffs();
    }

    /// @notice Allows a solver to settle any outstanding ETH owed, either to repay gas used by their solverOp or to
    /// repay any ETH borrowed from Atlas. This debt can be paid either by sending ETH when calling this function
    /// (msg.value) or by approving Atlas to use a certain amount of the solver's bonded AtlETH.
    /// @param maxApprovedGasSpend The maximum amount of the solver's bonded AtlETH that Atlas can deduct to cover the
    /// solver's debt.
    /// @return owed The amount owed, if any, by the solver after reconciliation.
    /// @dev The solver can call this function multiple times until the owed amount is zero.
    /// @dev Note: `reconcile()` must be called by the solver to avoid a `CallbackNotCalled` error in `solverCall()`.
    function reconcile(uint256 maxApprovedGasSpend) external payable returns (uint256 owed) {
        // NOTE: maxApprovedGasSpend is the amount of the solver's atlETH that the solver is allowing
        // to be used to cover what they owe. Assuming they're successful, a value up to this amount
        // will be subtracted from the solver's bonded AtlETH during _settle().

        // NOTE: After reconcile is called for the first time by the solver, neither the claims nor withdrawals values
        // can be increased.

        // NOTE: While anyone can call this function, it can only be called in the SolverOperation phase. Because Atlas
        // calls directly to the solver contract in this phase, the solver should be careful to not call malicious
        // contracts which may call reconcile() on their behalf, with an excessive maxApprovedGasSpend.
        if (_phase() != uint8(ExecutionPhase.SolverOperation)) revert WrongPhase();
        if (msg.sender != _solverTo()) revert InvalidAccess();

        (address _currentSolver, bool _calledBack, bool _fulfilled) = _solverLockData();
        uint256 _bondedBalance = uint256(S_accessData[_currentSolver].bonded);

        // Solver can only approve up to their bonded balance, not more
        if (maxApprovedGasSpend > _bondedBalance) maxApprovedGasSpend = _bondedBalance;

        uint256 _deductions = _deficit();
        uint256 _additions = deposits() + msg.value;

        // Add msg.value to solver's deposits
        // NOTE: Surplus deposits are credited back to the Solver during settlement.
        // NOTE: This function is called inside the solver try/catch and will be undone if solver fails.
        if (msg.value > 0) _setDeposits(_additions);

        // CASE: Callback verified but insufficient balance
        if (_deductions > _additions + maxApprovedGasSpend) {
            if (!_calledBack) {
                // Setting the solverLock here does not make the solver liable for the submitted maxApprovedGasSpend,
                // but it does treat any msg.value as a deposit and allows for either the solver to call back with a
                // higher maxApprovedGasSpend or to have their deficit covered by a contribute during the postSolverOp
                // hook.
                _setSolverLock(uint256(uint160(_currentSolver)) | _SOLVER_CALLED_BACK_MASK);
            }
            return _deductions - _additions;
        }

        // CASE: Callback verified and solver duty fulfilled
        if (!_fulfilled) {
            _setSolverLock(uint256(uint160(_currentSolver)) | _SOLVER_CALLED_BACK_MASK | _SOLVER_FULFILLED_MASK);
        }
        return 0;
    }

    /// @notice Internal function to handle ETH contribution, increasing deposits if a non-zero value is sent.
    function _contribute() internal {
        if (msg.value != 0) _setDeposits(deposits() + msg.value);
    }

    /// @notice Borrows ETH from the contract, transferring the specified amount to the caller if available.
    /// @dev Borrowing should never be allowed after the SolverOperation phase, for solver safety. This is enforced in
    /// the external `borrow` function, and the only other time this internal `_borrow` function is called is in
    /// `_solverOpInner` which happens at the beginning of the SolverOperation phase.
    /// @param amount The amount of ETH to borrow.
    /// @return valid A boolean indicating whether the borrowing operation was successful.
    function _borrow(uint256 amount) internal returns (bool valid) {
        if (amount == 0) return true;
        if (address(this).balance < amount) return false;

        _setWithdrawals(withdrawals() + amount);

        return true;
    }

    /// @notice Takes AtlETH from the owner's bonded balance and, if necessary, from the owner's unbonding balance to
    /// increase transient solver deposits.
    /// @param owner The address of the owner from whom AtlETH is taken.
    /// @param amount The amount of AtlETH to be taken.
    /// @param gasValueUsed The ETH value of gas used in the SolverOperation.
    /// @param solverWon A boolean indicating whether the solver won the bid.
    /// @return deficit The amount of AtlETH that was not repaid, if any.
    function _assign(
        address owner,
        uint256 amount,
        uint256 gasValueUsed,
        bool solverWon
    )
        internal
        returns (uint256 deficit)
    {
        if (amount > type(uint112).max) revert ValueTooLarge();
        uint112 _amt = SafeCast.toUint112(amount);

        EscrowAccountAccessData memory _aData = S_accessData[owner];

        if (_amt > _aData.bonded) {
            // The bonded balance does not cover the amount owed. Check if there is enough unbonding balance to
            // make up for the missing difference. If not, there is a deficit. Atlas does not consider drawing from
            // the regular AtlETH balance (not bonded nor unbonding) to cover the remaining deficit because it is
            // not meant to be used within an Atlas transaction, and must remain independent.

            EscrowAccountBalance memory _bData = s_balanceOf[owner];
            uint256 _total = uint256(_bData.unbonding) + uint256(_aData.bonded);

            if (_amt > _total) {
                // The unbonding balance is insufficient to cover the remaining amount owed. There is a deficit. Set
                // both bonded and unbonding balances to 0 and adjust the "amount" variable to reflect the amount
                // that was actually deducted.
                deficit = amount - _total;
                s_balanceOf[owner].unbonding = 0;
                _aData.bonded = 0;

                _setWriteoffs(writeoffs() + deficit);
                amount -= deficit; // Set amount equal to total to accurately track the changing bondedTotalSupply
            } else {
                // The unbonding balance is sufficient to cover the remaining amount owed. Draw everything from the
                // bonded balance, and adjust the unbonding balance accordingly.
                s_balanceOf[owner].unbonding = SafeCast.toUint112(_total - _amt);
                _aData.bonded = 0;
            }
        } else {
            // The bonded balance is sufficient to cover the amount owed.
            _aData.bonded -= _amt;
        }

        // Update analytics (auctionWins, auctionFails, totalGasValueUsed) and lastAccessedBlock
        _updateAnalytics(_aData, solverWon && deficit == 0, gasValueUsed);
        _aData.lastAccessedBlock = uint32(SafeBlockNumber.get());

        // Persist changes in the _aData memory struct back to storage
        S_accessData[owner] = _aData;

        S_bondedTotalSupply -= amount;
        _setDeposits(deposits() + amount);
    }

    /// @notice Increases the owner's bonded balance by the specified amount.
    /// @param owner The address of the owner whose bonded balance will be increased.
    /// @param amount The amount by which to increase the owner's bonded balance.
    /// @param gasValueUsed The ETH value of gas used in the SolverOperation.
    function _credit(address owner, uint256 amount, uint256 gasValueUsed) internal {
        uint112 _amt = SafeCast.toUint112(amount);

        EscrowAccountAccessData memory _aData = S_accessData[owner];

        _aData.lastAccessedBlock = uint32(SafeBlockNumber.get());
        _aData.bonded += _amt;

        S_bondedTotalSupply += amount;

        // Update analytics (auctionWins, auctionFails, totalGasValueUsed)
        _updateAnalytics(_aData, true, gasValueUsed);

        // Persist changes in the _aData memory struct back to storage
        S_accessData[owner] = _aData;
        _setWithdrawals(withdrawals() + amount);
    }

    /// @notice Accounts for the gas cost of a failed SolverOperation, either by increasing writeoffs (if the bundler is
    /// blamed for the failure) or by assigning the gas cost to the solver's bonded AtlETH balance (if the solver is
    /// blamed for the failure).
    /// @param solverOp The current SolverOperation for which to account.
    /// @param gasWaterMark The `gasleft()` watermark taken at the start of executing the SolverOperation.
    /// @param result The result bitmap of the SolverOperation execution.
    /// @param includeCalldata Whether to include calldata cost in the gas calculation.
    function _handleSolverAccounting(
        SolverOperation calldata solverOp,
        uint256 gasWaterMark,
        uint256 result,
        bool includeCalldata
    )
        internal
    {
        uint256 _gasUsed = (gasWaterMark + _SOLVER_BASE_GAS_USED - gasleft()) * tx.gasprice;

        if (includeCalldata) {
            _gasUsed += _getCalldataCost(solverOp.data.length);
        }

        // Calculate what the solver owes
        // NOTE: This will cause an error if you are simulating with a gasPrice of 0
        if (result.bundlersFault()) {
            // CASE: Solver is not responsible for the failure of their operation, so we blame the bundler
            // and reduce the total amount refunded to the bundler
            _setWriteoffs(writeoffs() + _gasUsed.withAtlasAndBundlerSurcharges());
        } else {
            // CASE: Solver failed, so we calculate what they owe.
            uint256 _gasUsedWithSurcharges = _gasUsed.withAtlasAndBundlerSurcharges();
            _assign(solverOp.from, _gasUsedWithSurcharges, _gasUsedWithSurcharges, false);
        }
    }

    function _writeOffBidFindGasCost(uint256 gasUsed) internal {
        _setWriteoffs(writeoffs() + gasUsed.withAtlasAndBundlerSurcharges());
    }

    /// @param ctx Context struct containing relevant context information for the Atlas auction.
    /// @param solverGasLimit The maximum gas limit for a solver, as set in the DAppConfig
    /// @return adjustedWithdrawals Withdrawals of the current metacall, adjusted by adding the Atlas gas surcharge.
    /// @return adjustedDeposits Deposits of the current metacall, no adjustments applied.
    /// @return adjustedClaims Claims of the current metacall, adjusted by subtracting the unused gas scaled to include
    /// bundler surcharge.
    /// @return adjustedWriteoffs Writeoffs of the current metacall, adjusted by adding the bundler gas overage penalty
    /// if applicable.
    /// @return netAtlasGasSurcharge The net gas surcharge of the metacall, taken by Atlas.
    /// @dev This function is called internally to adjust the accounting for fees based on the gas usage.
    /// Note: The behavior of this function depends on whether `_bidFindingIteration()` or `_bidKnownIteration()` is
    /// used, as they both use a different order of execution.
    function _adjustAccountingForFees(
        Context memory ctx,
        uint256 solverGasLimit
    )
        internal
        returns (
            uint256 adjustedWithdrawals,
            uint256 adjustedDeposits,
            uint256 adjustedClaims,
            uint256 adjustedWriteoffs,
            uint256 netAtlasGasSurcharge
        )
    {
        uint256 _surcharge = S_cumulativeSurcharge;
        uint256 _fees = fees();

        adjustedWithdrawals = withdrawals();
        adjustedDeposits = deposits();
        adjustedClaims = claims();
        adjustedWriteoffs = writeoffs();

        uint256 _gasLeft = gasleft(); // Hold this constant for the calculations

        // Estimate the unspent, remaining gas that the Solver will not be liable for.
        uint256 _gasRemainder = _gasLeft * tx.gasprice;

        // Calculate the preadjusted netAtlasGasSurcharge
        netAtlasGasSurcharge = _fees - _gasRemainder.getAtlasSurcharge();

        adjustedClaims -= _gasRemainder.withBundlerSurcharge();
        adjustedWithdrawals += netAtlasGasSurcharge;
        S_cumulativeSurcharge = _surcharge + netAtlasGasSurcharge; // Update the cumulative surcharge

        // Calculate whether or not the bundler used an excessive amount of gas and, if so, reduce their
        // gas rebate. By reducing the claims, solvers end up paying less in total.
        if (ctx.solverCount > 0) {
            // Calculate the unadjusted bundler gas surcharge
            uint256 _grossBundlerGasSurcharge = adjustedClaims.withoutBundlerSurcharge();

            // Calculate an estimate for how much gas should be remaining
            // NOTE: There is a free buffer of one SolverOperation because solverIndex starts at 0.
            uint256 _upperGasRemainingEstimate =
                (solverGasLimit * (ctx.solverCount - ctx.solverIndex)) + _BUNDLER_GAS_PENALTY_BUFFER;

            // Increase the writeoffs value if the bundler set too high of a gas parameter and forced solvers to
            // maintain higher escrow balances.
            if (_gasLeft > _upperGasRemainingEstimate) {
                // Penalize the bundler's gas
                uint256 _bundlerGasOveragePenalty =
                    _grossBundlerGasSurcharge - (_grossBundlerGasSurcharge * _upperGasRemainingEstimate / _gasLeft);
                adjustedWriteoffs += _bundlerGasOveragePenalty;
            }
        }
    }

    /// @notice Settle makes the final adjustments to accounting variables based on gas used in the metacall. AtlETH is
    /// either taken (via _assign) or given (via _credit) to the winning solver, the bundler is sent the appropriate
    /// refund for gas spent, and Atlas' gas surcharge is updated.
    /// @param ctx Context struct containing relevant context information for the Atlas auction.
    /// @param solverGasLimit The dApp's maximum gas limit for a solver, as set in the DAppConfig.
    /// @return claimsPaidToBundler The amount of ETH paid to the bundler in this function.
    /// @return netAtlasGasSurcharge The net gas surcharge of the metacall, taken by Atlas.
    function _settle(
        Context memory ctx,
        uint256 solverGasLimit
    )
        internal
        returns (uint256 claimsPaidToBundler, uint256 netAtlasGasSurcharge)
    {
        // NOTE: If there is no winning solver but the dApp config allows unfulfilled 'successes', the bundler
        // is treated as the solver.

        // If a solver won, their address is still in the _solverLock
        (address _winningSolver,,) = _solverLockData();

        // Load what we can from storage so that it shows up in the gasleft() calc

        uint256 _claims;
        uint256 _writeoffs;
        uint256 _withdrawals;
        uint256 _deposits;

        (_withdrawals, _deposits, _claims, _writeoffs, netAtlasGasSurcharge) =
            _adjustAccountingForFees(ctx, solverGasLimit);

        uint256 _amountSolverPays;
        uint256 _amountSolverReceives;
        uint256 _adjustedClaims = _claims - _writeoffs;

        // Calculate the balances that should be debited or credited to the solver and the bundler
        if (_deposits < _withdrawals) {
            _amountSolverPays = _withdrawals - _deposits;
        } else {
            _amountSolverReceives = _deposits - _withdrawals;
        }

        // Only force solver to pay gas claims if they aren't also the bundler
        // NOTE: If the auction isn't won, _winningSolver will be address(0).
        if (ctx.solverSuccessful && _winningSolver != ctx.bundler) {
            _amountSolverPays += _adjustedClaims;
            claimsPaidToBundler = _adjustedClaims;
        } else {
            claimsPaidToBundler = 0;
            _winningSolver = ctx.bundler;
        }

        if (_amountSolverPays > _amountSolverReceives) {
            if (!ctx.solverSuccessful) {
                revert InsufficientTotalBalance(_amountSolverPays - _amountSolverReceives);
            }

            uint256 _currentDeficit =
                _assign(_winningSolver, _amountSolverPays - _amountSolverReceives, _adjustedClaims, true);
            if (_currentDeficit > claimsPaidToBundler) {
                revert InsufficientTotalBalance(_currentDeficit - claimsPaidToBundler);
            }
            claimsPaidToBundler -= _currentDeficit;
        } else {
            _credit(_winningSolver, _amountSolverReceives - _amountSolverPays, _adjustedClaims);
        }

        // Set lock to FullyLocked to prevent any reentrancy possibility
        _setLockPhase(uint8(ExecutionPhase.FullyLocked));

        if (claimsPaidToBundler != 0) SafeTransferLib.safeTransferETH(ctx.bundler, claimsPaidToBundler);

        return (claimsPaidToBundler, netAtlasGasSurcharge);
    }

    /// @notice Updates auctionWins, auctionFails, and totalGasUsed values of a solver's EscrowAccountAccessData.
    /// @dev This function is only ever called in the context of bidFind = false so no risk of doublecounting changes.
    /// @param aData The Solver's EscrowAccountAccessData struct to update.
    /// @param auctionWon A boolean indicating whether the solver's solverOp won the auction.
    /// @param gasValueUsed The ETH value of gas used by the solverOp. Should be calculated as gasUsed * tx.gasprice.
    function _updateAnalytics(
        EscrowAccountAccessData memory aData,
        bool auctionWon,
        uint256 gasValueUsed
    )
        internal
        pure
    {
        if (auctionWon) {
            unchecked {
                ++aData.auctionWins;
            }
        } else {
            unchecked {
                ++aData.auctionFails;
            }
        }

        // Track total ETH value of gas spent by solver in metacalls. Measured in gwei (1e9 digits truncated).
        aData.totalGasValueUsed += SafeCast.toUint64(gasValueUsed / _GAS_VALUE_DECIMALS_TO_DROP);
    }

    /// @notice Calculates the gas cost of the calldata used to execute a SolverOperation.
    /// @param calldataLength The length of the `data` field in the SolverOperation.
    /// @return calldataCost The gas cost of the calldata used to execute the SolverOperation.
    function _getCalldataCost(uint256 calldataLength) internal view returns (uint256 calldataCost) {
        if (L2_GAS_CALCULATOR == address(0)) {
            // Default to using mainnet gas calculations
            // _SOLVER_OP_BASE_CALLDATA = SolverOperation calldata length excluding solverOp.data
            calldataCost = (calldataLength + _SOLVER_OP_BASE_CALLDATA) * _CALLDATA_LENGTH_PREMIUM * tx.gasprice;
        } else {
            calldataCost =
                IL2GasCalculator(L2_GAS_CALCULATOR).getCalldataCost(calldataLength + _SOLVER_OP_BASE_CALLDATA);
        }
    }

    /// @notice Checks if the current balance is reconciled.
    /// @dev Compares the deposits with the sum of claims, withdrawals, fees, and write-offs to ensure the balance is
    /// correct.
    /// @return True if the balance is reconciled, false otherwise.
    function _isBalanceReconciled() internal view returns (bool) {
        return deposits() >= _deficit();
    }
}
