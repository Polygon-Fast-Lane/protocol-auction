//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { SafeERC20, IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// A wrapper contract for a specific Chainlink price feed, used by Atlas to capture Oracle Extractable Value (OEV).
// Each MEV-generating protocol needs their own wrapper for each Chainlink price feed they use.
contract ChainlinkAtlasWrapper is Ownable {
    address public immutable ATLAS;
    IChainlinkFeed public immutable BASE_FEED; // Base Chainlink Feed
    IChainlinkDAppControl public immutable DAPP_CONTROL; // Chainlink Atlas DAppControl

    int256 public atlasLatestAnswer;
    uint256 public atlasLatestTimestamp;

    uint256 private immutable _GAS_THRESHOLD;

    error TransmitterInvalid(address transmitter);
    error InvalidTransmitMsgDataLength();
    error ObservationsNotOrdered();
    error AnswerMustBeAboveZero();
    error SignerVerificationFailed();
    error WithdrawETHFailed();

    event SignerStatusChanged(address indexed account, bool isSigner);

    constructor(address atlas, address baseChainlinkFeed, address _owner) Ownable(_owner) {
        ATLAS = atlas;
        BASE_FEED = IChainlinkFeed(baseChainlinkFeed);
        DAPP_CONTROL = IChainlinkDAppControl(msg.sender); // Chainlink DAppControl is also wrapper factory

        // do a gas usage check on an invalid trasmitting address
        address _aggregator = BASE_FEED.aggregator();

        // heat up the address
        IOffchainAggregator(_aggregator).oracleObservationCount{ gas: 10_000 }(_owner);

        // get the gas usage of an Unset address
        uint256 gasUsed = gasleft();
        IOffchainAggregator(_aggregator).oracleObservationCount{ gas: 10_000 }(atlas);
        gasUsed -= gasleft();

        _GAS_THRESHOLD = gasUsed + 199; // 199 = warm SLOADx2 - 1

        address transmitter = IOffchainAggregator(_aggregator).transmitters()[2];
        // heat up the second storage slot
        IOffchainAggregator(_aggregator).oracleObservationCount{ gas: 10_000 }(transmitter);
        // change to next transmitter (packed w/ prev one in second storage slot)
        transmitter = IOffchainAggregator(_aggregator).transmitters()[3];

        // check gas used
        gasUsed = gasleft();
        IOffchainAggregator(_aggregator).oracleObservationCount{ gas: 10_000 }(transmitter);
        gasUsed -= gasleft();

        require(gasUsed > _GAS_THRESHOLD, "invalid gas threshold");
    }

    // Called by the contract which creates OEV when reading a price feed update.
    // If Atlas solvers have submitted a more recent answer than the base oracle's most recent answer,
    // the `atlasLatestAnswer` will be returned. Otherwise fallback to the base oracle's answer.
    function latestAnswer() public view returns (int256) {
        if (BASE_FEED.latestTimestamp() >= atlasLatestTimestamp) {
            return BASE_FEED.latestAnswer();
        }

        return atlasLatestAnswer;
    }

    // Use this contract's latestTimestamp if more recent than base oracle's.
    // Otherwise fallback to base oracle's latestTimestamp
    function latestTimestamp() public view returns (uint256) {
        if (BASE_FEED.latestTimestamp() >= atlasLatestTimestamp) {
            return BASE_FEED.latestTimestamp();
        }

        return atlasLatestTimestamp;
    }

    // Fallback to base oracle's latestRoundData, unless this contract's latestTimestamp and latestAnswer are more
    // recent, in which case return those values as well as the other round data from the base oracle.
    function latestRoundData()
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = BASE_FEED.latestRoundData();
        if (updatedAt < atlasLatestTimestamp) {
            answer = atlasLatestAnswer;
            updatedAt = atlasLatestTimestamp;
        }
    }

    // Called by a trusted ExecutionEnvironment during an Atlas metacall
    // Returns address of this contract - used in allocateValueCall for OEV allocation
    function transmit(
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        external
        returns (address)
    {
        int256 answer = _verifyTransmitData(report, rs, ss, rawVs);

        atlasLatestAnswer = answer;
        atlasLatestTimestamp = block.timestamp;

        return address(this);
    }

    // Verification checks for new transmit data
    function _verifyTransmitData(
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        internal
        view
        returns (int256)
    {
        ReportData memory r;
        (,, r.observations) = abi.decode(report, (bytes32, bytes32, int192[]));

        // Check observations are ordered, then take median observation
        for (uint256 i; i < r.observations.length - 1; ++i) {
            bool inOrder = r.observations[i] <= r.observations[i + 1];
            if (!inOrder) revert ObservationsNotOrdered();
        }

        (address[] memory validTransmitters, address _aggregator) = _validateTransmitter();

        bytes32 reportHash = keccak256(report);

        for (uint256 i; i < rs.length; ++i) {
            address signer = ecrecover(reportHash, uint8(rawVs[i]) + 27, rs[i], ss[i]);
            if (!_isSigner(validTransmitters, _aggregator, signer)) {
                // console.log("invalid signer:", signer);
                revert();
            }
            // console.log("__valid signer:", signer);
        }

        int192 median = r.observations[r.observations.length / 2];

        if (median <= 0) revert AnswerMustBeAboveZero();

        return int256(median);
    }

    function _validateTransmitter() internal view returns (address[] memory validTransmitters, address _aggregator) {
        // Get the user from the EE
        // NOTE: technically we can pull this from calldata, including full function here for readability
        address transmitter = IExecutionEnvironment(msg.sender).getUser();

        // Verify that the execution environment (msg.sender) is genuine
        // NOTE: Technically we can skip this too since the activeEnvironment check below also validates this
        (address _executionEnvironment,,) =
            IAtlasFactory(ATLAS).getExecutionEnvironment(transmitter, address(DAPP_CONTROL));

        if (msg.sender != _executionEnvironment) {
            revert TransmitterInvalid(transmitter);
        }

        if (IExecutionEnvironment(msg.sender).getControl() != address(DAPP_CONTROL)) {
            revert TransmitterInvalid(transmitter);
        }

        // Verify that this environment is the currently active one according to Atlas
        // require(msg.sender == _activeEnvironment(), "inactive EE");

        // Get the valid transmitters
        // NOTE: Be careful if considering storing these in a map - that would make it tricky to deauthorize for this
        // contract
        // when they're deauthorized on the parent aggregator. imo it's better to skip the map altogether since we'd
        // want a
        //fully updated list each time to make sure no transmitter has been removed.
        _aggregator = BASE_FEED.aggregator();
        validTransmitters = IOffchainAggregator(_aggregator).transmitters();

        // Make sure this transmitter is valid
        if (!_isTransmitter(validTransmitters, transmitter)) {
            revert TransmitterInvalid(transmitter);
        }

        // Heat up the storage access on the s_oracle array loc/length so that _isSigner()'s gasleft() checks are even
        IOffchainAggregator(_aggregator).oracleObservationCount(transmitter);
    }

    function _isTransmitter(address[] memory validTransmitters, address transmitter) internal pure returns (bool) {
        uint256 len = validTransmitters.length;
        // Loop through them and see if there's a match
        for (uint256 i; i < len; i++) {
            if (transmitter == validTransmitters[i]) return true;
        }
        return false;
    }

    function _isSigner(
        address[] memory validTransmitters,
        address _aggregator,
        address signer
    )
        internal
        view
        returns (bool)
    {
        /*
            Super hacky approach... but if an address isn't "Role.Unset" and it also isn't
            Role.Transmitter then by the process of elimination that means it's a valid signer.

            We can determine if it's Unset or not by the gas used for the view call:
            Unset = 1 storage read, Transmitter or Signer = 2 storage reads:

                function oracleObservationCount(address _signerOrTransmitter) {
                    Oracle memory oracle = s_oracles[_signerOrTransmitter];
                    if (oracle.role == Role.Unset) { return 0; }
                    return s_oracleObservationsCounts[oracle.index] - 1;
                }

            s_oracles[i] should be a cold storage load - if not, it's invalid.
            s_oracleObservationsCounts[i] may be cold or hot - it's a packed struct. 
            _aggregator is a hot address.
        */

        uint256 gasUsed = gasleft();
        IOffchainAggregator(_aggregator).oracleObservationCount{ gas: 10_000 }(signer);
        gasUsed -= gasleft();

        /*
            console.log("---");
            console.log("signer:", signer);
            console.log("gas used:", gasUsed);
        */

        // NOTE: The gas usage check also will fail if a signer doublesigns
        if (gasUsed > _GAS_THRESHOLD) {
            // TODO: pinpoint the actual threshold, add in index + packing.
            return !_isTransmitter(validTransmitters, signer);
        }
        return false;
    }

    // ---------------------------------------------------- //
    //                     Owner Functions                  //
    // ---------------------------------------------------- //

    // Withdraw ETH OEV captured via Atlas solver bids
    function withdrawETH(address recipient) external onlyOwner {
        (bool success,) = recipient.call{ value: address(this).balance }("");
        if (!success) revert WithdrawETHFailed();
    }

    // Withdraw ERC20 OEV captured via Atlas solver bids
    function withdrawERC20(address token, address recipient) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), recipient, IERC20(token).balanceOf(address(this)));
    }

    fallback() external payable { }
    receive() external payable { }

    // ---------------------------------------------------- //
    //                     View  Functions                  //
    // ---------------------------------------------------- //
    function aggregator() external view returns (address) {
        return BASE_FEED.aggregator();
    }

    function transmitters() external view returns (address[] memory) {
        return IOffchainAggregator(BASE_FEED.aggregator()).transmitters();
    }

    function executionEnvironment(address transmitter) external view returns (address environment) {
        (environment,,) = IAtlasFactory(ATLAS).getExecutionEnvironment(transmitter, address(DAPP_CONTROL));
    }
}

// -----------------------------------------------
// Structs and interface for Chainlink Aggregator
// -----------------------------------------------

struct ReportData {
    HotVars hotVars; // Only read from storage once
    bytes observers; // ith element is the index of the ith observer
    int192[] observations; // ith element is the ith observation
    bytes vs; // jth element is the v component of the jth signature
    bytes32 rawReportContext;
}

struct HotVars {
    // Provides 128 bits of security against 2nd pre-image attacks, but only
    // 64 bits against collisions. This is acceptable, since a malicious owner has
    // easier way of messing up the protocol than to find hash collisions.
    bytes16 latestConfigDigest;
    uint40 latestEpochAndRound; // 32 most sig bits for epoch, 8 least sig bits for round
    // Current bound assumed on number of faulty/dishonest oracles participating
    // in the protocol, this value is referred to as f in the design
    uint8 threshold;
    // Chainlink Aggregators expose a roundId to consumers. The offchain reporting
    // protocol does not use this id anywhere. We increment it whenever a new
    // transmission is made to provide callers with contiguous ids for successive
    // reports.
    uint32 latestAggregatorRoundId;
}

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function owner() external view returns (address);
    function aggregator() external view returns (address);
    function phaseId() external view returns (uint16);
    function phaseAggregators(uint16 phaseId) external view returns (address);
    function proposedAggregator() external view returns (address);
}

interface IOffchainAggregator {
    function transmitters() external view returns (address[] memory);
    function oracleObservationCount(address _signerOrTransmitter) external view returns (uint16);
}

interface IExecutionEnvironment {
    function getUser() external pure returns (address user);
    function getControl() external pure returns (address control);
}

interface IAtlasFactory {
    function activeEnvironment() external view returns (address);
    function getExecutionEnvironment(
        address user,
        address dAppControl
    )
        external
        view
        returns (address executionEnvironment, uint32 callConfig, bool exists);
}

interface IChainlinkDAppControl {
    function verifyTransmitSigners(
        address baseChainlinkFeed,
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        external
        view
        returns (bool verified);
}
