// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IArbAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IUniswapV3Router {
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

interface ISushiV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract WethUsdcArbitrage is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant AAVE = 0;
    uint8 public constant BALANCER = 1;
    uint8 public constant UNISWAP_V3 = 0;
    uint8 public constant SUSHI_V2 = 1;
    uint256 public constant MAX_DEADLINE_SECONDS = 120;

    struct CycleData {
        uint8 buyVenue;
        uint8 sellVenue;
        uint24 buyFee;
        uint24 sellFee;
        uint256 amount;
        uint256 minUsdcOut;
        uint256 minWethOut;
        uint256 minProfit;
        uint256 deadline;
        uint256 startingWethBalance;
    }

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IArbAavePool public immutable aavePool;
    IBalancerVault public immutable balancerVault;
    IUniswapV3Router public immutable uniswapRouter;
    ISushiV2Router public immutable sushiRouter;

    uint256 public maxLoanAmount = 10 ether;
    bool public paused;

    event CycleStarted(uint8 indexed lender, uint256 loanAmount);
    event CycleSuccess(uint8 indexed lender, uint256 profitWeth);
    event Paused(bool isPaused);

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(
        address _weth,
        address _usdc,
        address _aavePool,
        address _balancerVault,
        address _uniswapRouter,
        address _sushiRouter
    ) Ownable(msg.sender) {
        require(_weth != _usdc, "Tokens must differ");
        require(_weth.code.length > 0 && _usdc.code.length > 0, "Invalid token");
        require(_aavePool.code.length > 0, "Invalid Aave pool");
        require(_balancerVault.code.length > 0, "Invalid Balancer vault");
        require(_uniswapRouter.code.length > 0, "Invalid Uniswap router");
        require(_sushiRouter.code.length > 0, "Invalid Sushi router");

        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        aavePool = IArbAavePool(_aavePool);
        balancerVault = IBalancerVault(_balancerVault);
        uniswapRouter = IUniswapV3Router(_uniswapRouter);
        sushiRouter = ISushiV2Router(_sushiRouter);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function setMaxLoanAmount(uint256 _maxLoanAmount) external onlyOwner {
        require(_maxLoanAmount > 0, "Invalid loan cap");
        maxLoanAmount = _maxLoanAmount;
    }

    function executeCycle(
        uint8 lender,
        uint256 loanAmount,
        uint8 buyVenue,
        uint8 sellVenue,
        uint24 buyFee,
        uint24 sellFee,
        uint256 minUsdcOut,
        uint256 minWethOut,
        uint256 minProfit,
        uint256 deadline
    ) external onlyOwner nonReentrant whenNotPaused {
        require(lender <= BALANCER, "Invalid lender");
        require(buyVenue <= SUSHI_V2 && sellVenue <= SUSHI_V2, "Invalid venue");
        require(buyVenue != sellVenue, "Venues must differ");
        _validateFee(buyVenue, buyFee);
        _validateFee(sellVenue, sellFee);
        require(loanAmount > 0 && loanAmount <= maxLoanAmount, "Invalid loan size");
        require(minUsdcOut > 0 && minWethOut > 0, "Invalid output minimum");
        require(deadline > block.timestamp, "Deadline passed");
        require(
            deadline <= block.timestamp + MAX_DEADLINE_SECONDS,
            "Deadline too far"
        );

        CycleData memory cycle = CycleData({
            buyVenue: buyVenue,
            sellVenue: sellVenue,
            buyFee: buyFee,
            sellFee: sellFee,
            amount: loanAmount,
            minUsdcOut: minUsdcOut,
            minWethOut: minWethOut,
            minProfit: minProfit,
            deadline: deadline,
            startingWethBalance: weth.balanceOf(address(this))
        });

        emit CycleStarted(lender, loanAmount);
        bytes memory userData = abi.encode(cycle);

        if (lender == AAVE) {
            aavePool.flashLoanSimple(address(this), address(weth), loanAmount, userData, 0);
        } else {
            IERC20[] memory tokens = new IERC20[](1);
            tokens[0] = weth;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = loanAmount;
            balancerVault.flashLoan(address(this), tokens, amounts, userData);
        }
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
        require(amount == cycle.amount, "Wrong loan amount");
        uint256 profit = _executeRoute(cycle, premium);
        weth.forceApprove(address(aavePool), amount + premium);
        emit CycleSuccess(AAVE, profit);
        return true;
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        require(msg.sender == address(balancerVault), "Only Balancer");
        require(tokens.length == 1 && amounts.length == 1 && feeAmounts.length == 1, "Invalid loan");
        require(address(tokens[0]) == address(weth), "Wrong asset");

        CycleData memory cycle = abi.decode(userData, (CycleData));
        require(amounts[0] == cycle.amount, "Wrong loan amount");
        uint256 profit = _executeRoute(cycle, feeAmounts[0]);
        weth.forceApprove(address(balancerVault), amounts[0] + feeAmounts[0]);
        emit CycleSuccess(BALANCER, profit);
    }

    function _executeRoute(CycleData memory cycle, uint256 lenderFee)
        private
        returns (uint256 profit)
    {
        require(block.timestamp <= cycle.deadline, "Deadline expired");

        weth.forceApprove(address(_router(cycle.buyVenue)), cycle.amount);
        uint256 usdcOut = _swap(
            cycle.buyVenue,
            address(weth),
            address(usdc),
            cycle.amount,
            cycle.minUsdcOut,
            cycle.buyFee,
            cycle.deadline
        );
        weth.forceApprove(address(_router(cycle.buyVenue)), 0);
        require(usdcOut >= cycle.minUsdcOut, "Insufficient USDC output");

        usdc.forceApprove(address(_router(cycle.sellVenue)), usdcOut);
        uint256 wethOut = _swap(
            cycle.sellVenue,
            address(usdc),
            address(weth),
            usdcOut,
            cycle.minWethOut,
            cycle.sellFee,
            cycle.deadline
        );
        usdc.forceApprove(address(_router(cycle.sellVenue)), 0);
        require(wethOut >= cycle.minWethOut, "Insufficient WETH output");

        uint256 debt = cycle.amount + lenderFee;
        uint256 balance = weth.balanceOf(address(this));
        require(balance >= cycle.startingWethBalance + debt + cycle.minProfit, "Not profitable");
        profit = balance - cycle.startingWethBalance - debt;
        weth.safeTransfer(owner(), profit);
    }

    function _swap(
        uint8 venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint24 fee,
        uint256 deadline
    ) private returns (uint256 amountOut) {
        if (venue == UNISWAP_V3) {
            return uniswapRouter.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts = sushiRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMinimum,
            path,
            address(this),
            deadline
        );
        return amounts[amounts.length - 1];
    }

    function _router(uint8 venue) private view returns (address) {
        return venue == UNISWAP_V3 ? address(uniswapRouter) : address(sushiRouter);
    }

    function _validateFee(uint8 venue, uint24 fee) private pure {
        if (venue == UNISWAP_V3) {
            require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000, "Invalid V3 fee");
        } else {
            require(fee == 0, "V2 fee must be zero");
        }
    }

    function emergencyWithdraw(address token) external onlyOwner {
        IERC20 asset = IERC20(token);
        uint256 balance = asset.balanceOf(address(this));
        if (balance > 0) asset.safeTransfer(owner(), balance);
    }
}