//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IDAppControl } from "../interfaces/IDAppControl.sol";

/// @title GovernanceBurner
/// @author FastLane Labs
/// @notice Effectively burns the governance keys of a target Atlas DAppControl contract. This recipient burner contract
/// is necessary due to the 2-step governance transfer process of Atlas DAppControl contracts. NOTE: Once governance has
/// been transferred to this burner contract, there is no way to recover it.
contract GovernanceBurner {
    constructor() { }

    /// @notice Accepts the transfer of governance of an Atlas DAppControl contract. After this governance has been
    /// transferred to this burner contract, it is effectively burned. This burner contract cannot transfer governance
    /// to any other address, and does not have the ability to use any governance functions.
    /// @dev Before calling this function, the governance address must have called transferGovernance on the DAppControl
    /// contract, to initialize the transfer process.
    /// @param control The address of the DAppControl contract for which to burn governance.
    function burnGovernance(address control) external {
        IDAppControl(control).acceptGovernance();
    }
}
