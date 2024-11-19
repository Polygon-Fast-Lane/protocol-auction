// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { V2RewardDAppControl } from "../src/contracts/examples/v2-example-router/V2RewardDAppControl.sol";
import { IUniswapV2Router02 } from "../src/contracts/examples/v2-example-router/interfaces/IUniswapV2Router.sol";

import { Token } from "../src/contracts/helpers/DemoToken.sol";
import { WETH } from "solady/tokens/WETH.sol";

// Deploy 3 stablecoin tokens (DAI, USDA, USDB) - all 18 decimals
// Use WETH recognized by Uniswap V2 Router on the target chain
// Make WETH/Stable pools on Uniswap V2 for each stablecoin
// Add liquidity to each pool: 900 Stablecoin / 0.3 WETH = $3000 per WETH

contract DeployDemoTokensScript is DeployBaseScript {
    address public constant UNISWAP_V2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008; // on Sepolia
    address public constant UNISWAP_V2_FACTORY = 0x7E0987E5b3a30e3f2828572Bb659A548460a3003; // on Sepolia

    uint256 public constant WETH_AMOUNT = 0.3 ether;
    uint256 public constant STABLE_AMOUNT = 900 ether;

    uint256 public constant ETH_GAS_BUFFER = 0.2 ether; //TODO update
    uint256 public constant ETH_NEEDED = ETH_GAS_BUFFER + (WETH_AMOUNT * 3);

    Token dai;
    Token usda;
    Token usdb;

    address payable public constant WETH_ADDRESS = payable(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
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

        // Create WETH/Stablecoin pools on Uniswap V2
        console.log("Creating Uniswap V2 Pools...\n");
        address daiWethPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(dai), address(weth));
        address usdaWethPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(usda), address(weth));
        address usdbWethPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(usdb), address(weth));
        address daiUsdaPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(dai), address(usda));
        address daiUsdbPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(dai), address(usdb));
        address usdaUsdbPool = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(usda), address(usdb));

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
        tokenA.approve(UNISWAP_V2_ROUTER, amountA);
        tokenB.approve(UNISWAP_V2_ROUTER, amountB);
        IUniswapV2Router02(UNISWAP_V2_ROUTER).addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, amountA, amountB, deployer, block.timestamp + 900
        );
    }
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

// Foundry not compiling if WETH imported directly from solady/tokens/WETH.sol for some reason.
contract WETH9 is WETH {
    constructor() WETH() { }
}
