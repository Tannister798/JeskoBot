// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/CZToken.sol";
import "../src/PrivateAMM.sol";
import "../src/HouseBorrower.sol";
import "../src/SkewKeeper.sol";
import "../src/PriceFeed.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // --- Tokens / infra from env (set in .env) ---
        address WETH = vm.envAddress("WETH");
        address USDC = vm.envAddress("USDC");
        address AAVE_POOL = vm.envAddress("AAVE_POOL");
        address SWAP_ROUTER = vm.envAddress("UNISWAP_V3_ROUTER");
        uint24 SWAP_FEE = uint24(vm.envUint("UNISWAP_V3_FEE"));

        // 1. CZ
        CZToken cz = new CZToken();
        console.log("CZToken deployed at:", address(cz));

        // 2. Price feed (no constructor arg — use setPrice after if needed)
        MockPriceFeed priceFeed = new MockPriceFeed();
        console.log("MockPriceFeed deployed at:", address(priceFeed));

        // 3. PrivateAMM (CZ / WETH)
        PrivateAMM amm = new PrivateAMM(address(cz), WETH);
        console.log("PrivateAMM deployed at:", address(amm));

        // 4. SkewKeeper
        SkewKeeper keeper = new SkewKeeper(address(amm), address(priceFeed));
        console.log("SkewKeeper deployed at:", address(keeper));

        // 5. HouseBorrower Path B:
        //    (cz, amm, weth, usdc, aavePool, swapRouter, swapFee)
        HouseBorrower borrower = new HouseBorrower(
            address(cz),
            address(amm),
            WETH,
            USDC,
            AAVE_POOL,
            SWAP_ROUTER,
            SWAP_FEE
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