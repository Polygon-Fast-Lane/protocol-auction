//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "../../dapp/DAppControl.sol";
import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";

// Uniswap Imports
import { IUniswapV2Router01, IUniswapV2Router02 } from "./interfaces/IUniswapV2Router.sol";

/*
* @title V2RewardDAppControl
* @notice This contract is a Uniswap v2 "backrun" module that rewards users with an arbitrary ERC20 token (or ETH) for
    MEV generating swaps conducted on a UniswapV2Router02. The bid amount paid by solvers (the "reward token") is gifted
    to users.
* @notice Frontends can easily offer gasless swaps to users selling ERC20 tokens (users would need to approve Atlas to
    spend their tokens first). For ETH swaps, the user would need to bundle their own operation.
* @notice The reward token can be ETH (address(0)) or any ERC20 token. Solvers are required to pay their bid with that
    token. */
contract V2RewardDAppControl is DAppControl {
    address public immutable REWARD_TOKEN;
    address public immutable uniswapV2Router02;

    mapping(bytes4 => bool) public ERC20StartingSelectors;
    mapping(bytes4 => bool) public ETHStartingSelectors;
    mapping(bytes4 => bool) public exactINSelectors;

    event TokensRewarded(address indexed user, address indexed token, uint256 amount);

    constructor(
        address _atlas,
        address _rewardToken,
        address _uniswapV2Router02
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: true,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: true,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false,
                trustedOpHash: true,
                invertBidValue: false,
                exPostBids: true,
                allowAllocateValueFailure: false
            })
        )
    {
        REWARD_TOKEN = _rewardToken;
        uniswapV2Router02 = _uniswapV2Router02;

        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapExactTokensForTokens.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapTokensForExactTokens.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapTokensForExactETH.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapExactTokensForETH.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router02.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector)]
        = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens.selector)] =
            true;

        ETHStartingSelectors[bytes4(IUniswapV2Router01.swapExactETHForTokens.selector)] = true;
        ETHStartingSelectors[bytes4(IUniswapV2Router01.swapETHForExactTokens.selector)] = true;
        ETHStartingSelectors[bytes4(IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector)] =
            true;

        exactINSelectors[bytes4(IUniswapV2Router01.swapExactTokensForTokens.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router01.swapExactTokensForETH.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector)] =
            true;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router01.swapExactETHForTokens.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector)] = true;
    }

    // ---------------------------------------------------- //
    //                       Custom                         //
    // ---------------------------------------------------- //

    /*
    * @notice This function inspects the user's call data to determine the token they are selling and the amount sold
    * @param userData The user's call data
    * @return tokenSold The address of the ERC20 token the user is selling (or address(0) for ETH)
    * @return amountSold The amount of the token sold
    */
    function getTokenSold(bytes calldata userData) external view returns (address tokenSold, uint256 amountSold) {
        bytes4 funcSelector = bytes4(userData);

        // User is only allowed to call swap functions
        require(
            ERC20StartingSelectors[funcSelector] || ETHStartingSelectors[funcSelector],
            "V2RewardDAppControl: InvalidFunction"
        );

        if (ERC20StartingSelectors[funcSelector]) {
            address[] memory path;

            if (exactINSelectors[funcSelector]) {
                // Exact amount sold
                (amountSold,, path,,) = abi.decode(userData[4:], (uint256, uint256, address[], address, uint256));
            } else {
                // Max amount sold, unused amount will be refunded in the _postOpsCall hook if any
                (, amountSold, path,,) = abi.decode(userData[4:], (uint256, uint256, address[], address, uint256));
            }

            tokenSold = path[0];
        }
    }

    // ---------------------------------------------------- //
    //                     Atlas hooks                      //
    // ---------------------------------------------------- //

    function _checkUserOperation(UserOperation memory userOp) internal view override {
        // User is only allowed to call UniswapV2Router02
        require(userOp.dapp == uniswapV2Router02, "V2RewardDAppControl: InvalidDestination");
    }

    /*
    * @notice This function is called before the user's call to UniswapV2Router02
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev If the user is selling an ERC20 token, the function transfers the tokens from the user to the
        ExecutionEnvironment and approves UniswapV2Router02 to spend the tokens from the ExecutionEnvironment
    * @param userOp The UserOperation struct
    * @return The address of the ERC20 token the user is selling (or address(0) for ETH), which is used in the
        _postOpsCall hook to refund leftover dust, if any
    */
    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory) {
        // The current hook is delegatecalled, so we need to call the userOp.control to access the mappings
        (address tokenSold, uint256 amountSold) = V2RewardDAppControl(userOp.control).getTokenSold(userOp.data);

        // Pull the tokens from the user and approve UniswapV2Router02 to spend them
        _getAndApproveUserERC20(tokenSold, amountSold, uniswapV2Router02);

        // Return tokenSold for the _postOpsCall hook to be able to refund dust
        return abi.encode(tokenSold);
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It simply transfers the reward token to the user (solvers are required to pay their bid with the reward
        token, so we don't have any more steps to take here)
    * @param bidToken The address of the token used for the winning SolverOperation's bid
    * @param bidAmount The winning bid amount
    * @param _
    */
    function _allocateValueCall(address bidToken, uint256 bidAmount, bytes calldata) internal override {
        require(bidToken == REWARD_TOKEN, "V2RewardDAppControl: InvalidBidToken");

        address user = _user();

        if (bidToken == address(0)) {
            SafeTransferLib.safeTransferETH(user, bidAmount);
        } else {
            SafeTransferLib.safeTransfer(REWARD_TOKEN, user, bidAmount);
        }

        emit TokensRewarded(user, REWARD_TOKEN, bidAmount);
    }

    /*
    * @notice This function is called as the last phase of a `metacall` transaction
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It refunds any leftover dust (ETH/ERC20) to the user (this can occur when the user is calling an exactOUT
        function and the amount sold is less than the amountInMax)
    * @param data The address of the ERC20 token the user is selling (or address(0) for ETH), that was returned by the
        _preOpsCall hook
    */
    function _postOpsCall(bool, bytes calldata data) internal override {
        address tokenSold = abi.decode(data, (address));
        uint256 balance;

        // Refund ETH/ERC20 dust if any
        if (tokenSold == address(0)) {
            balance = address(this).balance;
            if (balance > 0) {
                SafeTransferLib.safeTransferETH(_user(), balance);
            }
        } else {
            balance = IERC20(tokenSold).balanceOf(address(this));
            if (balance > 0) {
                SafeTransferLib.safeTransfer(tokenSold, _user(), balance);
            }
        }
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public view override returns (address bidToken) {
        return REWARD_TOKEN;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
