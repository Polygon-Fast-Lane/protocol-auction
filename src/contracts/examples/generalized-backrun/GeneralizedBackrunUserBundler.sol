//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "../../dapp/DAppControl.sol";
import { DAppOperation } from "../../types/DAppOperation.sol";
import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";

// Interface Import
import { IAtlasVerification } from "../../interfaces/IAtlasVerification.sol";
import { IExecutionEnvironment } from "../../interfaces/IExecutionEnvironment.sol";
import { IAtlas } from "../../interfaces/IAtlas.sol";

struct Approval {
    address token;
    address spender;
    uint256 amount;
}

struct Beneficiary {
    address owner;
    uint256 percentage; // out of 100
}
// NOTE user gets remainder

interface IGeneralizedBackrunProxy {
    function getUser() external view returns (address);
}

contract GeneralizedBackrunUserBundler is DAppControl {
    address private _userLock = address(1); // TODO: Convert to transient storage

    uint256 private constant _FEE_BASE = 100;

    //      USER                TOKEN       AMOUNT
    mapping(address => mapping(address => uint256)) internal s_deposits;

    //   SolverOpHash   SolverOperation
    mapping(bytes32 => SolverOperation) public S_solverOpCache;

    //      UserOpHash  SolverOpHash[]
    mapping(bytes32 => bytes32[]) public S_solverOpHashes;

    constructor(address _atlas)
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
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: false,
                zeroSolvers: true,
                reuseUserOp: true,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false,
                trustedOpHash: true,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: true
            })
        )
    { }

    // ---------------------------------------------------- //
    //                       Custom                         //
    // ---------------------------------------------------- //

    /////////////////////////////////////////////////////////
    //              CONTROL FUNCTIONS                      //
    //                 (not delegated)                     //
    /////////////////////////////////////////////////////////

    modifier onlyAsControl() {
        if (address(this) != CONTROL) revert();
        _;
    }

    modifier withUserLock(address user) {
        if (_userLock != address(1)) revert();
        _userLock = user;
        _;
        _userLock = address(1);
    }

    modifier onlyWhenUnlocked() {
        if (_userLock != address(1)) revert();
        _;
    }

    function getUser() external view onlyAsControl returns (address) {
        address _user = _userLock;
        if (_user == address(1)) revert();
        return _user;
    }

    function addSolverOp(SolverOperation calldata solverOp) external onlyAsControl {
        /*
        //   SolverOpHash   SolverOperation
        mapping(bytes32 => SolverOperation) public S_solverOpCache;

        //      UserOpHash  SolverOpHash[]
        mapping(bytes32 => bytes32[]) public S_solverOpHashes;
        */
        if (msg.sender != solverOp.from) revert();

        bytes32 _solverOpHash = keccak256(abi.encode(solverOp));

        S_solverOpCache[_solverOpHash] = solverOp;
        S_solverOpHashes[solverOp.userOpHash].push(_solverOpHash);
    }

    // Entrypoint function for usage with permit / permit2 / bridges / whatever
    function bundledProxyCall(
        UserOperation calldata userOp,
        address transferHelper,
        bytes calldata transferData,
        bytes32[] calldata solverOpHashes
    )
        external
        payable
        withUserLock(userOp.from)
        onlyAsControl
    {
        // Decode the token information
        (Approval[] memory _approvals,,,,) =
            abi.decode(userOp.data[4:], (Approval[], address[], Beneficiary[], address, bytes));

        // Process token transfers if necessary.  If transferHelper == address(0), skip.
        if (transferHelper != address(0)) {
            (bool _success, bytes memory _data) = transferHelper.call(transferData);
            if (!_success) {
                assembly {
                    revert(add(_data, 32), mload(_data))
                }
            }

            // Get the execution environment address
            (address _environment,,) = IAtlas(ATLAS).getExecutionEnvironment(userOp.from, CONTROL);

            for (uint256 i; i < _approvals.length; i++) {
                uint256 _balance = IERC20(_approvals[i].token).balanceOf(address(this));
                if (_balance != 0) {
                    IERC20(_approvals[i].token).transfer(_environment, _balance);
                }
            }
        }

        uint256 _bundlerRefundTracker = address(this).balance - msg.value;

        bytes32 _userOpHash = IAtlasVerification(ATLAS_VERIFICATION).getUserOperationHash(userOp);

        DAppOperation memory _dAppOp = DAppOperation({
            from: address(this), // signer of the DAppOperation
            to: ATLAS, // Atlas address
            nonce: 0, // Atlas nonce of the DAppOperation available in the AtlasVerification contract
            deadline: userOp.deadline, // block.number deadline for the DAppOperation
            control: address(this), // DAppControl address
            bundler: address(this), // Signer of the atlas tx (msg.sender)
            userOpHash: _userOpHash, // keccak256 of userOp.to, userOp.data
            callChainHash: bytes32(0), // keccak256 of the solvers' txs
            signature: new bytes(0) // DAppOperation signed by DAppOperation.from
         });

        // TODO: Add in the solverOp grabber
        SolverOperation[] memory _solverOps = _getSolverOps(solverOpHashes);

        (bool _success, bytes memory _data) =
            ATLAS.call{ value: msg.value }(abi.encodeCall(IAtlas.metacall, (userOp, _solverOps, _dAppOp, address(0))));
        if (!_success) {
            assembly {
                revert(add(_data, 32), mload(_data))
            }
        }

        if (address(this).balance > _bundlerRefundTracker) {
            SafeTransferLib.safeTransferETH(msg.sender, address(this).balance - _bundlerRefundTracker);
        }

        // TODO: add bundler subsidy capabilities for apps.
    }

    function _getSolverOps(bytes32[] calldata solverOpHashes)
        internal
        view
        returns (SolverOperation[] memory solverOps)
    {
        solverOps = new SolverOperation[](solverOpHashes.length);

        uint256 _j;
        for (uint256 i; i < solverOpHashes.length; i++) {
            SolverOperation memory _solverOp = S_solverOpCache[solverOpHashes[i]];
            if (_solverOp.from != address(0)) {
                solverOps[_j++] = _solverOp;
            }
        }
    }

    /////////////////////////////////////////////////////////
    //        EXECUTION ENVIRONMENT FUNCTIONS              //
    //                 (not delegated)                     //
    /////////////////////////////////////////////////////////

    // NOTE: this is delegatecalled
    function proxyCall(
        Approval[] calldata approvals,
        address[] calldata receivables,
        Beneficiary[] calldata beneficiaries,
        address innerTarget,
        bytes calldata innerData
    )
        external
        payable
        onlyAtlasEnvironment
        returns (Beneficiary[] memory)
    {
        bool _isProxied;

        // CASE: Bundled (Force all bundlers to go through bundler contract (this one))
        if (_bundler() == CONTROL) {
            if (IGeneralizedBackrunProxy(CONTROL).getUser() != _user()) revert();
            _isProxied = true;

            // CASE: Direct
        } else if (_bundler() != _user()) {
            // revert if bundler isn't CONTROL or _user()
            revert();
        }

        return _proxyCall(approvals, receivables, beneficiaries, innerTarget, innerData, _isProxied);
    }

    function _proxyCall(
        Approval[] calldata approvals,
        address[] calldata receivables,
        Beneficiary[] calldata beneficiaries,
        address innerTarget,
        bytes calldata innerData,
        bool isProxied
    )
        internal
        returns (Beneficiary[] memory)
    {
        address _recipient = _user();

        // Handle approvals
        for (uint256 i; i < approvals.length; i++) {
            Approval calldata approval = approvals[i];

            // CASE: Proxied - user should have signed a permit or permit2
            if (isProxied) {
                uint256 _currentBalance = IERC20(approval.token).balanceOf(address(this));
                if (approval.amount > _currentBalance) {
                    _transferUserERC20(approval.token, address(this), approval.amount - _currentBalance);
                }
            } else {
                // Transfer the User's token to the EE:
                _transferUserERC20(approval.token, address(this), approval.amount);
            }

            // Have the EE approve the User's target:
            IERC20(approval.token).approve(approval.spender, approval.amount);
        }

        // Do the actual call
        (bool _success, bytes memory _data) = innerTarget.call{ value: msg.value }(innerData);
        // Bubble up the revert message (note there's not really a reason to do this,
        // we'll replace with a custom error soon.
        if (!_success) {
            assembly {
                revert(add(_data, 32), mload(_data))
            }
        }

        // Reset approvals for the EE
        for (uint256 i; i < approvals.length; i++) {
            Approval calldata approval = approvals[i];

            // Remove the EE's approvals
            IERC20(approval.token).approve(approval.spender, 0);

            uint256 _balance = IERC20(approval.token).balanceOf(address(this));

            // Transfer any leftover tokens back to the User
            if (_balance != 0) {
                IERC20(approval.token).transfer(_recipient, _balance);
            }
        }

        // Return the receivable tokens to the user
        for (uint256 i; i < receivables.length; i++) {
            address _receivable = receivables[i];
            uint256 _balance = IERC20(_receivable).balanceOf(address(this));

            // Transfer the EE's tokens (note that this will revert if balance is insufficient)
            if (_balance != 0) {
                IERC20(_receivable).transfer(_recipient, _balance);
            }
        }

        // Forward any value that accrued to the bundler (either user or contract) - don't share w/ solvers
        uint256 _balance = address(this).balance;
        if (_balance > 0) {
            SafeTransferLib.safeTransferETH(_bundler(), _balance);
        }
        return beneficiaries;
    }

    // ---------------------------------------------------- //
    //                     Atlas hooks                      //
    // ---------------------------------------------------- //

    function _allocateValueCall(address bidToken, uint256, bytes calldata returnData) internal override {
        // NOTE: The _user() receives any remaining balance after the other beneficiaries are paid.
        Beneficiary[] memory _beneficiaries = abi.decode(returnData, (Beneficiary[]));

        uint256 _unallocatedPercent = _FEE_BASE;
        uint256 _balance = address(this).balance;

        // Return the receivable tokens to the user
        for (uint256 i; i < _beneficiaries.length; i++) {
            uint256 _percentage = _beneficiaries[i].percentage;
            if (_percentage < _unallocatedPercent) {
                _unallocatedPercent -= _percentage;
                SafeTransferLib.safeTransferETH(_beneficiaries[i].owner, _balance * _percentage / _FEE_BASE);
            } else {
                SafeTransferLib.safeTransferETH(_beneficiaries[i].owner, address(this).balance);
            }
        }

        // Transfer the remaining value to the user
        if (_unallocatedPercent != 0) {
            SafeTransferLib.safeTransferETH(_user(), address(this).balance);
        }
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public pure override returns (address bidToken) {
        return address(0);
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
