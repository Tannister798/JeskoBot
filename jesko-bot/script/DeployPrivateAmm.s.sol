// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/PriceFeed.sol";
import "../src/SkewKeeper.sol";
import "../src/HouseBorrowerBalancer.sol";

contract DeployPrivateAmm is Script {
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        CZToken cz = new CZToken();
        MockPriceFeed feed = new MockPriceFeed();
        PrivateAMM amm = new PrivateAMM(address(cz), WETH);
        SkewKeeper keeper = new SkewKeeper(address(amm), address(feed));
        HouseBorrowerBalancer borrower = new HouseBorrowerBalancer(
            address(cz),
            address(amm),
            WETH,
            USDC
        );

        console.log("CZ_TOKEN", address(cz));
        console.log("PRICE_FEED", address(feed));
        console.log("PRIVATE_AMM", address(amm));
        console.log("SKEW_KEEPER", address(keeper));
        console.log("HOUSE_BORROWER", address(borrower));

        vm.stopBroadcast();
    }
}