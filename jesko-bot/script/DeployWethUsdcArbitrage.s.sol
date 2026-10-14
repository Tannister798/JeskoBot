// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/WethUsdcArbitrage.sol";

contract DeployWethUsdcArbitrage is Script {
    function run() external {
        require(block.chainid == 42161, "Arbitrum One only");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        WethUsdcArbitrage executor = new WethUsdcArbitrage(
            vm.envAddress("WETH"),
            vm.envAddress("USDC"),
            vm.envAddress("AAVE_POOL"),
            vm.envAddress("BALANCER_VAULT"),
            vm.envAddress("UNISWAP_V3_ROUTER"),
            vm.envAddress("SUSHI_V2_ROUTER")
        );

        console.log("WethUsdcArbitrage deployed at:", address(executor));
        console.log("Owner:", executor.owner());
        vm.stopBroadcast();
    }
}
