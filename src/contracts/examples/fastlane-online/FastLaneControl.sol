//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/SolverOperation.sol";
import "src/contracts/types/LockTypes.sol";

import { SwapIntent, BaselineCall } from "src/contracts/examples/fastlane-online/FastLaneTypes.sol";

interface ISolverGateway {
    function getBidAmount(bytes32 solverOpHash) external view returns (uint256 bidAmount);
}

contract FastLaneOnlineControl is DAppControl {
    constructor(address _atlas)
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: false,
                trackPreOpsReturnData: false,
                trackUserReturnData: true,
                delegateUser: true,
                requirePreSolver: true,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: true,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: false,
                forwardReturnData: true,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    { }

    // ---------------------------------------------------- //
    //                     Atlas hooks                      //
    // ---------------------------------------------------- //

    /*
    * @notice This function is called before a solver operation executes
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers the tokens that the user is selling to the solver
    * @param solverOp The SolverOperation that is about to execute
    * @return true if the transfer was successful, false otherwise
    */
    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        (SwapIntent memory _swapIntent,) = abi.decode(returnData, (SwapIntent, BaselineCall));

        // Make sure the token is correct
        require(solverOp.bidToken == _swapIntent.tokenUserBuys, "FLOnlineControl: BuyTokenMismatch");
        require(solverOp.bidToken != _swapIntent.tokenUserSells, "FLOnlineControl: SellTokenMismatch");

        // NOTE: This module is unlike the generalized swap intent module - here, the solverOp.bidAmount includes
        // the min amount that the user expects. 
        // We revert early if the baseline swap returned more than the solver's bid.
        require(solverOp.bidAmount >= _swapIntent.minAmountUserBuys, "FLOnlineControl: BidBelowReserve");

        // Optimistically transfer the user's sell tokens to the solver.
        if (_swapIntent.tokenUserBuys == address(0)) {
            SafeTransferLib.safeTransferETH(solverOp.to, _swapIntent.amountUserSells);
        } else {
            SafeTransferLib.safeTransfer(_swapIntent.tokenUserSells, solverOp.to, _swapIntent.amountUserSells);
        }
        return; // success
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers all the available bid tokens on the contract (instead of only the bid amount,
    *      to avoid leaving any dust on the contract)
    * @param bidToken The address of the token used for the winning solver operation's bid
    * @param _
    * @param _
    */
    function _allocateValueCall(address, uint256, bytes calldata returnData) internal override {
        (SwapIntent memory _swapIntent,) = abi.decode(returnData, (SwapIntent, BaselineCall));
        _sendTokensToUser(_swapIntent);
    }

    function _postOpsCall(bool solved, bytes calldata returnData) internal override {
        // If a solver beat the baseline and the amountOutMin, return early
        if (solved) return;

        (SwapIntent memory _swapIntent, BaselineCall memory _baselineCall) = abi.decode(returnData, (SwapIntent, BaselineCall));

        // Do the baseline call
        uint256 _buyTokensReceived = _baselineSwap(_swapIntent, _baselineCall);

        // Verify that it exceeds the minAmountOut
        require(_buyTokensReceived >= _swapIntent.minAmountUserBuys, "ERR - INSUFICCIENT BASELINE");

        // Undo the token approval
        SafeTransferLib.safeApprove(_swapIntent.tokenUserSells, _baselineCall.to, 0);

        // Transfer tokens to user
        _sendTokensToUser(_swapIntent);
    }

    //////////////////////////////////////////////
    //              CUSTOM FUNCTIONS            //
    //////////////////////////////////////////////
    function _sendTokensToUser(SwapIntent memory swapIntent) internal {
        // Transfer the buy token
        if (swapIntent.tokenUserBuys == address(0)) {
            SafeTransferLib.safeTransferETH(_user(), address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, _user(), _getERC20Balance(swapIntent.tokenUserBuys));
        }

        // Transfer any surplus sell token
        if (swapIntent.tokenUserSells == address(0)) {
            SafeTransferLib.safeTransferETH(_user(), address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(swapIntent.tokenUserSells, _user(), _getERC20Balance(swapIntent.tokenUserSells));
        }
    }

    function _baselineSwap(SwapIntent memory swapIntent, BaselineCall memory baselineCall) internal returns (uint256 received) {
        // Track the balance (count any previously-forwarded tokens)
        uint256 _startingBalance = swapIntent.tokenUserBuys == address(0) ? 
            address(this).balance - msg.value : 
            _getERC20Balance(swapIntent.tokenUserBuys);

        // CASE not gas token
        // NOTE: if gas token, pass as value
        if (swapIntent.tokenUserSells != address(0)) {
            // Approve the router (NOTE that this approval happens either inside the try/catch and is reverted 
            // or in the postOps hook where we cancel it afterwards. 
            SafeTransferLib.safeApprove(swapIntent.tokenUserSells, baselineCall.to, swapIntent.amountUserSells);
        } 

        // Perform the Baseline Call
        (bool _success,) = baselineCall.to.call{value: baselineCall.value}(baselineCall.data);
        require(_success, "BackupRouter: BaselineCallFail"); // dont pass custom errors

        // Track the balance delta
        uint256 _endingBalance = swapIntent.tokenUserBuys == address(0) ? 
            address(this).balance - msg.value : 
            _getERC20Balance(swapIntent.tokenUserBuys);

        require(_endingBalance > _startingBalance, "BackupRouter: NoBalanceIncrease"); // dont pass custom errors

        return _endingBalance - _startingBalance;
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        (SwapIntent memory _swapIntent,) = abi.decode(userOp.data[4:], (SwapIntent, BaselineCall));
        bidToken = _swapIntent.tokenUserBuys;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function _getERC20Balance(address token) internal view returns (uint256 balance) {
        (bool _success, bytes memory _data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, address(this)));
        require(_success, "OuterHelper: BalanceCheckFail");
        balance = abi.decode(_data, (uint256));
    }
}
