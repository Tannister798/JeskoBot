// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/HouseBorrower.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IAaveFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

contract MockAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        require(IERC20(asset).transfer(receiverAddress, amount), "Transfer failed");
        require(
            IAaveFlashLoanReceiver(receiverAddress).executeOperation(
                asset,
                amount,
                0,
                msg.sender,
                params
            ),
            "Callback failed"
        );
        require(
            IERC20(asset).transferFrom(receiverAddress, address(this), amount),
            "Repayment failed"
        );
    }
}

contract MockUniswapV3Router {
    IERC20 public immutable weth;
    IERC20 public immutable cz;

    constructor(address _weth, address _cz) {
        weth = IERC20(_weth);
        cz = IERC20(_cz);
    }

    function exactOutputSingle(IUniswapV3SwapRouter.ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn)
    {
        require(params.fee == 10_000, "Wrong fee tier");
        amountIn = (params.amountOut * 5) / 10_000;
        require(amountIn <= params.amountInMaximum, "Too much input");
        require(weth.transferFrom(msg.sender, address(this), amountIn), "WETH transfer failed");
        require(cz.transfer(params.recipient, params.amountOut), "CZ transfer failed");
    }
}

contract HouseBorrowerTest is Test {
    CZToken cz;
    PrivateAMM amm;
    MockWETH weth;
    MockAavePool aavePool;
    MockUniswapV3Router swapRouter;
    HouseBorrower borrower;

    function setUp() public {
        cz = new CZToken();
        weth = new MockWETH();
        aavePool = new MockAavePool();
        swapRouter = new MockUniswapV3Router(address(weth), address(cz));
        amm = new PrivateAMM(address(cz), address(weth));
        borrower = new HouseBorrower(
            address(cz),
            address(amm),
            address(weth),
            address(aavePool),
            address(swapRouter),
            10_000
        );

        cz.approve(address(amm), type(uint256).max);
        amm.addLiquidity(900_000 ether, 0);
        assertTrue(cz.transfer(address(swapRouter), 100_000 ether));
        weth.mint(address(this), 1_000 ether);
        weth.approve(address(amm), type(uint256).max);
        amm.addLiquidity(0, 1_000 ether);
        weth.mint(address(aavePool), 1_000 ether);
    }

    function test_CZTokenFlashMintable() public {
        assertEq(cz.name(), "CZ Token");
        assertEq(cz.symbol(), "CZ");
    }

    function test_PrivateAMMReservesStartAtZero() public {
        // Deploy with dummy addresses for unit test
        PrivateAMM testAmm = new PrivateAMM(address(cz), address(0x1));
        (uint256 r0, uint256 r1) = testAmm.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function test_ProfitableCycleBuysBackCZAndPreservesExistingWeth() public {
        uint256 startingBalance = 5 ether;
        weth.mint(address(borrower), startingBalance);

        borrower.executeCycle(10_000 ether, 1 ether, block.timestamp + 600, 6 ether);

        assertEq(weth.balanceOf(address(borrower)), startingBalance);
        assertEq(weth.balanceOf(address(aavePool)), 1_000 ether);
        assertEq(cz.balanceOf(address(borrower)), 0);
        assertGt(weth.balanceOf(address(this)), 0);
    }

    function test_PreexistingWethCannotMaskUnprofitableCycle() public {
        weth.mint(address(borrower), 5 ether);
        borrower.setMinProfit(15 ether);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Not enough profit"));
        borrower.executeCycle(10_000 ether, 1 ether, block.timestamp + 600, 6 ether);
    }

    function test_BuybackCannotExceedConfiguredWethLimit() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Too much input"));
        borrower.executeCycle(10_000 ether, 1 ether, block.timestamp + 600, 4 ether);
    }
}