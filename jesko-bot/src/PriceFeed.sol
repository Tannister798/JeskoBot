// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IPriceFeed {
    function getPrice() external view returns (uint256);
}

contract MockPriceFeed is IPriceFeed, Ownable {
    uint256 private price;

    constructor() Ownable(msg.sender) {
        // 1e18 = neutral unit; set to your external reference after deploy
        price = 1e18;
    }

    function setPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Invalid price");
        price = _price;
    }

    function getPrice() external view override returns (uint256) {
        return price;
    }
}