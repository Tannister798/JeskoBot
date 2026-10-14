// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/WethUsdcArbitrage.sol";

contract MockArbToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_)
        ERC20(name, symbol)
    {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IArbitrageReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

contract MockArbAavePool {
    IERC20 public immutable weth;

    constructor(address _weth) {
        weth = IERC20(_weth);
    }

    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        require(asset == address(weth), "wrong asset");
        require(weth.transfer(receiver, amount), "loan failed");
        require(
            IArbitrageReceiver(receiver).executeOperation(
                asset,
                amount,
                0,
                msg.sender,
                params
            ),
            "callback failed"
        );
        require(weth.transferFrom(receiver, address(this), amount), "repay failed");
    }
}

contract MockArbBalancerVault {
    IERC20 public immutable weth;

    constructor(address _weth) {
        weth = IERC20(_weth);
    }

    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        require(tokens.length == 1 && address(tokens[0]) == address(weth), "wrong asset");
        require(weth.transfer(recipient, amounts[0]), "loan failed");
        uint256[] memory fees = new uint256[](1);
        IArbitrageReceiver(recipient).receiveFlashLoan(tokens, amounts, fees, userData);
        require(
            weth.transferFrom(recipient, address(this), amounts[0]),
            "repay failed"
        );
    }
}

contract MockArbDexRouter {
    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    uint256 public immutable usdcPerWeth;

    constructor(address _weth, address _usdc, uint256 _usdcPerWeth) {
        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        usdcPerWeth = _usdcPerWeth;
    }

    function exactInputSingle(IUniswapV3Router.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = _swap(params.tokenIn, params.tokenOut, params.amountIn, params.recipient);
        require(amountOut >= params.amountOutMinimum, "slippage");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "bad path");
        uint256 amountOut = _swap(path[0], path[1], amountIn, to);
        require(amountOut >= amountOutMin, "slippage");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to)
        private
        returns (uint256 amountOut)
    {
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "input failed");
        if (tokenIn == address(weth) && tokenOut == address(usdc)) {
            amountOut = (amountIn * usdcPerWeth) / 1 ether;
        } else {
            require(tokenIn == address(usdc) && tokenOut == address(weth), "bad pair");
            amountOut = (amountIn * 1 ether) / usdcPerWeth;
        }
        require(IERC20(tokenOut).transfer(to, amountOut), "output failed");
    }
}

contract WethUsdcArbitrageTest is Test {
    MockArbToken weth;
    MockArbToken usdc;
    MockArbAavePool aave;
    MockArbBalancerVault balancer;
    MockArbDexRouter buyRouter;
    MockArbDexRouter sellRouter;
    WethUsdcArbitrage executor;

    function setUp() public {
        weth = new MockArbToken("Wrapped Ether", "WETH", 18);
        usdc = new MockArbToken("USD Coin", "USDC", 6);
        aave = new MockArbAavePool(address(weth));
        balancer = new MockArbBalancerVault(address(weth));
        buyRouter = new MockArbDexRouter(address(weth), address(usdc), 2_100_000);
        sellRouter = new MockArbDexRouter(address(weth), address(usdc), 2_000_000);
        executor = new WethUsdcArbitrage(
            address(weth),
            address(usdc),
            address(aave),
            address(balancer),
            address(buyRouter),
            address(sellRouter)
        );

        weth.mint(address(aave), 100 ether);
        weth.mint(address(balancer), 100 ether);
        weth.mint(address(sellRouter), 100 ether);
        usdc.mint(address(buyRouter), 1_000_000_000);
    }

    function testAaveCrossVenueCycleRepaysAndPaysProfit() public {
        uint256 startingBalance = 3 ether;
        weth.mint(address(executor), startingBalance);

        executor.executeCycle(
            executor.AAVE(),
            1 ether,
            executor.UNISWAP_V3(),
            executor.SUSHI_V2(),
            500,
            0,
            2_100_000,
            1.05 ether,
            0.01 ether,
            block.timestamp + 60
        );

        assertEq(weth.balanceOf(address(aave)), 100 ether);
        assertEq(weth.balanceOf(address(executor)), startingBalance);
        assertEq(weth.balanceOf(address(this)), 0.05 ether);
    }

    function testBalancerCanBeSelectedAsFlashLoanProvider() public {
        executor.executeCycle(
            executor.BALANCER(),
            1 ether,
            executor.UNISWAP_V3(),
            executor.SUSHI_V2(),
            500,
            0,
            2_100_000,
            1.05 ether,
            0.01 ether,
            block.timestamp + 60
        );

        assertEq(weth.balanceOf(address(balancer)), 100 ether);
        assertEq(weth.balanceOf(address(this)), 0.05 ether);
    }

    function testExistingWethCannotCoverUnprofitableRoute() public {
        weth.mint(address(executor), 5 ether);
        sellRouter = new MockArbDexRouter(address(weth), address(usdc), 2_200_000);
        weth.mint(address(sellRouter), 100 ether);
        executor = new WethUsdcArbitrage(
            address(weth),
            address(usdc),
            address(aave),
            address(balancer),
            address(buyRouter),
            address(sellRouter)
        );
        weth.mint(address(executor), 5 ether);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Not profitable"));
        executor.executeCycle(
            0,
            1 ether,
            0,
            1,
            500,
            0,
            2_100_000,
            950_000_000,
            0.01 ether,
            block.timestamp + 60
        );
    }

    function testRejectsSameVenueRoute() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Venues must differ"));
        executor.executeCycle(
            0,
            1 ether,
            0,
            0,
            500,
            500,
            2_100_000,
            1.05 ether,
            0.01 ether,
            block.timestamp + 60
        );
    }
}
