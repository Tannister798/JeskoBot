// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

import "./CZToken.sol";
import "./PrivateAMM.sol";

/**
 * @title HouseBorrowerPure
 * @notice Test version - only CZ flash mint + PrivateAMM.
 *         No external flash loan (Aave / Balancer).
 */
contract HouseBorrowerPure is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;

    uint256 public minProfit = 0.00001 ether;
    bool public paused;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    event CycleStarted(uint256 mintAmount);
    event CycleSuccess(uint256 mintAmount, uint256 profit);

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(address _cz, address _amm, address _weth) Ownable(msg.sender) {
        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setMinProfit(uint256 _min) external onlyOwner {
        minProfit = _min;
    }

    function fundWeth(uint256 amount) external onlyOwner {
        weth.safeTransferFrom(msg.sender, address(this), amount);
    }

    function executeCycle(
        uint256 mintAmount,
        uint256 /* loanAmount ignored */,
        uint256 deadline
    ) external onlyOwner nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline passed");
        require(mintAmount > 0, "Zero mint");

        emit CycleStarted(mintAmount);

        bytes memory data = abi.encode(deadline);
        cz.flashLoan(this, address(cz), mintAmount, data);
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

        uint256 deadline = abi.decode(data, (uint256));
        require(block.timestamp <= deadline, "Deadline expired");

        uint256 totalCzDebt = amount + fee;

        uint256 tempWeth = 0.0005 ether;
        require(weth.balanceOf(address(this)) >= tempWeth, "Need WETH in contract - call fundWeth first");

        weth.approve(address(amm), tempWeth);
        amm.addLiquidity(0, tempWeth);

        cz.approve(address(amm), amount);
        (, uint256 wethBought) = amm.swap(amount, 0);
        require(wethBought > 0, "Swap failed");

        amm.removeMyTemporaryLiquidity();

        cz.approve(address(cz), totalCzDebt);

        uint256 remaining = weth.balanceOf(address(this));
        require(remaining >= minProfit, "Not enough profit");

        weth.safeTransfer(owner(), remaining);

        emit CycleSuccess(amount, remaining);
        return CALLBACK_SUCCESS;
    }

    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(owner(), bal);
    }

    receive() external payable {}
}
