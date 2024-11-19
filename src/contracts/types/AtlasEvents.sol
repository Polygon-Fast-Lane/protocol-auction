//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract AtlasEvents {
    // Metacall
    event MetacallResult(
        address indexed bundler,
        address indexed user,
        bool solverSuccessful,
        bool disbursementSuccessful,
        uint256 ethPaidToBundler,
        uint256 netGasSurcharge
    );

    // AtlETH
    event Bond(address indexed owner, uint256 amount);
    event Unbond(address indexed owner, uint256 amount, uint256 earliestAvailable);
    event Redeem(address indexed owner, uint256 amount);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);

    // Escrow events
    event SolverTxResult(
        address indexed solverTo,
        address indexed solverFrom,
        address indexed dAppControl,
        address bidToken,
        uint256 bidAmount,
        bool executed,
        bool success,
        uint256 result
    );

    // Factory events
    event ExecutionEnvironmentCreated(address indexed user, address indexed executionEnvironment);

    // Surcharge events
    event SurchargeWithdrawn(address indexed to, uint256 amount);
    event SurchargeRecipientTransferStarted(address indexed currentRecipient, address indexed newRecipient);
    event SurchargeRecipientTransferred(address indexed newRecipient);

    // DAppControl events
    event GovernanceTransferStarted(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    // DAppIntegration events
    event NewDAppSignatory(
        address indexed control, address indexed governance, address indexed signatory, uint32 callConfig
    );
    event RemovedDAppSignatory(
        address indexed control, address indexed governance, address indexed signatory, uint32 callConfig
    );
    event DAppGovernanceChanged(
        address indexed control, address indexed oldGovernance, address indexed newGovernance, uint32 callConfig
    );
    event DAppDisabled(address indexed control, address indexed governance, uint32 callConfig);
}
