//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { SafeERC20, IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IChainlinkAtlasWrapper, AggregatorV2V3Interface } from "./IChainlinkAtlasWrapper.sol";
import { IChainlinkDAppControl } from "./IChainlinkDAppControl.sol";

// A wrapper contract for a specific Chainlink price feed, used by Atlas to capture Oracle Extractable Value (OEV).
// Each MEV-generating protocol needs their own wrapper for each Chainlink price feed they use.
contract ChainlinkAtlasWrapper is Ownable, IChainlinkAtlasWrapper {
    address public immutable ATLAS;
    AggregatorV2V3Interface public immutable BASE_FEED; // Base Chainlink Feed
    IChainlinkDAppControl public immutable DAPP_CONTROL; // Chainlink Atlas DAppControl

    // Vars below hold values from the most recent successful `transmit()` call to this wrapper.
    int256 public atlasLatestAnswer;
    uint256 public atlasLatestTimestamp;
    uint40 public atlasLatestEpochAndRound;

    // Trusted ExecutionEnvironments
    mapping(address transmitter => bool trusted) public transmitters;

    error TransmitterNotTrusted(address transmitter);
    error ArrayLengthMismatch();
    error CannotReuseReport();
    error ZeroObservations();
    error ObservationsNotOrdered();
    error ObservationsMustBePositive();
    error SignerVerificationFailed();
    error WithdrawETHFailed();

    event TransmitterStatusChanged(address indexed transmitter, bool trusted);

    constructor(address atlas, address baseChainlinkFeed, address _owner) Ownable(_owner) {
        ATLAS = atlas;
        BASE_FEED = AggregatorV2V3Interface(baseChainlinkFeed);
        DAPP_CONTROL = IChainlinkDAppControl(msg.sender); // Chainlink DAppControl is also wrapper factory
    }

    // ---------------------------------------------------- //
    //                  Atlas Impl Functions                //
    // ---------------------------------------------------- //

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
        if (!transmitters[msg.sender]) revert TransmitterNotTrusted(msg.sender);
        if (rs.length != ss.length) revert ArrayLengthMismatch();

        (int256 answer, uint40 epochAndRound) = _verifyTransmitData(report, rs, ss, rawVs);

        atlasLatestAnswer = answer;
        atlasLatestTimestamp = block.timestamp;
        atlasLatestEpochAndRound = epochAndRound;

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
        returns (int256, uint40)
    {
        int192 median;
        uint40 epochAndRound;
        ReportData memory r;
        (r.rawReportContext,, r.observations) = abi.decode(report, (bytes32, bytes32, int192[]));

        // New stack frame required here to avoid Stack Too Deep error
        {
            uint256 observationCount = r.observations.length;
            if (observationCount == 0) revert ZeroObservations();

            // Check report data has not already been used in this wrapper
            epochAndRound = uint40(uint256(r.rawReportContext));
            if (epochAndRound <= atlasLatestEpochAndRound) revert CannotReuseReport();

            // Check observations are ordered
            for (uint256 i; i < observationCount - 1; ++i) {
                bool inOrder = r.observations[i] <= r.observations[i + 1];
                if (!inOrder) revert ObservationsNotOrdered();
            }
            if (r.observations[0] < 0) revert ObservationsMustBePositive();

            // Calculate median from observations, cannot be 0
            median = r.observations[observationCount / 2];
        }

        bool signersVerified =
            IChainlinkDAppControl(DAPP_CONTROL).verifyTransmitSigners(address(BASE_FEED), report, rs, ss, rawVs);
        if (!signersVerified) revert SignerVerificationFailed();

        return (int256(median), epochAndRound);
    }

    // ---------------------------------------------------- //
    //           Chainlink Pass-through Functions           //
    // ---------------------------------------------------- //

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
        uint256 baseFeedLatestTimestamp = BASE_FEED.latestTimestamp();
        if (baseFeedLatestTimestamp >= atlasLatestTimestamp) {
            return baseFeedLatestTimestamp;
        }

        return atlasLatestTimestamp;
    }

    // Pass-through call to base oracle's `latestRound()` function
    function latestRound() external view override returns (uint256) {
        return BASE_FEED.latestRound();
    }

    // Fallback to base oracle's latestRoundData, unless this contract's `latestTimestamp` and `latestAnswer` are more
    // recent, in which case return those values as well as the other round data from the base oracle.
    // NOTE: This may break some integrations as it implies a `roundId` has multiple answers (the canonical answer from
    // the base feed, and the `atlasLatestAnswer` if more recent), which deviates from the expected behaviour of the
    // base Chainlink feeds. Be aware of this tradeoff when integrating ChainlinkAtlasWrappers as your price feed.
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

    // Pass-through call to base oracle's `getAnswer()` function
    function getAnswer(uint256 roundId) external view override returns (int256) {
        return BASE_FEED.getAnswer(roundId);
    }

    // Pass-through call to base oracle's `getTimestamp()` function
    function getTimestamp(uint256 roundId) external view override returns (uint256) {
        return BASE_FEED.getTimestamp(roundId);
    }

    // Pass-through call to base oracle's `getRoundData()` function
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return BASE_FEED.getRoundData(_roundId);
    }

    // Pass-through calls to base oracle's `decimals()` functions
    function decimals() external view override returns (uint8) {
        return BASE_FEED.decimals();
    }

    // Pass-through calls to base oracle's `description()` functions
    function description() external view override returns (string memory) {
        return BASE_FEED.description();
    }

    // Pass-through calls to base oracle's `version()` functions
    function version() external view override returns (uint256) {
        return BASE_FEED.version();
    }

    // ---------------------------------------------------- //
    //                     Owner Functions                  //
    // ---------------------------------------------------- //

    // Owner can add/remove trusted transmitters (ExecutionEnvironments)
    function setTransmitterStatus(address transmitter, bool trusted) external onlyOwner {
        transmitters[transmitter] = trusted;
        emit TransmitterStatusChanged(transmitter, trusted);
    }

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
}

// ---------------------------------------------------- //
//             Chainlink Aggregator Structs             //
// ---------------------------------------------------- //

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
