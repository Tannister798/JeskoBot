// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import "./CZToken.sol";
import "./PrivateAMM.sol";

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/**
 * @title HouseBorrower (Path B)
 * @notice Private skewed AMM house cycle:
 *         Aave WETH flash loan + CZ flash mint + temp liquidity +
 *         CZ→WETH on PrivateAMM + optional WETH→USDC on Uniswap.
 *         CZ mint is repaid from held CZ (no need to buy CZ on Uniswap).
 */
contract HouseBorrower is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    struct CycleData {
        uint256 mintAmount;
        uint256 aaveAmount;
        uint256 aavePremium;
        uint256 deadline;
        uint256 startingWethBalance;
        uint256 minUsdcOut;
        bool sellWethForUsdc;
    }

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IPool public immutable aavePool;
    IUniswapV3SwapRouter public immutable swapRouter;
    uint24 public immutable swapFee;

    uint256 public minProfit;
    uint256 public maxTradeSize;
    /// @notice Fraction of minted CZ kept to repay the flash mint (rest can be swapped).
    ///         10000 = 100%. Default keeps enough for debt; remainder is used on AMM.
    bool public paused;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    event CycleStarted(uint256 mintAmount, uint256 loanAmount);
    event CycleSuccess(uint256 mintAmount, uint256 profitWeth);
    event Paused(bool isPaused);

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(
        address _cz,
        address _amm,
        address _weth,
        address _usdc,
        address _aavePool,
        address _swapRouter,
        uint24 _swapFee
    ) Ownable(msg.sender) {
        require(_cz.code.length > 0, "Invalid CZ");
        require(_amm.code.length > 0, "Invalid AMM");
        require(_weth.code.length > 0, "Invalid WETH");
        require(_usdc.code.length > 0, "Invalid USDC");
        require(_aavePool.code.length > 0, "Invalid Aave");
        require(_swapRouter.code.length > 0, "Invalid router");
        require(_swapFee == 100 || _swapFee == 500 || _swapFee == 3000 || _swapFee == 10000, "Bad fee");
        require(
            address(PrivateAMM(_amm).token0()) == _cz
                && address(PrivateAMM(_amm).token1()) == _weth,
            "Invalid AMM pair"
        );

        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        aavePool = IPool(_aavePool);
        swapRouter = IUniswapV3SwapRouter(_swapRouter);
        swapFee = _swapFee;

        minProfit = 0.0001 ether;
        maxTradeSize = 100_000 ether;
    }

    function setMinProfit(uint256 _min) external onlyOwner {
        minProfit = _min;
    }

    function setMaxTradeSize(uint256 _max) external onlyOwner {
        require(_max > 0, "Zero");
        maxTradeSize = _max;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @param mintAmount   CZ to flash mint
     * @param loanAmount   WETH to flash loan from Aave
     * @param deadline     tx deadline
     * @param minUsdcOut   min USDC if sellWethForUsdc is true (else 0)
     * @param sellWethForUsdc  if true, sell a portion of bought WETH → USDC on Uniswap
     */
    function executeCycle(
        uint256 mintAmount,
        uint256 loanAmount,
        uint256 deadline,
        uint256 minUsdcOut,
        bool sellWethForUsdc
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp < deadline, "Deadline passed");
        require(mintAmount > 0 && mintAmount <= maxTradeSize, "Invalid mint");
        require(loanAmount > 0, "Invalid loan");

        emit CycleStarted(mintAmount, loanAmount);

        CycleData memory cycle = CycleData({
            mintAmount: mintAmount,
            aaveAmount: 0,
            aavePremium: 0,
            deadline: deadline,
            startingWethBalance: weth.balanceOf(address(this)),
            minUsdcOut: minUsdcOut,
            sellWethForUsdc: sellWethForUsdc
        });

        aavePool.flashLoanSimple(
            address(this),
            address(weth),
            loanAmount,
            abi.encode(cycle),
            0
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(aavePool), "Only Aave");
        require(initiator == address(this), "Invalid initiator");
        require(asset == address(weth), "Wrong asset");

        CycleData memory cycle = abi.decode(params, (CycleData));
        require(block.timestamp <= cycle.deadline, "Deadline");

        cycle.aaveAmount = amount;
        cycle.aavePremium = premium;

        cz.flashLoan(this, address(cz), cycle.mintAmount, abi.encode(cycle));

        return true;
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(cz), "Only CZ");
        require(initiator == address(this), "Invalid initiator");
        require(token == address(cz), "Wrong token");

        CycleData memory cycle = abi.decode(data, (CycleData));
        require(block.timestamp <= cycle.deadline, "Deadline expired");

        uint256 profit = _executeArbitrage(cycle, amount, fee);
        emit CycleSuccess(amount, profit);
        return CALLBACK_SUCCESS;
    }

    function _executeArbitrage(
        CycleData memory cycle,
        uint256 czMinted,
        uint256 czFee
    ) private returns (uint256 profit) {
        uint256 totalCzDebt = czMinted + czFee;
        uint256 totalAaveDebt = cycle.aaveAmount + cycle.aavePremium;

        // OpenZeppelin ERC20FlashMint fee is usually 0, but handle fee > 0:
        // we must still hold totalCzDebt at repay time.
        require(czMinted >= totalCzDebt || czFee == 0, "Fee model unsupported");
        // When fee == 0, totalCzDebt == czMinted; we keep that much CZ unspent.

        // --- 1) Temporary liquidity (two-sided) ---
        // Use a small slice of CZ + full Aave WETH as temp depth.
        uint256 tempCz = czMinted / 10;
        if (tempCz == 0) tempCz = 0; // allow WETH-only temp if mint tiny
        uint256 tempWeth = cycle.aaveAmount;

        if (tempCz > 0) {
            cz.forceApprove(address(amm), czMinted);
        }
        weth.forceApprove(address(amm), tempWeth);
        amm.addLiquidity(tempCz, tempWeth, true);

        // --- 2) CZ available to swap = minted - tempCz - amount reserved to repay mint ---
        // Reserve totalCzDebt CZ for repayment (when fee==0 this is all minted if tempCz=0).
        // So we only swap what is left after temp + repay reserve.
        uint256 reservedForRepay = totalCzDebt;
        uint256 locked = tempCz + reservedForRepay;
        require(czMinted >= locked, "Mint too small for temp+repay");
        uint256 czToSwap = czMinted - locked;

        uint256 wethBought = 0;
        if (czToSwap > 0) {
            (, wethBought) = amm.swap(czToSwap, 0);
            require(wethBought > 0, "AMM swap failed");
        }

        // --- 3) Optional external leg: sell some WETH → USDC (real market) ---
        if (cycle.sellWethForUsdc && wethBought > 0) {
            uint256 wethToSell = wethBought / 2;
            if (wethToSell > 0) {
                weth.forceApprove(address(swapRouter), wethToSell);
                swapRouter.exactInputSingle(
                    IUniswapV3SwapRouter.ExactInputSingleParams({
                        tokenIn: address(weth),
                        tokenOut: address(usdc),
                        fee: swapFee,
                        recipient: address(this),
                        deadline: cycle.deadline,
                        amountIn: wethToSell,
                        amountOutMinimum: cycle.minUsdcOut,
                        sqrtPriceLimitX96: 0
                    })
                );
                weth.forceApprove(address(swapRouter), 0);
            }
        }

        // --- 4) Remove temporary liquidity ---
        // May return less WETH than deposited if swap drained reserves;
        // PrivateAMM must not over-claim. If your AMM still tracks full temp
        // and reverts, reduce swap size or patch AMM remove to min(temp, reserve).
        amm.removeMyTemporaryLiquidity();

        // --- 5) Repay CZ flash mint from held CZ ---
        uint256 czBal = cz.balanceOf(address(this));
        require(czBal >= totalCzDebt, "Missing CZ for repay");
        cz.forceApprove(address(cz), totalCzDebt);

        // --- 6) Approve Aave repayment (Aave pulls after this callback returns) ---
        weth.forceApprove(address(aavePool), totalAaveDebt);

        // --- 7) Profit in WETH above starting balance, after Aave debt ---
        uint256 remainingWeth = weth.balanceOf(address(this));
        require(remainingWeth >= cycle.startingWethBalance, "Ate into buffer");

        uint256 cycleWeth = remainingWeth - cycle.startingWethBalance;
        require(cycleWeth >= totalAaveDebt + minProfit, "Not profitable");

        profit = cycleWeth - totalAaveDebt;
        if (profit > 0) {
            weth.safeTransfer(owner(), profit);
        }

        // USDC (if any) stays on contract; owner can emergencyWithdraw
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(owner(), bal);
        }
    }

    receive() external payable {}
}