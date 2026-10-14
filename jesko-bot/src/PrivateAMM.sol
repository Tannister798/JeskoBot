// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateAMM is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    // Tracks temporary liquidity so it can be removed cleanly
    mapping(address => uint256) public tempLiquidity1;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out);

    constructor(address _token0, address _token1) Ownable(msg.sender) {
        require(_token0 != address(0) && _token1 != address(0), "Zero address");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external {
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
            reserve0 += amount0;
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
            reserve1 += amount1;
            tempLiquidity1[msg.sender] += amount1;
        }
        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    function removeMyTemporaryLiquidity() external {
        uint256 amount1 = tempLiquidity1[msg.sender];
        require(amount1 > 0, "No temp liquidity");
        require(amount1 <= reserve1, "Insufficient reserves");

        tempLiquidity1[msg.sender] = 0;
        reserve1 -= amount1;
        token1.safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, 0, amount1);
    }

    function removeLiquidity(uint256 amount0, uint256 amount1) external onlyOwner {
        require(amount0 <= reserve0 && amount1 <= reserve1, "Insufficient reserves");
        reserve0 -= amount0;
        reserve1 -= amount1;
        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1);
    }

    function swap(uint256 amount0In, uint256 amount1In) external returns (uint256 amount0Out, uint256 amount1Out) {
        require(amount0In > 0 || amount1In > 0, "Zero input");

        if (amount0In > 0) {
            amount1Out = (reserve1 * amount0In) / (reserve0 + amount0In);
            require(amount1Out > 0 && amount1Out < reserve1, "Insufficient liquidity");
            token0.safeTransferFrom(msg.sender, address(this), amount0In);
            token1.safeTransfer(msg.sender, amount1Out);
            reserve0 += amount0In;
            reserve1 -= amount1Out;
        } else {
            amount0Out = (reserve0 * amount1In) / (reserve1 + amount1In);
            require(amount0Out > 0 && amount0Out < reserve0, "Insufficient liquidity");
            token1.safeTransferFrom(msg.sender, address(this), amount1In);
            token0.safeTransfer(msg.sender, amount0Out);
            reserve1 += amount1In;
            reserve0 -= amount0Out;
        }

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }
}