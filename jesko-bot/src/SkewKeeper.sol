// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PrivateAMM.sol";
import "./PriceFeed.sol";

contract SkewKeeper is Ownable {
    using SafeERC20 for IERC20;

    PrivateAMM public immutable amm;
    IPriceFeed public priceFeed;

    uint256 public minSkewBps = 100;   // 1.0%
    uint256 public maxSkewBps = 200;   // 2.0%
    uint256 public idealSkewBps = 180; // 1.8%

    uint256 public lastRebalance;
    uint256 public rebalanceCooldown = 30;

    event Rebalanced(int256 currentSkewBps, string action);
    event PriceFeedUpdated(address newFeed);

    constructor(address _amm, address _priceFeed) Ownable(msg.sender) {
        require(_amm != address(0) && _priceFeed != address(0), "Zero address");
        amm = PrivateAMM(_amm);
        priceFeed = IPriceFeed(_priceFeed);
    }

    function setPriceFeed(address _feed) external onlyOwner {
        priceFeed = IPriceFeed(_feed);
        emit PriceFeedUpdated(_feed);
    }

    function setSkewRange(uint256 _min, uint256 _max, uint256 _ideal) external onlyOwner {
        require(_min < _max, "Invalid range");
        require(_ideal >= _min && _ideal <= _max, "Ideal out of range");
        minSkewBps = _min;
        maxSkewBps = _max;
        idealSkewBps = _ideal;
    }

    function getCurrentSkewBps() public view returns (int256) {
        (uint256 reserve0, uint256 reserve1) = amm.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");

        uint256 internalPrice = (reserve0 * 1e18) / reserve1;
        uint256 externalPrice = priceFeed.getPrice();

        int256 skew = int256(externalPrice) - int256(internalPrice);
        skew = (skew * 10000) / int256(externalPrice);
        return skew;
    }

    function isSkewHealthy() external view returns (bool) {
        int256 skew = getCurrentSkewBps();
        return skew >= int256(minSkewBps) && skew <= int256(maxSkewBps);
    }

    function rebalance() external onlyOwner {
        require(block.timestamp >= lastRebalance + rebalanceCooldown, "Cooldown active");

        int256 skew = getCurrentSkewBps();

        if (skew < int256(minSkewBps)) {
            emit Rebalanced(skew, "REBALANCE_UP");
        } else if (skew > int256(maxSkewBps)) {
            emit Rebalanced(skew, "REBALANCE_DOWN");
        } else {
            emit Rebalanced(skew, "WITHIN_RANGE");
            return;
        }

        lastRebalance = block.timestamp;
    }
}