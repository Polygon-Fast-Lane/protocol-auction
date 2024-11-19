// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { BaseTest } from "./base/BaseTest.t.sol";
import "./base/TestUtils.sol";

import { Permit69 } from "../src/contracts/atlas/Permit69.sol";
import { Mimic } from "../src/contracts/common/Mimic.sol";
import { FactoryLib } from "../src/contracts/atlas/FactoryLib.sol";

import { SAFE_USER_TRANSFER, SAFE_DAPP_TRANSFER } from "../src/contracts/atlas/Permit69.sol";
import { AtlasEvents } from "../src/contracts/types/AtlasEvents.sol";
import { AtlasErrors } from "../src/contracts/types/AtlasErrors.sol";

import { ExecutionEnvironment } from "../src/contracts/common/ExecutionEnvironment.sol";

import { Atlas } from "../src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "../src/contracts/atlas/AtlasVerification.sol";

import "../src/contracts/types/LockTypes.sol";
import "../src/contracts/types/DAppOperation.sol";

contract Permit69Test is BaseTest {
    Context ctx;
    address mockUser;

    MockAtlasForPermit69Tests public mockAtlas;

    address public mockExecutionEnvAddress;
    address public mockDAppControl;
    uint32 public mockCallConfig;

    function setUp() public virtual override {
        BaseTest.setUp();

        mockUser = address(0x13371337);

        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);

        vm.startPrank(deployer);
        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);
        FactoryLib factoryLib = new FactoryLib(address(execEnvTemplate));

        mockAtlas = new MockAtlasForPermit69Tests({
            escrowDuration: 64,
            atlasSurchargeRate: DEFAULT_ATLAS_SURCHARGE_RATE,
            bundlerSurchargeRate: DEFAULT_BUNDLER_SURCHARGE_RATE,
            verification: expectedAtlasVerificationAddr,
            simulator: address(0),
            factoryLib: address(factoryLib),
            _surchargeRecipient: deployer,
            l2GasCalculator: address(0)
        });
        vm.stopPrank();

        console.log("Mock Atlas address: ", address(mockAtlas));
        console.log("Predicted atlas address: ", expectedAtlasAddr);


        assertEq(address(mockAtlas), expectedAtlasAddr, "Atlas address mismatch");

        mockDAppControl = address(0x123321);
        mockCallConfig = 0;

        mockExecutionEnvAddress = mockAtlas.getOrCreateExecutionEnvironment({
            user: mockUser,
            control: mockDAppControl,
            callConfig: mockCallConfig
        });

        ctx = Context({
            executionEnvironment: mockExecutionEnvAddress,
            userOpHash: bytes32(0),
            bundler: address(0),
            solverSuccessful: false,
            paymentsSuccessful: false,
            solverIndex: 0,
            solverCount: 0,
            phase: uint8(ExecutionPhase.PreOps),
            solverOutcome: 0,
            bidFind: false,
            isSimulation: false,
            callDepth: 0
        });

        mockAtlas.setLock(mockExecutionEnvAddress, mockCallConfig);
        mockAtlas.setContext(ctx);
        mockAtlas.setEnvironment(mockExecutionEnvAddress);

        deal(WETH_ADDRESS, mockDAppControl, 100e18);
        deal(WETH_ADDRESS, mockUser, 100e18);
    }

    // transferUserERC20 tests

    function testTransferUserERC20RevertsIsCallerNotExecutionEnv() public {
        ExecutionPhase phase = ExecutionPhase.PreOps;
        mockAtlas.setContext(ctx);
        mockAtlas.setPhase(phase);

        vm.prank(solverOneEOA);
        vm.expectRevert(AtlasErrors.InvalidEnvironment.selector);
        mockAtlas.transferUserERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);
    }

    function testTransferUserERC20RevertsIfLockStateNotValid() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        ExecutionPhase phase = ExecutionPhase.Uninitialized;
        mockAtlas.setContext(ctx);
        mockAtlas.setPhase(phase);

        // Check reverts at all invalid execution phases
        vm.startPrank(mockExecutionEnvAddress);

        // Uninitialized
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferUserERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        // AllocateValue
        phase = ExecutionPhase.AllocateValue;
        mockAtlas.setContext(ctx);
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferUserERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        // Releasing
        phase = ExecutionPhase.Uninitialized;
        mockAtlas.setContext(ctx);
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferUserERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        vm.stopPrank();
    }

    function testTransferUserERC20SuccessfullyTransfersTokens() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        uint256 wethTransferred = 10e18;

        uint256 userWethBefore = WETH.balanceOf(mockUser);
        uint256 solverWethBefore = WETH.balanceOf(solverOneEOA);

        ExecutionPhase phase = ExecutionPhase.PreOps;

        mockAtlas.setPhase(phase);

        vm.prank(mockUser);
        WETH.approve(address(mockAtlas), wethTransferred);

        vm.prank(mockExecutionEnvAddress);
        mockAtlas.transferUserERC20(WETH_ADDRESS, solverOneEOA, wethTransferred, mockUser, mockDAppControl);

        assertEq(WETH.balanceOf(mockUser), userWethBefore - wethTransferred, "User did not lose WETH");
        assertEq(WETH.balanceOf(solverOneEOA), solverWethBefore + wethTransferred, "Solver did not gain WETH");
    }

    // transferDAppERC20 tests

    function testTransferDAppERC20RevertsIsCallerNotExecutionEnv() public {
        ExecutionPhase phase = ExecutionPhase.PreOps;
        mockAtlas.setPhase(phase);

        vm.prank(solverOneEOA);
        vm.expectRevert(AtlasErrors.InvalidEnvironment.selector);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);
    }

    function testTransferDAppERC20RevertsIfLockStateNotValid() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        // Check reverts at all invalid execution phases
        vm.startPrank(mockExecutionEnvAddress);

        // Uninitialized
        ExecutionPhase phase = ExecutionPhase.Uninitialized;
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        // UserOperation
        phase = ExecutionPhase.UserOperation;
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        // SolverOperations
        phase = ExecutionPhase.SolverOperation;
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        // Releasing
        phase = ExecutionPhase.Uninitialized;
        mockAtlas.setPhase(phase);
        vm.expectRevert(AtlasErrors.InvalidLockState.selector);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, 10e18, mockUser, mockDAppControl);

        vm.stopPrank();
    }

    function testTransferDAppERC20SuccessfullyTransfersTokens() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        uint256 wethTransferred = 10e18;

        uint256 dAppWethBefore = WETH.balanceOf(mockDAppControl);
        uint256 solverWethBefore = WETH.balanceOf(solverOneEOA);

        ExecutionPhase phase = ExecutionPhase.PreOps;
        mockAtlas.setPhase(phase);

        vm.prank(mockDAppControl);
        WETH.approve(address(mockAtlas), wethTransferred);

        vm.prank(mockExecutionEnvAddress);
        mockAtlas.transferDAppERC20(WETH_ADDRESS, solverOneEOA, wethTransferred, mockUser, mockDAppControl);

        assertEq(WETH.balanceOf(mockDAppControl), dAppWethBefore - wethTransferred, "DApp did not lose WETH");
        assertEq(WETH.balanceOf(solverOneEOA), solverWethBefore + wethTransferred, "Solver did not gain WETH");
    }

    // constants tests
    function testConstantValueOfSafeUserTransfer() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        string memory expectedBitMapString = "0000101011100000";
        // Safe phases for user transfers are PreOps, UserOperation, and DAppOperation
        // preOpsPhaseSafe = 0000 0000 0010 0000
        uint8 preOpsPhaseSafe = uint8(ExecutionPhase.PreOps);
        // userOpPhaseSafe = 0000 0000 0100 0000
        uint8 userOpPhaseSafe = uint8(ExecutionPhase.UserOperation);

        uint8 preSolverOpsPhaseSafe = uint8(ExecutionPhase.PreSolver);
        uint8 postSolverOpsPhaseSafe = uint8(ExecutionPhase.PostSolver);
        // verificationPhaseSafe = 0000 0100 0000 0000
        uint8 verificationPhaseSafe = uint8(ExecutionPhase.PostOps);

        uint8 expectedSafeUserTransferBitMap =
            preOpsPhaseSafe | userOpPhaseSafe | preSolverOpsPhaseSafe | postSolverOpsPhaseSafe | verificationPhaseSafe;

        assertEq(
            mockAtlas.getSafeUserTransfer(),
            expectedSafeUserTransferBitMap,
            "Expected to be the bitwise OR of the safe phases (0000 0100 1110 0000)"
        );
        assertEq(
            TestUtils.uint16ToBinaryString(expectedSafeUserTransferBitMap),
            expectedBitMapString,
            "Binary string form of bit map not as expected"
        );
    }

    function testConstantValueOfSafeDAppTransfer() public {
        // FIXME: fix before merging spearbit-reaudit branch
        vm.skip(true);

        string memory expectedBitMapString = "0000111010100000";
        // Safe phases for dApp transfers are PreOps, AllocateValue, and DAppOperation
        // preOpsPhaseSafe = 0000 0000 0010 0000
        uint8 preOpsPhaseSafe = uint8(ExecutionPhase.PreOps);
        // userOpPhaseSafe = 0000 0000 0100 0000
        // uint8 userOpPhaseSafe = uint8(ExecutionPhase.UserOperation);

        uint8 preSolverOpsPhaseSafe = uint8(ExecutionPhase.PreSolver);
        uint8 postSolverOpsPhaseSafe = uint8(ExecutionPhase.PostSolver);
        uint8 allocateValuePhaseSafe = uint8(ExecutionPhase.AllocateValue);
        // verificationPhaseSafe = 0000 0100 0000 0000
        uint8 verificationPhaseSafe = uint8(ExecutionPhase.PostOps);

        uint16 expectedSafeDAppTransferBitMap = preOpsPhaseSafe | preSolverOpsPhaseSafe | postSolverOpsPhaseSafe
            | allocateValuePhaseSafe | verificationPhaseSafe;

        assertEq(
            mockAtlas.getSafeDAppTransfer(),
            expectedSafeDAppTransferBitMap,
            "Expected to be the bitwise OR of the safe phases (0000 0111 0010 0000)"
        );
        assertEq(
            TestUtils.uint16ToBinaryString(expectedSafeDAppTransferBitMap),
            expectedBitMapString,
            "Binary string form of bit map not as expected"
        );
    }

    function testVerifyCallerIsExecutionEnv() public {
        vm.prank(solverOneEOA);
        vm.expectRevert(AtlasErrors.InvalidEnvironment.selector);
        mockAtlas.verifyCallerIsExecutionEnv(mockUser, mockDAppControl, mockCallConfig);

        vm.prank(mockExecutionEnvAddress);
        bool res = mockAtlas.verifyCallerIsExecutionEnv(mockUser, mockDAppControl, mockCallConfig);
        assertTrue(res, "Should return true and not revert");
    }
}

// Mock Atlas with standard implementations of Permit69's virtual functions
contract MockAtlasForPermit69Tests is Atlas {
    constructor(
        uint256 escrowDuration,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate,
        address verification,
        address simulator,
        address _surchargeRecipient,
        address l2GasCalculator,
        address factoryLib
    )
        Atlas(
            escrowDuration,
            atlasSurchargeRate,
            bundlerSurchargeRate,
            verification,
            simulator,
            _surchargeRecipient,
            l2GasCalculator,
            factoryLib
        )
    { }

    // Declared in SafetyLocks.sol in the canonical Atlas system
    // The only property relevant to testing Permit69 is _ctx.phase (bitwise uint16)
    Context internal _ctx;
    address internal _environment;

    function getSafeUserTransfer() public pure returns (uint16) {
        return SAFE_USER_TRANSFER;
    }

    function getSafeDAppTransfer() public pure returns (uint16) {
        return SAFE_DAPP_TRANSFER;
    }

    // Setters for testing
    function setContext(Context memory ctx) public {
        _ctx = ctx;
    }

    function setEnvironment(address _activeEnvironment) public {
        _environment = _activeEnvironment;
    }

    function setLock(address _activeEnvironment, uint32 callConfig) public {
        _setLock({
            activeEnvironment: _activeEnvironment,
            callConfig: callConfig,
            phase: uint8(ExecutionPhase.Uninitialized)
        });
    }

    function setPhase(ExecutionPhase _phase) public {
        _setLockPhase(uint8(_phase));
        _ctx.phase = uint8(_phase);
    }

    function getOrCreateExecutionEnvironment(
        address user,
        address control,
        uint32 callConfig
    )
        public
        returns (address executionEnvironment)
    {
        return _getOrCreateExecutionEnvironment(user, control, callConfig);
    }

    function verifyUserControlExecutionEnv(
        address sender,
        address user,
        address control,
        uint32 callConfig
    )
        internal
        returns (bool)
    {
        return _verifyUserControlExecutionEnv(sender, user, control, callConfig);
    }

    // Exposing above overridden function for testing and Permit69 coverage
    function verifyCallerIsExecutionEnv(address user, address control, uint32 callConfig) public returns (bool) {
        if (!_verifyUserControlExecutionEnv(msg.sender, user, control, callConfig)) {
            revert AtlasErrors.InvalidEnvironment();
        }
        return true; // Added to test lack of revert
    }

    // Implemented in Factory.sol in the canonical Atlas system
    function _getLockState() internal view virtual returns (Context memory) {
        return _ctx;
    }
}
