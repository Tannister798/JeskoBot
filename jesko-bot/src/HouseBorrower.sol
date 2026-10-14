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

contract HouseBorrower is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;
    IPool public immutable aavePool;

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
        address _aavePool
    ) Ownable(msg.sender) {
        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
        aavePool = IPool(_aavePool);

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
        uint256 deadline
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline passed");
        require(mintAmount > 0 && mintAmount <= maxTradeSize, "Invalid mint size");
        require(loanAmount > 0, "Invalid loan size");

        emit CycleStarted(mintAmount, loanAmount);

        bytes memory params = abi.encode(mintAmount, deadline);

        aavePool.flashLoanSimple(
            address(this),
            address(weth),
            loanAmount,
            params,
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

        (uint256 mintAmount, uint256 deadline) = abi.decode(params, (uint256, uint256));
        require(block.timestamp <= deadline, "Deadline");

        bytes memory czData = abi.encode(amount, premium, deadline);

        cz.flashLoan(this, address(cz), mintAmount, czData);

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

        (uint256 aaveAmount, uint256 aavePremium, uint256 deadline) =
            abi.decode(data, (uint256, uint256, uint256));
        require(block.timestamp <= deadline, "Deadline expired");

        uint256 totalAaveDebt = aaveAmount + aavePremium;
        uint256 totalCzDebt = amount + fee;

        // 1. Add temporary liquidity
        weth.approve(address(amm), aaveAmount);
        amm.addLiquidity(0, aaveAmount);

        // 2. Swap CZ → WETH on skewed AMM
        cz.approve(address(amm), amount);
        (, uint256 wethBought) = amm.swap(amount, 0);
        require(wethBought > 0, "Swap failed");

        // 3. Remove temporary liquidity
        amm.removeMyTemporaryLiquidity();

        // 4. Repay CZ
        cz.approve(address(cz), totalCzDebt);

        // 5. Repay Aave
        weth.approve(address(aavePool), totalAaveDebt);

        // 6. Profit check
        uint256 remainingWeth = weth.balanceOf(address(this));
        require(remainingWeth >= totalAaveDebt + minProfit, "Not enough profit");

        uint256 profit = remainingWeth - totalAaveDebt;
        weth.safeTransfer(owner(), profit);

        emit CycleSuccess(amount, profit);

        return CALLBACK_SUCCESS;
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(owner(), bal);
        }
    }

    receive() external payable {}
}