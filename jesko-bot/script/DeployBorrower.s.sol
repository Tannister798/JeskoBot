// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HouseBorrower.sol";

contract DeployBorrower is Script {
    function run() external {
        require(block.chainid == 42161, "Arbitrum One only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        HouseBorrower borrower = new HouseBorrower(
            vm.envAddress("CZ_TOKEN"),
            vm.envAddress("PRIVATE_AMM"),
            vm.envAddress("WETH"),
            vm.envAddress("AAVE_POOL"),
            vm.envAddress("UNISWAP_V3_ROUTER"),
            uint24(vm.envUint("UNISWAP_V3_FEE"))
        );

        console.log("New HouseBorrower deployed at:", address(borrower));

        vm.stopBroadcast();
    }
}
