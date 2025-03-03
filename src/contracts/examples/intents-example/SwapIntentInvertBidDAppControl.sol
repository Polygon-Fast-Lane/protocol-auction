//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Base Imports
import { IAtlas } from "../../interfaces/IAtlas.sol";

import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";

// Atlas DApp-Control Imports
import { DAppControl } from "../../dapp/DAppControl.sol";

import "forge-std/Test.sol";

/**
 * @notice SwapIntent where user wants exact amount of `tokenUserBuys` and is willing to sell up to `maxAmountUserSells`
 * of
 * `tokenUserSells` for it
 */
struct SwapIntent {
    address tokenUserBuys;
    address tokenUserSells;
    uint256 amountUserBuys;
    uint256 maxAmountUserSells;
}

/**
 * @title SwapIntentInvertBidDAppControl
 * @notice A DAppControl contract that allows a user to swap tokens with a solver using a `SwapIntent`
 * @dev The invertBidValue flag is set to true
 */
contract SwapIntentInvertBidDAppControl is DAppControl {
    bool public immutable _solverBidRetrievalRequired;

    constructor(
        address _atlas,
        bool solverBidRetrievalRequired
    )
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
                requirePostSolver: true,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: true,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: true,
                invertBidValue: true,
                exPostBids: false,
                allowAllocateValueFailure: true,
                multipleSuccessfulSolvers: false
            })
        )
    {
        _solverBidRetrievalRequired = solverBidRetrievalRequired;
    }

    // ---------------------------------------------------- //
    //                       Custom                         //
    // ---------------------------------------------------- //

    /*
    * @notice This is the user operation target function
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It checks that the user has approved Atlas to spend the tokens they are selling and the conditions are met
    * @param swapIntent The SwapIntent struct
    */
    function swap(SwapIntent calldata swapIntent) external payable returns (SwapIntent memory) {
        require(msg.sender == ATLAS, "SwapIntentDAppControl: InvalidSender");
        require(address(this) != CONTROL, "SwapIntentDAppControl: MustBeDelegated");

        // Transfer to the Execution Environment the amount that the solver is invert bidding
        _transferUserERC20(swapIntent.tokenUserSells, address(this), swapIntent.maxAmountUserSells);

        return SwapIntent({
            tokenUserBuys: swapIntent.tokenUserBuys,
            tokenUserSells: swapIntent.tokenUserSells,
            amountUserBuys: swapIntent.amountUserBuys,
            maxAmountUserSells: swapIntent.maxAmountUserSells
        });
    }

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
        address solverTo = solverOp.solver;
        SwapIntent memory swapData = abi.decode(returnData, (SwapIntent));

        // The solver must be bidding less than the intent's maxAmountUserSells
        require(solverOp.bidAmount <= swapData.maxAmountUserSells, "SwapIntentInvertBid: BidTooHigh");

        if (_solverBidRetrievalRequired) {
            // Approve solver to take their bidAmount of the token the user is selling
            // _getAndApproveUserERC20(swapData.tokenUserSells, solverOp.bidAmount, solverTo);
            SafeTransferLib.safeApprove(swapData.tokenUserSells, solverTo, solverOp.bidAmount);
        } else {
            // Optimistically transfer to the solver contract the amount that the solver is invert bidding
            // _transferUserERC20(swapData.tokenUserSells, solverTo, solverOp.bidAmount);
            SafeTransferLib.safeTransfer(swapData.tokenUserSells, solverTo, solverOp.bidAmount);
        }
    }

    /*
    * @notice This function is called after a solver operation executed
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers to the user the tokens they are buying
    * @param _
    * @param returnData The return data from the user operation (swap data)
    * @return true if the transfer was successful, false otherwise
    */
    function _postSolverCall(SolverOperation calldata, bytes calldata returnData) internal override {
        SwapIntent memory swapIntent = abi.decode(returnData, (SwapIntent));
        uint256 buyTokenBalance = IERC20(swapIntent.tokenUserBuys).balanceOf(address(this));

        if (buyTokenBalance < swapIntent.amountUserBuys) {
            revert("SwapIntentInvertBid: Intent Unfulfilled - buyTokenBalance < amountUserBuys");
        }

        // Transfer the tokens the user is buying to the user
        SafeTransferLib.safeTransfer(swapIntent.tokenUserBuys, _user(), swapIntent.amountUserBuys);
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function transfers any excess `tokenUserSells` tokens back to the user
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It transfers all the available bid tokens on the contract (instead of only the bid amount,
    *      to avoid leaving any dust on the contract)
    * @param bidToken The address of the token used for the winning solver operation's bid
    * @param bidAmount The winning bid amount
    * @param _
    */
    function _allocateValueCall(address bidToken, uint256, bytes calldata) internal override {
        if (bidToken == address(0)) {
            SafeTransferLib.safeTransferETH(_user(), address(this).balance);
        } else {
            SafeTransferLib.safeTransfer(bidToken, _user(), IERC20(bidToken).balanceOf(address(this)));
        }
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        (SwapIntent memory swapIntent) = abi.decode(userOp.data[4:], (SwapIntent));
        bidToken = swapIntent.tokenUserSells;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
