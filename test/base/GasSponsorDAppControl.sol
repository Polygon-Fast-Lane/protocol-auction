// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { DAppControl } from "../../src/contracts/dapp/DAppControl.sol";
import { IAtlas } from "../../src/contracts/interfaces/IAtlas.sol";
import { IExecutionEnvironment } from "../../src/contracts/interfaces/IExecutionEnvironment.sol";

import "../../src/contracts/types/ConfigTypes.sol";
import "../../src/contracts/types/UserOperation.sol";
import "../../src/contracts/types/SolverOperation.sol";

import "forge-std/Test.sol";

library CallConfigBuilder {
    function allFalseCallConfig() internal pure returns (CallConfig memory) { }
}

contract GasSponsorDAppControl is DAppControl {
    event MEVPaymentSuccess(address bidToken, uint256 bidAmount);

    constructor(
        address _atlas,
        address _governance,
        CallConfig memory _callConfig
    )
        DAppControl(_atlas, _governance, _callConfig)
    { }

    // ****************************************
    // Atlas overrides
    // ****************************************

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        if (userOp.data.length == 0) {
            return new bytes(0);
        }

        (bool success, bytes memory data) = address(userOp.dapp).call(userOp.data);
        require(success, "_preOpsCall reverted");
        return data;
    }

    function _postOpsCall(bool, bytes calldata data) internal pure virtual override {
        if (data.length == 0) return;

        (bool shouldRevert) = abi.decode(data, (bool));
        require(!shouldRevert, "_postOpsCall revert requested");
    }

    function _preSolverCall(SolverOperation calldata, bytes calldata returnData) internal pure virtual override {
        if (returnData.length == 0) {
            return;
        }

        (bool shouldRevert, bool returnValue) = abi.decode(returnData, (bool, bool));
        require(!shouldRevert, "_preSolverCall revert requested");
        if (!returnValue) revert("_preSolverCall returned false");
    }

    function _postSolverCall(SolverOperation calldata, bytes calldata) internal virtual override {
        uint256 _solverShortfall = IAtlas(ATLAS).shortfall();

        GasSponsorDAppControl(CONTROL).sponsorETHViaExecutionEnvironment(_solverShortfall);

        require(address(this).balance >= _solverShortfall, "Not enough ETH in DAppControl to pay solver shortfall");
        IAtlas(ATLAS).contribute{ value: _solverShortfall }();
    }

    function _allocateValueCall(
        address bidToken,
        uint256 winningAmount,
        bytes calldata data
    )
        internal
        virtual
        override
    {
        if (data.length == 0) {
            return;
        }

        (bool shouldRevert) = abi.decode(data, (bool));
        require(!shouldRevert, "_allocateValueCall revert requested");
        emit MEVPaymentSuccess(bidToken, winningAmount);
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address) { }

    // ****************************************
    // Custom functions
    // ****************************************

    function userOperationCall(bool shouldRevert, uint256 returnValue) public pure returns (uint256) {
        require(!shouldRevert, "userOperationCall revert requested");
        return returnValue;
    }

    function sponsorETHViaExecutionEnvironment(uint256 amount) public {
        // Check caller is active execution environment and this contract is active dapp on atlas
        (address activeEnvironment,,) = IAtlas(ATLAS).lock();
        require(activeEnvironment == msg.sender, "Caller isn't active EE");
        require(
            IExecutionEnvironment(msg.sender).getControl() == CONTROL, "Calling EE's control is not this DAppControl"
        );

        // Send caller requested ETH
        payable(msg.sender).transfer(amount);
    }
}
