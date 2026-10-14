// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/HouseBorrower.sol";
import "../src/SkewKeeper.sol";
import "../src/PriceFeed.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CZ Token
        CZToken cz = new CZToken();
        console.log("CZToken deployed at:", address(cz));

        // 2. Deploy Mock Price Feed
        MockPriceFeed priceFeed = new MockPriceFeed(1e18);
        console.log("MockPriceFeed deployed at:", address(priceFeed));

        // 3. Deploy PrivateAMM
        address WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73; // replace later with real WETH
        PrivateAMM amm = new PrivateAMM(address(cz), WETH);
        console.log("PrivateAMM deployed at:", address(amm));

        // 4. Deploy SkewKeeper (needs amm + priceFeed)
        SkewKeeper keeper = new SkewKeeper(address(amm), address(priceFeed));
        console.log("SkewKeeper deployed at:", address(keeper));

        // 5. Deploy HouseBorrower (4 arguments)
        address AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

        HouseBorrower borrower = new HouseBorrower(
            address(cz),
            address(amm),
            WETH,
            AAVE_POOL
        );
        console.log("HouseBorrower deployed at:", address(borrower));

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("CZ_TOKEN=", address(cz));
        console.log("PRICE_FEED=", address(priceFeed));
        console.log("PRIVATE_AMM=", address(amm));
        console.log("SKEW_KEEPER=", address(keeper));
        console.log("HOUSE_BORROWER=", address(borrower));
    }
}