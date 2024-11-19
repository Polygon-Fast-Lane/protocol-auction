// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import {AtlasEvents} from "../src/contracts/types/AtlasEvents.sol";
import {AtlasErrors} from "../src/contracts/types/AtlasErrors.sol";

contract AtlETHTest is BaseTest {

    // AtlETH Tests

    function test_atleth_deposit() public {
        uint256 totalSupplyBefore = atlas.totalSupply();
        assertEq(atlas.balanceOf(userEOA), 0, "user's atlETH balance should be 0");

        deal(userEOA, 1e18);
        vm.prank(userEOA);
        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Mint(userEOA, 1e18);
        atlas.deposit{ value: 1e18 }();

        assertEq(atlas.balanceOf(userEOA), 1e18, "user's atlETH balance should be 1 ETH");
        assertEq(atlas.totalSupply(), totalSupplyBefore + 1e18, "total atlETH supply should be 1 ETH more");
    }

    function test_atleth_withdraw() public {
        uint256 totalSupplyBefore = atlas.totalSupply();
        uint256 solverEthBalanceBefore = address(solverOneEOA).balance;
        assertEq(atlas.balanceOf(solverOneEOA), 1e18, "solverOne's atlETH balance should be 1 ETH");

        vm.prank(solverOneEOA);
        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Burn(solverOneEOA, 1e18);
        atlas.withdraw(1e18);

        assertEq(atlas.balanceOf(solverOneEOA), 0, "solverOne's atlETH balance should be 0");
        assertEq(atlas.totalSupply(), totalSupplyBefore - 1e18, "total atlETH supply should be 1 ETH less");
        assertEq(address(solverOneEOA).balance, solverEthBalanceBefore + 1e18, "solverOne's ETH balance should be 1 ETH more");

        // Testing _deduct(from, amount) within withdraw
        uint256 solverTwoAtlETH = atlas.balanceOf(solverTwoEOA);
        uint256 snapshot = vm.snapshot();

        // Test withdraw less than full AtlETH balance
        vm.prank(solverTwoEOA);
        atlas.withdraw(solverTwoAtlETH / 2);

        assertEq(atlas.balanceOf(solverTwoEOA), solverTwoAtlETH / 2, "solverTwo's atlETH balance should be half of what it was");

        // withdraw should be blocked during metacall
        vm.revertTo(snapshot);
        atlas.setLock(address(solverOneEOA), 0, 0);
        vm.startPrank(solverOneEOA);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        atlas.withdraw(1e18);
        vm.stopPrank();

        // Test withdraw 2x AtlETH balance - should revert with custom error
        vm.revertTo(snapshot);
        vm.startPrank(solverTwoEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);
        vm.expectRevert(abi.encodeWithSelector(AtlasErrors.InsufficientBalanceForDeduction.selector, 0, 2e18));
        atlas.withdraw(solverTwoAtlETH * 2);
        vm.stopPrank();

        // Test withdraw after unbonding and waiting the escrow duration
        vm.revertTo(snapshot);
        vm.startPrank(solverTwoEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);
        vm.stopPrank();

        assertEq(atlas.balanceOfUnbonding(solverTwoEOA), 1e18, "unbonding atleth should be 1 ETH");
        vm.roll(block.number + atlas.ESCROW_DURATION() + 1);
        assertEq(atlas.balanceOfUnbonding(solverTwoEOA), 1e18, "unbonding atleth should still be 1 ETH");
        solverEthBalanceBefore = address(solverTwoEOA).balance;

        vm.prank(solverTwoEOA);
        atlas.withdraw(solverTwoAtlETH);

        assertEq(atlas.balanceOf(solverTwoEOA), 0, "solverTwo's atlETH balance should be 0");
        assertEq(atlas.balanceOfUnbonding(solverTwoEOA), 0, "unbonding atleth should be 0");
        assertEq(address(solverTwoEOA).balance, solverEthBalanceBefore + 1e18, "solverTwo's ETH balance should be 1 ETH more");
    }

    function test_atleth_bond() public {
        assertEq(atlas.balanceOf(solverOneEOA), 1e18, "solverOne's atlETH balance should be 1 ETH");
        assertEq(atlas.balanceOfBonded(solverOneEOA), 0, "solverOne's bonded atlETH should be 0");
        assertEq(atlas.bondedTotalSupply(), 0, "total bonded atlETH supply should be 0");

        vm.prank(solverOneEOA);
        vm.expectRevert(); // Underflow error
        atlas.bond(2e18);

        vm.prank(solverOneEOA);
        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Bond(solverOneEOA, 1e18);
        atlas.bond(1e18);

        assertEq(atlas.balanceOf(solverOneEOA), 0, "solverOne's atlETH balance should be 0");
        assertEq(atlas.balanceOfBonded(solverOneEOA), 1e18, "solverOne's bonded atlETH should be 1 ETH");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1 ETH");
    }

    function test_atleth_depositAndBond() public {
        assertEq(atlas.balanceOf(userEOA), 0, "user's atlETH balance should be 0");
        assertEq(atlas.balanceOfBonded(userEOA), 0, "user's bonded atlETH should be 0");
        assertEq(atlas.bondedTotalSupply(), 0, "total bonded atlETH supply should be 0");

        deal(userEOA, 1e18);

        vm.prank(userEOA);
        vm.expectRevert(); // Underflow error
        atlas.depositAndBond{ value: 1e18 }(2e18);

        vm.prank(userEOA);
        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Mint(userEOA, 1e18);
        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Bond(userEOA, 1e18);
        atlas.depositAndBond{ value: 1e18 }(1e18);

        assertEq(atlas.balanceOf(userEOA), 0, "user's atlETH balance should still be 0");
        assertEq(atlas.balanceOfBonded(userEOA), 1e18, "user's bonded atlETH should be 1 ETH");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1 ETH");
    }

    function test_atleth_unbond() public {
        vm.startPrank(solverOneEOA);
        atlas.bond(1e18);

        assertEq(atlas.balanceOf(solverOneEOA), 0, "solverOne's atlETH balance should be 0");
        assertEq(atlas.balanceOfBonded(solverOneEOA), 1e18, "solverOne's bonded atlETH should be 1 ETH");
        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 0, "solverOne's unbonding atlETH should be 0");
        assertEq(atlas.accountLastActiveBlock(solverOneEOA), 0, "solverOne's last active block should be 0");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1 ETH");

        // unbond should be blocked during metacall
        atlas.setLock(address(solverOneEOA), 0, 0);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        atlas.unbond(1e18);
        atlas.clearTransientStorage();

        // Reverts if unbonding more than bonded balance
        vm.expectRevert(); // Underflow error
        atlas.unbond(2e18);

        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Unbond(solverOneEOA, 1e18, block.number + atlas.ESCROW_DURATION() + 1);
        atlas.unbond(1e18);

        // NOTE: On unbonding, individual account bonded balances decrease, but total bonded supply remains the same
        assertEq(atlas.balanceOf(solverOneEOA), 0, "solverOne's atlETH balance should be 0");
        assertEq(atlas.balanceOfBonded(solverOneEOA), 0, "solverOne's bonded atlETH should be 1 ETH");
        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 1e18, "solverOne's unbonding atlETH should be 1 ETH");
        assertEq(atlas.accountLastActiveBlock(solverOneEOA), block.number, "solverOne's last active block should be the current block");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1e18");
    }

    function test_atleth_redeem() public {
        vm.startPrank(solverOneEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);

        uint256 solverEthBefore = address(solverOneEOA).balance;
        uint256 totalSupplyBefore = atlas.totalSupply();
        assertEq(atlas.balanceOf(solverOneEOA), 0, "solverOne's atlETH balance should be 0");
        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 1e18, "solverOne's unbonding atlETH should be 1 ETH");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1 ETH");

        // redeem should be blocked during metacall
        atlas.setLock(address(solverOneEOA), 0, 0);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        atlas.redeem(1e18);
        atlas.clearTransientStorage();

        vm.expectRevert(AtlasErrors.EscrowLockActive.selector);
        atlas.redeem(1e18);

        vm.roll(block.number + atlas.ESCROW_DURATION() + 1);

        vm.expectEmit(true, true, false, true);
        emit AtlasEvents.Redeem(solverOneEOA, 1e18);
        atlas.redeem(1e18);

        assertEq(address(solverOneEOA).balance, solverEthBefore, "solverOne's ETH balance should be the same");
        assertEq(atlas.totalSupply(), totalSupplyBefore + 1e18, "total atlETH supply should be 1 ETH more");
        assertEq(atlas.balanceOf(solverOneEOA), 1e18, "solverOne's atlETH balance should be 1 ETH");
        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 0, "solverOne's unbonding atlETH should be 0");
        assertEq(atlas.bondedTotalSupply(), 0, "total bonded atlETH supply should be 0");
    }

    // View Function Tests
    
    function test_atleth_balanceOf() public {
        assertEq(atlas.balanceOf(solverOneEOA), 1e18, "solverOne's atlETH balance should be 1 ETH");
        assertEq(atlas.balanceOf(userEOA), 0, "user's atlETH balance should be 0");

        deal(userEOA, 1e18);
        vm.prank(userEOA);
        atlas.deposit{ value: 1e18 }();

        assertEq(atlas.balanceOf(userEOA), 1e18, "user's atlETH balance should now be 1 ETH");
    }

    function test_atleth_balanceOfBonded() public {
        assertEq(atlas.balanceOfBonded(solverOneEOA), 0, "solverOne's bonded atlETH starts at 0");
        assertEq(atlas.bondedTotalSupply(), 0, "total bonded atlETH supply should be 0");

        vm.prank(solverOneEOA);
        atlas.bond(1e18);

        assertEq(atlas.balanceOfBonded(solverOneEOA), 1e18, "solverOne's bonded atlETH should be 1 ETH");
        assertEq(atlas.bondedTotalSupply(), 1e18, "total bonded atlETH supply should be 1 ETH");
    }

    function test_atleth_balanceOfUnbonding() public {
        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 0, "solverOne's unbonding atlETH starts at 0");

        vm.startPrank(solverOneEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);
        vm.stopPrank();

        assertEq(atlas.balanceOfUnbonding(solverOneEOA), 1e18, "solverOne's unbonding atlETH should be 1 ETH"); 
    }

    function test_atleth_accountLastActiveBlock() public {
        assertEq(atlas.accountLastActiveBlock(solverOneEOA), 0, "solverOne's last active block should be 0");

        vm.startPrank(solverOneEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);
        vm.stopPrank();

        assertEq(atlas.accountLastActiveBlock(solverOneEOA), block.number, "solverOne's last active block should be the current block");
    }

    function test_atleth_unbondingCompleteBlock() public {
        assertEq(atlas.unbondingCompleteBlock(solverOneEOA), 0, "solverOne's unbonding complete block should be 0");

        vm.startPrank(solverOneEOA);
        atlas.bond(1e18);
        atlas.unbond(1e18);
        vm.stopPrank();

        assertEq(atlas.unbondingCompleteBlock(solverOneEOA), block.number + atlas.ESCROW_DURATION(), "solverOne's unbonding complete block should be the current block + 64");
    }
}
