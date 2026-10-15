// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * token0 = CZ, token1 = WETH (or whatever you set at deploy)
 * Skew: buys of token1 (paying token0) get a better rate for the trader
 * so the house can buy cheap when it is the trader.
 */
contract PrivateAMM is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    // Skew in bps applied in favor of token0→token1 swaps (house buy of WETH)
    // 180 = 1.8%
    uint256 public skewBps = 180;
    uint256 public constant MAX_SKEW_BPS = 500;

    mapping(address => uint256) public tempLiquidity0;
    mapping(address => uint256) public tempLiquidity1;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, bool temporary);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out);
    event SkewUpdated(uint256 skewBps);

    constructor(address _token0, address _token1) Ownable(msg.sender) {
        require(_token0 != address(0) && _token1 != address(0), "Zero address");
        require(_token0 != _token1, "Same token");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function setSkewBps(uint256 _skewBps) external onlyOwner {
        require(_skewBps <= MAX_SKEW_BPS, "Skew too high");
        skewBps = _skewBps;
        emit SkewUpdated(_skewBps);
    }

    /// @notice amount0/amount1 deposited; if temporary=true both sides are tracked for later removal
    function addLiquidity(uint256 amount0, uint256 amount1, bool temporary) external {
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
            reserve0 += amount0;
            if (temporary) tempLiquidity0[msg.sender] += amount0;
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
            reserve1 += amount1;
            if (temporary) tempLiquidity1[msg.sender] += amount1;
        }
        emit LiquidityAdded(msg.sender, amount0, amount1, temporary);
    }

    /// @notice Backward-compatible wrapper (treats deposits as temporary on token1 only was old behavior)
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        this.addLiquidity(amount0, amount1, true);
    }

    function removeMyTemporaryLiquidity() external {
        uint256 a0 = tempLiquidity0[msg.sender];
        uint256 a1 = tempLiquidity1[msg.sender];
        require(a0 > 0 || a1 > 0, "No temp liquidity");
        require(a0 <= reserve0 && a1 <= reserve1, "Insufficient reserves");

        tempLiquidity0[msg.sender] = 0;
        tempLiquidity1[msg.sender] = 0;
        reserve0 -= a0;
        reserve1 -= a1;

        if (a0 > 0) token0.safeTransfer(msg.sender, a0);
        if (a1 > 0) token1.safeTransfer(msg.sender, a1);

        emit LiquidityRemoved(msg.sender, a0, a1);
    }

    function removeLiquidity(uint256 amount0, uint256 amount1) external onlyOwner {
        require(amount0 <= reserve0 && amount1 <= reserve1, "Insufficient reserves");
        reserve0 -= amount0;
        reserve1 -= amount1;
        if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, bool applySkewFavor)
        public
        view
        returns (uint256)
    {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "Invalid");
        uint256 baseOut = (reserveOut * amountIn) / (reserveIn + amountIn);
        if (applySkewFavor && skewBps > 0) {
            // Trader receives more out (up to skewBps) — funded by pool reserves
            baseOut = baseOut + (baseOut * skewBps) / 10_000;
            if (baseOut >= reserveOut) baseOut = reserveOut - 1;
        }
        return baseOut;
    }

    /// @notice Exactly one of amount0In / amount1In must be non-zero
    function swap(uint256 amount0In, uint256 amount1In)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        require((amount0In > 0) != (amount1In > 0), "One input only");

        if (amount0In > 0) {
            // CZ in → WETH out (house buy of WETH) — skewed in trader's favor
            amount1Out = getAmountOut(amount0In, reserve0, reserve1, true);
            require(amount1Out > 0 && amount1Out < reserve1, "Insufficient liquidity");
            token0.safeTransferFrom(msg.sender, address(this), amount0In);
            token1.safeTransfer(msg.sender, amount1Out);
            reserve0 += amount0In;
            reserve1 -= amount1Out;
        } else {
            // WETH in → CZ out — no favorable skew
            amount0Out = getAmountOut(amount1In, reserve1, reserve0, false);
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