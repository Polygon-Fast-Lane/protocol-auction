// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { Mimic } from "../src/contracts/common/Mimic.sol";

contract MimicTest is Test {
    function testMimicDelegatecall() public {
        // Deploy mimic
        Mimic mimic = new Mimic();
        deployCodeTo("Mimic.t.sol:MimicDelegateCheck", 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
        // Check it is delegatecalled and data pass is correct
        vm.expectEmit(true, true, true, true);
        bytes memory passedData = hex"01";
        emit MimicDelegateCheck.DelegateCalled(abi.encodePacked(
            passedData,
            address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB),
            address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC),
            uint32(0x22222222)
        ));
        (bool success, bytes memory data) = address(mimic).call(passedData);
        assertEq(success, true);
        assertEq(data, hex"0001");
    }

    function testMimicRevert() public {
        // Deploy mimic
        Mimic mimic = new Mimic();
        deployCodeTo("Mimic.t.sol:MimicRevertCheck", 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
        // Check that revert data gets forwarded to top level caller
        (bool success, bytes memory data) = address(mimic).call(hex"01");
        assertEq(success, false);
        assertEq(data, abi.encode(uint256(1)));
    }
}

contract MimicDelegateCheck {
    event DelegateCalled(bytes data);

    address immutable original;
    constructor() {
        original = address(this);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if(address(this) == original) {
            revert("Not delegatecall");
        }
        emit DelegateCalled(msg.data);
        return hex"0001";
    }
}

contract MimicRevertCheck {
    fallback() external {
        assembly {
            mstore(0, 0x01)
            revert(0, 32)
        }
    }
}
