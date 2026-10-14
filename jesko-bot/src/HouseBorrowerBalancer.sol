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

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

contract HouseBorrowerBalancer is Ownable, ReentrancyGuard, IERC3156FlashBorrower, IFlashLoanRecipient {
    using SafeERC20 for IERC20;

    IBalancerVault public constant BALANCER_VAULT =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;

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

    constructor(address _cz, address _amm, address _weth) Ownable(msg.sender) {
        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
        minProfit = 0.01 ether;
        maxTradeSize = 250_000 ether;
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
        uint256 deadline
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline passed");
        require(mintAmount > 0 && mintAmount <= maxTradeSize, "Invalid mint size");
        require(loanAmount > 0, "Invalid loan size");

        emit CycleStarted(mintAmount, loanAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanAmount;

        bytes memory userData = abi.encode(mintAmount, deadline);

        BALANCER_VAULT.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(BALANCER_VAULT), "Only Balancer");
        require(tokens.length == 1 && tokens[0] == address(weth), "Wrong token");

        uint256 loanAmount = amounts[0];
        uint256 feeAmount = feeAmounts[0];

        (uint256 mintAmount, uint256 deadline) = abi.decode(userData, (uint256, uint256));
        require(block.timestamp <= deadline, "Deadline");

        bytes memory czData = abi.encode(loanAmount, feeAmount, deadline);
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
        require(msg.sender == address(cz), "Only CZToken");
        require(initiator == address(this), "Invalid initiator");
        require(token == address(cz), "Wrong token");

        (uint256 loanAmount, uint256 balancerFee, uint256 deadline) =
            abi.decode(data, (uint256, uint256, uint256));
        require(block.timestamp <= deadline, "Deadline expired");

        uint256 totalBalancerDebt = loanAmount + balancerFee;
        uint256 totalCzDebt = amount + fee;

        weth.approve(address(amm), loanAmount);
        amm.addLiquidity(0, loanAmount);

        cz.approve(address(amm), amount);
        (, uint256 wethBought) = amm.swap(amount, 0);
        require(wethBought > 0, "Swap failed");

        amm.removeMyTemporaryLiquidity();

        cz.approve(address(cz), totalCzDebt);

        uint256 remainingWeth = weth.balanceOf(address(this));
        require(remainingWeth >= totalBalancerDebt + minProfit, "Not enough profit");

        uint256 profit = remainingWeth - totalBalancerDebt;
        weth.safeTransfer(owner(), profit);

        emit CycleSuccess(amount, profit);

        return CALLBACK_SUCCESS;
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(owner(), bal);
    }

    receive() external payable {}
}
