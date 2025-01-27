// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

import { BaseTest } from "test/base/BaseTest.t.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { UserOperationBuilder } from "test/base/builders/UserOperationBuilder.sol";

import { SolverOperation } from "src/contracts/types/SolverOperation.sol";
import { UserOperation } from "src/contracts/types/UserOperation.sol";
import { DAppConfig } from "src/contracts/types/ConfigTypes.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";
import "src/contracts/types/DAppOperation.sol";

import { V2RewardDAppControl } from "src/contracts/examples/v2-example-router/V2RewardDAppControl.sol";
import { IUniswapV2Router01, IUniswapV2Router02 } from "src/contracts/examples/v2-example-router/interfaces/IUniswapV2Router.sol";
import { SolverBase } from "src/contracts/solver/SolverBase.sol";

contract V2RewardDAppControlTest is BaseTest {
    address V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    V2RewardDAppControl v2RewardControl;
    TxBuilder txBuilder;
    Sig sig;

    BasicV2Solver basicV2Solver;

    function setUp() public override {
        super.setUp();

        vm.startPrank(governanceEOA);
        v2RewardControl = new V2RewardDAppControl(address(atlas), WETH_ADDRESS, V2_ROUTER);
        atlasVerification.initializeGovernance(address(v2RewardControl));
        vm.stopPrank();

        txBuilder = new TxBuilder({
            _control: address(v2RewardControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
    }

    // Swap 1 WETH for 1830 DAI
    function test_V2RewardDApp_swapWETHForDAI() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);
        // This whole test will get redone in the gas accounting update
        
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        // USER STUFF

        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(v2RewardControl));
        console.log("Execution Environment:", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        address[] memory path = new address[](2);
        path[0] = WETH_ADDRESS;
        path[1] = DAI_ADDRESS;
        bytes memory userOpData = abi.encodeCall(IUniswapV2Router01.swapExactTokensForTokens, (
            1e18, // amountIn
            0, // amountOutMin
            path, // path
            userEOA, // to
            block.timestamp + 999 // timestamp deadline
        ));

        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(v2RewardControl),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: SafeBlockNumber.get() + 555, // block deadline
            data: userOpData
        });

        // Exec Env calls swapExactTokensForTokens on Uni V2 Router directly
        userOp.dapp = V2_ROUTER;
        userOp.sessionKey = governanceEOA;

        // User signs UserOperation data
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        vm.startPrank(userEOA);
        WETH.transfer(address(1), WETH.balanceOf(userEOA) - 2e18); // Burn WETH to make logs readable
        WETH.approve(address(atlas), 1e18); // approve Atlas to take WETH for swap
        vm.stopPrank();

        // SOLVER STUFF - SOLVER NOT NEEDED IF BUNDLER (DAPP) PAYS GAS

        // vm.startPrank(solverOneEOA);
        // basicV2Solver = new BasicV2Solver(WETH_ADDRESS, address(atlas));
        // atlas.deposit{ value: 1e18 }();
        // atlas.bond(1e18);
        // vm.stopPrank();

        // bytes memory solverOpData = abi.encodeWithSelector(BasicV2Solver.backrun.selector);
        // solverOps[0] = txBuilder.buildSolverOperation({
        //     userOp: userOp,
        //     solverOpData: solverOpData,
        //     solverEOA: solverOneEOA,
        //     solverContract: address(basicV2Solver),
        //     bidAmount: 1e17, // 0.1 ETH
        //     value: 0
        // });

        // (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        // solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // DAPP STUFF
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // DApp Gov bonds AtlETH to pay gas in event of no solver
        deal(governanceEOA, 2e18);
        vm.startPrank(governanceEOA);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);
        vm.stopPrank();

        // METACALL STUFF

        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));

        vm.prank(governanceEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
    }
}

contract BasicV2Solver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function backrun() public onlySelf {
        // Backrun logic would go here
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}