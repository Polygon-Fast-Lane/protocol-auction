// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";

import { IUniswapV2Pair } from "src/contracts/examples/v2-example/interfaces/IUniswapV2Pair.sol";

import { BlindBackrun } from "src/contracts/solver/src/BlindBackrun/BlindBackrun.sol";

import "src/contracts/types/SolverOperation.sol";
import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/EscrowTypes.sol";
import "src/contracts/types/LockTypes.sol";
import "src/contracts/types/ConfigTypes.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";

import "forge-std/Test.sol";

contract V2Helper is Test, TxBuilder {
    uint256 public immutable maxFeePerGas;

    constructor(address _control, address _atlas, address _verification) TxBuilder(_control, _atlas, _verification) {
        maxFeePerGas = tx.gasprice * 2;
    }

    function _getTradeAmtAndDirection(
        address firstPool,
        address secondPool,
        address tokenIn
    )
        internal
        view
        returns (uint256 token0Balance, uint256 token1Balance)
    {
        address token0 = IUniswapV2Pair(firstPool).token0();

        (uint112 token0Balance_a, uint112 token1Balance_a,) = IUniswapV2Pair(firstPool).getReserves();
        (uint112 token0Balance_b, uint112 token1Balance_b,) = IUniswapV2Pair(secondPool).getReserves();

        if (token0 != IUniswapV2Pair(secondPool).token0()) {
            (token1Balance_b, token0Balance_b,) = IUniswapV2Pair(secondPool).getReserves();
        }

        // get the smaller one
        bool flip = token0 == tokenIn;
        token0Balance = flip ? 0 : uint256(token0Balance_a > token0Balance_b ? token0Balance_b : token0Balance_a) / 3;
        token1Balance = flip ? uint256(token1Balance_a > token1Balance_b ? token1Balance_b : token1Balance_a) / 3 : 0;
    }

    function buildUserOperation(
        address firstPool,
        address secondPool,
        address from,
        address tokenIn
    )
        public
        view
        returns (UserOperation memory userOp)
    {
        (uint256 token0Balance, uint256 token1Balance) = _getTradeAmtAndDirection(firstPool, secondPool, tokenIn);

        console.log("-");
        console.log("sell token", tokenIn);
        console.log("token0 in ", token0Balance);
        console.log("token1 in ", token1Balance);
        console.log("-");

        return TxBuilder.buildUserOperation(
            from,
            firstPool,
            maxFeePerGas,
            0,
            SafeBlockNumber.get() + 2,
            buildV2SwapCalldata(token0Balance, token1Balance, from)
        );
    }

    function buildV2SwapCalldata(
        uint256 amount0Out,
        uint256 amount1Out,
        address recipient
    )
        public
        pure
        returns (bytes memory data)
    {
        data = abi.encodeWithSelector(IUniswapV2Pair.swap.selector, amount0Out, amount1Out, recipient, data);
    }

    function buildV2SolverOperationData(address poolOne, address poolTwo) public pure returns (bytes memory data) {
        data = abi.encodeWithSelector(BlindBackrun.executeArbitrage.selector, poolOne, poolTwo);
    }
}
