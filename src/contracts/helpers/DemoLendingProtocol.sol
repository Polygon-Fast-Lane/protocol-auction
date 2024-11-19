// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

// A super basic Demo Lending Protocol to illustrate Atlas' OEV (Oracle Extractable Value) capturing abilities during
// oracle price update events, e.g. when triggering lending protocol liquidations.
//
// In a real lending protocol, collateral is deposited and borrowed against. If the "health factor" (ratio of borrowed
// value to collateral value) falls below a certain threshold, the position is liquidatable. Liquidations are performed
// by a liquidator returning the borrowed asset in exchange for the collateral + a liquidation fee.
//
// In this demo protocol, collateral is deposited and a liquidation price is set, per account. If the price reported by
// the oracle is below the liquidation price, the account can be liquidated simply by calling `liquidate()` - the
// liquidator does not need to return any assets, and will receive the entire amount deposited by the targeted account.
//
// These simplifications let us focus on the core OEV capture mechanics of Atlas.

struct Position {
    uint256 amount; // amount of deposit token in the position
    uint256 liquidationPrice; // price at which the position can be liquidated
}

contract DemoLendingProtocol is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable DEPOSIT_TOKEN;
    IChainlinkFeed public chainlinkFeed;

    mapping(address account => Position) public positions;

    error PositionNotLiquidatable();
    error PositionNotFound();
    error PositionAlreadyExists();

    event Deposit(address indexed account, uint256 amount, uint256 liquidationPrice);
    event Withdraw(address indexed account, uint256 amount);
    event Liquidation(address indexed account, address indexed recipient, uint256 amount);

    constructor(address depositToken) Ownable(msg.sender) {
        DEPOSIT_TOKEN = IERC20(depositToken);
    }

    // ---------------------------------------------------- //
    //                    Setup Functions                   //
    // ---------------------------------------------------- //

    // Deposits `amount` of deposit token into caller's position, setting the liquidation price to `liquidationPrice`.
    // NOTE: `liquidationPrice` is specified with 8 decimals, as this is the price format reported by Chainlink oracles.
    // e.g. $5 = 500000000.
    function deposit(uint256 amount, uint256 liquidationPrice) external {
        Position memory position = positions[msg.sender];

        if (position.amount > 0) revert PositionAlreadyExists();

        DEPOSIT_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        positions[msg.sender] = Position(amount, liquidationPrice);

        emit Deposit(msg.sender, amount, liquidationPrice);
    }

    // Withdraws funds in caller's position if not liquidated, and deletes the position.
    function withdraw() external {
        Position memory position = positions[msg.sender];

        if (position.amount == 0) revert PositionNotFound();

        DEPOSIT_TOKEN.safeTransfer(msg.sender, position.amount);
        delete positions[msg.sender];

        emit Withdraw(msg.sender, position.amount);
    }

    // ---------------------------------------------------- //
    //                    Solver Functions                  //
    // ---------------------------------------------------- //

    // Called by a solver. If targeted account's position is liquidatable, the position amount is sent to the
    // `recipient` address. If position is not liquidatable, reverts.
    function liquidate(address account, address recipient) external {
        Position memory position = positions[account];

        if (position.amount == 0) revert PositionNotFound();
        if (position.liquidationPrice <= uint256(chainlinkFeed.latestAnswer())) revert PositionNotLiquidatable();

        // Send liquidated amount to solver's recipient, and delete the account's position
        DEPOSIT_TOKEN.safeTransfer(recipient, position.amount);
        delete positions[account];

        emit Liquidation(account, recipient, position.amount);
    }

    // Helper view function for solvers to check if a position is liquidatable
    function isLiquidatable(address account) external view returns (bool) {
        Position storage position = positions[account];
        return (position.amount > 0) && (uint256(chainlinkFeed.latestAnswer()) < position.liquidationPrice);
    }

    // ---------------------------------------------------- //
    //                     Owner Functions                  //
    // ---------------------------------------------------- //

    function setOracle(address newChainlinkFeed) external onlyOwner {
        chainlinkFeed = IChainlinkFeed(newChainlinkFeed);
    }
}

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
