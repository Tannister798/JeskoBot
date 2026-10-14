// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceFeed {
    function getPrice() external view returns (uint256);
}

contract MockPriceFeed is IPriceFeed {
    uint256 public price;

    constructor(uint256 _initialPrice) {
        price = _initialPrice;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getPrice() external view override returns (uint256) {
        return price;
    }
}
