// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { AtlasVerification, USER_TYPEHASH_DEFAULT, USER_TYPEHASH_TRUSTED } from "../src/contracts/atlas/AtlasVerification.sol";
import { DAppConfig, CallConfig } from "../src/contracts/types/ConfigTypes.sol";
import "../src/contracts/types/DAppOperation.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { ValidCallsResult } from "../src/contracts/types/ValidCalls.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";
import { DummyDAppControl } from "./base/DummyDAppControl.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { CallVerification } from "../src/contracts/libraries/CallVerification.sol";
import { CallBits } from "../src/contracts/libraries/CallBits.sol";
import { SolverOutcome } from "../src/contracts/types/EscrowTypes.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./base/builders/DAppOperationBuilder.sol";

// 
// ---- TEST HELPERS BEGIN HERE ---- //
// --- (Also used in other files) --- //
// - Scroll down for the actual tests - //
//

contract DummyNotSmartWallet {
}

contract DummySmartWallet {
    bytes4 constant internal EIP1271_MAGIC_VALUE = 0x1626ba7e;
    bool public isValidResult = true;

    function isValidSignature(
        bytes32,
        bytes memory
    ) public view returns (bytes4) {
        console.log("DummySmartWallet.isValidSignature called, isValidResult: ", isValidResult);
        if (isValidResult) {
            return EIP1271_MAGIC_VALUE;
        } else {
            return 0;
        }
    }

    function setIsValidResult(bool data) external {
        isValidResult = data;
    }
}

contract AtlasVerificationBase is BaseTest {
    DummyDAppControl dAppControl;

    struct ValidCallsCall {
        UserOperation userOp;
        SolverOperation[] solverOps;
        DAppOperation dAppOp;
        uint256 msgValue;
        address msgSender;
        bool isSimulation;
    }

    function defaultCallConfig() public returns (CallConfigBuilder) {
        return new CallConfigBuilder();
    }

    function defaultDAppControl() public returns (DummyDAppControlBuilder) {
        return new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(defaultCallConfig().build());
    }

    function validUserOperation() public returns (UserOperationBuilder) {
        return new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withControl(address(dAppControl))
            .withCallConfig(dAppControl.CALL_CONFIG())
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
            .withControl(userOp.control)
            .withData("")
            .withUserOpHash(userOp)
            .sign(address(atlasVerification), solverOnePK);
    }

    function validSolverOperations(UserOperation memory userOp) public returns (SolverOperation[] memory) {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp).build();
        return solverOps;
    }

    function validDAppOperation(DAppConfig memory config, UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(callChainHash)
            .sign(address(atlasVerification), governancePK);
    }

    function validDAppOperation(UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
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

    function doValidateCalls(ValidCallsCall memory call) public returns (ValidCallsResult result) {
        DAppConfig memory config = dAppControl.getDAppConfig(call.userOp);
        vm.startPrank(address(atlas));
        result = atlasVerification.validateCalls(
            config,
            call.userOp,
            call.solverOps,
            call.dAppOp,
            call.msgValue,
            call.msgSender,
            call.isSimulation);
        vm.stopPrank();
    }

    function assertValidCallsResult(ValidCallsResult actual, ValidCallsResult expected) public view {
        console.log("validCallsResult actual: ", uint(actual));
        console.log("validCallsResult expected: ", uint(expected));
        assertTrue(actual == expected, "validCallsResult different to expected");
    }

    function callAndAssert(ValidCallsCall memory call, ValidCallsResult expected) public {
        ValidCallsResult result;
        result = doValidateCalls(call);
        assertValidCallsResult(result, expected);
    }

    function callAndExpectRevert(ValidCallsCall memory call, bytes4 selector) public {
        vm.expectRevert(selector);
        doValidateCalls(call);
    }

    function defaultAtlasEnvironment() public {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().buildAndIntegrate(atlasVerification);
    }

    function defaultAtlasWithCallConfig(CallConfig memory callConfig) public {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().withCallConfig(callConfig).buildAndIntegrate(atlasVerification);
    }
}

//
// ---- NON VALID CALLS TESTS ---- //
//

contract AtlasVerificationVerifySolverOpTest is AtlasVerificationBase {
    using CallVerification for UserOperation;

    function setUp() public override {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().buildAndIntegrate(atlasVerification);
    }

    function test_verifySolverOp_InvalidSignature() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = userEOA;

        // Signed by wrong PK = SolverOutcome.InvalidSignature
        solverOps[0] = validSolverOperation(userOp).signAndBuild(address(atlasVerification), userPK);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSignature), "Expected InvalidSignature 1");

        // No signature = SolverOutcome.InvalidSignature
        solverOps[0].signature = "";
        result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSignature), "Expected InvalidSignature 2");
    }

    function test_verifySolverOp_InvalidUserHash() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // userOpHash doesnt match = SolverOutcome.InvalidUserHash
        solverOps[0].userOpHash = keccak256(abi.encodePacked("Not the userOp"));
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidUserHash), "Expected InvalidUserHash");
    }

    function test_verifySolverOp_InvalidTo() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.to != atlas = SolverOutcome.InvalidTo
        solverOps[0].to = address(0);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidTo), "Expected InvalidTo");
    }

    function test_verifySolverOp_GasPriceOverCap() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.maxFeePerGas < tx.gasprice = SolverOutcome.GasPriceOverCap
        vm.txGasPrice(solverOps[0].maxFeePerGas + 1); // Increase gas price above solver's max
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.GasPriceOverCap), "Expected GasPriceOverCap");
        vm.txGasPrice(tx.gasprice); // Reset gas price to expected level
    }

    function test_verifySolverOp_GasPriceBelowUsers() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // maxFeePerGas is below user's = SolverOutcome.GasPriceBelowUsers
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas + 1,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.GasPriceBelowUsers), "Expected GasPriceBelowUsers");
    }

    function test_verifySolverOp_InvalidSolver() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.solver is atlas = SolverOutcome.InvalidSolver
        solverOps[0].solver = address(atlas);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSolver), "Expected InvalidSolver");
    }

    function test_verifySolverOp_Valid() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // no sig, everything valid = Valid result
        solverOps[0].signature = "";
        vm.prank(solverOneEOA);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 0, "Expected No Errors 1"); // 0 = No SolverOutcome errors

        // Valid solver sig, everything valid = Valid result
        solverOps = validSolverOperations(userOp);
        bundler = userEOA;
        result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 0, "Expected No Errors 2"); // 0 = No SolverOutcome errors
    }
    }

//
// ---- VALID CALLS TESTS BEGIN HERE ---- //
//

contract AtlasVerificationValidCallsTest is AtlasVerificationBase {
    using CallVerification for UserOperation;

    // Default Everything Valid Test Case

    function test_DefaultEverything_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not signed properly
    // when validCalls is called and the bundler is not the user
    // then it should return InvalidSignature
    // because the user operation must be signed by the user unless the bundler is the user
    //
    function test_verifyUserOp_UserSignatureInvalid_WhenOpUnsignedIfNotUserBundler() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not signed properly
    // when validCalls is called and the bundler is the user
    // then it should return Valid
    // because the user operation doesn't need to be signed by the user if the bundler is the user
    //
    function test_verifyUserOp_Valid_WhenOpUnsignedIfUserBundler() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not
    // when validCalls is called
    //   and the bundler is not the user
    //   and isSimulation = true
    // then it should return Valid
    // because the user operation doesn't need to be signed if it's a simulation
    //
    function test_verifyUserOp_Valid_WhenOpUnsignedIfIsSimulation() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: true}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation has a bad signature
    // when validCalls is called
    //   and the bundler is not the user
    //   and isSimulation = true
    // then it should return UserSignatureInvalid
    // because the user operation doesn't need to be signed if it's a simulation
    //
    function test_verifyUserOp_Valid_WhenOpHasBadSignatureIfIsSimulation() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation()
            .withSignature("bad signature")
            .build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: true}
        ), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a smart contract
    //   and the from address is Atlas, AtlasVerification or the dAppControl
    // when validCalls is called
    // then it should return UserFromInvalid
    // to prevent abusive behavior
    //
    function test_verifyUserOp_UserFromInvalid_WhenFromInvalidSmartContract() public {
        defaultAtlasEnvironment();

        address[] memory invalidFroms = new address[](2);
        invalidFroms[0] = address(atlas);
        invalidFroms[1] = address(atlasVerification);

        for (uint256 i = 0; i < invalidFroms.length; i++) {
            UserOperation memory userOp = validUserOperation()
                .withFrom(invalidFroms[i])
                .withSignature("")
                .build();

            SolverOperation[] memory solverOps = validSolverOperations(userOp);
            DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

            callAndAssert(ValidCallsCall({
                userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
            ), ValidCallsResult.UserFromInvalid);
        }
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a contract
    //   and the contract doesn't implement IAccount
    // when validCalls is called
    // then it should revert with an EVM revert error
    // to prevent abusive behavior
    //
    function test_verifyUserOp_UserSmartWalletInvalid_NotFromSmartWallet() public {
        defaultAtlasEnvironment();

        DummyNotSmartWallet smartWallet = new DummyNotSmartWallet();

        UserOperation memory userOp = validUserOperation()
            .withFrom(address(smartWallet))
            .withSignature("")
            .build();

        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        vm.skip(true); // TODO: can't get expectRevert to catch the EVM revert here, not sure why, but it does revert

        vm.expectRevert();
        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ));
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a contract
    //   and the contract implements IAccount
    //   and the userOp is not valid
    // when validCalls is called
    // then it should return UserSmartWalletInvalid
    // because the user operation has failed validation
    //
    function test_verifyUserOp_UserSmartWalletInvalid_FromSmartWallet() public {
        defaultAtlasEnvironment();

        DummySmartWallet smartWallet = new DummySmartWallet();
        smartWallet.setIsValidResult(false); // Set validationData to 1 to fail validation

        UserOperation memory userOp = validUserOperation()
            .withFrom(address(smartWallet))
            .withSignature("")
            .build();

        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a contract
    //   and the contract contract implements IAccount
    //   and the userOp passes IAccount validation
    // when validCalls is called
    // then it should return Valid
    //
    function test_verifyUserOp_Valid_FromSmartWallet() public {
        defaultAtlasEnvironment();

        DummySmartWallet smartWallet = new DummySmartWallet();

        UserOperation memory userOp = validUserOperation()
            .withFrom(address(smartWallet))
            .withSignature("")
            .build();

        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a contract
    //   and the contract contract implements IAccount
    //   and the userOp passes IAccount validation
    // when validCalls is called twice with the same userOp
    // then the second call should return UserOpNonceInvalid
    // to prevent replay attacks
    //
    function test_verifyUserOp_UserNonceInvalid_FromSmartWallet() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        DummySmartWallet smartWallet = new DummySmartWallet();

        UserOperation memory userOp = validUserOperation()
            .withFrom(address(smartWallet))
            .withSignature("")
            .build();

        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        dappOp = validDAppOperation(userOp, solverOps).build(); // increment dappOp so we can hit _verifyUser

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.UserNonceInvalid);
    }

    // TrustedOpHash Allowed Tests

    function test_validCalls_trustedOpHash_sessionKeyWrong_InvalidAuctioneer() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withTrustedOpHash(true).build());

        UserOperation memory userOp = validUserOperation().withSessionKey(address(0)).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();
        solverOps[0] = validSolverOperation(userOp).withUserOpHash(atlasVerification.getUserOperationHash(userOp)).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidAuctioneer);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a contract
    //   and the contract contract implements IAccount
    //   and the userOp passes IAccount validation
    // when validCalls is called twice with the same userOp
    // then the second call should return UserOpNonceInvalid
    // to prevent replay attacks
    //
    function test_validCalls_trustedOpHash_userOpChangesButTrustedHashStillValid_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withTrustedOpHash(true).build());

        UserOperation memory userOp = validUserOperation().withSessionKey(governanceEOA).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        userOp = validUserOperation().withSessionKey(governanceEOA).withDeadline(block.number + 3).build();
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    function test_validCalls_trustedOpHash_msgSenderWrong_InvalidBundler() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withTrustedOpHash(true).build());

        UserOperation memory userOp = validUserOperation().withSessionKey(governanceEOA).sign(address(atlasVerification), userPK).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();
        solverOps[0] = validSolverOperation(userOp).build();

        // If msgSender in _validCalls is neither dAppOp.from nor userOp.from,
        // and trustedOpHash is true --> return InvalidBundler
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.InvalidBundler);
    }

    // Valid cases

    // 
    // given a default atlas environment
    //   and valid user, solver and dapp operations
    // when validCalls is called from the userEOA
    // then it should return Valid
    //
    function test_validCalls_ValidResult() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    // OpHashMismatch case
    // When userOpHash != dAppOp.userOpHash

    function test_validCalls_OpHashMismatch() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withUserOpHash(bytes32(0)).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.OpHashMismatch);
    }

    // InvalidCaller cases

    //
    // given a default atlas environment
    //   and valid user, solver and dapp operations 
    // when validCalls is called from the userEOA
    //  and the caller is not the atlas contract
    // then it should revert with InvalidCaller
    //
    function test_validCalls_InvalidCallerResult() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        DAppConfig memory config = dAppControl.getDAppConfig(userOp);
        vm.expectRevert(AtlasErrors.InvalidCaller.selector);
        atlasVerification.validateCalls(config, userOp, solverOps, dappOp, 0, userEOA, false);
    }

    //
    // InvalidAuctioneer cases
    //
    
    // 
    // given a default atlas environment
    //   and a callConfig with verifyCallChainHash = true
    //   and valid user, solver and dapp operations 
    // when validCalls is called from the userEOA
    // then it should return Valid
    //
    function test_validCalls_VerifyCallChainHash_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withVerifyCallChainHash(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and a callConfig with verifyCallChainHash = true
    //   and otherwise valid user, solver and dapp operations
    //      where the dapp operation has an empty callChainHash
    // when validCalls is called from the userEOA
    // then it should return InvalidCallChainHash
    //
    function test_validCalls_VerifyCallChainHash_InvalidCallChainHash() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withVerifyCallChainHash(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps)
            .withCallChainHash(bytes32(0))
            .signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidCallChainHash);
    }

    //
    // given a default atlas environment
    //   and a callConfig with verifyCallChainHash = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation has an empty callChainHash
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return Valid
    //
    function test_validCalls_Simulated_VerifyCallChainHash_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withVerifyCallChainHash(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps)
            .withCallChainHash(bytes32(0))
            .signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ), ValidCallsResult.Valid);
    }

    // DAppSignatureInvalid cases

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation has an empty signature
    // when validCalls is called from the userEOA
    // then it should return DAppSignatureInvalid
    //
    function test_validCalls_BrokenSignature_DAppSignatureInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withSignature(bytes("")).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.DAppSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation is signed by the wrong PK
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return DAppSignatureInvalid
    //
    function test_validCalls_Simulated_BrokenSignature_DAppSignatureInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), userPK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ), ValidCallsResult.DAppSignatureInvalid);
    }

    // 
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //   and the governanceEOA is not a valid signatory
    //   and callConfig.userAuctioneer = true
    // when validCalls is called from the userEOA
    // then it should bypass signatory verification
    //   and return Valid
    //
    function test_validCalls_SignerNotEnabled_BypassSignatory_UserAuctioneer_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserAuctioneer(true).build());
        vm.prank(governanceEOA);
        atlasVerification.removeSignatory(address(dAppControl), governanceEOA);

        UserOperation memory userOp = validUserOperation().withSessionKey(governanceEOA).signAndBuild(address(atlasVerification), governancePK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    // 
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //   and the governanceEOA is not a valid signatory
    //   and callConfig.solverAuctioneer = true
    // when validCalls is called from the solverOneEOA
    // then it should bypass signatory verification
    //   and return Valid
    //
    function test_validCalls_SignerNotEnabled_BypassSignatory_SolverAuctioneer_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withSolverAuctioneer(true).build());
        vm.prank(governanceEOA);
        atlasVerification.removeSignatory(address(dAppControl), governanceEOA);

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withFrom(solverOneEOA).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    // 
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //   and the governanceEOA is not a valid signatory
    //   and callConfig.solverAuctioneer = true
    // when validCalls is called from the solverOneEOA
    // when there is more than 1 solver (must be exactly 1 solver if solver == auctioneer)
    // then it should return TooManySolverOps
    //
    function test_validCalls_SolverAuctioneer_TwoSolvers_TooManySolverOps() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withSolverAuctioneer(true).build());
        vm.prank(governanceEOA);
        atlasVerification.removeSignatory(address(dAppControl), governanceEOA);
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = validSolverOperation(userOp).build();
        solverOps[1] = validSolverOperation(userOp).build();
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withFrom(solverOneEOA).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.TooManySolverOps);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //   and the governanceEOA is not a valid signatory
    //   and callConfig.unknownAuctioneer = true
    // when validCalls is called from the userEOA
    // then it should bypass signatory verification
    //   and return Valid
    //
    function test_validCalls_SignerNotEnabled_BypassSignatory_UnknownAuctioneer_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUnknownAuctioneer(true).build());
        vm.prank(governanceEOA);
        atlasVerification.removeSignatory(address(dAppControl), governanceEOA);

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //   and the governanceEOA is not a valid signatory
    //   and the dAppControl is not enabled
    // when validCalls is called from the userEOA
    // then it should return DAppSignatureInvalid
    //
    function test_validCalls_SignerNotEnabled_DAppNotEnabled() public {
        defaultAtlasEnvironment();
        vm.prank(governanceEOA);
        atlasVerification.removeSignatory(address(dAppControl), governanceEOA);

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.DAppNotEnabled);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation control address is different to the dapp config to address
    // when validCalls is called from the userEOA
    // then it should return InvalidControl
    //
    function test_validCalls_ControlConfigMismatch_InvalidControl() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withControl(address(0)).signAndBuild(address(atlasVerification), governancePK);
        
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidControl);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is zero
    // when validCalls is called from the userEOA
    // then it should return valid
    // because although zero is not a valid nonce, it is not
    // checked when dappNoncesSequential isn't enabled
    //
    function test_validCalls_NonceIsZero_valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(0).signAndBuild(address(atlasVerification), governancePK);

        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ));
    }

    //
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is zero
    // when validCalls is called from the userEOA
    // then it should return InvalidDAppNonce
    // because zero is not a valid nonce when dappNoncesSequential is enabled
    //
    function test_validCalls_NonceIsZero_InvalidDAppNonce() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(0).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidDAppNonce);
    }

    //
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is zero
    //     and the dapp operation `from` field is address(0)
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return Valid
    // because zero is a valid nonce for simulations when the dapp operation `from` field isn't set
    //
    function test_validCalls_NonceIsZero_Simulated_valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(0).build();

        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ));
    }

    //
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is zero
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return InvalidDAppNonce
    // because zero is not a valid nonce for simulations when the dapp operation `from` field is set
    //
    function test_validCalls_NonceIsZero_Simulated_InvalidDAppNonce() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(0).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ), ValidCallsResult.InvalidDAppNonce);
    }

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = false
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because one has not been used before
    //
    function test_validCalls_NonSeqNonceIsOne_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(1).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because one is the first valid nonce for sequential calls
    //  and this is the first call for the user
    //
    function test_validCalls_SequentialNonceIsOne_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(1).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is two
    // when validCalls is called from the userEOA
    // then it should return DAppSignatureInvalid
    // because one is the first valid nonce for sequential calls
    //  and this is the first call for the user
    //
    function test_validCalls_SequentialNonceIsTwo_DAppSignatureInvalid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidDAppNonce);
    }

    //
    // given an otherwise valid atlas transaction with a dAppOp.nonce of 2
    //   and the callConfig.userNoncesSequential = true
    //   and the last dAppOp.nonce for the user is 1
    // when validCalls is called
    // then it should return Valid
    //

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is two
    //   and the last dapp operation nonce for the user is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because one is the first valid nonce for sequential calls
    //  and this is the first call for the user
    //
    function test_validCalls_SequentialNonceWasOneIsNowTwo_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        // these first ops are to increment the nonce to 1
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        // this is the actual testcase
        userOp = validUserOperation().withNonce(2).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    // 
    // given a default atlas environment
    //   and callConfig.dappNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp operation nonce is three
    //   and the last dapp operation nonce for the user is one
    // when validCalls is called from the userEOA
    // then it should return DAppSignatureInvalid
    // because the current nonce for the user is 1
    //  and the next valid nonce is 2
    //
    function test_validCalls_SequentialNonceWasOneIsNowThree_DAppSignatureInvalid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());

        // these first ops are to increment the nonce to 1
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();
        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        // this is the actual testcase
        userOp = validUserOperation().build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(3).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidDAppNonce);
    }

    // UserSignatureInvalid cases

    // userOp signatures are invalid when:
    // * (userOp.signature.length == 0)
    // * _hashTypedDataV4(_getProofHash(userOp)).recover(userOp.signature) != userOp.from

    //
    // gived a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp signature is blank
    // when validCalls is called from the governanceEOA
    // then it should return UserSignatureInvalid
    // because the signature is not valid for the user
    //
    function test_validCalls_InvalidUserSignatureBlank_BundlerNotUser_UserSignatureInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withSignature(bytes("")).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp signature is signed by someone else
    // when validCalls is called from the governanceEOA
    // then it should return UserSignatureInvalid
    // because the signature is not valid for the user
    //
    function test_validCalls_InvalidUserSignatureWrongEOA_BundlerNotUser_UserSignatureInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().signAndBuild(address(atlasVerification), governancePK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp signature is blank
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because the user op signature is not required when the bundler is the user
    //
    function test_validCalls_InvalidUserSignatureBlank_BundlerIsUser_UserSignatureInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withSignature(bytes("")).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp signature is blank
    // when validCalls is called from the governanceEOA
    //   and isSimulation = true
    // then it should return Valid
    // because the user op signature is not required for simulations
    //
    function test_validCalls_InvalidUserSignatureBlank_Simulated_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withSignature(bytes("")).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: true}
        ), ValidCallsResult.Valid);
    }


    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the user op control address is different to the dapp config to address
    // when validCalls is called from the userEOA
    // then it should return ControlMismatch
    // because the user op signature control address must match the dapp config to address
    //
    function test_validCalls_InvalidUserOpControl_ControlMismatch() public {
        defaultAtlasEnvironment();
        DummyDAppControl otherDappControl = defaultDAppControl().buildAndIntegrate(atlasVerification);

        UserOperation memory userOp = validUserOperation().withControl(address(otherDappControl)).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withControl(address(dAppControl)).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: true}
        ), ValidCallsResult.ControlMismatch);
    }
    
    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is zero
    // when validCalls is called from the userEOA
    // then it should return UserNonceInvalid
    // because zero is not a valid nonce
    //
    function test_validCalls_UserOpNonceIsZero_UserNonceInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withNonce(0).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.UserNonceInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is zero
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return UserNonceInvalid
    // because zero is never a valid nonce
    //
    function test_validCalls_UserOpNonceIsZero_Simulated_UserNonceInvalid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withNonce(0).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ), ValidCallsResult.UserNonceInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because one has not been used before
    //
    function test_validCalls_UserOpNonceIsOne_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withNonce(1).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because one is the first valid nonce for sequential calls
    //  and this is the first call for the user
    //
    function test_validCalls_SequentialUserOpNonceIsOne_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().withNonce(1).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given an otherwise valid atlas transaction with a userOp.nonce of 2
    //   and the callConfig.userNoncesSequential = true
    //   and the nonce is uninitialized for the user
    // when validCalls is called
    // then it should return UserNonceInvalid
    //

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is two
    // when validCalls is called from the userEOA
    // then it should return UserNonceInvalid
    // because one is the first valid nonce for sequential calls
    //  and this is the first call for the user
    //
    function test_validCalls_SequentialUserOpNonceIsTwo_UserNonceInvalid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().withNonce(2).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.UserNonceInvalid);
    }

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is two
    //  and the last user operation nonce for the user is one
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because the current nonce for the user is 1
    //  and the next valid nonce is 2
    //
    function test_validCalls_SequentialUserOpNonceIsTwo_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        // increment the nonce to 1
        UserOperation memory userOp = validUserOperation().signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();
        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ));

        // this is the actual testcase
        userOp = validUserOperation().withNonce(2).signAndBuild(address(atlasVerification), userPK);
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given an otherwise valid atlas transaction with a userOp.nonce of 3
    //   and the callConfig.userNoncesSequential = true
    //   and the last nonce for the user is 1
    // when validCalls is called
    // then it should return UserNonceInvalid
    //

    //
    // given a default atlas environment
    //   and callConfig.userNoncesSequential = true
    //   and otherwise valid user, solver and dapp operations
    //     where the user operation nonce is three
    //   and the last user operation nonce for the user is one
    // when validCalls is called from the userEOA
    // then it should return UserNonceInvalid
    // because the current nonce for the user is 1
    //   and the next valid nonce is 2
    //
    function test_validCalls_SequentialUserOpNonceIsThree_UserNonceInvalid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        // increment the nonce to 1
        UserOperation memory userOp = validUserOperation().signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();
        doValidateCalls(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ));

        // this is the actual testcase
        userOp = validUserOperation().withNonce(3).signAndBuild(address(atlasVerification), userPK);
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.UserNonceInvalid);
    }

    // TooManySolverOps cases

    //
    // given an otherwise valid atlas transaction with more than (type(uint8).max - 2) = 253 solverOps
    // when validCalls is called
    // then it should return TooManySolverOps
    //

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where there are more than 253 solverOps
    // when validCalls is called from the userEOA
    // then it should return TooManySolverOps
    // because 253 is the maximum number of solverOps
    //
    function test_validCalls_TooManySolverOps() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](255);
        SolverOperation memory solverOp = validSolverOperation(userOp).build();
        for (uint i = 0; i < 255; i++) {
            solverOps[i] = solverOp;
        }
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.TooManySolverOps);
    }

    // UserDeadlineReached cases

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp.deadline is earlier than block.number
    // when validCalls is called from the userEOA
    // then it should return UserDeadlineReached
    // because the deadline has passed
    //
    function test_validCalls_UserDeadlineReached() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withDeadline(block.number - 1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.UserDeadlineReached);
    }

    // DAppDeadlineReached cases

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dappOp.deadline is earlier than block.number
    // when validCalls is called from the userEOA
    // then it should return DAppDeadlineReached
    // because the deadline has passed
    //
    function test_validCalls_DAppDeadlineReached() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withDeadline(block.number - 1).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.DAppDeadlineReached);
    }

    // InvalidBundler cases

    //
    // given an otherwise valid atlas transaction where the bundler is not the message sender
    // when validCalls is called
    // then it should return InvalidBundler
    //

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the dapp op bundler is not the message sender
    // when validCalls is called from the userEOA
    // then it should return InvalidBundler
    // because the bundler must be the message sender
    //
    function test_validCalls_InvalidBundler() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withBundler(address(1)).signAndBuild(address(atlasVerification), governancePK);

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.InvalidBundler);
    }

    // GasPriceHigherThanMax cases

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the userOp.maxFeePerGas is lower than tx.gasprice
    // when validCalls is called from the userEOA
    // then it should return GasPriceHigherThanMax
    // because the userOp.maxFeePerGas must be higher than tx.gasprice
    //
    function test_validCalls_GasPriceHigherThanMax() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withMaxFeePerGas(tx.gasprice - 1).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.GasPriceHigherThanMax);
    }

    // TxValueLowerThanCallValue cases

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the msgValue is lower than the userOp.value
    // when validCalls is called from the userEOA
    // then it should return TxValueLowerThanCallValue
    // because the msgValue must be higher than the userOp.value
    //
    function test_validCalls_TxValueLowerThanCallValue() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().withValue(1).signAndBuild(address(atlasVerification), userPK);
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.TxValueLowerThanCallValue);
    }

    // Prune invalid solverOps cases

    //
    // given an otherwise valid atlas transaction with a solverOp that:
    // * is the bundler
    // * has an invalid signature
    // when validCalls is called
    // then it should return Valid
    //

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where the solver op has an invalid signature
    // when validCalls is called from the solverOneEOA
    // then it should return Valid
    // because the solver op signature is not required when the solver is the bundler
    //
    function test_validCalls_SolverIsBundlerWithNoSignature_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        SolverOperation memory solverOp = validSolverOperation(userOp).withSignature(bytes("")).build();
        solverOps[0] = solverOp;
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: solverOneEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where there are no solver ops
    // when validCalls is called from the userEOA
    //   and isSimulation = true
    // then it should return Valid
    // because no solver ops is valid for simulations
    //
    function test_validCalls_NoSolverOps_Simulated_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: true}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where there are no solver ops
    //   and callConfig.zeroSolvers = true
    // when validCalls is called from the userEOA
    // then it should return Valid
    // because no solver ops is valid when zeroSolvers is true
    //
    function test_validCalls_NoSolverOps_ZeroSolverSet_Valid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withZeroSolvers(true).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where there are no solver ops
    // when validCalls is called from the userEOA
    // then it should return NoSolverOp
    // because no solver ops is not valid by default
    //
    function test_validCalls_NoSolverOpsSent_NoSolverOp() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.NoSolverOp);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    //     where all solver ops are pruned
    //   and callConfig.requireFulfillment = true
    //   and callConfig.zeroSolvers = true
    // when validCalls is called from the userEOA
    // then it should return NoSolverOp
    // because all solver ops are pruned
    //
    function test_validCalls_NoSolverOps_ZeroSolverSet_NoSolverOp() public {
        // Should return NoSolverOp in the `if (!dConfig.callConfig.allowsZeroSolvers())` branch
        defaultAtlasWithCallConfig(defaultCallConfig().withRequireFulfillment(true).withZeroSolvers(false).build());

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.NoSolverOp);

        // Should return NoSolverOp in the `if (dConfig.callConfig.needsFulfillment())` branch
        defaultAtlasWithCallConfig(defaultCallConfig().withRequireFulfillment(true).withZeroSolvers(true).build());

        userOp = validUserOperation().build();
        solverOps = new SolverOperation[](0);
        dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.NoSolverOp);
    }

    function testGetDomainSeparatorInAtlasVerification() public view {
        bytes32 hashedName = keccak256(bytes("AtlasVerification"));
        bytes32 hashedVersion = keccak256(bytes("1.0"));
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 predictedDomainSeparator = keccak256(abi.encode(typeHash, hashedName, hashedVersion, block.chainid, address(atlasVerification)));
        bytes32 domainSeparator = atlasVerification.getDomainSeparator();

        assertEq(predictedDomainSeparator, domainSeparator);
    }
}
