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
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

contract HouseBorrower is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    struct CycleData {
        uint256 mintAmount;
        uint256 aaveAmount;
        uint256 aavePremium;
        uint256 deadline;
        uint256 startingWethBalance;
        uint256 maxWethIn;
    }

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;
    IPool public immutable aavePool;
    IUniswapV3SwapRouter public immutable swapRouter;
    uint24 public immutable swapFee;

    uint256 public minProfit;
    uint256 public maxTradeSize;
    bool public paused;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    event CycleStarted(uint256 mintAmount, uint256 loanAmount);
    event CycleSuccess(uint256 mintAmount, uint256 profit);
    event Paused(bool isPaused);

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(
        address _cz,
        address _amm,
        address _weth,
        address _aavePool,
        address _swapRouter,
        uint24 _swapFee
    ) Ownable(msg.sender) {
        require(_cz.code.length > 0, "Invalid CZ token");
        require(_amm.code.length > 0, "Invalid AMM");
        require(_weth.code.length > 0, "Invalid WETH");
        require(_aavePool.code.length > 0, "Invalid Aave pool");
        require(_swapRouter.code.length > 0, "Invalid swap router");
        require(_swapFee < 1_000_000, "Invalid swap fee");
        require(
            address(PrivateAMM(_amm).token0()) == _cz
                && address(PrivateAMM(_amm).token1()) == _weth,
            "Invalid AMM pair"
        );

        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
        aavePool = IPool(_aavePool);
        swapRouter = IUniswapV3SwapRouter(_swapRouter);
        swapFee = _swapFee;

        minProfit = 0.01 ether;
        maxTradeSize = 100_000 ether;
    }

    function setMinProfit(uint256 _min) external onlyOwner {
        minProfit = _min;
    }

    function setMaxTradeSize(uint256 _max) external onlyOwner {
        maxTradeSize = _max;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function executeCycle(
        uint256 mintAmount,
        uint256 loanAmount,
        uint256 deadline,
        uint256 maxWethIn
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline passed");
        require(mintAmount > 0 && mintAmount <= maxTradeSize, "Invalid mint size");
        require(loanAmount > 0, "Invalid loan size");
        require(maxWethIn > 0, "Invalid swap limit");

        emit CycleStarted(mintAmount, loanAmount);

        uint256 startingWethBalance = weth.balanceOf(address(this));
        CycleData memory cycle = CycleData(
            mintAmount,
            0,
            0,
            deadline,
            startingWethBalance,
            maxWethIn
        );

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
        require(msg.sender == address(cz), "Only CZToken");
        require(initiator == address(this), "Invalid initiator");
        require(token == address(cz), "Wrong token");

        CycleData memory cycle = abi.decode(data, (CycleData));
        require(block.timestamp <= cycle.deadline, "Deadline expired");
        uint256 totalCzDebt = amount + fee;

        uint256 profit = _executeArbitrage(cycle, totalCzDebt);
        emit CycleSuccess(amount, profit);

        return CALLBACK_SUCCESS;
    }

    function _executeArbitrage(CycleData memory cycle, uint256 totalCzDebt)
        private
        returns (uint256 profit)
    {
        uint256 totalAaveDebt = cycle.aaveAmount + cycle.aavePremium;

        // 1. Add temporary liquidity
        weth.forceApprove(address(amm), cycle.aaveAmount);
        amm.addLiquidity(0, cycle.aaveAmount);

        // 2. Swap CZ → WETH on skewed AMM
        IERC20(address(cz)).forceApprove(address(amm), cycle.mintAmount);
        (, uint256 wethBought) = amm.swap(cycle.mintAmount, 0);
        require(wethBought > 0, "Swap failed");

        // 3. Remove temporary liquidity
        amm.removeMyTemporaryLiquidity();

        // 4. Buy back the flash-minted CZ before its lender pulls repayment.
        uint256 availableWeth = weth.balanceOf(address(this)) - cycle.startingWethBalance;
        require(cycle.maxWethIn <= availableWeth, "Swap limit exceeds proceeds");
        weth.forceApprove(address(swapRouter), cycle.maxWethIn);
        uint256 wethSpent = swapRouter.exactOutputSingle(
            IUniswapV3SwapRouter.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(cz),
                fee: swapFee,
                recipient: address(this),
                deadline: cycle.deadline,
                amountOut: totalCzDebt,
                amountInMaximum: cycle.maxWethIn,
                sqrtPriceLimitX96: 0
            })
        );
        weth.forceApprove(address(swapRouter), 0);
        require(wethSpent <= cycle.maxWethIn, "Swap limit exceeded");

        // 5. Approve flash-loan repayments.
        IERC20(address(cz)).forceApprove(address(cz), totalCzDebt);

        weth.forceApprove(address(aavePool), totalAaveDebt);

        uint256 remainingWeth = weth.balanceOf(address(this));
        require(remainingWeth >= cycle.startingWethBalance, "Initial balance spent");
        uint256 cycleWeth = remainingWeth - cycle.startingWethBalance;
        require(cycleWeth >= totalAaveDebt + minProfit, "Not enough profit");

        profit = cycleWeth - totalAaveDebt;
        weth.safeTransfer(owner(), profit);

    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(owner(), bal);
        }
    }

    receive() external payable {}
}