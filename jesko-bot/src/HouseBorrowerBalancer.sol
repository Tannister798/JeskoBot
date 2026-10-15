// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import "./CZToken.sol";
import "./PrivateAMM.sol";

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
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

contract HouseBorrowerBalancer is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    IBalancerVault public constant BALANCER_VAULT =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    IUniswapV3Router public constant UNI_ROUTER =
        IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;
    IERC20 public immutable usdc;

    uint256 public minProfit;
    uint256 public maxTradeSize;
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

    constructor(address _cz, address _amm, address _weth, address _usdc) Ownable(msg.sender) {
        require(_cz != address(0) && _amm != address(0), "Zero");
        require(_weth != address(0) && _usdc != address(0), "Zero");
        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        minProfit = 0.0001 ether;
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
        uint256 minUsdcOut,
        uint256 deadline
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp < deadline, "Deadline passed");
        require(mintAmount > 0 && mintAmount <= maxTradeSize, "Invalid mint");
        require(loanAmount > 0, "Invalid loan");

        emit CycleStarted(mintAmount, loanAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanAmount;

        bytes memory userData = abi.encode(mintAmount, minUsdcOut, deadline);
        BALANCER_VAULT.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        require(msg.sender == address(BALANCER_VAULT), "Only Balancer");
        require(tokens.length == 1 && tokens[0] == address(weth), "Wrong token");

        uint256 loanAmount = amounts[0];
        uint256 feeAmount = feeAmounts[0];
        (uint256 mintAmount, uint256 minUsdcOut, uint256 deadline) =
            abi.decode(userData, (uint256, uint256, uint256));

        bytes memory czData = abi.encode(loanAmount, feeAmount, minUsdcOut, deadline);
        cz.flashLoan(this, address(cz), mintAmount, czData);

        uint256 totalDebt = loanAmount + feeAmount;
        weth.safeTransfer(address(BALANCER_VAULT), totalDebt);
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(cz), "Only CZ");
        require(initiator == address(this), "Bad initiator");
        require(token == address(cz), "Wrong token");

        (
            uint256 loanAmount,
            uint256 balancerFee,
            uint256 minUsdcOut,
            uint256 deadline
        ) = abi.decode(data, (uint256, uint256, uint256, uint256));
        require(block.timestamp <= deadline, "Deadline");

        uint256 totalBalancerDebt = loanAmount + balancerFee;
        uint256 totalCzDebt = amount + fee;

        uint256 tempCz = amount / 10;
        if (tempCz == 0) tempCz = amount;

        cz.approve(address(amm), amount);
        weth.forceApprove(address(amm), loanAmount);
        amm.addLiquidity(tempCz, loanAmount, true);

        uint256 czForSwap = amount - tempCz;
        if (czForSwap == 0) czForSwap = amount;

        (, uint256 wethBought) = amm.swap(czForSwap, 0);
        require(wethBought > 0, "AMM swap failed");

        uint256 wethToSell = wethBought / 2;
        if (wethToSell > 0) {
            weth.forceApprove(address(UNI_ROUTER), wethToSell);
            UNI_ROUTER.exactInputSingle(
                IUniswapV3Router.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: address(usdc),
                    fee: 500,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: wethToSell,
                    amountOutMinimum: minUsdcOut,
                    sqrtPriceLimitX96: 0
                })
            );
            weth.forceApprove(address(UNI_ROUTER), 0);
        }

        amm.removeMyTemporaryLiquidity();
        cz.approve(address(cz), totalCzDebt);

        uint256 bal = weth.balanceOf(address(this));
        require(bal >= totalBalancerDebt + minProfit, "Not profitable");

        uint256 profit = bal - totalBalancerDebt;
        if (profit > 0) {
            weth.safeTransfer(owner(), profit);
        }

        emit CycleSuccess(amount, profit);
        return CALLBACK_SUCCESS;
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(owner(), bal);
    }

    receive() external payable {}
}