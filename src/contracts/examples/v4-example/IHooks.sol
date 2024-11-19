// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import { IPoolManager } from "./IPoolManager.sol";

interface IHooks {
    function beforeSwap(
        address sender,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    )
        external
        returns (bytes4);

    struct Calls {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeModifyPosition;
        bool afterModifyPosition;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
    }
}
