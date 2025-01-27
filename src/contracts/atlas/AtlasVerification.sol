//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { EIP712 } from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import { SignatureChecker } from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import { DAppIntegration } from "src/contracts/atlas/DAppIntegration.sol";
import { NonceManager } from "src/contracts/atlas/NonceManager.sol";

import { CallBits } from "src/contracts/libraries/CallBits.sol";
import { CallVerification } from "src/contracts/libraries/CallVerification.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";
import { AtlasErrors } from "src/contracts/types/AtlasErrors.sol";
import { AtlasConstants } from "src/contracts/types/AtlasConstants.sol";
import "src/contracts/types/SolverOperation.sol";
import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/DAppOperation.sol";
import "src/contracts/types/EscrowTypes.sol";
import "src/contracts/types/ValidCalls.sol";

/// @title AtlasVerification
/// @author FastLane Labs
/// @notice AtlasVerification handles the verification of DAppConfigs, UserOperations, SolverOperations, and
/// DAppOperations within a metacall to ensure that calldata sourced from various parties is safe and valid.
contract AtlasVerification is EIP712, NonceManager, DAppIntegration {
    using ECDSA for bytes32;
    using CallBits for uint32;
    using CallVerification for UserOperation;

    constructor(address atlas) EIP712("AtlasVerification", "1.0") DAppIntegration(atlas) { }

    /// @notice The validateCalls function verifies the validity of the metacall calldata components.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp The UserOperation struct of the metacall.
    /// @param solverOps An array of SolverOperation structs.
    /// @param dAppOp The DAppOperation struct of the metacall.
    /// @param msgValue The ETH value sent with the metacall transaction.
    /// @param msgSender The forwarded msg.sender of the original metacall transaction in the Atlas contract.
    /// @param isSimulation A boolean indicating if the call is a simulation.
    /// @return The result of the ValidCalls check, in enum ValidCallsResult form.
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
        returns (ValidCallsResult)
    {
        if (msg.sender != ATLAS) revert AtlasErrors.InvalidCaller();
        // Verify that the calldata injection came from the dApp frontend
        // and that the signatures are valid.

        bytes32 _userOpHash = _getUserOperationHash(userOp, userOp.callConfig.allowsTrustedOpHash());

        {
            // Check user signature
            ValidCallsResult verifyUserResult = _verifyUser(dConfig, userOp, _userOpHash, msgSender, isSimulation);
            if (verifyUserResult != ValidCallsResult.Valid) {
                return verifyUserResult;
            }

            // allowUnapprovedDAppSignatories still verifies signature match, but does not check
            // if dApp owner approved the signer.
            (ValidCallsResult verifyAuctioneerResult, bool allowUnapprovedDAppSignatories) =
                _verifyAuctioneer(dConfig, userOp, solverOps, dAppOp, msgSender);

            if (verifyAuctioneerResult != ValidCallsResult.Valid && !isSimulation) {
                return verifyAuctioneerResult;
            }

            // Check dapp signature
            ValidCallsResult verifyDappResult =
                _verifyDApp(dConfig, dAppOp, msgSender, allowUnapprovedDAppSignatories, isSimulation);
            if (verifyDappResult != ValidCallsResult.Valid) {
                return verifyDappResult;
            }
        }

        // Check if the call configuration is valid
        ValidCallsResult _verifyCallConfigResult = _verifyCallConfig(dConfig.callConfig);
        if (_verifyCallConfigResult != ValidCallsResult.Valid) {
            return _verifyCallConfigResult;
        }

        // CASE: Solvers trust app to update content of UserOp after submission of solverOp
        if (dConfig.callConfig.allowsTrustedOpHash()) {
            // SessionKey must match explicitly - cannot be skipped
            if (userOp.sessionKey != dAppOp.from && !isSimulation) {
                return ValidCallsResult.InvalidAuctioneer;
            }

            // msgSender (the bundler) must be userOp.from, userOp.sessionKey / dappOp.from, or dappOp.bundler
            if (!(msgSender == dAppOp.from || msgSender == dAppOp.bundler || msgSender == userOp.from) && !isSimulation)
            {
                return ValidCallsResult.InvalidBundler;
            }
        }

        uint256 _solverOpCount = solverOps.length;

        {
            uint256 currentBlockNumber = SafeBlockNumber.get();
            // Check number of solvers not greater than max, to prevent overflows in `solverIndex`
            if (_solverOpCount > _MAX_SOLVERS) {
                return ValidCallsResult.TooManySolverOps;
            }

            // Check if past user's deadline
            if (userOp.deadline != 0 && currentBlockNumber > userOp.deadline) {
                return ValidCallsResult.UserDeadlineReached;
            }

            // Check if past dapp's deadline
            if (dAppOp.deadline != 0 && currentBlockNumber > dAppOp.deadline) {
                return ValidCallsResult.DAppDeadlineReached;
            }

            // Check gas price is within user's limit
            if (tx.gasprice > userOp.maxFeePerGas) {
                return ValidCallsResult.GasPriceHigherThanMax;
            }

            // Check that the value of the tx is greater than or equal to the value specified
            if (msgValue < userOp.value) {
                return ValidCallsResult.TxValueLowerThanCallValue;
            }

            // Check the call config read at the start of the metacall is same as user expected (as set in userOp)
            if (dConfig.callConfig != userOp.callConfig) {
                return ValidCallsResult.CallConfigMismatch;
            }
        }

        // Some checks are only needed when call is not a simulation
        if (isSimulation) {
            // Add all solver ops if simulation
            return ValidCallsResult.Valid;
        }

        // Verify a solver was successfully verified.
        if (_solverOpCount == 0) {
            if (!dConfig.callConfig.allowsZeroSolvers()) {
                return ValidCallsResult.NoSolverOp;
            }

            if (dConfig.callConfig.needsFulfillment()) {
                return ValidCallsResult.NoSolverOp;
            }
        }

        if (_userOpHash != dAppOp.userOpHash) {
            return ValidCallsResult.OpHashMismatch;
        }

        return ValidCallsResult.Valid;
    }

    /// @notice The verifySolverOp function verifies the validity of a SolverOperation.
    /// @param solverOp The SolverOperation struct to verify.
    /// @param userOpHash The hash of the associated UserOperation struct.
    /// @param userMaxFeePerGas The maximum fee per gas the user is willing to pay.
    /// @param bundler The address of the bundler.
    /// @return result The result of the SolverOperation verification, containing SolverOutcome info in a bitmap.
    function verifySolverOp(
        SolverOperation calldata solverOp,
        bytes32 userOpHash,
        uint256 userMaxFeePerGas,
        address bundler,
        bool allowsTrustedOpHash
    )
        external
        view
        returns (uint256 result)
    {
        if (bundler == solverOp.from || _verifySolverSignature(solverOp)) {
            // Validate solver signature
            // NOTE: First two failures are the bundler's fault - solver does not
            // owe a gas refund to the bundler.
            if (solverOp.userOpHash != userOpHash) {
                result |= (1 << uint256(SolverOutcome.InvalidUserHash));
            }

            if (solverOp.to != ATLAS) result |= (1 << uint256(SolverOutcome.InvalidTo));

            // NOTE: The next three failures below here are the solver's fault, and as a result
            // they are on the hook for their own gas cost.
            if (tx.gasprice > solverOp.maxFeePerGas) result |= (1 << uint256(SolverOutcome.GasPriceOverCap));

            if (solverOp.maxFeePerGas < userMaxFeePerGas) {
                result |= (
                    1
                        << (
                            allowsTrustedOpHash
                                ? uint256(SolverOutcome.GasPriceBelowUsersAlt)
                                : uint256(SolverOutcome.GasPriceBelowUsers)
                        )
                );
            }

            if (solverOp.solver == ATLAS || solverOp.solver == address(this)) {
                result |= (1 << uint256(SolverOutcome.InvalidSolver));
            }
            // NOTE: If result is not set above, result stays 0, therefore result is `canExecute == true`
        } else {
            // No refund
            result |= (1 << uint256(SolverOutcome.InvalidSignature));
        }
    }

    /// @notice External function to call the internal _verifyCallConfig function
    /// @param callConfig The call configuration struct to verify.
    /// @return The result of the ValidCalls check, in enum ValidCallsResult form.
    function verifyCallConfig(uint32 callConfig) external pure returns (ValidCallsResult) {
        return _verifyCallConfig(callConfig);
    }

    /// @notice The _verifyCallConfig internal function verifies the validity of the call configuration.
    /// @param callConfig The call configuration to verify.
    /// @return The result of the ValidCalls check, in enum ValidCallsResult form.
    function _verifyCallConfig(uint32 callConfig) internal pure returns (ValidCallsResult) {
        if (callConfig.needsPreOpsReturnData() && callConfig.needsUserReturnData()) {
            // Max one of preOps or userOp return data can be tracked, not both
            return ValidCallsResult.InvalidCallConfig;
        }

        if (callConfig.needsSequentialUserNonces() && callConfig.needsSequentialDAppNonces()) {
            // Max one of user or dapp nonces can be sequential, not both
            return ValidCallsResult.BothUserAndDAppNoncesCannotBeSequential;
        }
        if (callConfig.invertsBidValue() && callConfig.exPostBids()) {
            // If both invertBidValue and exPostBids are true, solver's retrieved bid cannot be determined
            return ValidCallsResult.InvertBidValueCannotBeExPostBids;
        }
        return ValidCallsResult.Valid;
    }

    /// @notice The _verifyAuctioneer internal function is called by _validCalls to verify that the auctioneer of the
    /// metacall is valid according to the rules set in the DAppConfig.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp The UserOperation struct of the metacall.
    /// @param solverOps An array of SolverOperation structs.
    /// @param dAppOp The DAppOperation struct of the metacall.
    /// @param msgSender The bundler (msg.sender) of the metacall transaction in the Atlas contract.
    /// @return validCallsResult The result of the ValidCalls check, in enum ValidCallsResult form.
    /// @return allowUnapprovedDAppSignatories A boolean indicating if the signatory approval check should be bypassed.
    function _verifyAuctioneer(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp,
        address msgSender
    )
        internal
        pure
        returns (ValidCallsResult validCallsResult, bool allowUnapprovedDAppSignatories)
    {
        if (
            dConfig.callConfig.verifyCallChainHash()
                && dAppOp.callChainHash != CallVerification.getCallChainHash(userOp, solverOps)
        ) return (ValidCallsResult.InvalidCallChainHash, false);

        if (dConfig.callConfig.allowsUserAuctioneer() && dAppOp.from == userOp.sessionKey) {
            return (ValidCallsResult.Valid, true);
        }

        if (dConfig.callConfig.allowsSolverAuctioneer() && solverOps.length > 0) {
            // If the solver is the auctioneer, there must be exactly 1 solver
            if (dAppOp.from == solverOps[0].from) {
                if (solverOps.length != 1) {
                    // If not exactly one solver and first solver is auctioneer
                    // => invalid
                    return (ValidCallsResult.TooManySolverOps, false);
                } else if (msgSender == solverOps[0].from) {
                    // If exactly one solver AND that solver is auctioneer,
                    // AND the solver is also the bundler,
                    // => valid AND bypass sig approval
                    return (ValidCallsResult.Valid, true);
                }
            }
            // If first solver is not the auctioneer,
            // => valid BUT do not bypass sig approval
        }

        if (dConfig.callConfig.allowsUnknownAuctioneer()) return (ValidCallsResult.Valid, true);

        return (ValidCallsResult.Valid, false);
    }

    /// @notice The getSolverPayload function returns the hash of a SolverOperation struct for use in signatures.
    /// @param solverOp The SolverOperation struct to hash.
    function getSolverPayload(SolverOperation calldata solverOp) external view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getSolverOpHash(solverOp));
    }

    /// @notice The internal _verifySolverSignature function verifies the signature of a SolverOperation.
    /// @param solverOp The SolverOperation struct to verify.
    /// @return A boolean indicating if the signature is valid.
    function _verifySolverSignature(SolverOperation calldata solverOp) internal view returns (bool) {
        (address _signer,,) = _hashTypedDataV4(_getSolverOpHash(solverOp)).tryRecover(solverOp.signature);
        return _signer == solverOp.from;
    }

    /// @notice The _getSolverOpHash internal function returns the hash of a SolverOperation struct.
    /// @param solverOp The SolverOperation struct to hash.
    /// @return solverOpHash The hash of the SolverOperation struct.
    function _getSolverOpHash(SolverOperation calldata solverOp) internal pure returns (bytes32 solverOpHash) {
        return keccak256(
            abi.encode(
                SOLVER_TYPEHASH,
                solverOp.from,
                solverOp.to,
                solverOp.value,
                solverOp.gas,
                solverOp.maxFeePerGas,
                solverOp.deadline,
                solverOp.solver,
                solverOp.control,
                solverOp.userOpHash,
                solverOp.bidToken,
                solverOp.bidAmount,
                keccak256(solverOp.data)
            )
        );
    }

    //
    // DAPP VERIFICATION
    //

    /// @notice Verifies that the dapp's data matches the data submitted by the user and solvers. NOTE: The dapp's front
    /// end is the last party in the supply chain to submit data.  If any other party (user, solver, FastLane,  or a
    /// collusion between all of them) attempts to alter it, this check will fail.
    /// @param dConfig The DAppConfig containing configuration details.
    /// @param dAppOp The DAppOperation struct of the metacall.
    /// @param msgSender The forwarded msg.sender of the original metacall transaction in the Atlas contract.
    /// @param allowUnapprovedDAppSignatories Boolean indicating whether to bypass signatory approval.
    /// @param isSimulation Boolean indicating whether the execution is a simulation.
    /// @return The result of the ValidCalls check, in enum ValidCallsResult form.
    function _verifyDApp(
        DAppConfig memory dConfig,
        DAppOperation calldata dAppOp,
        address msgSender,
        bool allowUnapprovedDAppSignatories,
        bool isSimulation
    )
        internal
        returns (ValidCallsResult)
    {
        if (dAppOp.to != ATLAS) return ValidCallsResult.DAppToInvalid;

        bool _bypassSignature = msgSender == dAppOp.from || (isSimulation && dAppOp.signature.length == 0);

        if (!_bypassSignature && !_verifyDAppSignature(dAppOp)) {
            return ValidCallsResult.DAppSignatureInvalid;
        }

        if (dAppOp.control != dConfig.to) {
            return ValidCallsResult.InvalidControl;
        }

        // Some checks skipped if call is `simUserOperation()`, because the dAppOp struct is not available.
        bool _skipDAppOpChecks = isSimulation && dAppOp.from == address(0);

        // If the dApp enabled sequential nonces (IE for FCFS execution), check and make sure the order is correct
        // NOTE: enabling sequential nonces could create a scenario in which builders or validators may be able to
        // profit via censorship. DApps are encouraged to rely on the deadline parameter.
        if (!_skipDAppOpChecks && dConfig.callConfig.needsSequentialDAppNonces()) {
            // When not in a simulation, nonces are stored even if the metacall fails, to prevent replay attacks.
            if (!_handleDAppNonces(dAppOp.from, dAppOp.nonce, isSimulation)) {
                return ValidCallsResult.InvalidDAppNonce;
            }
        }

        // If `_verifyAuctioneer()` allows bypassing signatory approval, the checks below are skipped and we can return
        // Valid here, considering the checks above have all passed.
        if (allowUnapprovedDAppSignatories) return ValidCallsResult.Valid;

        // Check actual bundler matches the dApp's intended `dAppOp.bundler`
        // If bundler and auctioneer are the same address, this check is skipped
        if (dAppOp.bundler != address(0) && msgSender != dAppOp.bundler && !isSimulation) {
            if (!_isDAppSignatory(dAppOp.control, msgSender)) {
                return ValidCallsResult.InvalidBundler;
            }
        }

        // Make sure the signer is currently enabled by dapp owner
        if (!_skipDAppOpChecks && !_isDAppSignatory(dAppOp.control, dAppOp.from)) {
            return ValidCallsResult.DAppNotEnabled;
        }

        return ValidCallsResult.Valid;
    }

    /// @notice Generates the hash of a DAppOperation struct.
    /// @param dAppOp The DAppOperation struct to hash.
    /// @return dappOpHash The hash of the DAppOperation struct.
    function _getDAppOpHash(DAppOperation calldata dAppOp) internal pure returns (bytes32 dappOpHash) {
        dappOpHash = keccak256(
            abi.encode(
                DAPP_TYPEHASH,
                dAppOp.from,
                dAppOp.to,
                dAppOp.nonce,
                dAppOp.deadline,
                dAppOp.control,
                dAppOp.bundler,
                dAppOp.userOpHash,
                dAppOp.callChainHash
            )
        );
    }

    /// @notice Verifies the signature of a DAppOperation struct.
    /// @param dAppOp The DAppOperation struct to verify.
    /// @return A boolean indicating if the signature is valid.
    function _verifyDAppSignature(DAppOperation calldata dAppOp) internal view returns (bool) {
        (address _signer,,) = _hashTypedDataV4(_getDAppOpHash(dAppOp)).tryRecover(dAppOp.signature);
        return _signer == dAppOp.from;
    }

    /// @notice Generates the hash of a DAppOperation struct.
    /// @param dAppOp The DAppOperation struct to hash.
    /// @return payload The hash of the DAppOperation struct.
    function getDAppOperationPayload(DAppOperation calldata dAppOp) public view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getDAppOpHash(dAppOp));
    }

    /// @notice Returns the domain separator for the EIP712 signature scheme.
    /// @return domainSeparator The domain separator for the EIP712 signature scheme.
    function getDomainSeparator() external view returns (bytes32 domainSeparator) {
        domainSeparator = _domainSeparatorV4();
    }

    //
    // USER VERIFICATION
    //

    /// @notice Verifies the validity of a UserOperation struct.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp The UserOperation struct to verify.
    /// @param msgSender The forwarded msg.sender of the original metacall transaction in the Atlas contract.
    /// @param isSimulation A boolean indicating if the call is a simulation.
    /// @return The result of the UserOperation verification, in enum ValidCallsResult form.
    function _verifyUser(
        DAppConfig memory dConfig,
        UserOperation calldata userOp,
        bytes32 userOpHash,
        address msgSender,
        bool isSimulation
    )
        internal
        returns (ValidCallsResult)
    {
        if (userOp.from == address(this) || userOp.from == ATLAS) {
            return ValidCallsResult.UserFromInvalid;
        }

        if (userOp.to != ATLAS) {
            return ValidCallsResult.UserToInvalid;
        }

        // Verify the signature before storing any data to avoid
        // spoof transactions clogging up dapp userNonces

        bool _userIsBundler = userOp.from == msgSender;
        bool _hasNoSignature = userOp.signature.length == 0;
        bool _signatureValid;

        if (!_userIsBundler) {
            if (userOp.callConfig.allowsTrustedOpHash()) {
                // Use full untrusted hash for signature verification to ensure all operation parameters are included.
                userOpHash = _getUserOperationHash(userOp, false);
            }
            _signatureValid = SignatureChecker.isValidSignatureNow(userOp.from, userOpHash, userOp.signature);
        }

        if (!(_signatureValid || _userIsBundler || (isSimulation && _hasNoSignature))) {
            return ValidCallsResult.UserSignatureInvalid;
        }

        if (userOp.control != dConfig.to) {
            return ValidCallsResult.ControlMismatch;
        }

        // If the dapp indicated that they only accept sequential userNonces
        // (IE for FCFS execution), check and make sure the order is correct
        // NOTE: allowing only sequential userNonces could create a scenario in
        // which builders or validators may be able to profit via censorship.
        // DApps are encouraged to rely on the deadline parameter
        // to prevent replay attacks.
        if (!_handleUserNonces(userOp.from, userOp.nonce, dConfig.callConfig.needsSequentialUserNonces(), isSimulation))
        {
            return ValidCallsResult.UserNonceInvalid;
        }

        return ValidCallsResult.Valid;
    }

    /// @notice Generates the payload hash of a UserOperation struct used in signatures.
    /// @param userOp The UserOperation struct to generate the payload for.
    /// @return payload The hash of the UserOperation struct for use in signatures.
    function getUserOperationPayload(UserOperation calldata userOp) public view returns (bytes32 payload) {
        payload = _getUserOperationHash(userOp, false);
    }

    /// @notice Generates the hash of a UserOperation struct used for inter-operation references.
    /// @param userOp The UserOperation struct to generate the hash for.
    /// @return userOpHash The hash of the UserOperation struct for in inter-operation references.
    function getUserOperationHash(UserOperation calldata userOp) public view returns (bytes32 userOpHash) {
        userOpHash = _getUserOperationHash(userOp, userOp.callConfig.allowsTrustedOpHash());
    }

    function _getUserOperationHash(
        UserOperation memory userOp,
        bool trusted
    )
        internal
        view
        returns (bytes32 userOpHash)
    {
        if (trusted) {
            userOpHash = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        USER_TYPEHASH_TRUSTED,
                        userOp.from,
                        userOp.to,
                        userOp.dapp,
                        userOp.control,
                        userOp.callConfig,
                        userOp.sessionKey
                    )
                )
            );
        } else {
            userOpHash = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        USER_TYPEHASH_DEFAULT,
                        userOp.from,
                        userOp.to,
                        userOp.value,
                        userOp.gas,
                        userOp.maxFeePerGas,
                        userOp.nonce,
                        userOp.deadline,
                        userOp.dapp,
                        userOp.control,
                        userOp.callConfig,
                        userOp.sessionKey,
                        keccak256(userOp.data)
                    )
                )
            );
        }
    }
}
