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

// This struct is for passing around data internally
struct SwapData {
    address tokenIn;
    address tokenOut;
    int256 requestedAmount; // positive for exact in, negative for exact out
    uint256 limitAmount; // if exact in, min amount out. if exact out, max amount in
    address recipient;
}

contract V4SwapIntentControl is DAppControl {
    address immutable V4_POOL; // TODO: set for test v4 pool

    uint256 startingBalance; // Balance tracked for the v4 pool

    constructor(
        address _atlas,
        address poolManager
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
                userAuctioneer: true,
                solverAuctioneer: true,
                verifyCallChainHash: true,
                unknownAuctioneer: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false,
                multipleSuccessfulSolvers: false
            })
        )
    {
        V4_POOL = poolManager;
    }

    //////////////////////////////////
    // CONTRACT-SPECIFIC FUNCTIONS  //
    //////////////////////////////////

    modifier verifyCall(address tokenIn, address tokenOut, uint256 amount) {
        require(msg.sender == ATLAS, "ERR-PI002 InvalidSender");
        require(address(this) != CONTROL, "ERR-PI004 MustBeDelegated");

        address user = _user();

        // TODO: Could maintain a balance of "1" of each token to allow the user to save gas over multiple uses
        uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
        if (tokenInBalance > 0) {
            SafeTransferLib.safeTransfer(tokenIn, user, tokenInBalance);
        }

        uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));
        if (tokenOutBalance > 0) {
            SafeTransferLib.safeTransfer(tokenOut, user, tokenOutBalance);
        }

        require(_availableFundsERC20(tokenIn, user, amount, ExecutionPhase.PreSolver), "ERR-PI059 SellFundsUnavailable");
        _;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 maxFee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint256 sqrtPriceLimitX96;
    }

    // selector 0x04e45aaf
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        verifyCall(params.tokenIn, params.tokenOut, params.amountIn)
        returns (SwapData memory)
    {
        SwapData memory swapData = SwapData({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            requestedAmount: int256(params.amountIn),
            limitAmount: params.amountOutMinimum,
            recipient: params.recipient
        });

        return swapData;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 maxFee;
        address recipient;
        uint256 amountInMaximum;
        uint256 amountOut;
        uint256 sqrtPriceLimitX96;
    }

    // selector 0x5023b4df
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        verifyCall(params.tokenIn, params.tokenOut, params.amountInMaximum)
        returns (SwapData memory)
    {
        SwapData memory swapData = SwapData({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            requestedAmount: -int256(params.amountOut),
            limitAmount: params.amountInMaximum,
            recipient: params.recipient
        });

        return swapData;
    }

    //////////////////////////////////
    //   ATLAS OVERRIDE FUNCTIONS   //
    //////////////////////////////////

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        address solverTo = solverOp.solver;
        if (solverTo == address(this) || solverTo == _control() || solverTo == ATLAS) {
            revert();
        }

        SwapData memory swapData = abi.decode(returnData, (SwapData));

        // Record balance and transfer to the solver
        if (swapData.requestedAmount > 0) {
            // exact input
            startingBalance = IERC20(swapData.tokenIn).balanceOf(V4_POOL);
            _transferUserERC20(swapData.tokenIn, solverTo, uint256(swapData.requestedAmount));
        } else {
            // exact output
            startingBalance = IERC20(swapData.tokenOut).balanceOf(V4_POOL);
            _transferUserERC20(swapData.tokenIn, solverTo, swapData.limitAmount - solverOp.bidAmount);
            // For exact output swaps, the solver solvers compete and bid on how much tokens they can
            // return to the user in excess of their specified limit input. We only transfer what they
            // require to make the swap in this step.
        }

        // TODO: Permit69 is currently enabled during solver phase, but there is low conviction that this
        // does not enable an attack vector. Consider enabling to save gas on a transfer?
    }

    // Checking intent was fulfilled, and user has received their tokens, happens here
    function _postSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        SwapData memory swapData = abi.decode(returnData, (SwapData));

        uint256 buyTokenBalance = IERC20(swapData.tokenOut).balanceOf(address(this));
        uint256 amountUserBuys =
            swapData.requestedAmount > 0 ? swapData.limitAmount : uint256(-swapData.requestedAmount);

        // If it was an exact input swap, we need to verify that
        // a) We have enough tokens to meet the user's minimum amount out
        // b) The output amount matches (or is greater than) the solver's bid
        // c) PoolManager's balances increased by the provided input amount
        if (swapData.requestedAmount > 0) {
            if (buyTokenBalance < swapData.limitAmount) {
                revert(); // insufficient amount out
            }
            if (buyTokenBalance < solverOp.bidAmount) {
                revert(); // does not meet solver bid
            }
            uint256 endingBalance = IERC20(swapData.tokenIn).balanceOf(V4_POOL);
            if ((endingBalance - startingBalance) < uint256(swapData.requestedAmount)) {
                revert(); // pool manager balances did not increase by the provided input amount
            }
        } else {
            // Exact output swap - check the output amount was transferred out by pool
            uint256 endingBalance = IERC20(swapData.tokenOut).balanceOf(V4_POOL);
            if ((startingBalance - endingBalance) < amountUserBuys) {
                revert(); // pool manager balances did not decrease by the provided output amount
            }
        }
        // no need to check for exact output, since the max is whatever the user transferred

        if (buyTokenBalance >= amountUserBuys) {
            // Make sure not to transfer any extra 'auctionBaseCurrency' token, since that will be used
            // for the auction measurements
            address auctionBaseCurrency = swapData.requestedAmount > 0 ? swapData.tokenOut : swapData.tokenIn;

            if (swapData.tokenOut != auctionBaseCurrency) {
                SafeTransferLib.safeTransfer(swapData.tokenOut, swapData.recipient, buyTokenBalance);
            } else {
                SafeTransferLib.safeTransfer(swapData.tokenOut, swapData.recipient, amountUserBuys);
            }
            return; // only success case of this hook
        }

        revert();
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev transfers the bid amount to the user supports native ETH and ERC20 tokens
    * @param bidToken The address of the token used for the winning SolverOperation's bid
    * @param bidAmount The winning bid amount
    * @param _
    */
    function _allocateValueCall(address bidToken, uint256 bidAmount, bytes calldata) internal override {
        // This function is delegatecalled
        // address(this) = ExecutionEnvironment
        // msg.sender = Atlas
        if (bidToken == address(0)) {
            SafeTransferLib.safeTransferETH(_user(), bidAmount);
        } else {
            SafeTransferLib.safeTransfer(bidToken, _user(), bidAmount);
        }
    }

    /////////////////////////////////////////////////////////
    ///////////////// GETTERS & HELPERS // //////////////////
    /////////////////////////////////////////////////////////
    // NOTE: These are not delegatecalled

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        // This is a helper function called by solvers
        // so that they can get the proper format for
        // submitting their bids to the hook.

        if (bytes4(userOp.data[:4]) == this.exactInputSingle.selector) {
            // exact input swap, the bidding is done in output token
            (, bidToken) = abi.decode(userOp.data[4:], (address, address));
        } else if (bytes4(userOp.data[:4]) == this.exactOutputSingle.selector) {
            // exact output, bidding done in input token
            bidToken = abi.decode(userOp.data[4:], (address));
        }

        // should we return an error here if the function is wrong?
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
