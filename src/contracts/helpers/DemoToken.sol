// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract Token is ERC20, Ownable {
    uint8 internal immutable _decimals;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 __decimals
    )
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        _decimals = __decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}
