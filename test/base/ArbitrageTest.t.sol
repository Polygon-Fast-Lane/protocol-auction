// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { BaseTest } from "./BaseTest.t.sol";
import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract ArbitrageTest is BaseTest {
    // Uniswap
    address public constant v2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    // Sushiswap
    address public constant s2Router = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    address public swapper;

    function setUp() public virtual override {
        BaseTest.setUp();
        swapper = vm.addr(666_666);
    }

    function testSimpleArbitrage() public {
        // Increase DAI reserve and decrease WETH reserve on Uniswap LP
        // Increase WETH reserve and decrease DAI reserve on Sushiswap LP
        // This should create an arbitrage opportunity
        setUpArbitragePools(WETH_ADDRESS, DAI_ADDRESS, 50e18, 100_000e18, address(v2Router), address(s2Router));

        // Arbitrage is fulfilled by swapping WETH for DAI on Uniswap, then DAI for WETH on Sushiswap
        (uint256 revenue, uint256 optimalAmountIn) =
            ternarySearch(WETH_ADDRESS, DAI_ADDRESS, address(v2Router), address(s2Router), 1, 50e18, 0, 20);

        assertTrue(revenue - optimalAmountIn > 0, "No arbitrage opportunity");

        deal(WETH_ADDRESS, swapper, optimalAmountIn);
        uint256 balanceBefore = WETH.balanceOf(swapper);

        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = DAI_ADDRESS;

        vm.startPrank(swapper);
        WETH.approve(v2Router, optimalAmountIn);
        uint256 daiOut =
            IUniswapV2Router02(v2Router).swapExactTokensForTokens(optimalAmountIn, 0, path, swapper, block.timestamp)[1];
        vm.stopPrank();

        path[0] = DAI_ADDRESS;
        path[1] = WETH_ADDRESS;

        vm.startPrank(swapper);
        DAI.approve(s2Router, daiOut);
        IUniswapV2Router02(s2Router).swapExactTokensForTokens(daiOut, 0, path, swapper, block.timestamp);
        vm.stopPrank();

        uint256 balanceAfter = WETH.balanceOf(swapper);

        assertTrue(balanceAfter > balanceBefore, "Arbitrage failed");
        console.log("WETH revenue: ", balanceAfter - balanceBefore);
    }

    // Swap amountB tokenB for tokenA on routerA and amountA tokenA for tokenB on routerB.
    // This is meant to create an imbalance between the pools and create an arbitrage opportunity.
    function setUpArbitragePools(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        address routerA,
        address routerB
    )
        public
    {
        deal(tokenA, swapper, amountA);
        deal(tokenB, swapper, amountB);

        address[] memory path = new address[](2);
        path[0] = tokenB;
        path[1] = tokenA;

        vm.startPrank(swapper);
        IERC20(tokenB).approve(routerA, amountB);
        IUniswapV2Router02(routerA).swapExactTokensForTokens(amountB, 0, path, swapper, block.timestamp);
        vm.stopPrank();

        path[0] = tokenA;
        path[1] = tokenB;

        vm.startPrank(swapper);
        IERC20(tokenA).approve(routerB, amountA);
        IUniswapV2Router02(routerB).swapExactTokensForTokens(amountA, 0, path, swapper, block.timestamp);
        vm.stopPrank();
    }

    function simulateSimpleArbitrage(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address routerIn,
        address routerOut
    )
        public
        view
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Invalid amountIn");

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        amountOut = IUniswapV2Router02(routerIn).getAmountsOut(amountIn, path)[1];

        path[0] = tokenOut;
        path[1] = tokenIn;

        amountOut = IUniswapV2Router02(routerOut).getAmountsOut(amountOut, path)[1];
    }

    function ternarySearch(
        address tokenIn,
        address tokenOut,
        address routerIn,
        address routerOut,
        uint256 left,
        uint256 right,
        uint24 c,
        uint24 m
    )
        public
        returns (uint256 revenue, uint256 optimalAmountIn)
    {
        uint256 mid1 = left + (right - left) / 3;
        uint256 mid2 = right - (right - left) / 3;
        uint256 revenue1 = simulateSimpleArbitrage(tokenIn, tokenOut, mid1, routerIn, routerOut);
        uint256 revenue2 = simulateSimpleArbitrage(tokenIn, tokenOut, mid2, routerIn, routerOut);
        if (revenue1 == revenue2) {
            return (revenue1, mid1);
        } else if (revenue1 > revenue2) {
            if (c == m) return (revenue1, mid1);
            return ternarySearch(tokenIn, tokenOut, routerIn, routerOut, left, mid2, c + 1, m);
        }
        if (c == m) return (revenue2, mid2);
        return ternarySearch(tokenIn, tokenOut, routerIn, routerOut, mid1, right, c + 1, m);
    }
}
