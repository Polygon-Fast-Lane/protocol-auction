// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Base Imports
import { IAtlas } from "../../interfaces/IAtlas.sol";
import { SafetyBits } from "../../libraries/SafetyBits.sol";

import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/SolverOperation.sol";
import "../../types/UserOperation.sol";
import "../../types/ConfigTypes.sol";
import "../../types/LockTypes.sol";

// Atlas DApp-Control Imports
import { DAppControl } from "../../dapp/DAppControl.sol";

// V4 Imports
import { IPoolManager } from "./IPoolManager.sol";
import { IHooks } from "./IHooks.sol";

contract V4DAppControl is DAppControl {
    struct PreOpsReturn {
        address approvedToken;
        IPoolManager.PoolKey poolKey;
    }

    struct PoolKey {
        bool initialized;
        IPoolManager.PoolKey key;
    }

    bytes4 public constant SWAP = IPoolManager.swap.selector;
    address public immutable hook;
    address public immutable v4Singleton;

    // Map to track when "Non Adversarial" flow is allowed.
    // NOTE: This hook is meant to be used for multiple pairs
    // key: keccak(token0, token1, block.number)
    mapping(bytes32 => bool) public sequenceLock;

    uint256 transient_slot_initialized = uint256(keccak256("V4DAppControl.initialized"));
    uint256 transient_slot_hashLock = uint256(keccak256("V4DAppControl.hashLock"));

    constructor(
        address _atlas,
        address _v4Singleton
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: true,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: true,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: true,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    {
        hook = address(this);
        v4Singleton = _v4Singleton;
    }

    /////////////////////////////////////////////////////////
    //                   ATLAS CALLS                       //
    /////////////////////////////////////////////////////////

    function _checkUserOperation(UserOperation memory userOp) internal view override {
        require(bytes4(userOp.data) == SWAP, "ERR-H10 InvalidFunction");
        require(userOp.dapp == v4Singleton, "ERR-H11 InvalidTo"); // this is wrong
    }

    /////////////// DELEGATED CALLS //////////////////
    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory preOpsData) {
        // This function is delegatecalled
        // address(this) = ExecutionEnvironment
        // msg.sender = Atlas Escrow

        bool initialized;
        assembly {
            initialized := tload(transient_slot_initialized.slot)
        }

        require(!initialized, "ERR-H09 AlreadyInitialized");

        (IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory params) =
            abi.decode(userOp.data[4:], (IPoolManager.PoolKey, IPoolManager.SwapParams));

        // Perform more checks and activate the lock
        V4DAppControl(hook).setLock(key);

        assembly {
            tstore(transient_slot_initialized.slot, 1)
        }

        // Handle forwarding of token approvals, or token transfers.
        // NOTE: The user will have approved the ExecutionEnvironment in a prior call
        PreOpsReturn memory preOpsReturn = PreOpsReturn({
            approvedToken: (
                params.zeroForOne
                    ? IPoolManager.Currency.unwrap(key.currency0)
                    : IPoolManager.Currency.unwrap(key.currency1)
            ),
            poolKey: key
        });

        // TODO: Determine if optimistic transfers are possible
        // (An example)
        if (params.zeroForOne) {
            if (params.amountSpecified > 0) {
                // Buying Pool's token1 with amountSpecified of User's token0
                // ERC20(token0).approve(v4Singleton, amountSpecified);
                SafeTransferLib.safeTransferFrom(
                    IPoolManager.Currency.unwrap(key.currency0),
                    userOp.from,
                    v4Singleton, // <- TODO: confirm
                    uint256(params.amountSpecified)
                );
            } else {
                // Buying amountSpecified of Pool's token1 with User's token0
            }
        } else {
            if (params.amountSpecified > 0) {
                // Buying Pool's token0 with amountSpecified of User's token1
            }
            else {
                // Buying amountSpecified of Pool's token0 with User's token1
            }
        }

        // Return value
        preOpsData = abi.encode(preOpsReturn);
    }

    // This occurs after a Solver has successfully paid their bid, which is
    // held in ExecutionEnvironment.
    function _allocateValueCall(address bidToken, uint256 bidAmount, bytes calldata) internal override {
        // This function is delegatecalled
        // address(this) = ExecutionEnvironment
        // msg.sender = Escrow

        bool initialized;
        assembly {
            initialized := tload(transient_slot_initialized.slot)
        }
        require(!initialized, "ERR-H09 AlreadyInitialized");

        IPoolManager.PoolKey memory key; // todo: finish

        if (bidToken == IPoolManager.Currency.unwrap(key.currency0)) {
            IPoolManager(v4Singleton).donate(key, bidAmount, 0);
        } else {
            IPoolManager(v4Singleton).donate(key, 0, bidAmount);
        }

        // Flag the pool to be open for trading for the remainder of the block
        bytes32 sequenceKey = keccak256(
            abi.encodePacked(
                IPoolManager.Currency.unwrap(key.currency0), IPoolManager.Currency.unwrap(key.currency1), block.number
            )
        );

        sequenceLock[sequenceKey] = true;
    }

    function _postOpsCall(bool solved, bytes calldata data) internal override {
        // This function is delegatecalled
        // address(this) = ExecutionEnvironment
        // msg.sender = Escrow

        if (!solved) revert();

        (bytes memory returnData) = abi.decode(data, (bytes));

        PreOpsReturn memory preOpsReturn = abi.decode(returnData, (PreOpsReturn));

        V4DAppControl(hook).releaseLock(preOpsReturn.poolKey);

        assembly {
            tstore(transient_slot_initialized.slot, 0)
        }
    }

    /////////////// EXTERNAL CALLS //////////////////
    function setLock(IPoolManager.PoolKey memory key) external {
        // This function is a standard call
        // address(this) = hook
        // msg.sender = ExecutionEnvironment

        // Verify that the swapper went through the FastLane Atlas MEV Auction
        // and that DAppControl supplied a valid signature
        require(address(this) == hook, "ERR-H00 InvalidCallee");
        require(hook == _control(), "ERR-H01 InvalidCaller");
        require(_phase() == uint8(ExecutionPhase.PreOps), "ERR-H02 InvalidLockStage");

        bytes32 hashLock;
        assembly {
            hashLock := tload(transient_slot_hashLock.slot)
        }
        require(hashLock == bytes32(0), "ERR-H03 AlreadyActive");

        // Set the storage lock to block reentry / concurrent trading
        hashLock = keccak256(abi.encode(key, msg.sender));
        assembly {
            tstore(transient_slot_hashLock.slot, hashLock)
        }
    }

    function releaseLock(IPoolManager.PoolKey memory key) external {
        // This function is a standard call
        // address(this) = hook
        // msg.sender = ExecutionEnvironment

        // Verify that the swapper went through the FastLane Atlas MEV Auction
        // and that DAppControl supplied a valid signature
        require(address(this) == hook, "ERR-H20 InvalidCallee");
        require(hook == _control(), "ERR-H21 InvalidCaller");
        require(_phase() == uint8(ExecutionPhase.PostOps), "ERR-H22 InvalidLockStage");

        bytes32 hashLock;
        assembly {
            hashLock := tload(transient_slot_hashLock.slot)
        }
        require(hashLock == keccak256(abi.encode(key, msg.sender)), "ERR-H23 InvalidKey");

        // Release the storage lock
        assembly {
            tstore(transient_slot_hashLock.slot, 0)
        }
        //delete hashLock;
    }

    ///////////////// GETTERS & HELPERS // //////////////////

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        // This is a helper function called by solvers
        // so that they can get the proper format for
        // submitting their bids to the hook.

        (IPoolManager.PoolKey memory key,) = abi.decode(userOp.data, (IPoolManager.PoolKey, IPoolManager.SwapParams));

        // TODO: need to return whichever token the solvers are trying to buy
        return IPoolManager.Currency.unwrap(key.currency0);
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
