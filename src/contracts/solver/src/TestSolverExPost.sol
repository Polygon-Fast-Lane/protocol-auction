// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { SolverBase } from "../../solver/SolverBase.sol";

// Flashbots opensource repo
import { BlindBackrun } from "./BlindBackrun/BlindBackrun.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external payable;
}

contract SolverExPost is SolverBase, BlindBackrun {
    uint256 private immutable _bidPayPercent;

    error BidPayPercentTooHigh();

    constructor(
        address weth,
        address atlasEscrow,
        address owner,
        uint256 bidPayPercent
    )
        SolverBase(weth, atlasEscrow, owner)
    {
        if (bidPayPercent > 100) revert BidPayPercentTooHigh();
        _bidPayPercent = bidPayPercent;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata
    )
        external
        payable
        override(SolverBase)
        safetyFirst(executionEnvironment, solverOpFrom)
        findAndPayBids(executionEnvironment, bidToken, bidAmount)
    {
        (bool success,) = address(this).call{ value: msg.value }(solverOpData);
        if (!success) revert SolverCallUnsuccessful();
    }

    modifier findAndPayBids(address executionEnvironment, address bidToken, uint256 bidAmount) {
        // Track starting balances

        // Starting Balance
        uint256 balance =
            bidToken == address(0) ? address(this).balance - msg.value : IERC20(bidToken).balanceOf(address(this));

        _;

        // Calculate profit
        balance = (
            bidToken == address(0) ? address(this).balance - msg.value : IERC20(bidToken).balanceOf(address(this))
        ) - balance;

        // Handle bid payment
        if (bidToken == address(0)) {
            // Ether balance
            uint256 ethOwed;

            if (bidAmount == 0) {
                ethOwed = (balance * _bidPayPercent / 100) + msg.value;
            } else {
                ethOwed = bidAmount + msg.value;
            }

            if (ethOwed > address(this).balance) {
                IWETH9(WETH_ADDRESS).withdraw(ethOwed - address(this).balance);
            }

            SafeTransferLib.safeTransferETH(executionEnvironment, ethOwed);
        } else {
            // ERC20 balance

            if (msg.value > address(this).balance) {
                IWETH9(WETH_ADDRESS).withdraw(msg.value - address(this).balance);
            }

            if (bidAmount == 0) {
                SafeTransferLib.safeTransfer(bidToken, executionEnvironment, (balance * _bidPayPercent / 100));
            } else {
                SafeTransferLib.safeTransfer(bidToken, executionEnvironment, bidAmount);
            }
        }
    }
}
