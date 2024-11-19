// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { DAppControl } from "../../src/contracts/dapp/DAppControl.sol";

import "../../src/contracts/types/ConfigTypes.sol";
import "../../src/contracts/types/UserOperation.sol";
import "../../src/contracts/types/SolverOperation.sol";

import "forge-std/Test.sol";

library CallConfigBuilder {
    function allFalseCallConfig() internal pure returns (CallConfig memory) { }
}

contract DummyDAppControl is DAppControl {
    bool public preOpsShouldRevert;
    bool public userOpShouldRevert;
    bool public preSolverShouldRevert;
    bool public postSolverShouldRevert;
    bool public allocateValueShouldRevert;
    bool public postOpsShouldRevert;

    bytes public preOpsInputData;
    bytes public userOpInputData;
    bytes public preSolverInputData;
    bytes public postSolverInputData;
    bytes public allocateValueInputData;
    bytes public postOpsInputData;

    uint256 public userOpGasLeft;

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

    function _checkUserOperation(UserOperation memory) internal pure virtual override { }

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        bool shouldRevert = DummyDAppControl(CONTROL).preOpsShouldRevert();
        require(!shouldRevert, "_preOpsCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(userOp), 0);
        console.logBytes(abi.encode(userOp));

        if (userOp.data.length == 0) return new bytes(0);

        (, bytes memory data) = address(userOp.dapp).call(userOp.data);
        return data;
    }

    function _postOpsCall(bool solved, bytes calldata data) internal virtual override {
        bool shouldRevert = DummyDAppControl(CONTROL).postOpsShouldRevert();
        require(!shouldRevert, "_postOpsCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(solved, data), 5);
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal virtual override {
        bool shouldRevert = DummyDAppControl(CONTROL).preSolverShouldRevert();
        require(!shouldRevert, "_preSolverCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(solverOp, returnData), 2);
    }

    function _postSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal virtual override {
        bool shouldRevert = DummyDAppControl(CONTROL).postSolverShouldRevert();
        require(!shouldRevert, "_postSolverCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(solverOp, returnData), 3);
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
        bool shouldRevert = DummyDAppControl(CONTROL).allocateValueShouldRevert();
        require(!shouldRevert, "_allocateValueCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(bidToken, winningAmount, data), 4);

        // emit MEVPaymentSuccess(bidToken, winningAmount);
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address) { }

    // ****************************************
    // Custom functions
    // ****************************************

    function userOperationCall(uint256 returnValue) public returns (uint256) {
        DummyDAppControl(CONTROL).setUserOpGasLeft();

        bool shouldRevert = DummyDAppControl(CONTROL).userOpShouldRevert();
        require(!shouldRevert, "userOperationCall revert requested");

        DummyDAppControl(CONTROL).setInputData(abi.encode(returnValue), 1);

        return returnValue;
    }

    // Used to use all gas available during a call to get OOG error.
    function burnEntireGasLimit() public {
        uint256 _uselessSum;
        while (true) {
            _uselessSum += uint256(keccak256(abi.encodePacked(_uselessSum, gasleft()))) / 1e18;
        }
    }

    // Revert settings

    function setPreOpsShouldRevert(bool _preOpsShouldRevert) public {
        preOpsShouldRevert = _preOpsShouldRevert;
    }

    function setUserOpShouldRevert(bool _userOpShouldRevert) public {
        userOpShouldRevert = _userOpShouldRevert;
    }

    function setPreSolverShouldRevert(bool _preSolverShouldRevert) public {
        preSolverShouldRevert = _preSolverShouldRevert;
    }

    function setPostSolverShouldRevert(bool _postSolverShouldRevert) public {
        postSolverShouldRevert = _postSolverShouldRevert;
    }

    function setAllocateValueShouldRevert(bool _allocateValueShouldRevert) public {
        allocateValueShouldRevert = _allocateValueShouldRevert;
    }

    function setPostOpsShouldRevert(bool _postOpsShouldRevert) public {
        postOpsShouldRevert = _postOpsShouldRevert;
    }

    // Called by the EE to save input data for testing after the metacall ends
    function setInputData(
        bytes memory inputData,
        uint256 hook // 0: preOps, 1: userOp, 2: preSolver, 3: postSolver, 4: allocateValue, 5: postOps
    )
        public
    {
        if (hook == 0) preOpsInputData = inputData;
        if (hook == 1) userOpInputData = inputData;
        if (hook == 2) preSolverInputData = inputData;
        if (hook == 3) postSolverInputData = inputData;
        if (hook == 4) allocateValueInputData = inputData;
        if (hook == 5) postOpsInputData = inputData;
    }

    // Called by the EE to save gas left for testing at start of userOperationCall
    function setUserOpGasLeft() public {
        userOpGasLeft = gasleft();
    }
}
