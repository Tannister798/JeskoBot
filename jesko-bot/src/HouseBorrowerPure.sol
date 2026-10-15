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
 * @notice Test version — CZ flash mint + PrivateAMM only.
 *         No Aave/Balancer. Requires fundWeth() first.
 *         Does NOT include an external DEX leg (wiring test only).
 */
contract HouseBorrowerPure is Ownable, ReentrancyGuard, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    CZToken public immutable cz;
    PrivateAMM public immutable amm;
    IERC20 public immutable weth;

    uint256 public minProfit = 0.00001 ether;
    /// @notice WETH used as temporary AMM depth each cycle (must be pre-funded)
    uint256 public tempWethAmount = 0.0005 ether;
    bool public paused;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    event CycleStarted(uint256 mintAmount);
    event CycleSuccess(uint256 mintAmount, uint256 profit);
    event Paused(bool isPaused);

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(address _cz, address _amm, address _weth) Ownable(msg.sender) {
        require(_cz != address(0) && _amm != address(0) && _weth != address(0), "Zero");
        cz = CZToken(_cz);
        amm = PrivateAMM(_amm);
        weth = IERC20(_weth);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function setMinProfit(uint256 _min) external onlyOwner {
        minProfit = _min;
    }

    function setTempWethAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Zero temp");
        tempWethAmount = _amount;
    }

    /// @notice Pull WETH from owner into this contract for temp liquidity / buffer
    function fundWeth(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero");
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

        // Snapshot so we never drain the owner's funded buffer as "profit"
        uint256 startWeth = weth.balanceOf(address(this));
        uint256 tempWeth = tempWethAmount;
        require(startWeth >= tempWeth, "Need WETH - call fundWeth first");

        // Two-sided temporary liquidity: small CZ side + temp WETH
        uint256 tempCz = amount / 10;
        if (tempCz == 0) tempCz = amount;
        if (tempCz > amount) tempCz = amount;

        cz.forceApprove(address(amm), amount);
        weth.forceApprove(address(amm), tempWeth);
        amm.addLiquidity(tempCz, tempWeth, true);

        // Swap remaining CZ for WETH on skewed AMM
        uint256 czForSwap = amount - tempCz;
        if (czForSwap == 0) {
            // If mint was tiny, swap full amount instead of failing
            // (temp CZ still sits in pool until remove)
            czForSwap = amount;
        }

        (, uint256 wethBought) = amm.swap(czForSwap, 0);
        require(wethBought > 0, "Swap failed");

        // Pull back temporary liquidity
        amm.removeMyTemporaryLiquidity();

        // Repay CZ flash mint
        cz.forceApprove(address(cz), totalCzDebt);

        // Only profit above the starting buffer counts
        uint256 remaining = weth.balanceOf(address(this));
        require(remaining >= startWeth + minProfit, "Not enough profit");

        uint256 profit = remaining - startWeth;
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