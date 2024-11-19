//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { Base } from "./ExecutionBase.sol";

import { IAtlas } from "../interfaces/IAtlas.sol";
import { ISolverContract } from "../interfaces/ISolverContract.sol";
import { IDAppControl } from "../interfaces/IDAppControl.sol";
import { AtlasErrors } from "../types/AtlasErrors.sol";
import { CallBits } from "../libraries/CallBits.sol";
import "../types/SolverOperation.sol";
import "../types/UserOperation.sol";
import "../types/EscrowTypes.sol";

/// @title ExecutionEnvironment
/// @author FastLane Labs
/// @notice An Execution Environment contract is deployed for each unique combination of User address x DAppControl
/// address that interacts with the Atlas protocol via a metacall transaction.
/// @notice IMPORTANT: The contract is not meant to be used as a smart contract wallet with any other protocols other
/// than Atlas
contract ExecutionEnvironment is Base {
    using CallBits for uint32;

    constructor(address atlas) Base(atlas) { }

    modifier validUser(UserOperation calldata userOp) {
        if (userOp.to != ATLAS || userOp.dapp == ATLAS) revert AtlasErrors.InvalidTo();
        _;
    }

    //////////////////////////////////
    ///    CORE CALL FUNCTIONS     ///
    //////////////////////////////////

    /// @notice The preOpsWrapper function may be called by Atlas before the UserOperation is executed.
    /// @dev This contract is called by the Atlas contract, and delegatecalls the DAppControl contract via the
    /// corresponding `preOpsCall` function.
    /// @param userOp The UserOperation struct.
    /// @return preOpsData Data to be passed to the next call phase.
    function preOpsWrapper(UserOperation calldata userOp)
        external
        validUser(userOp)
        onlyAtlasEnvironment
        returns (bytes memory)
    {
        bytes memory _preOpsData = _forward(abi.encodeCall(IDAppControl.preOpsCall, userOp));

        bool _success;
        (_success, _preOpsData) = _control().delegatecall(_preOpsData);

        if (!_success) revert AtlasErrors.PreOpsDelegatecallFail();

        _preOpsData = abi.decode(_preOpsData, (bytes));
        return _preOpsData;
    }

    /// @notice The userWrapper function is called by Atlas to execute the UserOperation.
    /// @dev This contract is called by the Atlas contract, and either delegatecalls or calls the DAppControl contract
    /// with `userOp.data` as calldata, depending on the the needsDelegateUser flag.
    /// @param userOp The UserOperation struct.
    /// @return returnData Data to be passed to the next call phase.
    function userWrapper(UserOperation calldata userOp)
        external
        payable
        validUser(userOp)
        onlyAtlasEnvironment
        returns (bytes memory returnData)
    {
        if (userOp.value > msg.value) revert AtlasErrors.UserOpValueExceedsBalance();

        // Do not attach extra calldata via `_forward()` if contract called is not dAppControl, as the additional
        // calldata may cause unexpected behaviour in third-party protocols
        bytes memory _data = (userOp.dapp != userOp.control) ? userOp.data : _forward(userOp.data);
        bool _success;

        if (_config().needsDelegateUser()) {
            (_success, returnData) = userOp.dapp.delegatecall(_data);
            if (!_success) revert AtlasErrors.UserWrapperDelegatecallFail();
        } else {
            // regular user call - executed at regular destination and not performed locally
            (_success, returnData) = userOp.dapp.call{ value: userOp.value }(_data);
            if (!_success) revert AtlasErrors.UserWrapperCallFail();
        }
    }

    /// @notice The postOpsWrapper function may be called by Atlas as the last phase of a `metacall` transaction.
    /// @dev This contract is called by the Atlas contract, and delegatecalls the DAppControl contract via the
    /// corresponding `postOpsCall` function.
    /// @param solved Boolean indicating whether a winning SolverOperation was executed successfully.
    /// @param returnData Data returned from the previous call phase.
    function postOpsWrapper(bool solved, bytes calldata returnData) external onlyAtlasEnvironment {
        bytes memory _data = _forward(abi.encodeCall(IDAppControl.postOpsCall, (solved, returnData)));

        bool _success;
        (_success,) = _control().delegatecall(_data);

        if (!_success) revert AtlasErrors.PostOpsDelegatecallFail();
    }

    /// @notice The solverPreTryCatch function is called by Atlas to execute the preSolverCall part of each
    /// SolverOperation. A SolverTracker struct is also returned, containing bid info needed to handle the difference in
    /// logic between inverted and non-inverted bids.
    /// @dev Note that the DAppControl always has the option for custom logic in a hook between the measurement of
    /// solver bids (preSolverCall for invertsBid mode, postSolverCall for normal bid mode) which could potentially
    /// affect the solvers' net bid. These hooks should be used with caution and the behaviour should be clearly
    /// documented for participating solvers.
    /// @param bidAmount The Solver's bid amount.
    /// @param solverOp The SolverOperation struct.
    /// @param returnData Data returned from the previous call phase.
    /// @return solverTracker Bid tracking information for the current solver.
    function solverPreTryCatch(
        uint256 bidAmount,
        SolverOperation calldata solverOp,
        bytes calldata returnData
    )
        external
        payable
        onlyAtlasEnvironment
        validSolver(solverOp)
        returns (SolverTracker memory solverTracker)
    {
        solverTracker.bidAmount = bidAmount;
        solverTracker.etherIsBidToken = solverOp.bidToken == address(0);

        // bidValue is inverted; Lower bids are better; solver must withdraw <= bidAmount
        if (_config().invertsBidValue()) {
            solverTracker.invertsBidValue = true;
            // if invertsBidValue, record ceiling now
            // inventory to send to solver must have been transferred in by userOp or preOp call
            solverTracker.ceiling =
                solverTracker.etherIsBidToken ? address(this).balance : _tryBalanceOf(solverOp.bidToken, true);

            // Ensure the ceiling is not less than the bid amount
            if (solverTracker.ceiling < bidAmount) revert AtlasErrors.InvertedBidExceedsCeiling();
        }

        // Handle any solver preOps, if necessary
        if (_config().needsPreSolverCall()) {
            bool _success;

            bytes memory _data = _forward(abi.encodeCall(IDAppControl.preSolverCall, (solverOp, returnData)));
            (_success,) = _control().delegatecall(_data);

            if (!_success) revert AtlasErrors.PreSolverFailed();
        }

        // bidValue is not inverted; Higher bids are better; solver must deposit >= bidAmount
        if (!solverTracker.invertsBidValue) {
            // if not invertsBidValue, record floor now
            solverTracker.floor =
                solverTracker.etherIsBidToken ? address(this).balance : _tryBalanceOf(solverOp.bidToken, true);
        }
    }

    /// @notice The solverPostTryCatch function is called by Atlas to execute the postSolverCall part of each
    /// SolverOperation. The different logic scenarios depending on the value of invertsBidValue are also handled, and
    /// the SolverTracker struct is updated accordingly.
    /// @dev Note that the DAppControl always has the option for custom logic in a hook between the measurement of
    /// solver bids (preSolverCall for invertsBid mode, postSolverCall for normal bid mode) which could potentially
    /// affect the solvers' net bid. These hooks should be used with caution and the behaviour should be clearly
    /// documented for participating solvers.
    /// @param solverOp The SolverOperation struct.
    /// @param returnData Data returned from the previous call phase.
    /// @param solverTracker Bid tracking information for the current solver.
    /// @return solverTracker Updated bid tracking information for the current solver.
    function solverPostTryCatch(
        SolverOperation calldata solverOp,
        bytes calldata returnData,
        SolverTracker memory solverTracker
    )
        external
        payable
        onlyAtlasEnvironment
        returns (SolverTracker memory)
    {
        // bidValue is inverted; Lower bids are better; solver must withdraw <= bidAmount
        if (solverTracker.invertsBidValue) {
            // if invertsBidValue, record floor now
            solverTracker.floor =
                solverTracker.etherIsBidToken ? address(this).balance : _tryBalanceOf(solverOp.bidToken, false);
        }

        if (_config().needsPostSolverCall()) {
            bool _success;

            bytes memory _data = _forward(abi.encodeCall(IDAppControl.postSolverCall, (solverOp, returnData)));
            (_success,) = _control().delegatecall(_data);

            if (!_success) revert AtlasErrors.PostSolverFailed();
        }

        // bidValue is not inverted; Higher bids are better; solver must deposit >= bidAmount
        if (!solverTracker.invertsBidValue) {
            // if not invertsBidValue, record ceiling now
            solverTracker.ceiling =
                solverTracker.etherIsBidToken ? address(this).balance : _tryBalanceOf(solverOp.bidToken, false);
        }

        // Make sure the numbers add up and that the bid was paid
        if (solverTracker.floor > solverTracker.ceiling) revert AtlasErrors.BidNotPaid();

        // The solver net bid is the token difference before and after the solver call.
        // WARNING: There could be scenarios where the above assumption need not hold. For example, the solver could
        // trigger an airdrop to the execution environment, which would increase the balance of the execution
        // environment without the solver paying any bids.
        uint256 _netBid = solverTracker.ceiling - solverTracker.floor;

        // If bids aren't inverted, revert if net amount received is less than the bid
        if (!solverTracker.invertsBidValue && _netBid < solverTracker.bidAmount) revert AtlasErrors.BidNotPaid();

        // If bids are inverted, revert if the net amount sent is more than the bid
        if (solverTracker.invertsBidValue && _netBid > solverTracker.bidAmount) revert AtlasErrors.BidNotPaid();

        // Update the bidAmount to the bid received
        solverTracker.bidAmount = _netBid;

        return solverTracker;
    }

    /// @notice The allocateValue function is called by Atlas after a successful SolverOperation.
    /// @dev This contract is called by the Atlas contract, and delegatecalls the DAppControl contract via the
    /// corresponding `allocateValueCall` function.
    /// @param bidToken The address of the token used for the winning SolverOperation's bid.
    /// @param bidAmount The winning bid amount.
    /// @param allocateData Data returned from the previous call phase.
    /// @return allocateValueSucceeded Boolean indicating whether the allocateValue delegatecall succeeded (true) or
    /// reverted (false). This is useful when allowAllocateValueFailure is set to true, the failure is caught here, but
    /// we still need to communicate to Atlas that the hook did not succeed.
    function allocateValue(
        address bidToken,
        uint256 bidAmount,
        bytes memory allocateData
    )
        external
        onlyAtlasEnvironment
        returns (bool allocateValueSucceeded)
    {
        allocateData = _forward(abi.encodeCall(IDAppControl.allocateValueCall, (bidToken, bidAmount, allocateData)));

        (bool _success,) = _control().delegatecall(allocateData);
        if (!_success && !_config().allowAllocateValueFailure()) revert AtlasErrors.AllocateValueDelegatecallFail();

        uint256 _balance = address(this).balance;
        if (_balance > 0) {
            IAtlas(ATLAS).contribute{ value: _balance }();
        }

        return _success;
    }

    ///////////////////////////////////////
    //  USER SUPPORT / ACCESS FUNCTIONS  //
    ///////////////////////////////////////

    /// @notice The withdrawERC20 function allows the environment owner to withdraw ERC20 tokens from this Execution
    /// Environment.
    /// @dev This function is only callable by the environment owner and only when Atlas is in an unlocked state.
    /// @param token The address of the ERC20 token to withdraw.
    /// @param amount The amount of the ERC20 token to withdraw.
    function withdrawERC20(address token, uint256 amount) external {
        if (msg.sender != _user()) revert AtlasErrors.NotEnvironmentOwner();
        if (!IAtlas(ATLAS).isUnlocked()) revert AtlasErrors.AtlasLockActive();

        if (IERC20(token).balanceOf(address(this)) >= amount) {
            SafeTransferLib.safeTransfer(token, msg.sender, amount);
        } else {
            revert AtlasErrors.ExecutionEnvironmentBalanceTooLow();
        }
    }

    /// @notice The withdrawEther function allows the environment owner to withdraw Ether from this Execution
    /// Environment.
    /// @dev This function is only callable by the environment owner and only when Atlas is in an unlocked state.
    /// @param amount The amount of Ether to withdraw.
    function withdrawEther(uint256 amount) external {
        if (msg.sender != _user()) revert AtlasErrors.NotEnvironmentOwner();
        if (!IAtlas(ATLAS).isUnlocked()) revert AtlasErrors.AtlasLockActive();

        if (address(this).balance >= amount) {
            SafeTransferLib.safeTransferETH(msg.sender, amount);
        } else {
            revert AtlasErrors.ExecutionEnvironmentBalanceTooLow();
        }
    }

    /// @notice The getUser function returns the address of the user of this Execution Environment.
    /// @return user The address of the user of this Execution Environment.
    function getUser() external pure returns (address user) {
        user = _user();
    }

    /// @notice The getControl function returns the address of the DAppControl contract of the current metacall
    /// transaction.
    /// @return control The address of the DAppControl contract of the current metacall transaction.
    function getControl() external pure returns (address control) {
        control = _control();
    }

    /// @notice The getConfig function returns the CallConfig of the current metacall transaction.
    /// @return config The CallConfig in uint32 form of the current metacall transaction.
    function getConfig() external pure returns (uint32 config) {
        config = _config();
    }

    /// @notice The getEscrow function returns the address of the Atlas/Escrow contract.
    /// @return address The address of the Atlas/Escrow contract.
    function getEscrow() external view returns (address) {
        return ATLAS;
    }

    /// @notice Calls balanceOf of an arbitrary ERC20 token, and reverts with either a PreSolverFailed or
    /// PostSolverFailed, depending on the context in which this function is called, if any error occurs.
    /// @dev This stops malicious errors from bubbling up to the Atlas contract, and triggering unexpected behavior.
    function _tryBalanceOf(address token, bool inPreSolver) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, address(this)));

        if (!success) {
            if (inPreSolver) revert AtlasErrors.PreSolverFailed();
            revert AtlasErrors.PostSolverFailed();
        }

        // If the balanceOf call did not revert, decode result to uint256 and return
        return abi.decode(data, (uint256));
    }

    receive() external payable { }

    fallback() external payable { }
}
