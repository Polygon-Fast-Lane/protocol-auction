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

// Interface Import
import { IAtlasVerification } from "../../interfaces/IAtlasVerification.sol";
import { IExecutionEnvironment } from "../../interfaces/IExecutionEnvironment.sol";
import { IAtlas } from "../../interfaces/IAtlas.sol";

import { FastLaneOnlineControl } from "./FastLaneControl.sol";
import { BaseStorage } from "./BaseStorage.sol";

import { SwapIntent, BaselineCall } from "./FastLaneTypes.sol";

interface IGeneralizedBackrunProxy {
    function getUser() external view returns (address);
}

contract FastLaneOnlineInner is BaseStorage, FastLaneOnlineControl {
    error BaselineFailSuccessful(uint256 baselineAmount);
    error BaselineFailFailure();

    event BaselineEstablished(uint256 userMinAmountOut, uint256 baselineAmountOut);

    constructor(address atlas) FastLaneOnlineControl(atlas) { }

    /////////////////////////////////////////////////////////
    //        EXECUTION ENVIRONMENT FUNCTIONS              //
    //                                                     //
    /////////////////////////////////////////////////////////

    /*
    * @notice This is the user operation target function
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev selector = ??
    * @dev It checks that the user has approved Atlas to spend the tokens they are selling
    * @param swapIntent The SwapIntent struct
    * @return swapIntent The SwapIntent struct
    */
    function swap(
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall
    )
        external
        payable
        returns (SwapIntent memory, BaselineCall memory)
    {
        if (msg.sender != ATLAS) {
            revert FLOnlineInner_Swap_OnlyAtlas();
        }
        if (address(this) == CONTROL) {
            revert FLOnlineInner_Swap_MustBeDelegated();
        }
        if (swapIntent.tokenUserSells == swapIntent.tokenUserBuys) {
            revert FLOnlineInner_Swap_BuyAndSellTokensAreSame();
        }

        // control == bundler != user
        if (_bundler() != CONTROL) {
            revert FLOnlineInner_Swap_ControlNotBundler();
        }

        // Transfer sell token if it isn't native token and validate value deposit if it is
        if (swapIntent.tokenUserSells != _NATIVE_TOKEN) {
            _transferUserERC20(swapIntent.tokenUserSells, address(this), swapIntent.amountUserSells);
        } else {
            // UserOp.value already passed to this contract - ensure that userOp.value matches sell amount
            if (msg.value < swapIntent.amountUserSells) revert FLOnlineInner_Swap_UserOpValueTooLow();
            if (baselineCall.value < swapIntent.amountUserSells) revert FLOnlineInner_Swap_BaselineCallValueTooLow();
        }

        // Calculate the baseline swap amount from the frontend-sourced routing
        // This will typically be a uniswap v2 or v3 path.
        // NOTE: This runs inside a try/catch and is reverted.
        uint256 _baselineAmount = _catchSwapBaseline(swapIntent, baselineCall);

        emit BaselineEstablished(swapIntent.minAmountUserBuys, _baselineAmount);

        // Update the minAmountUserBuys with this value
        // NOTE: If all of the solvers fail to exceed this value, we'll redo this swap in the postOpsHook
        // and verify that the min amount is exceeded.
        if (_baselineAmount > swapIntent.minAmountUserBuys) {
            SwapIntent memory _swapIntent = swapIntent;
            _swapIntent.minAmountUserBuys = _baselineAmount;
            return (_swapIntent, baselineCall);
        }
        return (swapIntent, baselineCall);
    }

    function _catchSwapBaseline(
        SwapIntent calldata swapIntent,
        BaselineCall calldata baselineCall
    )
        internal
        returns (uint256 baselineAmount)
    {
        (bool _success, bytes memory _data) =
            CONTROL.delegatecall(_forward(abi.encodeCall(this.baselineSwapTryCatcher, (swapIntent, baselineCall))));

        if (_success) revert(); // unreachable

        if (bytes4(_data) == BaselineFailSuccessful.selector) {
            // Get the uint256 from the memory array
            assembly {
                let dataLocation := add(_data, 0x20)
                baselineAmount := mload(add(dataLocation, sub(mload(_data), 32)))
            }
            return baselineAmount;
        }
        return 0;
    }

    function baselineSwapTryCatcher(SwapIntent calldata swapIntent, BaselineCall calldata baselineCall) external {
        // Do the baseline swap and get the amount received
        uint256 _received = _baselineSwap(swapIntent, baselineCall);

        // Revert gracefully to undo the swap but show the baseline amountOut
        // NOTE: This does not check the baseline amount against the user's minimum requirement
        // This is to allow solvers a chance to succeed even if the baseline swap has returned
        // an unacceptable amount (such as if it were sandwiched to try and nullify the swap).
        revert BaselineFailSuccessful(_received);
    }
}
