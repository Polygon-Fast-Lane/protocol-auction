// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { NonceManager } from "../src/contracts/atlas/NonceManager.sol";
import { DAppConfig, CallConfig } from "../src/contracts/types/ConfigTypes.sol";
import { UserOperation } from "../src/contracts/types/UserOperation.sol";
import { SolverOperation } from "../src/contracts/types/SolverOperation.sol";
import { DAppOperation } from "../src/contracts/types/DAppOperation.sol";
import { ValidCallsResult } from "../src/contracts/types/ValidCalls.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";
import { AtlasVerificationBase } from "./AtlasVerification.t.sol";

contract MockNonceManager is NonceManager {
    function handleUserNonces(
        address user,
        uint256 nonce,
        bool sequential,
        bool isSimulation
    ) external returns (bool) {
        return _handleUserNonces(user, nonce, sequential, isSimulation);
    }

    function handleDAppNonces(
        address dAppSignatory,
        uint256 nonce,
        bool isSimulation
    ) external returns (bool) {
        return _handleDAppNonces(dAppSignatory, nonce, isSimulation);
    }

    function handleSequentialNonces(uint256 lastUsedNonce, uint256 nonce) external pure returns (bool, uint256) {
        return _handleSequentialNonces(lastUsedNonce, nonce);
    }

    function handleNonSequentialNonces(uint256 bitmap, uint8 bitPos) external pure returns (bool, uint256) {
        return _handleNonSequentialNonces(bitmap, bitPos);
    }
}

contract NonceManagerTest is AtlasVerificationBase {

    MockNonceManager public mockNonceManager;

    function setUp() public override {
        mockNonceManager = new MockNonceManager();
    }

    function testGetNextNonceReturnsOneForNewAccount_Sequential() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());
        assertEq(atlasVerification.getUserNextNonce(userEOA, true), 1, "User seq next nonce should be 1");
        assertEq(atlasVerification.getDAppNextNonce(governanceEOA), 1, "Gov seq next nonce should be 1");
    }

    function testGetNextNonceReturnsOneForNewAccount_NonSeq() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(false).build());
        assertEq(atlasVerification.getUserNextNonce(userEOA, false), 1, "User non-seq next nonce should be 1");
    }

    function testUsingSeqNoncesDoNotChangeNextNonSeqNonce() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());
        assertEq(atlasVerification.getUserNextNonce(userEOA, true), 1, "User next seq nonce should be 1");
        assertEq(atlasVerification.getUserNextNonce(userEOA, false), 1, "User next non-seq nonce should be 1");

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));
        assertEq(atlasVerification.getUserNextNonce(userEOA, true), 2, "User next seq nonce should now be 2");
        assertEq(atlasVerification.getUserNextNonce(userEOA, false), 1, "User next non-seq nonce should still be 1");
    }

    function testUsingNonSeqNoncesDoNotChangeNextSeqNonce() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(false).build());
        assertEq(atlasVerification.getUserNextNonce(userEOA, true), 1, "User next seq nonce should be 1");
        assertEq(atlasVerification.getUserNextNonce(userEOA, false), 1, "User next non-seq nonce should be 1");

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));
        assertEq(atlasVerification.getUserNextNonce(userEOA, true), 1, "User next seq nonce should still be 1");
        assertEq(atlasVerification.getUserNextNonce(userEOA, false), 2, "User next non-seq nonce should now be 2");
    }

    function testSameNonceCannotBeUsedTwice_UserSequential() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).withDappNoncesSequential(false).build());

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        // Fails with UserNonceInvalid due to re-used user nonce
        userOp = validUserOperation().withNonce(1).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.UserNonceInvalid);
    }

    function testSameNonceValidForSeqAndNonSeqDApps() public {
        // Set up DApp with sequential user nonces
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        // In Sequential DApp: User nonces 1 and 2 are valid
        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(1).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        userOp = validUserOperation().withNonce(2).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        // Set up DApp with non-seq user nonces
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(false).build());

        // In NonSeq DApp: User nonces 1 and 2 are valid even though already used in sequential dapp
        userOp = validUserOperation().withNonce(1).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(3).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        userOp = validUserOperation().withNonce(2).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(4).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    function testSeqNoncesMustBePerfectlySequential() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(true).build());

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(1).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        // Fails with UserSignatureInvalid due to non-sequential user nonce
        userOp = validUserOperation().withNonce(3).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);

        // Valid if using the sequential user nonce
        userOp = validUserOperation().withNonce(2).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(3).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        // Fails with UserSignatureInvalid due to non-sequential user nonce
        userOp = validUserOperation().withNonce(999).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(4).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: governanceEOA, isSimulation: false}
        ), ValidCallsResult.UserSignatureInvalid);

        // Valid if using the sequential user nonce
        userOp = validUserOperation().withNonce(3).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(5).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);
    }

    function testNonSeqNoncesAreValidEvenIfNotSequential() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withUserNoncesSequential(false).build());

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).withNonce(1).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ), ValidCallsResult.Valid);

        // Valid if using the non-seq user nonce
        userOp = validUserOperation().withNonce(100).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(2).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, isSimulation: false, msgValue: 0, msgSender: userEOA}
        ), ValidCallsResult.Valid);

        // Valid if using the non-seq user nonce
        userOp = validUserOperation().withNonce(500).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(3).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, isSimulation: false, msgValue: 0, msgSender: userEOA}
        ), ValidCallsResult.Valid);

        // Valid if using the non-seq user nonce
        userOp = validUserOperation().withNonce(2).build();
        solverOps = validSolverOperations(userOp);
        dappOp = validDAppOperation(userOp, solverOps).withNonce(4).signAndBuild(address(atlasVerification), governancePK);
        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, isSimulation: false, msgValue: 0, msgSender: userEOA}
        ), ValidCallsResult.Valid);
    }

    function testFirstEightNonces_DAppSequential() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withDappNoncesSequential(true).build());
        
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        // First call initializes at nonce = 1
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        // Testing nonces 2 - 8
        for (uint256 i = 2; i < 9; i++) {
            assertEq(atlasVerification.getDAppNextNonce(governanceEOA), i, "Next nonce not incrementing as expected");
            
            userOp = validUserOperation().withNonce(i).build();
            solverOps = validSolverOperations(userOp);
            dappOp = validDAppOperation(userOp, solverOps).withNonce(i).signAndBuild(address(atlasVerification), governancePK);
            callAndAssert(ValidCallsCall({
                userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
            ), ValidCallsResult.Valid);
        }

        assertEq(atlasVerification.getDAppNextNonce(governanceEOA), 9, "Next nonce should be 9 after 8 seq nonces used");
    }

    function testGetNextNonceAfter() public {
        defaultAtlasWithCallConfig(defaultCallConfig().build());
        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, 0), 1, "User next non-seq nonce after 0 should be 1");

        UserOperation memory userOp = validUserOperation().withNonce(1).build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, 0), 2, "User next non-seq nonce after 0 should be 2");
        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, 1), 2, "User next non-seq nonce after 1 should be 2");
        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, 2), 3, "User next non-seq nonce after 2 should be 3");
        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, 3), 4, "User next non-seq nonce after 3 should be 4");
    }

    function testMultipleGetNextNonceAfter() public {
        // From a given reference nonce, generate the next 5 operations (to simulate in-flight nonces)
        defaultAtlasWithCallConfig(defaultCallConfig().build());

        UserOperation[] memory userOps = new UserOperation[](5);
        SolverOperation[][] memory solverOps = new SolverOperation[][](5);
        DAppOperation[] memory dappOps = new DAppOperation[](5);

        // Consume nonce 254 for the user, it should not be used again
        userOps[0] = validUserOperation().withNonce(254).build();
        solverOps[0] = validSolverOperations(userOps[0]);
        dappOps[0] = validDAppOperation(userOps[0], solverOps[0]).withNonce(1).signAndBuild(address(atlasVerification), governancePK);
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[0], solverOps: solverOps[0], dAppOp: dappOps[0], msgValue: 0, msgSender: userEOA, isSimulation: false}
        ));

        uint256 refNonce = 252;
        uint256 userNextNonce = atlasVerification.getUserNextNonSeqNonceAfter(userEOA, refNonce);

        userOps[0] = validUserOperation().withNonce(userNextNonce).build();
        solverOps[0] = validSolverOperations(userOps[0]);
        dappOps[0] = validDAppOperation(userOps[0], solverOps[0]).withNonce(2).signAndBuild(address(atlasVerification), governancePK);

        userNextNonce = atlasVerification.getUserNextNonSeqNonceAfter(userEOA, userNextNonce);

        userOps[1] = validUserOperation().withNonce(userNextNonce).build();
        solverOps[1] = validSolverOperations(userOps[1]);
        dappOps[1] = validDAppOperation(userOps[1], solverOps[1]).withNonce(3).signAndBuild(address(atlasVerification), governancePK);

        userNextNonce = atlasVerification.getUserNextNonSeqNonceAfter(userEOA, userNextNonce);

        userOps[2] = validUserOperation().withNonce(userNextNonce).build();
        solverOps[2] = validSolverOperations(userOps[2]);
        dappOps[2] = validDAppOperation(userOps[2], solverOps[2]).withNonce(4).signAndBuild(address(atlasVerification), governancePK);

        userNextNonce = atlasVerification.getUserNextNonSeqNonceAfter(userEOA, userNextNonce);

        userOps[3] = validUserOperation().withNonce(userNextNonce).build();
        solverOps[3] = validSolverOperations(userOps[3]);
        dappOps[3] = validDAppOperation(userOps[3], solverOps[3]).withNonce(5).signAndBuild(address(atlasVerification), governancePK);

        userNextNonce = atlasVerification.getUserNextNonSeqNonceAfter(userEOA, userNextNonce);

        userOps[4] = validUserOperation().withNonce(userNextNonce).build();
        solverOps[4] = validSolverOperations(userOps[4]);
        dappOps[4] = validDAppOperation(userOps[4], solverOps[4]).withNonce(6).signAndBuild(address(atlasVerification), governancePK);

        // Execute all 5 operations in random order
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[2], solverOps: solverOps[2], dAppOp: dappOps[2], msgValue: 0, msgSender: userEOA, isSimulation: false}
        )); // Nonce 256
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[0], solverOps: solverOps[0], dAppOp: dappOps[0], msgValue: 0, msgSender: userEOA, isSimulation: false}
        )); // Nonce 253
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[4], solverOps: solverOps[4], dAppOp: dappOps[4], msgValue: 0, msgSender: userEOA, isSimulation: false}
        )); // Nonce 258
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[3], solverOps: solverOps[3], dAppOp: dappOps[3], msgValue: 0, msgSender: userEOA, isSimulation: false}
        )); // Nonce 257
        doValidateCalls(AtlasVerificationBase.ValidCallsCall({
            userOp: userOps[1], solverOps: solverOps[1], dAppOp: dappOps[1], msgValue: 0, msgSender: userEOA, isSimulation: false}
        )); // Nonce 255

        // Notice nonce 254 was skipped, the highest nonce used was 258 (in userOps[4])
        assertEq(atlasVerification.getUserNextNonSeqNonceAfter(userEOA, refNonce), 259, "User next non-seq nonce after 252 should be 259");
    }

    function testHandleSequentialNonces() public view {
        bool valid;
        uint256 updatedNonce;

        // Valid cases
        (valid, updatedNonce) = mockNonceManager.handleSequentialNonces(0, 1);
        assertTrue(valid, "lastUsedNonce=0 and nonce=1 should be valid");
        assertEq(updatedNonce, 1, "lastUsedNonce=0 and nonce=1 should return nonce=1");

        (valid, updatedNonce) = mockNonceManager.handleSequentialNonces(1337, 1338);
        assertTrue(valid, "lastUsedNonce=1337 and nonce=1338 should be valid");
        assertEq(updatedNonce, 1338, "lastUsedNonce=1337 and nonce=1338 should return nonce=1338");

        // Invalid cases
        (valid, updatedNonce) = mockNonceManager.handleSequentialNonces(1, 1);
        assertFalse(valid, "lastUsedNonce=1 and nonce=1 should not be valid");
        assertEq(updatedNonce, 1, "lastUsedNonce=1 and nonce=1 should return nonce=1");

        (valid, updatedNonce) = mockNonceManager.handleSequentialNonces(0, 2);
        assertFalse(valid, "lastUsedNonce=0 and nonce=2 should not be valid");
        assertEq(updatedNonce, 0, "lastUsedNonce=0 and nonce=2 should return nonce=0");

        (valid, updatedNonce) = mockNonceManager.handleSequentialNonces(1000, 999);
        assertFalse(valid, "lastUsedNonce=1000 and nonce=999 should not be valid");
        assertEq(updatedNonce, 1000, "lastUsedNonce=1000 and nonce=999 should return nonce=1000");
    }

    function testHandleNonSequentialNonces() public view {
        bool valid;
        uint256 updatedBitmap;

        uint256 bitmap = 1234;
        // ...010011010010
        //    ^ ^^  ^ ^^ ^ are available nonces (bit positions 0, 2, 3, 5, 8, 9, 11)
        //     ^  ^^ ^  ^  are used nonces (bit positions 1, 4, 6, 7, 10)

        // Valid cases
        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 0);
        assertTrue(valid, "bitmap=1234 and bitPos=0 should be valid");
        // updated bitmap = ...010011010011 (bit position 0 is now used) = 1235
        assertEq(updatedBitmap, 1235, "bitmap=1234 and bitPos=0 should return bitmap=1235");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 2);
        assertTrue(valid, "bitmap=1234 and bitPos=2 should be valid");
        // updated bitmap = ...010011010110 (bit position 2 is now used) = 1238
        assertEq(updatedBitmap, 1238, "bitmap=1234 and bitPos=2 should return bitmap=1238");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 3);
        assertTrue(valid, "bitmap=1234 and bitPos=3 should be valid");
        // updated bitmap = ...010011011010 (bit position 3 is now used) = 1242
        assertEq(updatedBitmap, 1242, "bitmap=1234 and bitPos=3 should return bitmap=1242");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 5);
        assertTrue(valid, "bitmap=1234 and bitPos=5 should be valid");
        // updated bitmap = ...010011110010 (bit position 5 is now used) = 1266
        assertEq(updatedBitmap, 1266, "bitmap=1234 and bitPos=5 should return bitmap=1266");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 8);
        assertTrue(valid, "bitmap=1234 and bitPos=8 should be valid");
        // updated bitmap = ...010111010010 (bit position 8 is now used) = 1490
        assertEq(updatedBitmap, 1490, "bitmap=1234 and bitPos=8 should return bitmap=1490");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 9);
        assertTrue(valid, "bitmap=1234 and bitPos=9 should be valid");
        // updated bitmap = ...011011010010 (bit position 9 is now used) = 1746
        assertEq(updatedBitmap, 1746, "bitmap=1234 and bitPos=9 should return bitmap=1746");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 11);
        assertTrue(valid, "bitmap=1234 and bitPos=11 should be valid");
        // updated bitmap = ...110011010010 (bit position 11 is now used) = 3282
        assertEq(updatedBitmap, 3282, "bitmap=1234 and bitPos=11 should return bitmap=3282");

        // Invalid cases
        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 1);
        assertFalse(valid, "bitmap=1234 and bitPos=1 should not be valid");
        assertEq(updatedBitmap, 1234, "bitmap=1234 and bitPos=1 should return bitmap=1234");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 4);
        assertFalse(valid, "bitmap=1234 and bitPos=4 should not be valid");
        assertEq(updatedBitmap, 1234, "bitmap=1234 and bitPos=4 should return bitmap=1234");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 6);
        assertFalse(valid, "bitmap=1234 and bitPos=6 should not be valid");
        assertEq(updatedBitmap, 1234, "bitmap=1234 and bitPos=6 should return bitmap=1234");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 7);
        assertFalse(valid, "bitmap=1234 and bitPos=7 should not be valid");
        assertEq(updatedBitmap, 1234, "bitmap=1234 and bitPos=7 should return bitmap=1234");

        (valid, updatedBitmap) = mockNonceManager.handleNonSequentialNonces(bitmap, 10);
        assertFalse(valid, "bitmap=1234 and bitPos=10 should not be valid");
        assertEq(updatedBitmap, 1234, "bitmap=1234 and bitPos=10 should return bitmap=1234");
    }

    function testHandleUserSequentialNonces() public {
        // Last used nonce is 0 (never used yet)
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 0, "User sequential nonce tracker should be 0");

        // Nonce 0 is not permitted
        assertFalse(mockNonceManager.handleUserNonces(userEOA, 0, true, false), "Nonce 0 is not permitted");

        // Last used nonce should still be 0
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 0, "User sequential nonce tracker should still be 0");

        // Nonce 1 is valid
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 1, true, false), "Nonce 1 should be valid");

        // Last used nonce should have been updated to 1
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 1, "User sequential nonce tracker should be 1");

        // Nonce 2 is valid (in simulation mode)
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 2, true, true), "Nonce 2 should be valid in simulation mode");

        // Last used nonce should not have been updated (because simulation mode), it should still be 1
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 1, "User sequential nonce tracker should still be 1");

        // Nonce 3 is invalid
        assertFalse(mockNonceManager.handleUserNonces(userEOA, 3, true, false), "Nonce 3 should be invalid");

        // Nonce 2 is valid
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 2, true, false), "Nonce 2 should be valid");

        // Last used nonce should have been updated to 2
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 2, "User sequential nonce tracker should be 2");

        // Nonce 2 is now invalid
        assertFalse(mockNonceManager.handleUserNonces(userEOA, 2, true, false), "Nonce 2 should be invalid");

        // Last used nonce should still be 2
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 2, "User sequential nonce tracker should still be 2");

        // Getting next nonce
        uint256 nextNonce = mockNonceManager.getUserNextNonce(userEOA, true);

        // Next nonce should be 3
        assertEq(nextNonce, 3, "Next nonce should be 3");

        // Consume the nonce
        assertTrue(mockNonceManager.handleUserNonces(userEOA, nextNonce, true, false), "Next nonce should be valid");

        // Last used nonce should have been updated to 3
        assertEq(mockNonceManager.userSequentialNonceTrackers(userEOA), 3, "User sequential nonce tracker should be 3");

        // Next nonce should be 4
        nextNonce = mockNonceManager.getUserNextNonce(userEOA, true);
        assertEq(nextNonce, 4, "Next nonce should be 4");
    }

    function testHandleDAppSequentialNonces() public {
        // Last used nonce is 0 (never used yet)
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 0, "DApp sequential nonce tracker should be 0");

        // Nonce 0 is not permitted
        assertFalse(mockNonceManager.handleDAppNonces(governanceEOA, 0, false), "Nonce 0 is not permitted");

        // Last used nonce should still be 0
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 0, "DApp sequential nonce tracker should still be 0");

        // Nonce 1 is valid
        assertTrue(mockNonceManager.handleDAppNonces(governanceEOA, 1, false), "Nonce 1 should be valid");

        // Last used nonce should have been updated to 1
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 1, "DApp sequential nonce tracker should be 1");

        // Nonce 2 is valid (in simulation mode)
        assertTrue(mockNonceManager.handleDAppNonces(governanceEOA, 2, true), "Nonce 2 should be valid in simulation mode");

        // Last used nonce should not have been updated (because simulation mode), it should still be 1
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 1, "DApp sequential nonce tracker should still be 1");

        // Nonce 3 is invalid
        assertFalse(mockNonceManager.handleDAppNonces(governanceEOA, 3, false), "Nonce 3 should be invalid");

        // Nonce 2 is valid
        assertTrue(mockNonceManager.handleDAppNonces(governanceEOA, 2, false), "Nonce 2 should be valid");

        // Last used nonce should have been updated to 2
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 2, "DApp sequential nonce tracker should be 2");

        // Nonce 2 is now invalid
        assertFalse(mockNonceManager.handleDAppNonces(governanceEOA, 2, false), "Nonce 2 should be invalid");

        // Last used nonce should still be 2
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 2, "DApp sequential nonce tracker should still be 2");

        // Getting next nonce
        uint256 nextNonce = mockNonceManager.getDAppNextNonce(governanceEOA);

        // Next nonce should be 3
        assertEq(nextNonce, 3, "Next nonce should be 3");

        // Consume the nonce
        assertTrue(mockNonceManager.handleDAppNonces(governanceEOA, nextNonce, false), "Next nonce should be valid");

        // Last used nonce should have been updated to 3
        assertEq(mockNonceManager.dAppSequentialNonceTrackers(governanceEOA), 3, "DApp sequential nonce tracker should be 3");

        // Next nonce should be 4
        nextNonce = mockNonceManager.getDAppNextNonce(governanceEOA);
        assertEq(nextNonce, 4, "Next nonce should be 4");
    }

    function testHandleUserNonSequentialNonces() public {
        // The 0 index bitmap should be 0 (no nonce used yet)
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 0, "User non-sequential nonce tracker should be 0");

        // Nonce 0 is not permitted
        assertFalse(mockNonceManager.handleUserNonces(userEOA, 0, false, false), "Nonce 0 is not permitted");

        // The 0 index bitmap should still be 0
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 0, "User non-sequential nonce tracker should still be 0");

        // Nonce 1 is valid
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 1, false, false), "Nonce 1 should be valid");

        // The 0 index bitmap should have been updated to 1 << 1 = 2
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 2, "User non-sequential nonce tracker should be 2");

        // Nonce 2 is valid (in simulation mode)
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 2, false, true), "Nonce 2 should be valid in simulation mode");

        // The 0 index bitmap should not have been updated (because simulation mode), it should still be 1
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 2, "User non-sequential nonce tracker should still be 2");

        // Nonce 69 is valid
        assertTrue(mockNonceManager.handleUserNonces(userEOA, 69, false, false), "Nonce 69 should be valid");

        // The 0 index bitmap should have been updated to 2 + (1 << 69) = 590295810358705651714
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 590295810358705651714, "User non-sequential nonce tracker should be 590295810358705651714");

        // Nonce 69 is now invalid
        assertFalse(mockNonceManager.handleUserNonces(userEOA, 69, false, false), "Nonce 69 should be invalid");

        // The 0 index bitmap should still be 590295810358705651714
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 590295810358705651714, "User non-sequential nonce tracker should still be 590295810358705651714");

        // Getting next nonce
        uint256 nextNonce = mockNonceManager.getUserNextNonce(userEOA, false);

        // Next nonce should be 2
        assertEq(nextNonce, 2, "Next nonce should be 2");

        // Consume the nonce
        assertTrue(mockNonceManager.handleUserNonces(userEOA, nextNonce, false, false), "Next nonce should be valid");

        // The 0 index bitmap should have been updated to 590295810358705651714 + (1 << 2) = 590295810358705651718
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 590295810358705651718, "User non-sequential nonce tracker should be 590295810358705651718");

        // Try to consume the same nonce again
        assertFalse(mockNonceManager.handleUserNonces(userEOA, nextNonce, false, false), "Next nonce should be invalid");

        // The 0 index bitmap should still be 590295810358705651718
        assertEq(mockNonceManager.userNonSequentialNonceTrackers(userEOA, 0), 590295810358705651718, "User non-sequential nonce tracker should still be 590295810358705651718");

        // Getting the next nonce after 68
        nextNonce = mockNonceManager.getUserNextNonSeqNonceAfter(userEOA, 68);

        // Next nonce should be 70
        assertEq(nextNonce, 70, "Next nonce should be 70");
    }
}
