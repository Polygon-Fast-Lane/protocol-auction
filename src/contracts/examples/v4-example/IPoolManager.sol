// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import { IHooks } from "./IHooks.sol";

interface IPoolManager {
    type Currency is address;
    type BalanceDelta is int256;

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    struct PoolKey {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
    }

    struct ModifyPositionParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // how to modify the liquidity
        int256 liquidityDelta;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta);
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external returns (BalanceDelta);
    function modifyPosition(PoolKey memory key, ModifyPositionParams memory params) external returns (BalanceDelta);
}
