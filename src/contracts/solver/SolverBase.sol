//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IAtlas } from "../interfaces/IAtlas.sol";
import { ISolverContract } from "../interfaces/ISolverContract.sol";

import "../types/SolverOperation.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external payable;
}

/**
 * @title SolverBase
 * @notice A base contract for Solvers
 * @dev Does safety checks, escrow reconciliation and pays bids.
 * @dev Works with DAppControls which have set the `invertBidValue` flag to false.
 * @dev Use `SolverBaseInvertBid` for DAppControls which have set the `invertBidValue` flag to true.
 */
contract SolverBase is ISolverContract {
    address public immutable WETH_ADDRESS;
    address internal immutable _owner;
    address internal immutable _atlas;

    error SolverCallUnsuccessful();
    error InvalidEntry();
    error InvalidCaller();

    constructor(address weth, address atlas, address owner) {
        WETH_ADDRESS = weth;
        _owner = owner;
        _atlas = atlas;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata forwardedData
    )
        external
        payable
        virtual
        safetyFirst(executionEnvironment, solverOpFrom)
        payBids(executionEnvironment, bidToken, bidAmount)
    {
        (bool success,) = address(this).call{ value: msg.value }(solverOpData);
        if (!success) revert SolverCallUnsuccessful();
    }

    modifier safetyFirst(address executionEnvironment, address solverOpFrom) {
        // Safety checks
        if (msg.sender != _atlas) revert InvalidEntry();
        if (solverOpFrom != _owner) revert InvalidCaller();

        _;

        uint256 shortfall = IAtlas(_atlas).shortfall();

        if (shortfall < msg.value) shortfall = 0;
        else shortfall -= msg.value;

        if (msg.value > address(this).balance) {
            IWETH9(WETH_ADDRESS).withdraw(msg.value - address(this).balance);
        }

        IAtlas(_atlas).reconcile{ value: msg.value }(shortfall);
    }

    modifier payBids(address executionEnvironment, address bidToken, uint256 bidAmount) {
        _;

        // After the solverCall logic has executed, pay the solver's bid to the Execution Environment of the current
        // metacall tx.

        if (bidToken == address(0)) {
            // Pay bid in ETH

            if (bidAmount > address(this).balance) {
                IWETH9(WETH_ADDRESS).withdraw(bidAmount - address(this).balance);
            }

            SafeTransferLib.safeTransferETH(executionEnvironment, bidAmount);
        } else {
            // Pay bid in ERC20 (bidToken)
            SafeTransferLib.safeTransfer(bidToken, executionEnvironment, bidAmount);
        }
    }
}
