// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CZToken is ERC20FlashMint, Ownable {
    constructor() ERC20("CZ Token", "CZ") Ownable(msg.sender) {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }
}
