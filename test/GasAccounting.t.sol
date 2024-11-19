// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import { GasAccounting } from "../src/contracts/atlas/GasAccounting.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";
import { AtlasConstants } from "../src/contracts/types/AtlasConstants.sol";

import { EscrowBits } from "../src/contracts/libraries/EscrowBits.sol";
import { IL2GasCalculator } from "../src/contracts/interfaces/IL2GasCalculator.sol";

import "../src/contracts/libraries/AccountingMath.sol";
import "../src/contracts/types/EscrowTypes.sol";
import "../src/contracts/types/LockTypes.sol";
import "../src/contracts/types/SolverOperation.sol";
import "../src/contracts/types/ConfigTypes.sol";

import { ExecutionEnvironment } from "../src/contracts/common/ExecutionEnvironment.sol";

import { TestAtlas } from "./base/TestAtlas.sol";
import { BaseTest } from "./base/BaseTest.t.sol";

contract MockGasAccounting is TestAtlas, BaseTest {
    uint256 public constant MOCK_SOLVER_GAS_LIMIT = 500_000;
    
    constructor(
        uint256 _escrowDuration,
        uint256 _atlasSurchargeRate,
        uint256 _bundlerSurchargeRate,
        address _verification,
        address _simulator,
        address _surchargeRecipient,
        address _l2GasCalculator,
        address _executionTemplate
    )
        TestAtlas(_escrowDuration, _atlasSurchargeRate, _bundlerSurchargeRate, _verification, _simulator, _surchargeRecipient, _l2GasCalculator, _executionTemplate)
    { }

    /////////////////////////////////////////////////////////
    //  Expose access to internal functions for testing    //
    /////////////////////////////////////////////////////////

    function assign(address owner, uint256 amount, uint256 gasValueUsed, bool solverWon) external returns (uint256) {
        return _assign(owner, amount, gasValueUsed, solverWon);
    }

    function credit(address owner, uint256 amount, uint256 gasValueUsed) external {
        _credit(owner, amount, gasValueUsed);
    }

    function handleSolverAccounting(
        SolverOperation calldata solverOp,
        uint256 gasWaterMark,
        uint256 result,
        bool includeCalldata
    )
        external
    {
        _handleSolverAccounting(solverOp, gasWaterMark, result, includeCalldata);
    }

    function settle(Context memory ctx) external returns (uint256, uint256) {
        return _settle(ctx, MOCK_SOLVER_GAS_LIMIT, makeAddr("bundler"));
    }

    function adjustAccountingForFees(Context memory ctx)
        external
        returns (
            uint256 adjustedWithdrawals,
            uint256 adjustedDeposits,
            uint256 adjustedClaims,
            uint256 adjustedWriteoffs,
            uint256 netAtlasGasSurcharge
        )
    {
        return _adjustAccountingForFees(ctx, MOCK_SOLVER_GAS_LIMIT);
    }

    /////////////////////////////////////////////////////////
    //                 SETTERS & HELPERS                   //
    /////////////////////////////////////////////////////////

    function buildContext(
        address bundler,
        bool solverSuccessful,
        bool paymentsSuccessful,
        uint256 winningSolverIndex,
        uint256 solverCount
    )
        public
        view
        returns (Context memory ctx)
    {
        ctx = Context({
            executionEnvironment: _activeEnvironment(),
            userOpHash: bytes32(0),
            bundler: bundler,
            solverSuccessful: solverSuccessful,
            paymentsSuccessful: paymentsSuccessful,
            solverIndex: uint8(winningSolverIndex),
            solverCount: uint8(solverCount),
            phase: uint8(ExecutionPhase.PostOps),
            solverOutcome: 0,
            bidFind: false,
            isSimulation: false,
            callDepth: 0
        });
    }

    function setPhase(ExecutionPhase _phase) external {
        _setLockPhase(uint8(_phase));
    }

    function setSolverLock(address _solverFrom) external {
        t_solverLock = (uint256(uint160(_solverFrom)));
    }

    function _balanceOf(address account) external view returns (uint112, uint112) {
        return (s_balanceOf[account].balance, s_balanceOf[account].unbonding);
    }

    function initializeLock(address executionEnvironment, uint256 gasMarker) external payable {
        DAppConfig memory dConfig;
        _setEnvironmentLock(dConfig, executionEnvironment);
        _initializeAccountingValues(gasMarker);
    }

    function increaseBondedBalance(address account, uint256 amount) external {
        deal(address(this), amount);
        S_accessData[account].bonded += uint112(amount);
        S_bondedTotalSupply += amount;
    }

    function increaseUnbondingBalance(address account, uint256 amount) external {
        deal(address(this), amount);
        s_balanceOf[account].unbonding += uint112(amount);
        S_bondedTotalSupply += amount;
    }

    function initializeAccountingValues(uint256 gasMarker) external {
        _initializeAccountingValues(gasMarker);
    }

    // View functions
    function getSolverBaseGasUsed() external pure returns (uint256) {
        return _SOLVER_BASE_GAS_USED;
    }

    function getSolverOpBaseCalldata() external pure returns (uint256) {
        return _SOLVER_OP_BASE_CALLDATA;
    }

    function getCalldataCost(uint256 length) external view returns (uint256) {
        return _getCalldataCost(length);
    }

    function getActiveEnvironment() public view returns (address) {
        return _activeEnvironment();
    }

    function getCalldataLengthPremium() external pure returns (uint256) {
        return _CALLDATA_LENGTH_PREMIUM;
    }

    function getContractGasPrice() external view returns (uint256) {
        return tx.gasprice;
    }

    function getFixedGasOffset() external pure returns (uint256) {
        return AccountingMath._FIXED_GAS_OFFSET;
    }
}

contract MockGasCalculator is IL2GasCalculator, Test {
    function getCalldataCost(uint256 length) external pure returns (uint256 calldataCostETH) {
        calldataCostETH = length * 16;
    }

    function initialGasUsed(uint256 calldataLength) external pure returns (uint256 gasUsed) {
        gasUsed = calldataLength * 16;
    }
}

contract GasAccountingTest is AtlasConstants, BaseTest {
    uint256 public constant ONE_GWEI = 1e9;

    MockGasAccounting public mockGasAccounting;
    uint256 gasMarker;
    uint256 initialClaims;
    SolverOperation solverOp;
    address executionEnvironment;

    function setUp() public override {
        // Run the base setup
        super.setUp();

        // Compute expected addresses for the deployment
        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        // Initialize MockGasAccounting
        mockGasAccounting = new MockGasAccounting(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(atlasVerification),
            address(simulator),
            deployer,
            address(0),
            address(execEnvTemplate)
        );

        // Initialize TestAtlas storage slots
        initializeTestAtlasSlots();

        gasMarker = gasleft();
        mockGasAccounting.initializeLock{ value: 0 }(solverOneEOA, gasMarker);
        initialClaims = getInitialClaims(gasMarker);
        solverOp.from = solverOneEOA; // Use the solverOneEOA address from BaseTest
        solverOp.to = solverOneEOA;
        solverOp.data = abi.encodePacked("calldata");
        executionEnvironment = mockGasAccounting.getActiveEnvironment();

        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);
    }

    function setupContext(
        uint256 _initialClaims,
        uint256 deposits,
        uint256 bondedAmount,
        uint256 unbondingAmount,
        bool solverSuccessful
    )
        internal
        returns (Context memory)
    {
        gasMarker = calculateGasMarker();
        mockGasAccounting.initializeAccountingValues(gasMarker);
        mockGasAccounting.setDeposits(deposits);
        mockGasAccounting.setClaims(_initialClaims);

        mockGasAccounting.increaseBondedBalance(solverOneEOA, bondedAmount);
        mockGasAccounting.increaseUnbondingBalance(solverOneEOA, unbondingAmount);

        // Set up execution environment balance
        uint256 eeBalance = bondedAmount + unbondingAmount;
        deal(address(mockGasAccounting), eeBalance);

        // Verify the balance setup
        uint256 actualBonded = mockGasAccounting.balanceOfBonded(solverOneEOA);
        uint256 actualUnbonding = mockGasAccounting.balanceOfUnbonding(solverOneEOA);

        require(actualBonded == bondedAmount, "Bonded balance not set correctly");
        require(actualUnbonding == unbondingAmount, "Unbonding balance not set correctly");

        Context memory ctx = mockGasAccounting.buildContext(
            makeAddr("bundler"),
            solverSuccessful,
            true, // paymentsSuccessful
            0, // winningSolverIndex
            1 // solverCount
        );

        mockGasAccounting.setPhase(ExecutionPhase.SolverOperation);
        mockGasAccounting.setSolverLock(solverOneEOA);
        mockGasAccounting.setSolverTo(solverOneEOA);

        return ctx;
    }

    function initializeTestAtlasSlots() internal {
        mockGasAccounting.clearTransientStorage();
    }

    function getInitialClaims(uint256 _gasMarker) public view returns (uint256 claims) {
        uint256 rawClaims = (_gasMarker + mockGasAccounting.FIXED_GAS_OFFSET()) * tx.gasprice;
        claims = rawClaims
            * (
                mockGasAccounting.SCALE() + mockGasAccounting.ATLAS_SURCHARGE_RATE()
                    + mockGasAccounting.BUNDLER_SURCHARGE_RATE()
            ) / mockGasAccounting.SCALE();
    }

    function calculateGasMarker() internal view returns (uint256) {
        return gasleft() + mockGasAccounting.getSolverBaseGasUsed() + mockGasAccounting.getCalldataCost(msg.data.length);
    }

    function fundContract(uint256 amount) internal {
        // Fund the contract with enough ETH
        deal(address(mockGasAccounting), amount);
        // Verify the contract has sufficient balance
        assertEq(address(mockGasAccounting).balance, amount, "Contract should have enough ETH balance");
    }

    function test_contribute_withInvalidExecutionEnvironment_revert() public {
        // Expect revert when contribute is called without the proper setup
        vm.expectRevert(abi.encodeWithSelector(AtlasErrors.InvalidExecutionEnvironment.selector, address(0)));
        mockGasAccounting.contribute();
    }

    function test_contribute() public {
        // Set up the environment for a valid contribute call
        uint256 contributeValue = 1000;
        deal(executionEnvironment, contributeValue);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));

        // Perform the valid contribute call
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: contributeValue }();

        // Verify the balances after contribution
        assertEq(address(mockGasAccounting).balance, contributeValue);
        assertEq(mockGasAccounting.deposits(), contributeValue);
    }

    function test_multipleContributes() public {
        // Set up the environment for multiple valid contribute calls
        uint256 firstContributeValue = 1000;
        uint256 secondContributeValue = 1500;
        uint256 totalContributeValue = firstContributeValue + secondContributeValue;

        deal(executionEnvironment, firstContributeValue + secondContributeValue);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));

        // Perform the first valid contribute call
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: firstContributeValue }();

        // Verify the balances after the first contribution
        assertEq(address(mockGasAccounting).balance, firstContributeValue);
        assertEq(mockGasAccounting.deposits(), firstContributeValue);

        // Perform the second valid contribute call
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: secondContributeValue }();

        // Verify the balances after the second contribution
        assertEq(address(mockGasAccounting).balance, totalContributeValue);
        assertEq(mockGasAccounting.deposits(), totalContributeValue);
    }

    function test_contribute_withZeroValue() public {
        // Set up the environment for the first valid contribute call
        uint256 contributeValue = 0;
        deal(executionEnvironment, contributeValue);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));

        // Perform the first valid contribute call
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: contributeValue }();

        // Verify the balances after the contribution is zero
        assertEq(address(mockGasAccounting).balance, contributeValue);
        assertEq(mockGasAccounting.deposits(), contributeValue);
    }

    function test_borrow_preOpsPhase() public {
        uint256 borrowedAmount = 1e18;

        fundContract(borrowedAmount);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));

        vm.prank(executionEnvironment);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(
            solverOneEOA.balance, borrowedAmount, "Execution environment balance should be equal to borrowed amount"
        );
        assertEq(borrowedAmount, mockGasAccounting.withdrawals(), "Withdrawals should be equal to borrowed amount");
    }

    function test_borrow_userOperationPhase() public {
        uint256 borrowedAmount = 1e18;

        fundContract(borrowedAmount);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.UserOperation));
        vm.prank(executionEnvironment);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(
            executionEnvironment.balance,
            borrowedAmount,
            "Execution environment balance should be equal to borrowed amount"
        );
        assertEq(borrowedAmount, mockGasAccounting.withdrawals(), "Withdrawals should be equal to borrowed amount");
    }

    function test_borrow_preSolverPhase() public {
        uint256 borrowedAmount = 1e18;

        fundContract(borrowedAmount);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreSolver));
        vm.prank(executionEnvironment);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(
            executionEnvironment.balance,
            borrowedAmount,
            "Execution environment balance should be equal to borrowed amount"
        );
        assertEq(borrowedAmount, mockGasAccounting.withdrawals(), "Withdrawals should be equal to borrowed amount");
    }

    function test_borrow_solverOperationPhase() public {
        uint256 borrowedAmount = 1e18;

        fundContract(borrowedAmount);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));
        vm.prank(executionEnvironment);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(
            executionEnvironment.balance,
            borrowedAmount,
            "Execution environment balance should be equal to borrowed amount"
        );
        assertEq(borrowedAmount, mockGasAccounting.withdrawals(), "Withdrawals should be equal to borrowed amount");
    }

    function test_borrow_postSolverPhase_reverts() public {
        uint256 borrowedAmount = 1e18;
        uint256 withdrawalsBefore = mockGasAccounting.withdrawals();
        fundContract(borrowedAmount);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PostSolver));
        vm.prank(executionEnvironment);
        vm.expectRevert(AtlasErrors.WrongPhase.selector);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(executionEnvironment.balance, 0, "Execution environment balance should remain zero");
        assertEq(withdrawalsBefore, mockGasAccounting.withdrawals(), "Withdrawals should remain unchanged");
    }

    function test_borrow_allocateValuePhase_reverts() public {
        uint256 borrowedAmount = 1e18;
        uint256 withdrawalsBefore = mockGasAccounting.withdrawals();
        fundContract(borrowedAmount);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.AllocateValue));
        vm.prank(executionEnvironment);
        vm.expectRevert(AtlasErrors.WrongPhase.selector);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(executionEnvironment.balance, 0, "Execution environment balance should remain zero");
        assertEq(withdrawalsBefore, mockGasAccounting.withdrawals(), "Withdrawals should remain unchanged");
    }

    function test_borrow_postOpsPhase_reverts() public {
        uint256 borrowedAmount = 1e18;
        uint256 withdrawalsBefore = mockGasAccounting.withdrawals();
        fundContract(borrowedAmount);

        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PostOps));
        vm.prank(executionEnvironment);
        vm.expectRevert(AtlasErrors.WrongPhase.selector);
        mockGasAccounting.borrow(borrowedAmount);

        assertEq(executionEnvironment.balance, 0, "Execution environment balance should remain zero");
        assertEq(withdrawalsBefore, mockGasAccounting.withdrawals(), "Withdrawals should remain unchanged");
    }

    function test_multipleBorrows() public {
        uint256 atlasBalance = 100 ether;
        uint256 borrow1 = 75 ether;
        uint256 borrow2 = 10 ether;
        uint256 borrow3 = 15 ether;

        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));

        // Fund the contract with enough ETH (initial claims + total borrow amount)
        uint256 totalBorrowAmount = borrow1 + borrow2 + borrow3;
        deal(address(mockGasAccounting), initialClaims + atlasBalance);

        // Verify the contract has sufficient balance before borrowing
        assertEq(
            address(mockGasAccounting).balance, initialClaims + atlasBalance, "Contract should have enough ETH balance"
        );

        // Set the phase to an allowed phase for borrowing
        mockGasAccounting.setPhase(ExecutionPhase.PreOps);

        // Start borrowing operations
        vm.startPrank(executionEnvironment);
        mockGasAccounting.borrow(borrow1);
        assertEq(
            executionEnvironment.balance,
            borrow1,
            "Execution environment balance should equal borrow1 after first borrow"
        );

        mockGasAccounting.borrow(borrow2);
        assertEq(
            executionEnvironment.balance,
            borrow1 + borrow2,
            "Execution environment balance should equal borrow1 + borrow2 after second borrow"
        );

        mockGasAccounting.borrow(borrow3);
        assertEq(
            executionEnvironment.balance,
            borrow1 + borrow2 + borrow3,
            "Execution environment balance should equal borrow1 + borrow2 + borrow3 after third borrow"
        );
        vm.stopPrank();

        // Verify the final balance of the execution environment
        assertEq(
            executionEnvironment.balance,
            borrow1 + borrow2 + borrow3,
            "Final execution environment balance should equal total borrowed amount"
        );

        // Verify the final balance of the contract
        uint256 expectedFinalContractBalance = initialClaims + atlasBalance - totalBorrowAmount;
        assertEq(
            address(mockGasAccounting).balance,
            expectedFinalContractBalance,
            "Final contract balance should be initial balance minus total borrowed amount"
        );
        assertEq(
            totalBorrowAmount, mockGasAccounting.withdrawals(), "Withdrawals should equal total borrowed amount"
        );
    }

    function test_shortfall_initialClaimsAndContribution() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Set initial claims in the contract
        initialClaims = 1000;
        mockGasAccounting.setClaims(initialClaims);

        // Verify initial shortfall
        assertEq(mockGasAccounting.shortfall(), initialClaims, "Initial shortfall should be equal to initial claims");

        // Contribute to the contract
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));
        deal(executionEnvironment, initialClaims);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: initialClaims }();

        // Verify shortfall after contribution
        assertEq(mockGasAccounting.shortfall(), 0, "Shortfall should be zero after contribution");
    }

    function test_shortfall_claimsAndWithdrawals() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Set initial claims and withdrawals in the contract
        initialClaims = 1000;
        uint256 withdrawals = 500;
        mockGasAccounting.setClaims(initialClaims);
        mockGasAccounting.setWithdrawals(withdrawals);

        // Verify initial shortfall
        uint256 expectedShortfall = initialClaims + withdrawals;
        assertEq(
            mockGasAccounting.shortfall(), expectedShortfall, "Initial shortfall should be claims plus withdrawals"
        );

        // Contribute to the contract
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));
        deal(executionEnvironment, expectedShortfall);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: expectedShortfall }();

        // Verify shortfall after contribution
        assertEq(mockGasAccounting.shortfall(), 0, "Shortfall should be zero after contribution");
    }

    function test_shortfall_claimsAndFees() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Set initial claims and fees in the contract
        initialClaims = 1000;
        uint256 fees = 200;
        mockGasAccounting.setClaims(initialClaims);
        mockGasAccounting.setFees(fees);

        // Verify initial shortfall
        uint256 expectedShortfall = initialClaims + fees;
        assertEq(mockGasAccounting.shortfall(), expectedShortfall, "Initial shortfall should be claims plus fees");

        // Contribute to the contract
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));
        deal(executionEnvironment, expectedShortfall);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: expectedShortfall }();

        // Verify shortfall after contribution
        assertEq(mockGasAccounting.shortfall(), 0, "Shortfall should be zero after contribution");
    }

    function test_shortfall_claimsAndWriteoffs() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Set initial claims and writeoffs in the contract
        initialClaims = 1000;
        uint256 writeoffs = 300;
        mockGasAccounting.setClaims(initialClaims);
        mockGasAccounting.setWriteoffs(writeoffs);

        // Verify initial shortfall
        uint256 expectedShortfall = initialClaims - writeoffs;
        assertEq(mockGasAccounting.shortfall(), expectedShortfall, "Initial shortfall should be claims minus writeoffs");

        // Contribute to the contract
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));
        deal(executionEnvironment, expectedShortfall);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: expectedShortfall }();

        // Verify shortfall after contribution
        assertEq(mockGasAccounting.shortfall(), 0, "Shortfall should be zero after contribution");
    }

    function test_shortfall_claimsAndDeposits() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Set initial claims and deposits in the contract
        initialClaims = 1000;
        uint256 deposits = 500;
        mockGasAccounting.setClaims(initialClaims);
        mockGasAccounting.setDeposits(deposits);

        // Verify initial shortfall
        uint256 expectedShortfall = initialClaims - deposits;
        assertEq(mockGasAccounting.shortfall(), expectedShortfall, "Initial shortfall should be claims minus deposits");

        // Contribute to the contract
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.PreOps));
        deal(executionEnvironment, expectedShortfall);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: expectedShortfall }();

        // Verify shortfall after contribution
        assertEq(mockGasAccounting.shortfall(), 0, "Shortfall should be zero after contribution");
    }

    function test_reconcile_initializeClaimsAndDeposits() public {
        // Set initial claims and deposits
        mockGasAccounting.setClaims(10 ether);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.UserOperation));

        deal(executionEnvironment, 10 ether);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: 10 ether }();

        assertEq(mockGasAccounting.claims(), 10 ether, "Claims should be set to 10 ether");
        assertEq(address(mockGasAccounting).balance, 10 ether, "mockGasAccounting should have 10 ether");
    }

    function test_reconcile_withWrongPhase_reverts() public {
        // Set initial claims and deposits
        mockGasAccounting.setClaims(10 ether);
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.UserOperation));

        deal(executionEnvironment, 10 ether);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: 10 ether }();

        // Expect revert if called in the wrong phase
        vm.expectRevert(AtlasErrors.WrongPhase.selector);
        mockGasAccounting.reconcile(0);
    }

    function test_reconcile_invalidAccess_reverts() public {
        // Set phase to SolverOperation and set solver lock
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));
        mockGasAccounting.setSolverTo(solverOneEOA);

        // Ensure bonded balance is set
        mockGasAccounting.increaseBondedBalance(solverOneEOA, 10 ether);

        // Expect revert if called by the wrong address
        vm.expectRevert(AtlasErrors.InvalidAccess.selector);
        mockGasAccounting.reconcile(0);
    }

    function test_reconcile_withCorrectAddress() public {
        // Set initial claims and deposits
        mockGasAccounting.setClaims(20 ether); // Increased claims to ensure deductions are higher
        mockGasAccounting.setLock(executionEnvironment, 0, uint8(ExecutionPhase.SolverOperation));
        deal(executionEnvironment, 10 ether);
        vm.prank(executionEnvironment);
        mockGasAccounting.contribute{ value: 10 ether }();

        mockGasAccounting.setSolverTo(executionEnvironment);

        // Ensure bonded balance is set
        mockGasAccounting.increaseBondedBalance(executionEnvironment, 10 ether);

        // Call reconcile with the correct execution environment
        vm.prank(executionEnvironment);
        uint256 result = mockGasAccounting.reconcile(5 ether);
        assertTrue(result > 0, "Reconcile should return a value greater than zero");
    }

    function test_reconcileWithoutETH() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Fund the contract initially
        initialClaims = 1000;
        mockGasAccounting.setDeposits(initialClaims);

        // Set phase to SolverOperation and set solver lock
        mockGasAccounting.setPhase(ExecutionPhase.SolverOperation);
        mockGasAccounting.setSolverLock(solverOneEOA);
        mockGasAccounting.setSolverTo(solverOneEOA);

        // Call reconcile without sending additional ETH
        vm.prank(solverOneEOA);
        assertTrue(mockGasAccounting.reconcile(0) == 0, "Reconcile should return zero");

        // Verify solver lock data
        (address currentSolver, bool verified, bool fulfilled) = mockGasAccounting.solverLockData();
        assertTrue(fulfilled, "Solver should be fulfilled");
        assertTrue(verified, "Solver should be verified");
        assertEq(currentSolver, solverOneEOA, "Current solver should match execution environment");

        // Verify that deposits did not increase
        assertEq(mockGasAccounting.deposits(), initialClaims, "Deposits should remain unchanged");
    }

    function test_reconcileWithETH() public {
        // Ensure the execution environment starts with zero balance
        deal(executionEnvironment, 0);

        // Fund the execution environment to allow reconciliation
        initialClaims = 1000;
        deal(executionEnvironment, initialClaims);

        // Set phase to SolverOperation and set solver lock
        mockGasAccounting.setPhase(ExecutionPhase.SolverOperation);
        mockGasAccounting.setSolverLock(solverOneEOA);
        mockGasAccounting.setSolverTo(solverOneEOA);

        // Call reconcile with the correct execution environment and ETH sent as msg.value
        vm.prank(solverOneEOA);
        assertTrue(mockGasAccounting.reconcile{ value: initialClaims }(0) == 0, "Reconcile should return zero");

        // Verify solver lock data
        (address currentSolver, bool verified, bool fulfilled) = mockGasAccounting.solverLockData();
        assertTrue(fulfilled, "Solver should be fulfilled");
        assertTrue(verified, "Solver should be verified");
        assertEq(currentSolver, solverOneEOA, "Current solver should match execution environment");

        // Verify that deposits increased by the reconciled amount
        assertEq(mockGasAccounting.deposits(), initialClaims, "Deposits should match the amount sent as msg.value");
    }

    function test_assign_zeroAmount() public {
        vm.skip(true);
        // the gas amount param passed to _assign() can never be zero in Atlas core contracts.
        // _assign() is called in 2 places:
        // 1. in _handleSolverAccounting() where the amount is explicitly checked and will return before calling
        // _assign() if the gasUsed amount is zero.
        // 2. in _settle() where the amount is calculated as (_amountSolverPays - _amountSolverReceives) and only
        // done when _amountSolverPays > _amountSolverReceives, so that amount is always greater than zero.
    }

    function test_assign_sufficientBondedBalance() public {
        uint256 assignedAmount = 1000;
        uint256 initialBondedAmount = assignedAmount * 3;

        // Initialize bonded balance
        mockGasAccounting.increaseBondedBalance(solverOp.from, initialBondedAmount);

        // Get initial values
        uint256 bondedTotalSupplyBefore = mockGasAccounting.bondedTotalSupply();
        uint256 depositsBefore = mockGasAccounting.deposits();

        uint256 deficit = mockGasAccounting.assign(solverOp.from, assignedAmount, assignedAmount, true);
        assertEq(deficit, 0, "Deficit should be 0");

        (, uint32 lastAccessedBlock,,,) = mockGasAccounting.accessData(solverOp.from);
        assertEq(lastAccessedBlock, uint32(block.number));

        uint256 bondedTotalSupplyAfter = mockGasAccounting.bondedTotalSupply();
        uint256 depositsAfter = mockGasAccounting.deposits();

        assertEq(bondedTotalSupplyAfter, bondedTotalSupplyBefore - assignedAmount);
        assertEq(depositsAfter, depositsBefore + assignedAmount);
    }

    function test_assign_insufficientBondedSufficientUnbonding() public {
        uint256 assignedAmount = 1000;
        uint256 unbondingAmount = assignedAmount * 2; // 2000
        uint256 bondedAmount = assignedAmount / 2; // 500

        // Set up initial balances
        mockGasAccounting.increaseUnbondingBalance(solverOp.from, unbondingAmount); // Set unbonding balance to 2000
        mockGasAccounting.increaseBondedBalance(solverOp.from, bondedAmount); // Set bonded balance to 500

        uint256 bondedTotalSupplyBefore = mockGasAccounting.bondedTotalSupply();
        uint256 depositsBefore = mockGasAccounting.deposits();

        // Call the assign function and capture the deficit
        uint256 deficit = mockGasAccounting.assign(solverOp.from, assignedAmount, assignedAmount, true);
        assertEq(deficit, 0, "Deficit should be 0");

        // Retrieve and check the updated access data
        (, uint32 lastAccessedBlock,,,) = mockGasAccounting.accessData(solverOp.from);
        assertEq(lastAccessedBlock, uint32(block.number), "Last accessed block should be current block");

        // Check the updated bonded total supply and deposits
        assertEq(
            mockGasAccounting.bondedTotalSupply(),
            bondedTotalSupplyBefore - assignedAmount,
            "Bonded total supply mismatch"
        );
        assertEq(mockGasAccounting.deposits(), depositsBefore + assignedAmount, "Deposits mismatch");

        // Retrieve and check the updated balances
        (uint112 bonded, uint112 unbonding) = mockGasAccounting._balanceOf(solverOp.from);
        uint256 expectedUnbonding = uint112(unbondingAmount - (assignedAmount - bondedAmount));
        assertEq(unbonding, expectedUnbonding, "Unbonding balance mismatch");
        assertEq(bonded, 0, "Bonded balance mismatch");
    }

    function test_assign_insufficientBondedAndUnbonding() public {
        uint256 assignedAmount = 1000;
        uint256 unbondingAmount = assignedAmount / 2;
        uint256 bondedAmount = assignedAmount / 4;

        mockGasAccounting.increaseUnbondingBalance(solverOp.from, unbondingAmount);
        mockGasAccounting.increaseBondedBalance(solverOp.from, bondedAmount);

        uint256 bondedTotalSupplyBefore = mockGasAccounting.bondedTotalSupply();
        uint256 depositsBefore = mockGasAccounting.deposits();
        uint256 deficit = mockGasAccounting.assign(solverOp.from, assignedAmount, assignedAmount, true);
        assertEq(deficit, assignedAmount - (unbondingAmount + bondedAmount));
        (, uint32 lastAccessedBlock,,,) = mockGasAccounting.accessData(solverOp.from);
        assertEq(lastAccessedBlock, uint32(block.number));
        assertEq(mockGasAccounting.bondedTotalSupply(), bondedTotalSupplyBefore - (unbondingAmount + bondedAmount));
        assertEq(mockGasAccounting.deposits(), depositsBefore + (unbondingAmount + bondedAmount));
        (uint112 bonded, uint112 unbonding) = mockGasAccounting._balanceOf(solverOp.from);
        assertEq(unbonding, 0);
        assertEq(bonded, 0);
    }

    function test_assign_reputationAnalytics() public {
        // NOTE: the `amount` and `gasValueUsed` params for `_assign()` should be measured in ETH value. I.e. they should be calculated as `gasUsed * tx.gasprice`.
        uint256 startGasPrice = 2e9;
        uint256 endGasPrice = 4e9;
        
        uint256 gasUsedAmount = 1_234_567;
        uint256 assignedAmount;
        uint24 auctionWins;
        uint24 auctionFails;
        uint64 totalGasValueUsed;
        uint256 expectedTotalGasValueUsed;

        mockGasAccounting.increaseBondedBalance(solverOp.from, 100e18);
        (,, auctionWins, auctionFails, totalGasValueUsed) = mockGasAccounting.accessData(solverOp.from);
        assertEq(auctionWins, 0, "auctionWins should start at 0");
        assertEq(auctionFails, 0, "auctionFails should start at 0");
        assertEq(totalGasValueUsed, 0, "totalGasValueUsed should start at 0");

        vm.txGasPrice(startGasPrice); // Set gas price to 2e9
        assertEq(tx.gasprice, startGasPrice, "tx.gasprice should be 2e9");
        assignedAmount = gasUsedAmount * tx.gasprice;
        mockGasAccounting.assign({
            owner: solverOp.from,
            amount: assignedAmount,
            gasValueUsed: assignedAmount,
            solverWon: true
        });

        (,, auctionWins, auctionFails, totalGasValueUsed) = mockGasAccounting.accessData(solverOp.from);
        expectedTotalGasValueUsed = assignedAmount / ONE_GWEI;
        assertEq(auctionWins, 1, "auctionWins should be incremented by 1");
        assertEq(auctionFails, 0, "auctionFails should remain at 0");
        assertEq(totalGasValueUsed, expectedTotalGasValueUsed, "totalGasValueUsed not as expected");

        vm.txGasPrice(endGasPrice); // Set gas price to 4e9
        assertEq(tx.gasprice, endGasPrice, "tx.gasprice should be 4e9");
        assignedAmount = gasUsedAmount * tx.gasprice;
        mockGasAccounting.assign({
            owner: solverOp.from,
            amount: assignedAmount,
            gasValueUsed: assignedAmount,
            solverWon: false
        });

        (,, auctionWins, auctionFails, totalGasValueUsed) = mockGasAccounting.accessData(solverOp.from);
        expectedTotalGasValueUsed += assignedAmount / ONE_GWEI;
        assertEq(auctionWins, 1, "auctionWins should remain at 1");
        assertEq(auctionFails, 1, "auctionFails should be incremented by 1");
        assertEq(totalGasValueUsed, expectedTotalGasValueUsed, "totalGasValueUsed not as expected");
    }

    function test_assign_overflow_reverts() public {
        uint256 bondedAmount = uint256(type(uint112).max) + 1e18;
        uint256 assignedAmount = uint256(type(uint112).max) + 1;

        mockGasAccounting.increaseBondedBalance(solverOp.from, bondedAmount);
        uint256 bondedTotalSupplyBefore = mockGasAccounting.bondedTotalSupply();
        uint256 depositsBefore = mockGasAccounting.deposits();
        (uint112 unbondingBefore,) = mockGasAccounting._balanceOf(solverOp.from);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 112, assignedAmount));
        mockGasAccounting.assign(solverOp.from, assignedAmount, assignedAmount, true);

        // Check assign reverted with overflow, and accounting values did not change
        assertEq(mockGasAccounting.bondedTotalSupply(), bondedTotalSupplyBefore);
        assertEq(mockGasAccounting.deposits(), depositsBefore);
        (uint112 unbonding,) = mockGasAccounting._balanceOf(solverOp.from);
        assertEq(unbonding, unbondingBefore);
    }

    function test_credit() public {
        uint256 creditedAmount = 10_000;
        uint256 lastAccessedBlock;

        uint256 bondedTotalSupplyBefore = mockGasAccounting.bondedTotalSupply();
        uint256 withdrawalsBefore = mockGasAccounting.withdrawals();
        (uint112 bondedBefore,,,,) = mockGasAccounting.accessData(solverOp.from);
        (, lastAccessedBlock,,,) = mockGasAccounting.accessData(solverOp.from);
        assertEq(lastAccessedBlock, 0);

        mockGasAccounting.credit(solverOp.from, creditedAmount, creditedAmount);

        (, lastAccessedBlock,,,) = mockGasAccounting.accessData(solverOp.from);
        (uint112 bondedAfter,,,,) = mockGasAccounting.accessData(solverOp.from);

        assertEq(lastAccessedBlock, uint32(block.number));
        assertEq(mockGasAccounting.bondedTotalSupply(), bondedTotalSupplyBefore + creditedAmount);
        assertEq(bondedAfter, bondedBefore + uint112(creditedAmount));
        assertEq(mockGasAccounting.withdrawals(), withdrawalsBefore + creditedAmount);

        // Testing uint112 boundary values for casting from uint256 to uint112 in _credit()
        uint256 overflowAmount = uint256(type(uint112).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 112, overflowAmount));
        mockGasAccounting.credit(solverOp.from, overflowAmount, overflowAmount);
    }

    function test_handleSolverAccounting_solverNotResponsible() public {
        // Setup
        solverOp.data = "";
        uint256 gasWaterMark = gasleft() + 5000;
        uint256 initialWriteoffs = mockGasAccounting.writeoffs();

        // Simulate solver not responsible for failure
        uint256 result = EscrowBits._NO_REFUND;

        // NOTE: This is a hack to get the correct gasUsed value will break on setup changes or code changes before
        // handleSolverAccounting is called
        uint256 gasUsedOffset = 7_073_419_500_000_000; //difference between _gasUsed

        // Recalculate expected writeoffs
        uint256 gasUsed =
            (gasWaterMark + mockGasAccounting.getSolverBaseGasUsed() - gasleft()) * tx.gasprice + gasUsedOffset;
        mockGasAccounting.handleSolverAccounting(solverOp, gasWaterMark, result, false);

        uint256 expectedWriteoffs = initialWriteoffs + AccountingMath.withSurcharges(gasUsed, DEFAULT_ATLAS_SURCHARGE_RATE, DEFAULT_BUNDLER_SURCHARGE_RATE);
        // Verify writeoffs have increased
        assertApproxEqRel(
            mockGasAccounting.writeoffs(),
            expectedWriteoffs,
            1e15, // 0.1% margin for error
            "Writeoffs should be approximately equal to expected value"
        );
    }

    function test_handleSolverAccounting_solverResponsible() public {
        // Setup
        solverOp.data = ""; // no calldata
        uint256 gasWaterMark = gasleft() + 5000;
        uint256 initialBondedBalance = 1000 ether;
        uint256 unbondingAmount = 500 ether;

        // Set up initial balances
        mockGasAccounting.increaseBondedBalance(solverOp.from, initialBondedBalance);
        mockGasAccounting.increaseUnbondingBalance(solverOp.from, unbondingAmount); // Set unbonding balance

        // Simulate solver responsible for failure
        uint256 result = EscrowBits._FULL_REFUND;

        // Perform the operation
        (uint112 unbondingBefore,) = mockGasAccounting._balanceOf(solverOp.from);

        mockGasAccounting.handleSolverAccounting(solverOp, gasWaterMark, result, false);
        // Verify bonded balance has decreased
        (uint112 unbonding,) = mockGasAccounting._balanceOf(solverOp.from);
        assertEq(unbonding, unbondingBefore);
    }

    function test_handleSolverAccounting_includingCalldata() public {
        // Setup
        solverOp.data = abi.encodePacked("calldata");
        uint256 gasWaterMark = gasleft() + 5000;
        uint256 initialBondedBalance = 1000 ether;
        uint256 unbondingAmount = 500 ether;

        // Set up initial balances
        mockGasAccounting.increaseBondedBalance(solverOp.from, initialBondedBalance);
        mockGasAccounting.increaseUnbondingBalance(solverOp.from, unbondingAmount); // Set unbonding balance

        // Perform the operation
        (uint112 unbondingBefore,) = mockGasAccounting._balanceOf(solverOp.from);

        // Simulate solver responsible for failure including calldata
        uint256 result = EscrowBits._FULL_REFUND;

        mockGasAccounting.handleSolverAccounting(solverOp, gasWaterMark, result, true);

        // Verify bonded balance has decreased
        (uint112 unbonding,) = mockGasAccounting._balanceOf(solverOp.from);
        assertEq(unbonding, unbondingBefore);
    }

    function test_settle_with_deposits() public {
        Context memory ctx = setupContext(1 ether, 0.5 ether, 4000 ether, 1000 ether, true);
        // Check initial balances
        uint256 initialEEBalance = address(mockGasAccounting).balance;
        uint256 initialBonded = mockGasAccounting.balanceOfBonded(solverOneEOA);
        uint256 initialUnbonding = mockGasAccounting.balanceOfUnbonding(solverOneEOA);
        {
            require(initialBonded > 0, "Initial solver bonded balance should be non-zero");
            require(initialUnbonding > 0, "Initial solver unbonding balance should be non-zero");
        }

        // Perform settlement
        (uint256 claimsPaidToBundler, uint256 netGasSurcharge) = mockGasAccounting.settle(ctx);

        // Check final balances and perform assertions
        uint256 finalClaims = mockGasAccounting.claims();
        uint256 finalBonded = mockGasAccounting.balanceOfBonded(solverOneEOA);
        uint256 finalUnbonding = mockGasAccounting.balanceOfUnbonding(solverOneEOA);
        {
            uint256 finalEEBalance = address(mockGasAccounting).balance;

            assertTrue(claimsPaidToBundler > 0, "Claims paid to bundler should be non-zero");
            assertTrue(netGasSurcharge > 0, "Net gas surcharge should be non-zero");
            assertLe(
                finalClaims, 1.5 ether, "Final claims should be less than or equal to initial claims plus deposits"
            );

            uint256 totalCost = claimsPaidToBundler + netGasSurcharge;
            uint256 initialSolverTotalBalance = initialBonded + initialUnbonding;

            assertGe(
                initialSolverTotalBalance,
                totalCost,
                "Initial solver total balance should be sufficient to cover all payments"
            );

            uint256 finalSolverTotalBalance = finalBonded + finalUnbonding;
            uint256 actualSolverBalanceDecrease = initialSolverTotalBalance - finalSolverTotalBalance;

            assertApproxEqAbs(
                actualSolverBalanceDecrease,
                totalCost,
                1.5 ether,
                "Solver balance decrease should approximately match total payments"
            );

            assertApproxEqAbs(
                finalEEBalance, initialEEBalance, claimsPaidToBundler, "EE balance should not change during settlement"
            );
        }
    }

    function test_settle_with_multiple_solvers() public {
        Context memory ctx = setupContext(2 ether, 1 ether, 4000 ether, 1000 ether, true);
        ctx.solverCount = 3;
        ctx.solverIndex = 1;
        (uint256 claimsPaidToBundler, uint256 netGasSurcharge) = mockGasAccounting.settle(ctx);

        assertTrue(claimsPaidToBundler > 0, "Claims paid to bundler should be non-zero");
        assertTrue(netGasSurcharge > 0, "Net gas surcharge should be non-zero");
        assertLe(
            mockGasAccounting.claims(),
            3 ether,
            "Final claims should be less than or equal to initial claims plus deposits"
        );
    }

    function test_l2GasCalculatorCall() public {
        IL2GasCalculator gasCalculator = new MockGasCalculator();
        MockGasAccounting mockL2GasAccounting = new MockGasAccounting(
            DEFAULT_ESCROW_DURATION,
            DEFAULT_ATLAS_SURCHARGE_RATE,
            DEFAULT_BUNDLER_SURCHARGE_RATE,
            address(atlasVerification),
            address(simulator),
            deployer,
            address(gasCalculator),
            address(0)
        );

        assertEq(mockL2GasAccounting.getCalldataCost(100), (100 + mockL2GasAccounting.getSolverOpBaseCalldata()) * 16);
    }
}