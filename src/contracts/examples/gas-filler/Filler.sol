//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// Atlas Base Imports
import { IAtlas } from "../../interfaces/IAtlas.sol";
import { IExecutionEnvironment } from "../../interfaces/IExecutionEnvironment.sol";

import { SafetyBits } from "../../libraries/SafetyBits.sol";

import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";

// Atlas DApp-Control Imports
import { DAppControl } from "../../dapp/DAppControl.sol";

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Filler is DAppControl {
    uint256 public constant CONTROL_GAS_USAGE = 250_000;

    struct AccessTuple {
        address accessAddress;
        bytes32[] accessStorageKeys;
    }

    // TODO: Need to use assembly to pack and unpack this correctly. Surely there's a lib somewhere?
    struct ApprovalTx {
        // address from; // technically txs don't have a from, may need to remove from sig
        uint64 txType;
        uint256 chainID;
        uint64 nonce;
        uint256 gasPrice; // legacy tx gasprice
        uint256 gasFeeCap; // 1559 maxFeePerGas
        uint256 gasTipCap; // 1559 maxPriorityFeePerGas
        uint64 gasLimit; // aka gas
        address to;
        uint256 value; // aka amount
        bytes data;
        AccessTuple[] accessList;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // NOTE: this is accessed on the control contract itself, not the EE
    uint256 public owed;
    uint256 public prepaid;

    // NOTE: this is accessed on the control contract itself, not the EE?
    address public userLock;
    bytes32 public hashLock;

    constructor(
        address _atlas,
        address _wrappedGasToken
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: false,
                trackPreOpsReturnData: false,
                trackUserReturnData: true,
                delegateUser: true,
                requirePreSolver: true,
                requirePostSolver: true,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: false,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: true,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: true,
                exPostBids: false,
                allowAllocateValueFailure: false,
                multipleSuccessfulSolvers: false
            })
        )
    { }

    // This occurs after a Solver has successfully paid their bid, which is
    // held in ExecutionEnvironment.
    function _allocateValueCall(address bidToken, uint256 bidAmount, bytes calldata) internal override {
        // NOTE: gas value xferred to user in postSolverCall
        // Pay the solver (since auction is reversed)
        // Address Pointer = winning solver.

        // revert for ERC20 tokens
        if (bidToken != address(0)) revert("ERC20 bids not supported");

        SafeTransferLib.safeTransferETH(_user(), bidAmount);
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        address solverTo = solverOp.solver;
        if (solverTo == address(this) || solverTo == _control() || solverTo == ATLAS) {
            revert();
        }

        (address approvalToken, uint256 maxTokenAmount,) = abi.decode(returnData, (address, uint256, uint256));

        if (solverOp.bidAmount > maxTokenAmount) revert();
        if (solverOp.bidToken != approvalToken) revert();

        _transferDAppERC20(approvalToken, solverOp.solver, solverOp.bidAmount);

        return; // success
    }

    function _postSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal override {
        (, uint256 maxTokenAmount, uint256 gasNeeded) = abi.decode(returnData, (address, uint256, uint256));

        require(address(this).balance >= gasNeeded, "ERR - EXISTING GAS BALANCE");

        bytes memory data = abi.encodeCall(this.postOpBalancing, maxTokenAmount - solverOp.bidAmount);

        (bool success,) = _control().call(_forward(data));
        require(success, "HITTING THIS = JOB OFFER");

        return; // success
    }

    ///////////////// GETTERS & HELPERS // //////////////////

    function getBidFormat(UserOperation calldata userOp) public view override returns (address bidToken) {
        // This is a helper function called by solvers
        // so that they can get the proper format for
        // submitting their bids to the hook.
        (, ApprovalTx memory approvalTx) = _decodeRawData(userOp.data[4:]);
        return approvalTx.to;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    ///////////////////// DAPP STUFF ///////////////////////

    function postOpBalancing(uint256 prepaidAmount) external {
        require(msg.sender == _activeEnvironment(), "ERR - INVALID SENDER");
        require(address(this) == _control(), "ERR - INVALID CONTROL");
        require(_depth() == 2, "ERR - INVALID DEPTH");

        prepaid = prepaidAmount;
    }

    // FUN AND TOTALLY UNNECESSARY MIND WORM
    // (BUT IT HELPS WITH MENTALLY GROKKING THE FLOW)
    function approve(bytes calldata data) external returns (bytes memory) {
        // CASE: Base call
        if (msg.sender == ATLAS) {
            require(address(this) != _control(), "ERR - NOT DELEGATED");
            return _innerApprove(data);
        }

        // CASE: Nested call from Atlas EE
        if (msg.sender == _activeEnvironment()) {
            require(address(this) == _control(), "ERR - INVALID CONTROL");
            return _outerApprove(data);
        }

        // CASE: Non-Atlas external call
        require(address(this) == _control(), "ERR - INVALID CONTROL");
        _externalApprove(data);
        return new bytes(0);
    }

    function _innerApprove(bytes calldata data) internal returns (bytes memory) {
        (, ApprovalTx memory approvalTx) = _decodeRawData(data);

        address approvalToken = approvalTx.to;

        require(IERC20(approvalToken).balanceOf(address(this)) == 0, "ERR - EXISTING ERC20 BALANCE");
        require(address(this).balance == 0, "ERR - EXISTING GAS BALANCE");

        // TODO: use assembly (current impl is a lazy way to grab the approval tx data)
        bytes memory mData = abi.encodeCall(this.approve, bytes.concat(approvalTx.data, data));

        (bool success, bytes memory returnData) = _control().call(_forward(mData));
        // NOTE: approvalTx.data includes func selector

        require(success, "ERR - REJECTED");

        return abi.decode(returnData, (bytes));
    }

    function _outerApprove(bytes calldata data) internal returns (bytes memory) {
        (address spender, uint256 amount, uint256 gasNeeded, ApprovalTx memory approvalTx) =
            abi.decode(data[4:], (address, uint256, uint256, ApprovalTx));

        address user = _user();
        address approvalToken = approvalTx.to;

        require(user.code.length == 0, "ERR - NOT FOR SMART ACCOUNTS"); // NOTE shouldn't be necessary b/c sig check
        // but might change sig check in future versions to support smart accounts, in which case revisit safety
        // checks at this stage.

        require(spender == address(this), "ERR - INVALID SPENDER");
        require(IERC20(approvalToken).allowance(user, address(this)) == 0, "ERR - EXISTING APPROVAL");
        require(IERC20(approvalToken).allowance(address(this), ATLAS) >= amount, "ERR - TOKEN UNAPPROVED");
        require(amount <= IERC20(approvalToken).balanceOf(address(this)), "ERR - POOL BALANCE TOO LOW");
        require(amount <= IERC20(approvalToken).balanceOf(user), "ERR - USER BALANCE TOO LOW");
        require(userLock == address(0), "ERR - USER ALREADY LOCKED");
        require(hashLock == bytes32(0), "ERR - HASH LOCK ALREADY LOCKED");
        require(owed == 0, "ERR - BALANCE OUTSTANDING");
        require(prepaid == 0, "ERR - USER ALREADY OWES");

        // TODO: Gas calcs (tx type specific) to ensure that allowance gas cost is covered by amount

        hashLock = _getApprovalTxHash(approvalTx);
        userLock = user;
        owed = amount;

        // IERC20(approvalToken).transfer(msg.sender, amount);
        // NOTE: We handle the token xfers with dapp-side permit69

        return abi.encode(approvalToken, amount, gasNeeded);
    }

    function _externalApprove(bytes calldata data) internal {
        // data = UserOperation.data
        require(bytes4(data) == this.approve.selector, "ERR - INVALID FUNC");

        (, ApprovalTx memory approvalTx) = abi.decode(data[:4], (uint256, ApprovalTx));

        // Check locks
        bytes32 approvalHash = _getApprovalTxHash(approvalTx);
        require(approvalHash == hashLock, "ERR - INVALID HASH");
        require(userLock != address(0), "ERR - USER UNLOCKED");

        // Verify balances
        address approvalToken = approvalTx.to;

        address _userLock = userLock;
        uint256 _owed = owed;
        uint256 _prepaid = prepaid;

        require(_owed >= _prepaid, "ERR - PREPAID TOO HIGH"); // should get caught as overflow below

        uint256 allowance = IERC20(approvalToken).allowance(_userLock, address(this));
        require(allowance >= _owed - _prepaid, "ERR - ALLOWANCE TOO LOW");

        // use up the entire allowance
        IERC20(approvalToken).transferFrom(_userLock, address(this), allowance);

        // transfer back the prepaid amount
        IERC20(approvalToken).transfer(_userLock, _prepaid);

        // Clear the locks
        delete userLock;
        delete hashLock;
        delete owed;
        delete prepaid;
    }

    function _decodeRawData(bytes calldata data)
        internal
        pure
        returns (uint256 gasNeeded, ApprovalTx memory approvalTx)
    {
        // BELOW HERE IS WRONG - TODO: COMPLETE
        (gasNeeded, approvalTx) = abi.decode(data, (uint256, ApprovalTx));
        address signer = _user();
        // TODO: NEED TO SIG VERIFY JUST approvalTx
        // ABOVE HERE IS WRONG - TODO: COMPLETE

        require(signer == _user(), "ERR - INVALID SIGNER");
    }

    function _getApprovalTxHash(ApprovalTx memory approvalTx) internal returns (bytes32) {
        // TODO: this is wrong
        return keccak256(abi.encode(approvalTx));
    }
}
