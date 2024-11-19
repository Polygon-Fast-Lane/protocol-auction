//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../types/UserOperation.sol";
import "../types/ConfigTypes.sol";
import "../types/DAppOperation.sol";
import "../types/SolverOperation.sol";
import "../types/EscrowTypes.sol";
import "../types/ValidCalls.sol";

interface IAtlasVerification {
    // AtlasVerification.sol
    function validateCalls(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp,
        uint256 msgValue,
        address msgSender,
        bool isSimulation
    )
        external
        returns (ValidCallsResult);
    function verifySolverOp(
        SolverOperation calldata solverOp,
        bytes32 userOpHash,
        uint256 userMaxFeePerGas,
        address bundler,
        bool allowsTrustedOpHash
    )
        external
        view
        returns (uint256 result);
    function verifyCallConfig(uint32 callConfig) external view returns (ValidCallsResult);
    function getUserOperationHash(UserOperation calldata userOp) external view returns (bytes32 hash);
    function getUserOperationPayload(UserOperation calldata userOp) external view returns (bytes32 payload);
    function getSolverPayload(SolverOperation calldata solverOp) external view returns (bytes32 payload);
    function getDAppOperationPayload(DAppOperation calldata dAppOp) external view returns (bytes32 payload);
    function getDomainSeparator() external view returns (bytes32 domainSeparator);

    // NonceManager.sol
    function getUserNextNonce(address user, bool sequential) external view returns (uint256 nextNonce);
    function getUserNextNonSeqNonceAfter(address user, uint256 refNonce) external view returns (uint256);
    function getDAppNextNonce(address dApp) external view returns (uint256 nextNonce);
    function userSequentialNonceTrackers(address account) external view returns (uint256 lastUsedSeqNonce);
    function dAppSequentialNonceTrackers(address account) external view returns (uint256 lastUsedSeqNonce);
    function userNonSequentialNonceTrackers(
        address account,
        uint248 wordIndex
    )
        external
        view
        returns (uint256 bitmap);

    // DAppIntegration.sol
    function initializeGovernance(address control) external;
    function addSignatory(address control, address signatory) external;
    function removeSignatory(address control, address signatory) external;
    function changeDAppGovernance(address oldGovernance, address newGovernance) external;
    function disableDApp(address control) external;
    function getGovFromControl(address control) external view returns (address);
    function isDAppSignatory(address control, address signatory) external view returns (bool);
    function signatories(bytes32 key) external view returns (bool);
    function dAppSignatories(address control) external view returns (address[] memory);
}
