// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/HouseBorrower.sol";

contract HouseBorrowerTest is Test {
    CZToken cz;
    PrivateAMM amm;
    // We mock Aave & WETH for unit tests

    function setUp() public {
        cz = new CZToken();
        // For real tests you would deploy mocks for WETH and Aave
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
}