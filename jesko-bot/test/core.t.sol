// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/PriceFeed.sol";
import "../src/SkewKeeper.sol";

contract CoreTest is Test {
    CZToken cz;
    PrivateAMM amm;
    MockPriceFeed feed;
    SkewKeeper keeper;

    function setUp() public {
        cz = new CZToken();
        feed = new MockPriceFeed(1e18);
        amm = new PrivateAMM(address(cz), address(0xBEEF)); // dummy WETH
        keeper = new SkewKeeper(address(amm), address(feed));
    }

    function test_CZTokenDeploys() public {
        assertEq(cz.symbol(), "CZ");
    }

    function test_PriceFeedWorks() public {
        assertEq(feed.getPrice(), 1e18);
        feed.setPrice(1.02e18);
        assertEq(feed.getPrice(), 1.02e18);
    }

    function test_SkewKeeperRange() public {
        assertEq(keeper.minSkewBps(), 100);
        assertEq(keeper.maxSkewBps(), 200);
    }
}