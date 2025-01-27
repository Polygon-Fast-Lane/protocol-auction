// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IAtlas } from "src/contracts/interfaces/IAtlas.sol";
import { IDAppControl } from "src/contracts/interfaces/IDAppControl.sol";
import { AtlasEvents } from "src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "src/contracts/types/AtlasErrors.sol";
import { CallBits } from "src/contracts/libraries/CallBits.sol";
import { EscrowBits } from "src/contracts/libraries/EscrowBits.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";

import { DummyDAppControl } from "./base/DummyDAppControl.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./base/builders/DAppOperationBuilder.sol";
import { GasSponsorDAppControl } from "./base/GasSponsorDAppControl.sol";

import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/SolverOperation.sol";
import "src/contracts/types/DAppOperation.sol";
import "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/EscrowTypes.sol";

contract EscrowTest is BaseTest {
    using CallBits for CallConfig;

    DummyDAppControl dAppControl;
    DummySolver dummySolver;
    uint256 defaultBidAmount = 1;
    bytes4 noError = 0;
    address invalid = makeAddr("invalid");

    uint256 private constant _SOLVER_GAS_LIMIT = 1_000_000;
    uint256 private constant _VALIDATION_GAS_LIMIT = 500_000;
    uint256 private constant _SOLVER_GAS_BUFFER = 5; // out of 100
    uint256 private constant _FASTLANE_GAS_BUFFER = 125_000; // integer amount

    event MEVPaymentSuccess(address bidToken, uint256 bidAmount);
    event SolverTxResult(
        address indexed solverTo, address indexed solverFrom, bool executed, bool success, uint256 result
    );

    function defaultCallConfig() public returns (CallConfigBuilder) {
        return new CallConfigBuilder();
    }

    function defaultDAppControl() public returns (DummyDAppControlBuilder) {
        return new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(defaultCallConfig().build());
    }

    function validUserOperation(address _control) public returns (UserOperationBuilder) {
        return new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(SafeBlockNumber.get() + 2)
            .withDapp(_control)
            .withControl(_control)
            .withCallConfig(IDAppControl(_control).CALL_CONFIG())
            .withSessionKey(address(0))
            .withData("")
            .sign(address(atlasVerification), userPK);
    }

    function validSolverOperation(UserOperation memory userOp) public returns (SolverOperationBuilder) {
        return new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(dummySolver))
            .withControl(userOp.control)
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(0)
            .withData("")
            .sign(address(atlasVerification), solverOnePK);
    }

    function validDAppOperation(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps
    )
        public
        returns (DAppOperationBuilder)
    {
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK);
    }

    function defaultAtlasWithCallConfig(CallConfig memory callConfig) public {
        dAppControl = defaultDAppControl().withCallConfig(callConfig).buildAndIntegrate(atlasVerification);
    }

    function setUp() public override {
        super.setUp();

        deal(solverOneEOA, 1 ether);

        vm.startPrank(solverOneEOA);
        dummySolver = new DummySolver(address(atlas));
        atlas.depositAndBond{ value: 1 ether }(1 ether);
        vm.stopPrank();

        deal(address(dummySolver), defaultBidAmount);
    }

    //
    // ---- TESTS BEGIN HERE ---- //
    //

    // Ensure the preOps hook is successfully called. To ensure the hooks' returned data is as expected, we forward it
    // to the solver call; the data field of the solverOperation contains the expected value, the check is made in the
    // solver's atlasSolverCall function, as defined in the DummySolver contract.
    function test_executePreOpsCall_success_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withRequirePreOps(true) // Execute the preOps hook
                .withTrackPreOpsReturnData(true) // Track the preOps hook's return data
                .withForwardReturnData(true) // Forward the preOps hook's return data to the solver call
                .withAllowAllocateValueFailure(true) // Allow the value allocation to fail
                .build()
        );
        executeHookCase(false, block.timestamp * 2, noError);
    }

    // Ensure metacall reverts with the proper error when the preOps hook reverts.
    function test_executePreOpsCall_failure() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withRequirePreOps(true) // Execute the preOps hook
                .withReuseUserOp(true) // Allow metacall to revert
                .build()
        );
        executeHookCase(true, 0, AtlasErrors.PreOpsFail.selector);
    }

    // Ensure the user operation executes successfully. To ensure the operation's returned data is as expected, we
    // forward it to the solver call; the data field of the solverOperation contains the expected value, the check is
    // made in the solver's atlasSolverCall function, as defined in the DummySolver contract.
    function test_executeUserOperation_success_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackUserReturnData(true) // Track the user operation's return data
                .withForwardReturnData(true) // Forward the user operation's return data to the solver call
                .withAllowAllocateValueFailure(true) // Allow the value allocation to fail
                .build()
        );
        executeHookCase(false, block.timestamp * 3, noError);
    }

    // Ensure metacall reverts with the proper error when the user operation reverts.
    function test_executeUserOperation_failure() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withReuseUserOp(true) // Allow metacall to revert
                .build()
        );
        executeHookCase(true, 0, AtlasErrors.UserOpFail.selector);
    }

    // Ensure metacall reverts with the proper error when the allocateValue hook reverts.
    function test_executeAllocateValueCall_failure_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackUserReturnData(true) // Track the user operation's return data
                .withForwardReturnData(true) // Forward the user operation's return data to the solver call
                .withReuseUserOp(true) // Allow metacall to revert
                .withAllowAllocateValueFailure(false) // Do not allow the value allocation to fail
                .build()
        );
        executeHookCase(false, 1, AtlasErrors.AllocateValueFail.selector);
    }

    // Ensure the postOps hook is successfully called. No return data is expected from the postOps hook, so we do not
    // forward any data to the solver call.
    function test_executePostOpsCall_success_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withRequirePostOps(true) // Execute the postOps hook
                .build()
        );
        executeHookCase(false, 0, noError);
    }

    // Ensure metacall reverts with the proper error when the postOps hook reverts.
    function test_executePostOpsCall_failure_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackUserReturnData(true) // Track the user operation's return data
                .withForwardReturnData(true) // Forward the user operation's return data to the solver call
                .withRequirePostOps(true) // Execute the postOps hook
                .withReuseUserOp(true) // Allow metacall to revert
                .withAllowAllocateValueFailure(true) // Allow the value allocation to fail
                .build()
        );
        executeHookCase(false, 1, AtlasErrors.PostOpsFail.selector);
    }

    // Ensure the allocateValue hook is successfully called. No return data is expected from the allocateValue hook, so
    // we check by emitting an event in the hook. The emitter must be the executionEnvironment since allocateValue is
    // delegatecalled.
    function test_allocateValue_success_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackUserReturnData(true) // Track the user operation's return data
                .build()
        );

        vm.prank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(dAppControl));

        vm.expectEmit(false, false, false, true, executionEnvironment);
        emit MEVPaymentSuccess(address(0), defaultBidAmount);
        this.executeHookCase(false, 0, noError);
    }

    function executeHookCase(bool hookShouldRevert, uint256 expectedHookReturnValue, bytes4 expectedError) public {
        bool revertExpected = expectedError != noError;

        UserOperation memory userOp = validUserOperation(address(dAppControl))
            .withData(
                abi.encodeWithSelector(
                    dAppControl.userOperationCall.selector,
                    hookShouldRevert,
                    expectedHookReturnValue
                )
            )
            .signAndBuild(address(atlasVerification), userPK);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount)
            .withData(abi.encode(expectedHookReturnValue))
            .signAndBuild(address(atlasVerification), solverOnePK);

        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        if (revertExpected) {
            vm.expectRevert(expectedError);
        }

        vm.prank(userEOA);
        bool auctionWon = atlas.metacall(userOp, solverOps, dappOp);
        
        if (!revertExpected) {
            assertTrue(auctionWon, "auction should have been won");
        }
    }

    function test_executeSolverOperation_validateSolverOperation_invalidTo() public {
        // This test can't pass with metacall as the entrypoint, because a solverOp with an invalid .to will
        // be filtered out by the AtlasVerification contract, before reaching executeSolverOperation.
        vm.skip(true);

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        solverOps[0] = validSolverOperation(userOp)
            .withTo(invalid)
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        executeSolverOperationCase(userOp, solverOps, false, false, 1 << uint256(SolverOutcome.InvalidTo), true);
    }

    function test_executeSolverOperation_validateSolverOperation_perBlockLimit_SkipCoverage() public {
        vm.prank(solverOneEOA);
        atlas.unbond(1); // This will set the solver's lastAccessedBlock to the current block

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        executeSolverOperationCase(userOp, solverOps, false, false, 1 << uint256(SolverOutcome.PerBlockLimit), false);
    }

    function test_executeSolverOperation_validateSolverOperation_insufficientEscrow_SkipCoverage() public {
        // Solver only has 1 ETH escrowed
        vm.txGasPrice(10e18); // Set a gas price that will cause the solver to run out of escrow
        uint256 solverGasLimit = 1_000_000;
        uint256 maxSolverGasCost = solverGasLimit * tx.gasprice;
        assertTrue(maxSolverGasCost > atlas.balanceOfBonded(solverOneEOA), "maxSolverGasCost must be greater than solver bonded AtlETH to trigger InsufficientEscrow");

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount)
            .withGas(solverGasLimit)
            .signAndBuild(address(atlasVerification), solverOnePK);

        executeSolverOperationCase(userOp, solverOps, false, false, 1 << uint256(SolverOutcome.InsufficientEscrow), true);
    }

    function test_executeSolverOperation_validateSolverOperation_callValueTooHigh_SkipCoverage() public {
        // Will revert with CallValueTooHigh if more ETH than held in Atlas requested
        uint256 solverOpValue = 100 ether;
        assertTrue(solverOpValue > address(atlas).balance, "solverOpValue must be greater than Atlas balance to trigger CallValueTooHigh");

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        solverOps[0] = validSolverOperation(userOp)
            .withValue(solverOpValue) // Set a call value that is too high
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        executeSolverOperationCase(userOp, solverOps, false, false, 1 << uint256(SolverOutcome.CallValueTooHigh), false);
    }

    function test_executeSolverOperation_validateSolverOperation_userOutOfGas_SkipCoverage() public {
        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        this.executeSolverOperationCase{gas: _VALIDATION_GAS_LIMIT + _SOLVER_GAS_LIMIT + 1_000_000}(
            userOp, solverOps, false, false, 1 << uint256(SolverOutcome.UserOutOfGas), true
        );
    }

    function test_executeSolverOperation_solverOpWrapper_BidNotPaid_SkipCoverage() public {
        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(
            defaultCallConfig()
                .withRequireFulfillment(true)
                .build()
        );
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount * 2) // Solver's contract doesn't have that much
            .signAndBuild(address(atlasVerification), solverOnePK);
        uint256 result = (1 << uint256(SolverOutcome.BidNotPaid));
        executeSolverOperationCase(userOp, solverOps, true, false, result, true);
    }

    function test_executeSolverOperation_solverOpWrapper_CallbackNotCalled_SkipCoverage() public {
        // Fails because solver doesn't call reconcile() at all
        uint256 bidAmount = dummySolver.noGasPayBack(); // Special bid value that will cause the solver to not call reconcile
        deal(address(dummySolver), bidAmount);

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(
            defaultCallConfig().withRequireFulfillment(true).build());
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(bidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        uint256 result = (1 << uint256(SolverOutcome.CallbackNotCalled));
        executeSolverOperationCase(userOp, solverOps, true, false, result, true);
    }

    function test_executeSolverOperation_solverOpWrapper_SolverOpReverted_SkipCoverage() public {
        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(
            defaultCallConfig()
                .withTrackUserReturnData(true)
                .withForwardReturnData(true)
                .withRequireFulfillment(true)
                .build()
        );
        solverOps[0] = validSolverOperation(userOp)
            .withData(abi.encode(1))
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        uint256 result = (1 << uint256(SolverOutcome.SolverOpReverted));
        executeSolverOperationCase(userOp, solverOps, true, false, result, true);
    }

    function test_executeSolverOperation_solverOpWrapper_preSolverFailed_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackPreOpsReturnData(false)
                .withTrackUserReturnData(true)
                .withRequirePreOps(false)
                .withRequirePreSolver(true)
                .withRequireFulfillment(true)
                .build()
        );

        UserOperation memory userOp = validUserOperation(address(dAppControl))
            .withData(abi.encodeWithSelector(dAppControl.userOperationCall.selector, false, 1))
            .signAndBuild(address(atlasVerification), userPK);
        
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);

        uint256 result = (1 << uint256(SolverOutcome.PreSolverFailed));
        executeSolverOperationCase(userOp, solverOps, false, false, result, true);
    }

    function test_executeSolverOperation_solverOpWrapper_postSolverFailed_SkipCoverage() public {
        defaultAtlasWithCallConfig(
            defaultCallConfig()
                .withTrackPreOpsReturnData(false)
                .withTrackUserReturnData(true)
                .withRequirePreOps(false)
                .withRequirePostSolver(true)
                .withRequireFulfillment(true)
                .build()
        );

        UserOperation memory userOp = validUserOperation(address(dAppControl))
            .withData(abi.encodeWithSelector(dAppControl.userOperationCall.selector, false, 1))
            .signAndBuild(address(atlasVerification), userPK);
        
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        
        uint256 result = (1 << uint256(SolverOutcome.PostSolverFailed));
        executeSolverOperationCase(userOp, solverOps, true, false, result, true);
    }

    function test_executeSolverOperation_solverOpWrapper_BalanceNotReconciled_ifPartialRepayment_SkipCoverage() public {
        // Fails because solver calls reconcile but doesn't fully repay the shortfall
        uint256 bidAmount = dummySolver.partialGasPayBack(); // solver only pays half of shortfall
        deal(address(dummySolver), bidAmount);

        vm.txGasPrice(2);

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(
            defaultCallConfig().withRequireFulfillment(true).build());
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(bidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        uint256 expectedResult = (1 << uint256(SolverOutcome.BalanceNotReconciled));
        executeSolverOperationCase(userOp, solverOps, true, false, expectedResult, true);
    }

    function test_executeSolverOperation_solverOpWrapper_Success_ifPartialRepaymentAndDappCoversTheRest_SkipCoverage() public {
        uint256 bidAmount = dummySolver.partialGasPayBack(); // solver only pays half of shortfall
        deal(address(dummySolver), bidAmount);

        GasSponsorDAppControl gasSponsorControl = new GasSponsorDAppControl(
            address(atlas),
            address(governanceEOA),
            defaultCallConfig()
                .withTrackPreOpsReturnData(false)
                .withTrackUserReturnData(true)
                .withRequirePreOps(false)
                .withRequirePostSolver(true)
                .build());
    
        // Give dapp control enough funds to cover the shortfall
        deal(address(gasSponsorControl), 1 ether);

        vm.prank(governanceEOA);
        atlasVerification.initializeGovernance(address(gasSponsorControl));

        UserOperation memory userOp = validUserOperation(address(gasSponsorControl))
            .withData(abi.encodeCall(gasSponsorControl.userOperationCall, (false, 0)))
            .signAndBuild(address(atlasVerification), userPK);
        
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(bidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);

        console.log("DApp control balance", address(gasSponsorControl).balance);
        console.log("Solver balance", address(dummySolver).balance);
        console.log("Bid amount (to trigger partial)", bidAmount);
        console.log("Solver bonded amt", atlas.balanceOfBonded(solverOneEOA));

        uint256 expectedResult = 0; // Success expected
        executeSolverOperationCase(userOp, solverOps, true, true, expectedResult, false);
    }

    function test_executeSolverOperation_solverBorrowsAndRepaysFullAtlasBalance() public {
        // Solver borrows and repays the full Atlas balance
        DummySolverContributor solver = new DummySolverContributor(address(atlas));

        uint256 solverOpValue = address(atlas).balance;
        assertTrue(solverOpValue > 0, "solverOpValue must be greater than 0");
        

        deal(address(solver), 10e18); // plenty of ETH to repay what solver owes

        (UserOperation memory userOp, SolverOperation[] memory solverOps) = executeSolverOperationInit(defaultCallConfig().build());
        solverOps[0] = validSolverOperation(userOp)
            .withSolver(address(solver))
            .withValue(solverOpValue)
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        vm.prank(userEOA);
        (bool success,) = address(atlas).call(abi.encodeCall(atlas.metacall, (userOp, solverOps, dappOp)));
        assertTrue(success, "metacall should have succeeded");
    }

    function test_executeSolverOperation_solverOpWrapper_defaultCase() public {
        // Can't find a way to reach the default case (which is a good thing)
        vm.skip(true);
    }

    function executeSolverOperationInit(CallConfig memory callConfig)
        public
        returns (UserOperation memory userOp, SolverOperation[] memory solverOps)
    {
        defaultAtlasWithCallConfig(callConfig);

        userOp = validUserOperation(address(dAppControl))
            .withData(abi.encodeWithSelector(dAppControl.userOperationCall.selector, false, 0))
            .signAndBuild(address(atlasVerification), userPK);
        
        solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp)
            .withBidAmount(defaultBidAmount)
            .signAndBuild(address(atlasVerification), solverOnePK);
    }

    function executeSolverOperationCase(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps,
        bool solverOpExecuted,
        bool solverOpSuccess,
        uint256 expectedResult,
        bool metacallShouldRevert
    )
        public
    {
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        vm.expectEmit(false, false, false, true, address(atlas));
        emit SolverTxResult(solverOps[0].solver, solverOps[0].from, solverOpExecuted, solverOpSuccess, expectedResult);

        vm.prank(userEOA);
        if (metacallShouldRevert) vm.expectRevert(); // Metacall should revert, the reason isn't important, we're only checking the event
        atlas.metacall(userOp, solverOps, dappOp);
    }
}

contract DummySolver {
    uint256 public noGasPayBack = 123456789;
    uint256 public partialGasPayBack = 987654321;
    address private _atlas;

    constructor(address atlas) {
        _atlas = atlas;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata extraReturnData
    )
        external
        payable
    {
        if (solverOpData.length > 0 && extraReturnData.length > 0) {
            (uint256 solverDataValue) = abi.decode(solverOpData, (uint256));
            (uint256 extraDataValue) = abi.decode(extraReturnData, (uint256));
            require(solverDataValue == extraDataValue, "solver data and extra data do not match");
        }

        // Pay bid
        if (address(this).balance >= bidAmount) {
            SafeTransferLib.safeTransferETH(executionEnvironment, bidAmount);
        }

        
        if (bidAmount == noGasPayBack) {
            // Don't pay gas
            return;
        } else if (bidAmount == partialGasPayBack) {
            // Only pay half of shortfall owed - expect postSolverCall hook in DAppControl to pay the rest
            uint256 _shortfall = IAtlas(_atlas).shortfall();

            console.log("Solver shortfall", _shortfall);
            console.log("gas price", tx.gasprice);

            IAtlas(_atlas).reconcile(_shortfall / 2);
            return;
        }
        
        // Default: Pay gas
        uint256 shortfall = IAtlas(_atlas).shortfall();
        IAtlas(_atlas).reconcile(shortfall);
        return;
    }
}

contract DummySolverContributor {
    address private _atlas;

    constructor(address atlas) {
        _atlas = atlas;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address,
        uint256 bidAmount,
        bytes calldata,
        bytes calldata
    )
        external
        payable
    {
        // Pay bid
        if (address(this).balance >= bidAmount) {
            SafeTransferLib.safeTransferETH(executionEnvironment, bidAmount);
        }

        // Pay borrowed ETH + gas used
        uint256 shortfall = IAtlas(_atlas).shortfall();
        IAtlas(_atlas).reconcile{value: shortfall}(0);

        return;
    }
}
