//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DAppControl } from "../../dapp/DAppControl.sol";
import { CallConfig } from "../../types/ConfigTypes.sol";
import "../../types/UserOperation.sol";
import "../../types/SolverOperation.sol";

struct SwapTokenInfo {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputMin;
}

contract TrebleSwapDAppControl is DAppControl {
    address public constant ODOS_ROUTER = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

    // TODO TREB token not available yet - replace when it is. DEGEN address for now.
    address public constant TREB = 0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed;
    address internal constant _ETH = address(0);
    address internal constant _BURN = address(0xdead);

    error InvalidUserOpData();
    error UserOpDappNotOdosRouter();
    error InsufficientUserOpValue();
    error InsufficientTrebBalance();
    error InsufficientOutputBalance();

    constructor(address atlas)
        DAppControl(
            atlas,
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
                reuseUserOp: true,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    { }

    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        if (userOp.dapp != ODOS_ROUTER) revert UserOpDappNotOdosRouter();

        (bool success, bytes memory swapData) =
            CONTROL.staticcall(abi.encodePacked(this.decodeUserOpData.selector, userOp.data));

        if (!success) revert InvalidUserOpData();

        SwapTokenInfo memory _swapInfo = abi.decode(swapData, (SwapTokenInfo));

        // If inputToken is ERC20, transfer tokens from user to EE, and approve Odos router for swap
        if (_swapInfo.inputToken != _ETH) {
            _transferUserERC20(_swapInfo.inputToken, address(this), _swapInfo.inputAmount);
            SafeTransferLib.safeApprove(_swapInfo.inputToken, ODOS_ROUTER, _swapInfo.inputAmount);
        } else {
            if (userOp.value < _swapInfo.inputAmount) revert InsufficientUserOpValue();
        }

        return swapData; // return SwapTokenInfo in bytes format, to be used in allocateValue.
    }

    function _allocateValueCall(address, uint256 bidAmount, bytes calldata data) internal virtual override {
        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));
        uint256 _outputTokenBalance = _balanceOf(_swapInfo.outputToken);
        uint256 _inputTokenBalance = _balanceOf(_swapInfo.inputToken);

        if (_outputTokenBalance < _swapInfo.outputMin) revert InsufficientOutputBalance();

        // Burn TREB bid
        SafeTransferLib.safeTransfer(TREB, _BURN, bidAmount);

        _transferUserTokens(_swapInfo, _outputTokenBalance, _inputTokenBalance);
    }

    function _postOpsCall(bool solved, bytes calldata data) internal virtual override {
        if (solved) return; // token distribution already handled in allocateValue hook

        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));
        uint256 _outputTokenBalance = _balanceOf(_swapInfo.outputToken);
        uint256 _inputTokenBalance = _balanceOf(_swapInfo.inputToken);

        if (_outputTokenBalance < _swapInfo.outputMin) revert InsufficientOutputBalance();

        _transferUserTokens(_swapInfo, _outputTokenBalance, _inputTokenBalance);
    }

    // ---------------------------------------------------- //
    //                 GETTERS AND HELPERS                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public view virtual override returns (address bidToken) {
        return TREB;
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function _transferUserTokens(
        SwapTokenInfo memory swapInfo,
        uint256 outputTokenBalance,
        uint256 inputTokenBalance
    )
        internal
    {
        // Transfer output token to user
        if (swapInfo.outputToken == _ETH) {
            SafeTransferLib.safeTransferETH(_user(), outputTokenBalance);
        } else {
            SafeTransferLib.safeTransfer(swapInfo.outputToken, _user(), outputTokenBalance);
        }

        // If any leftover input token, transfer back to user
        if (inputTokenBalance > 0) {
            if (swapInfo.inputToken == _ETH) {
                SafeTransferLib.safeTransferETH(_user(), inputTokenBalance);
            } else {
                SafeTransferLib.safeTransfer(swapInfo.inputToken, _user(), inputTokenBalance);
            }
        }
    }

    // Call this helper with userOp.data appended as calldata, to decode swap info in the Odos calldata.
    function decodeUserOpData() public view returns (SwapTokenInfo memory swapTokenInfo) {
        assembly {
            // helper function to get address either from calldata or Odos router addressList()
            function getAddress(currPos) -> result, newPos {
                let inputPos := shr(240, calldataload(currPos))

                switch inputPos
                // Reserve the null address as a special case that can be specified with 2 null bytes
                case 0x0000 { newPos := add(currPos, 2) }
                // This case means that the address is encoded in the calldata directly following the code
                case 0x0001 {
                    result := and(shr(80, calldataload(currPos)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    newPos := add(currPos, 22)
                }
                // If not 0000 or 0001, call ODOS_ROUTER.addressList(inputPos - 2) to get address
                default {
                    // 0000 and 0001 are reserved for cases above, so offset by 2 for addressList index
                    let arg := sub(inputPos, 2)
                    let selector := 0xb810fb43 // function selector for "addressList(uint256)"
                    let ptr := mload(0x40) // get the free memory pointer
                    mstore(ptr, shl(224, selector)) // shift selector to left of slot and store
                    mstore(add(ptr, 4), arg) // store the uint256 argument after the selector

                    // Perform the external call
                    let success :=
                        staticcall(
                            gas(), // gas remaining
                            ODOS_ROUTER,
                            ptr, // input location
                            0x24, // input size (4 byte selector + uint256 arg)
                            ptr, // output location
                            0x20 // output size (32 bytes for the address)
                        )

                    if eq(success, 0) { revert(0, 0) }

                    result := mload(ptr)
                    newPos := add(currPos, 2)
                }
            }

            let result := 0
            let pos := 8 // skip Odos compactSwap selector and this helper selector (4 + 4 bytes)

            // swapTokenInfo.inputToken (slot 0)
            result, pos := getAddress(pos)
            mstore(swapTokenInfo, result)

            // swapTokenInfo.outputToken (slot 2)
            result, pos := getAddress(pos)
            mstore(add(swapTokenInfo, 0x40), result)

            // swapTokenInfo.inputAmount (slot 1)
            let inputAmountLength := shr(248, calldataload(pos))
            pos := add(pos, 1)
            if inputAmountLength {
                mstore(add(swapTokenInfo, 0x20), shr(mul(sub(32, inputAmountLength), 8), calldataload(pos)))
                pos := add(pos, inputAmountLength)
            }

            // swapTokenInfo.outputMin (slot 3)
            // get outputQuote and slippageTolerance from calldata, then calculate outputMin
            let quoteAmountLength := shr(248, calldataload(pos))
            pos := add(pos, 1)
            let outputQuote := shr(mul(sub(32, quoteAmountLength), 8), calldataload(pos))
            pos := add(pos, quoteAmountLength)
            {
                let slippageTolerance := shr(232, calldataload(pos))
                mstore(add(swapTokenInfo, 0x60), div(mul(outputQuote, sub(0xFFFFFF, slippageTolerance)), 0xFFFFFF))
            }
        }
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == _ETH) {
            return address(this).balance;
        } else {
            return SafeTransferLib.balanceOf(token, address(this));
        }
    }
}
