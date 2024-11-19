// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { Storage } from "../src/contracts/atlas/Storage.sol";
import "../src/contracts/types/LockTypes.sol";

import { BaseTest } from "./base/BaseTest.t.sol";

contract StorageTest is BaseTest {
    using stdStorage for StdStorage;

    uint256 constant DEFAULT_SCALE = 10_000_000; // out of 10_000_000 = 100%
    uint256 constant DEFAULT_FIXED_GAS_OFFSET = 85_000;

    function setUp() public override {
        super.setUp();
    }

    // Public Constants

    function test_storage_publicConstants() public {
        assertEq(address(atlas.VERIFICATION()), address(atlasVerification), "VERIFICATION set incorrectly");
        assertEq(atlas.SIMULATOR(), address(simulator), "SIMULATOR set incorrectly");
        assertEq(atlas.ESCROW_DURATION(), DEFAULT_ESCROW_DURATION, "ESCROW_DURATION set incorrectly");

        assertEq(atlas.name(), "Atlas ETH", "name set incorrectly");
        assertEq(atlas.symbol(), "atlETH", "symbol set incorrectly");
        assertEq(atlas.decimals(), 18, "decimals set incorrectly");

        assertEq(atlas.ATLAS_SURCHARGE_RATE(), DEFAULT_ATLAS_SURCHARGE_RATE, "ATLAS_SURCHARGE_RATE set incorrectly");
        assertEq(
            atlas.BUNDLER_SURCHARGE_RATE(), DEFAULT_BUNDLER_SURCHARGE_RATE, "BUNDLER_SURCHARGE_RATE set incorrectly"
        );
        assertEq(atlas.SCALE(), DEFAULT_SCALE, "SCALE set incorrectly");
        assertEq(atlas.FIXED_GAS_OFFSET(), DEFAULT_FIXED_GAS_OFFSET, "FIXED_GAS_OFFSET set incorrectly");
    }

    // View Functions for internal storage variables

    function test_storage_view_totalSupply() public {
        uint256 depositAmount = 1e18;
        uint256 startTotalSupply = atlas.totalSupply();

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.deposit{ value: depositAmount }();

        assertEq(atlas.totalSupply(), startTotalSupply + depositAmount, "totalSupply did not increase correctly");
    }

    function test_storage_view_bondedTotalSupply() public {
        uint256 depositAmount = 1e18;
        assertEq(atlas.bondedTotalSupply(), 0, "bondedTotalSupply set incorrectly");

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.depositAndBond{ value: depositAmount }(depositAmount);

        assertEq(atlas.bondedTotalSupply(), depositAmount, "bondedTotalSupply did not increase correctly");
    }

    function test_storage_view_accessData() public {
        uint256 depositAmount = 1e18;
        (
            uint256 bonded,
            uint256 lastAccessedBlock,
            uint256 auctionWins,
            uint256 auctionFails,
            uint256 totalGasValueUsed
        ) = atlas.accessData(userEOA);

        assertEq(bonded, 0, "user bonded should start as 0");
        assertEq(lastAccessedBlock, 0, "user lastAccessedBlock should start as 0");
        assertEq(auctionWins, 0, "user auctionWins should start as 0");
        assertEq(auctionFails, 0, "user auctionFails should start as 0");
        assertEq(totalGasValueUsed, 0, "user totalGasValueUsed should start as 0");

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.depositAndBond{ value: depositAmount }(depositAmount);

        (bonded, lastAccessedBlock, auctionWins, auctionFails, totalGasValueUsed) = atlas.accessData(userEOA);

        assertEq(bonded, depositAmount, "user bonded should be equal to depositAmount");
        assertEq(lastAccessedBlock, 0, "user lastAccessedBlock should still be 0");
        assertEq(auctionWins, 0, "user auctionWins should still be 0");
        assertEq(auctionFails, 0, "user auctionFails should still be 0");
        assertEq(totalGasValueUsed, 0, "user totalGasValueUsed should still be 0");

        vm.prank(userEOA);
        atlas.unbond(depositAmount);

        (bonded, lastAccessedBlock, auctionWins, auctionFails, totalGasValueUsed) = atlas.accessData(userEOA);

        assertEq(bonded, 0, "user bonded should be 0 again");
        assertEq(lastAccessedBlock, block.number, "user lastAccessedBlock should be equal to block.number");
        assertEq(auctionWins, 0, "user auctionWins should still be 0");
        assertEq(auctionFails, 0, "user auctionFails should still be 0");
        assertEq(totalGasValueUsed, 0, "user totalGasValueUsed should still be 0");
    }

    function test_storage_view_solverOpHashes() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        bytes32 testHash = keccak256(abi.encodePacked("test"));
        assertEq(mockStorage.solverOpHashes(testHash), false, "solverOpHashes[testHash] not false");
        mockStorage.setSolverOpHash(testHash);
        assertEq(mockStorage.solverOpHashes(testHash), true, "solverOpHashes[testHash] not true");
    }

    function test_storage_view_cumulativeSurcharge() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        assertEq(mockStorage.cumulativeSurcharge(), 0, "cumulativeSurcharge not 0");
        mockStorage.setCumulativeSurcharge(100);
        assertEq(mockStorage.cumulativeSurcharge(), 100, "cumulativeSurcharge not 100");
    }

    function test_storage_view_surchargeRecipient() public {
        assertEq(atlas.surchargeRecipient(), deployer, "surchargeRecipient set incorrectly");
    }

    function test_storage_view_pendingSurchargeRecipient() public {
        assertEq(atlas.pendingSurchargeRecipient(), address(0), "pendingSurchargeRecipient should start at 0");
        vm.prank(deployer);
        atlas.transferSurchargeRecipient(userEOA);
        assertEq(atlas.pendingSurchargeRecipient(), userEOA, "pendingSurchargeRecipient should be userEOA");
    }

    // Transient Storage Getters and Setters

    function test_storage_transient_lock() public {
        (address activeEnv, uint32 callConfig, uint8 phase) = atlas.lock();

        assertEq(activeEnv, address(0), "activeEnv should start at 0");
        assertEq(callConfig, 0, "callConfig should start at 0");
        assertEq(phase, 0, "phase should start at 0");

        atlas.setLock(address(1), 2, 3);
        (activeEnv, callConfig, phase) = atlas.lock();

        assertEq(activeEnv, address(1), "activeEnv should be 1");
        assertEq(callConfig, 2, "callConfig should be 2");
        assertEq(phase, 3, "phase should be 3");

        atlas.clearTransientStorage();
        (activeEnv, callConfig, phase) = atlas.lock();

        assertEq(activeEnv, address(0), "activeEnv should be 0 again");
        assertEq(callConfig, 0, "callConfig should be 0 again");
        assertEq(phase, 0, "phase should be 0 again");
    }

    function test_storage_transient_isUnlocked() public {
        assertEq(atlas.isUnlocked(), true, "isUnlocked should start as true");

        atlas.setLock(address(1), 0, 0);
        assertEq(atlas.isUnlocked(), false, "isUnlocked should be false");

        atlas.clearTransientStorage();
        assertEq(atlas.isUnlocked(), true, "isUnlocked should be true");
    }

    function test_storage_transient_solverLockData() public {
        // MockStorage just used here to access AtlasConstants
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        (address currentSolver, bool calledBack, bool fulfilled) = atlas.solverLockData();

        assertEq(currentSolver, address(0), "currentSolver should start at 0");
        assertEq(calledBack, false, "calledBack should start as false");
        assertEq(fulfilled, false, "fulfilled should start as false");

        uint256 testSolverLock = mockStorage.SOLVER_CALLED_BACK_MASK();
        atlas.setSolverLock(testSolverLock);
        (currentSolver, calledBack, fulfilled) = atlas.solverLockData();

        assertEq(currentSolver, address(0), "currentSolver should still be 0");
        assertEq(calledBack, true, "calledBack should be true");
        assertEq(fulfilled, false, "fulfilled should still be false");

        testSolverLock = mockStorage.SOLVER_CALLED_BACK_MASK() | mockStorage.SOLVER_FULFILLED_MASK();
        atlas.setSolverLock(testSolverLock);
        (currentSolver, calledBack, fulfilled) = atlas.solverLockData();

        assertEq(currentSolver, address(0), "currentSolver should still be 0");
        assertEq(calledBack, true, "calledBack should still be true");
        assertEq(fulfilled, true, "fulfilled should be true");

        testSolverLock =
            mockStorage.SOLVER_CALLED_BACK_MASK() | mockStorage.SOLVER_FULFILLED_MASK() | uint256(uint160(userEOA));
        atlas.setSolverLock(testSolverLock);
        (currentSolver, calledBack, fulfilled) = atlas.solverLockData();

        assertEq(currentSolver, userEOA, "currentSolver should be userEOA");
        assertEq(calledBack, true, "calledBack should still be true");
        assertEq(fulfilled, true, "fulfilled should still be true");

        atlas.clearTransientStorage();
        (currentSolver, calledBack, fulfilled) = atlas.solverLockData();

        assertEq(currentSolver, address(0), "currentSolver should be 0 again");
        assertEq(calledBack, false, "calledBack should be false again");
        assertEq(fulfilled, false, "fulfilled should be false again");
    }

    function test_storage_transient_claims() public {
        assertEq(atlas.claims(), 0, "claims should start at 0");

        atlas.setClaims(100);
        assertEq(atlas.claims(), 100, "claims should be 100");

        atlas.clearTransientStorage();
        assertEq(atlas.claims(), 0, "claims should be 0 again");
    }

    function test_storage_transient_fees() public {
        assertEq(atlas.fees(), 0, "fees should start at 0");

        atlas.setFees(100);
        assertEq(atlas.fees(), 100, "fees should be 100");

        atlas.clearTransientStorage();
        assertEq(atlas.fees(), 0, "fees should be 0 again");
    }

    function test_storage_transient_writeoffs() public {
        assertEq(atlas.writeoffs(), 0, "writeoffs should start at 0");

        atlas.setWriteoffs(100);
        assertEq(atlas.writeoffs(), 100, "writeoffs should be 100");

        atlas.clearTransientStorage();
        assertEq(atlas.writeoffs(), 0, "writeoffs should be 0 again");
    }

    function test_storage_transient_withdrawals() public {
        assertEq(atlas.withdrawals(), 0, "withdrawals should start at 0");

        atlas.setWithdrawals(100);
        assertEq(atlas.withdrawals(), 100, "withdrawals should be 100");

        atlas.clearTransientStorage();
        assertEq(atlas.withdrawals(), 0, "withdrawals should be 0 again");
    }

    function test_storage_transient_deposits() public {
        assertEq(atlas.deposits(), 0, "deposits should start at 0");

        atlas.setDeposits(100);
        assertEq(atlas.deposits(), 100, "deposits should be 100");

        atlas.clearTransientStorage();
        assertEq(atlas.deposits(), 0, "deposits should be 0 again");
    }

    function test_storage_transient_solverTo() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        assertEq(mockStorage.solverTo(), address(0), "solverTo should start at 0");

        mockStorage.setSolverTo(userEOA);
        assertEq(mockStorage.solverTo(), userEOA, "solverTo should be userEOA");

        mockStorage.clearTransientStorage();
        assertEq(mockStorage.solverTo(), address(0), "solverTo should be 0 again");
    }

    function test_storage_transient_activeEnvironment() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        assertEq(mockStorage.activeEnvironment(), address(0), "activeEnvironment should start at 0");

        mockStorage.setLock(address(1), 0, 0);
        assertEq(mockStorage.activeEnvironment(), address(1), "activeEnvironment should be 1");

        mockStorage.clearTransientStorage();
        assertEq(mockStorage.activeEnvironment(), address(0), "activeEnvironment should be 0 again");
    }

    function test_storage_transient_activeCallConfig() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        assertEq(mockStorage.activeCallConfig(), 0, "activeCallConfig should start at 0");

        mockStorage.setLock(address(0), 1, 0);
        assertEq(mockStorage.activeCallConfig(), 1, "activeCallConfig should be 1");

        mockStorage.clearTransientStorage();
        assertEq(mockStorage.activeCallConfig(), 0, "activeCallConfig should be 0 again");
    }

    function test_storage_transient_phase() public {
        MockStorage mockStorage = new MockStorage(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        assertEq(mockStorage.phase(), 0, "phase should start at 0");

        mockStorage.setLock(address(0), 0, 1);
        assertEq(mockStorage.phase(), 1, "phase should be 1");

        mockStorage.clearTransientStorage();
        assertEq(mockStorage.phase(), 0, "phase should be 0 again");
    }
}

// To test solverOpHashes() and cumulativeSurcharge() view function
contract MockStorage is Storage {
    // For solverLockData test
    uint256 public constant SOLVER_CALLED_BACK_MASK = _SOLVER_CALLED_BACK_MASK;
    uint256 public constant SOLVER_FULFILLED_MASK = _SOLVER_FULFILLED_MASK;

    constructor(
        uint256 escrowDuration,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator
    )
        Storage(
            escrowDuration,
            atlasSurchargeRate,
            bundlerSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator
        )
    { }

    function setSolverOpHash(bytes32 opHash) public {
        S_solverOpHashes[opHash] = true;
    }

    function setCumulativeSurcharge(uint256 surcharge) public {
        S_cumulativeSurcharge = surcharge;
    }

    // For internal view functions without external versions

    function solverTo() public view returns (address) {
        return t_solverTo;
    }

    function setSolverTo(address newSolverTo) public {
        t_solverTo = newSolverTo;
    }

    function activeEnvironment() public view returns (address) {
        return _activeEnvironment();
    }

    function activeCallConfig() public view returns (uint32) {
        return _activeCallConfig();
    }

    function phase() public view returns (uint8) {
        return _phase();
    }

    // Setter for the above 3 view functions
    function setLock(address activeEnv, uint32 callConfig, uint8 newPhase) public {
        _setLock(activeEnv, callConfig, newPhase);
    }

    // To clear all transient storage vars
    function clearTransientStorage() public {
        _setLock(address(0), 0, 0);
        t_solverLock = 0;
        t_solverTo = address(0);
        t_claims = 0;
        t_fees = 0;
        t_writeoffs = 0;
        t_withdrawals = 0;
        t_deposits = 0;
        t_solverSurcharge = 0;
    }
}
