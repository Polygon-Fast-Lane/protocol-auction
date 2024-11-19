// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { Token } from "../src/contracts/helpers/DemoToken.sol";
import { WETH } from "solady/tokens/WETH.sol";

import { stdMath } from "forge-std/StdMath.sol";

// Deploy 3 stablecoin tokens (DAI, USDA, USDB) - all 18 decimals
// Use WETH recognized by Uniswap V3 Router on the target chain
// Make WETH/Stable pools on Uniswap V3 for each stablecoin
// Add liquidity to each pool: 900 Stablecoin / 0.00001 WETH

contract DeployDemoTokensScript is DeployBaseScript {
    // on Base Sepolia
    address public constant UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2;

    uint256 public constant WETH_AMOUNT = 0.00001 ether;
    uint256 public constant STABLE_AMOUNT = 900 ether;

    uint256 public constant ETH_GAS_BUFFER = 0.01 ether; //TODO update
    uint256 public constant ETH_NEEDED = ETH_GAS_BUFFER + (WETH_AMOUNT * 3);

    Token dai;
    Token usda;
    Token usdb;

    address payable public constant WETH_ADDRESS = payable(0x4200000000000000000000000000000000000006);
    WETH9 weth = WETH9(WETH_ADDRESS);

    function run() external {
        console.log("\n=== DEPLOYING DEMO TOKENS ===\n");

        uint256 deployerPrivateKey = vm.envUint("DAPP_GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address: \t\t\t\t", deployer);

        if (deployer.balance < ETH_NEEDED) {
            console.log("\n");
            console.log("NOT ENOUGH ETH IN DEPLOYER WALLET!");
            console.log("Wallet balance: \t\t\t\t", deployer.balance);
            console.log("ETH needed: \t\t\t\t\t", ETH_NEEDED);
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy 3 stablecoins
        console.log("Deploying tokens...\n");
        dai = new Token("DAI Stablecoin", "DAI", 18);
        usda = new Token("USDA Stablecoin", "USDA", 18);
        usdb = new Token("USDB Stablecoin", "USDB", 18);

        address daiWethPool;
        address usdaWethPool;
        address usdbWethPool;
        address daiUsdaPool;
        address daiUsdbPool;
        address usdaUsdbPool;
        uint24 fee = 100;

        // Create WETH/Stablecoin pools on Uniswap V3
        console.log("Creating Uniswap V3 Pools...\n");

        {
            address token0 = address(dai) < address(weth) ? address(dai) : address(weth);
            address token1 = address(dai) < address(weth) ? address(weth) : address(dai);
            uint256 amount0 = address(dai) < address(weth) ? STABLE_AMOUNT : WETH_AMOUNT;
            uint256 amount1 = address(dai) < address(weth) ? WETH_AMOUNT : STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            daiWethPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        {
            address token0 = address(usda) < address(weth) ? address(usda) : address(weth);
            address token1 = address(usda) < address(weth) ? address(weth) : address(usda);
            uint256 amount0 = address(usda) < address(weth) ? STABLE_AMOUNT : WETH_AMOUNT;
            uint256 amount1 = address(usda) < address(weth) ? WETH_AMOUNT : STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            usdaWethPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        {
            address token0 = address(usdb) < address(weth) ? address(usdb) : address(weth);
            address token1 = address(usdb) < address(weth) ? address(weth) : address(usdb);
            uint256 amount0 = address(usdb) < address(weth) ? STABLE_AMOUNT : WETH_AMOUNT;
            uint256 amount1 = address(usdb) < address(weth) ? WETH_AMOUNT : STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            usdbWethPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        {
            address token0 = address(dai) < address(usda) ? address(dai) : address(usda);
            address token1 = address(dai) < address(usda) ? address(usda) : address(dai);
            uint256 amount0 = STABLE_AMOUNT;
            uint256 amount1 = STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            daiUsdaPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        {
            address token0 = address(dai) < address(usdb) ? address(dai) : address(usdb);
            address token1 = address(dai) < address(usdb) ? address(usdb) : address(dai);
            uint256 amount0 = STABLE_AMOUNT;
            uint256 amount1 = STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            daiUsdbPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        {
            address token0 = address(usda) < address(usdb) ? address(usda) : address(usdb);
            address token1 = address(usda) < address(usdb) ? address(usdb) : address(usda);
            uint256 amount0 = STABLE_AMOUNT;
            uint256 amount1 = STABLE_AMOUNT;
            uint160 sqrtPriceX96 = uint160((sqrt((amount1 * 1e18) / amount0) * 2 ** 96) / 1e9);
            usdaUsdbPool = IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER)
                .createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        }

        // Add liquidity to stablecoin/weth pools: 900 Stablecoin / 0.3 WETH = $3000 per WETH
        console.log("Adding liquidity to STABLE/WETH pools...\n");
        mintApproveAndAddLiquidity(dai, Token(address(weth)), STABLE_AMOUNT, WETH_AMOUNT, deployer);
        mintApproveAndAddLiquidity(usda, Token(address(weth)), STABLE_AMOUNT, WETH_AMOUNT, deployer);
        mintApproveAndAddLiquidity(usdb, Token(address(weth)), STABLE_AMOUNT, WETH_AMOUNT, deployer);

        // Add liquidity to stablecoin/stablecoin pools: 900 Stablecoin / 900 Stablecoin = $1 per Stablecoin
        console.log("Adding liquidity to STABLE/STABLE pools...\n");
        mintApproveAndAddLiquidity(dai, usda, STABLE_AMOUNT, STABLE_AMOUNT, deployer);
        mintApproveAndAddLiquidity(dai, usdb, STABLE_AMOUNT, STABLE_AMOUNT, deployer);
        mintApproveAndAddLiquidity(usda, usdb, STABLE_AMOUNT, STABLE_AMOUNT, deployer);

        vm.stopBroadcast();

        console.log("\n");
        console.log("WETH Token used: \t\t", address(weth));
        console.log("\n");
        console.log("DAI deployed at: \t\t", address(dai));
        console.log("USDA deployed at: \t\t", address(usda));
        console.log("USDB deployed at: \t\t", address(usdb));
        console.log("\n");
        console.log("DAI/WETH Pool: \t\t", daiWethPool);
        console.log("USDA/WETH Pool: \t\t", usdaWethPool);
        console.log("USDB/WETH Pool: \t\t", usdbWethPool);
        console.log("DAI/USDA Pool: \t\t", daiUsdaPool);
        console.log("DAI/USDB Pool: \t\t", daiUsdbPool);
        console.log("USDA/USDB Pool: \t\t", usdaUsdbPool);
        console.log("\n");
    }

    function mintApproveAndAddLiquidity(
        Token tokenA,
        Token tokenB,
        uint256 amountA,
        uint256 amountB,
        address deployer
    )
        public
    {
        // Deposit ETH if token is WETH, or mint tokens if not WETH
        if (address(tokenA) == address(weth)) {
            WETH9(WETH_ADDRESS).deposit{ value: amountA }();
        } else {
            tokenA.mint(deployer, amountA);
        }

        if (address(tokenB) == address(weth)) {
            WETH9(WETH_ADDRESS).deposit{ value: amountB }();
        } else {
            tokenB.mint(deployer, amountB);
        }

        // Then approve both tokens and add liquidity on Uniswap
        tokenA.approve(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, amountA);
        tokenB.approve(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, amountB);
        IUniswapV3NonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER).mint(
            IUniswapV3NonfungiblePositionManager.MintParams({
                token0: address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB),
                token1: address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA),
                fee: 100,
                tickLower: -887_271,
                tickUpper: 887_271,
                amount0Desired: address(tokenA) < address(tokenB) ? amountA : amountB,
                amount1Desired: address(tokenA) < address(tokenB) ? amountB : amountA,
                amount0Min: 1,
                amount1Min: 1,
                recipient: deployer,
                deadline: block.timestamp + 1000
            })
        );
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

interface IUniswapV3NonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    )
        external
        payable
        returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

// Foundry not compiling if WETH imported directly from solady/tokens/WETH.sol for some reason.
contract WETH9 is WETH {
    constructor() WETH() { }
}
