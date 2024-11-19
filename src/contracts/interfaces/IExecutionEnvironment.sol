//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../types/SolverOperation.sol";
import "../types/UserOperation.sol";
import "../types/ConfigTypes.sol";
import "../types/EscrowTypes.sol";

interface IExecutionEnvironment {
    function preOpsWrapper(UserOperation calldata userOp) external returns (bytes memory preOpsData);

    function userWrapper(UserOperation calldata userOp) external payable returns (bytes memory userReturnData);

    function postOpsWrapper(bool solved, bytes calldata returnData) external;

    function solverPreTryCatch(
        uint256 bidAmount,
        SolverOperation calldata solverOp,
        bytes calldata returnData
    )
        external
        returns (SolverTracker memory solverTracker);

    function solverPostTryCatch(
        SolverOperation calldata solverOp,
        bytes calldata returnData,
        SolverTracker memory solverTracker
    )
        external
        returns (SolverTracker memory);

    function allocateValue(
        address bidToken,
        uint256 bidAmount,
        bytes memory returnData
    )
        external
        returns (bool allocateValueSucceeded);

    function getUser() external pure returns (address user);
    function getControl() external pure returns (address control);
    function getConfig() external pure returns (uint32 config);
    function getEscrow() external view returns (address escrow);

    function withdrawERC20(address token, uint256 amount) external;
    function withdrawEther(uint256 amount) external;
}
