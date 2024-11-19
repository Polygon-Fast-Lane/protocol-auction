//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";
import "../../types/LockTypes.sol";

// Atlas DApp-Control Imports
import { DAppControl } from "../../dapp/DAppControl.sol";
import { ChainlinkAtlasWrapper } from "./ChainlinkAtlasWrapperAlt.sol";

// Role enum as per Chainlink's OffchainAggregatorBilling.sol contract
enum Role {
    // No oracle role has been set for address a
    Unset,
    // Signing address a of an oracle. I.e. report signatures from this oracle should ecrecover back to address a.
    Signer,
    // Transmitter role is not used
    Transmitter
}

struct Oracle {
    uint8 index; // Index of oracle in signers array
    Role role; // Role of the address which mapped to this struct
}

struct VerificationVars {
    mapping(address signer => Oracle oracle) oracles;
    address[] signers;
}

// NOTE: This contract acts as the Chainlink DAppControl for Atlas,
// and as a factory for ChainlinkAtlasWrapper contracts
contract ChainlinkDAppControl is DAppControl {
    uint256 public constant MAX_NUM_ORACLES = 31;

    mapping(address baseChainlinkFeed => VerificationVars) internal verificationVars;

    error InvalidBaseFeed();
    error FailedToAllocateOEV();
    error OnlyGovernance();
    error SignerNotFound();
    error TooManySigners();
    error DuplicateSigner(address signer);

    event NewChainlinkWrapperCreated(address indexed wrapper, address indexed baseFeed, address indexed owner);
    event SignersSetForBaseFeed(address indexed baseFeed, address[] signers);
    event SignerAddedForBaseFeed(address indexed baseFeed, address indexed signer);
    event SignerRemovedForBaseFeed(address indexed baseFeed, address indexed signer);

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
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false, // Update oracle even if all solvers fail
                trustedOpHash: true,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    { }

    // ---------------------------------------------------- //
    //                  Atlas Hook Overrides                //
    // ---------------------------------------------------- //

    function _allocateValueCall(address, uint256 bidAmount, bytes calldata data) internal virtual override {
        address chainlinkWrapper = abi.decode(data, (address));
        (bool success,) = chainlinkWrapper.call{ value: bidAmount }("");
        if (!success) revert FailedToAllocateOEV();
    }

    // NOTE: Functions below are not delegatecalled

    // ---------------------------------------------------- //
    //                    View Functions                    //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public pure override returns (address bidToken) {
        return address(0); // ETH is bid token
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getSignersForBaseFeed(address baseChainlinkFeed) external view returns (address[] memory) {
        return verificationVars[baseChainlinkFeed].signers;
    }

    function getOracleDataForBaseFeed(
        address baseChainlinkFeed,
        address signer
    )
        external
        view
        returns (Oracle memory)
    {
        return verificationVars[baseChainlinkFeed].oracles[signer];
    }

    // ---------------------------------------------------- //
    //          ChainlinkWrapper Factory Functions          //
    // ---------------------------------------------------- //

    // Creates a new wrapper contract for a specific Chainlink feed, to attribute OEV captured by Atlas to the
    // OEV-generating protocol.
    function createNewChainlinkAtlasWrapper(address baseChainlinkFeed) external returns (address) {
        if (IChainlinkFeed(baseChainlinkFeed).latestAnswer() == 0) revert InvalidBaseFeed();
        address newWrapper = address(new ChainlinkAtlasWrapper(ATLAS, baseChainlinkFeed, msg.sender));
        emit NewChainlinkWrapperCreated(newWrapper, baseChainlinkFeed, msg.sender);
        return newWrapper;
    }

    // Called by a ChainlinkAtlasWrapper to verify if the signers of a price update via `transmit` are verified.
    function verifyTransmitSigners(
        address baseChainlinkFeed,
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        external
        view
        returns (bool verified)
    {
        bool[] memory signed = new bool[](MAX_NUM_ORACLES);
        bytes32 reportHash = keccak256(report);
        Oracle memory currentOracle;

        for (uint256 i; i < rs.length; ++i) {
            address signer = ecrecover(reportHash, uint8(rawVs[i]) + 27, rs[i], ss[i]);
            currentOracle = verificationVars[baseChainlinkFeed].oracles[signer];

            // Signer must be pre-approved and only 1 observation per signer
            if (currentOracle.role != Role.Signer || signed[currentOracle.index]) {
                return false;
            }
            signed[currentOracle.index] = true;
        }
        return true;
    }

    // ---------------------------------------------------- //
    //                    OnlyGov Functions                 //
    // ---------------------------------------------------- //

    // Clears any existing signers and adds a new set of signers for a specific Chainlink feed.
    function setSignersForBaseFeed(address baseChainlinkFeed, address[] calldata signers) external onlyGov {
        if (signers.length > MAX_NUM_ORACLES) revert TooManySigners();

        _removeAllSignersOfBaseFeed(baseChainlinkFeed); // Removes any existing signers first
        VerificationVars storage vars = verificationVars[baseChainlinkFeed];

        for (uint256 i; i < signers.length; ++i) {
            if (vars.oracles[signers[i]].role != Role.Unset) revert DuplicateSigner(signers[i]);
            vars.oracles[signers[i]] = Oracle({ index: uint8(i), role: Role.Signer });
        }
        vars.signers = signers;

        emit SignersSetForBaseFeed(baseChainlinkFeed, signers);
    }

    // Adds a specific signer to a specific Chainlink feed.
    function addSignerForBaseFeed(address baseChainlinkFeed, address signer) external onlyGov {
        VerificationVars storage vars = verificationVars[baseChainlinkFeed];

        if (vars.signers.length >= MAX_NUM_ORACLES) revert TooManySigners();
        if (vars.oracles[signer].role != Role.Unset) revert DuplicateSigner(signer);

        vars.signers.push(signer);
        vars.oracles[signer] = Oracle({ index: uint8(vars.signers.length - 1), role: Role.Signer });

        emit SignerAddedForBaseFeed(baseChainlinkFeed, signer);
    }

    // Removes a specific signer from a specific Chainlink feed.
    function removeSignerOfBaseFeed(address baseChainlinkFeed, address signer) external onlyGov {
        Oracle memory oracle = verificationVars[baseChainlinkFeed].oracles[signer];
        address[] storage signers = verificationVars[baseChainlinkFeed].signers;

        if (oracle.role != Role.Signer) revert SignerNotFound();

        if (oracle.index < signers.length - 1) {
            signers[oracle.index] = signers[signers.length - 1];
            verificationVars[baseChainlinkFeed].oracles[signers[oracle.index]].index = oracle.index;
        }
        signers.pop();
        delete verificationVars[baseChainlinkFeed].oracles[signer];

        emit SignerRemovedForBaseFeed(baseChainlinkFeed, signer);
    }

    function _removeAllSignersOfBaseFeed(address baseChainlinkFeed) internal {
        VerificationVars storage vars = verificationVars[baseChainlinkFeed];
        address[] storage signers = vars.signers;
        if (signers.length == 0) return;
        for (uint256 i; i < signers.length; ++i) {
            delete vars.oracles[signers[i]];
        }
        delete vars.signers;
    }

    function _onlyGov() internal view {
        if (msg.sender != governance) revert OnlyGovernance();
    }

    modifier onlyGov() {
        _onlyGov();
        _;
    }
}

interface IChainlinkAtlasWrapper {
    function transmit(bytes calldata report, bytes32[] calldata rs, bytes32[] calldata ss, bytes32 rawVs) external;
}

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
}
