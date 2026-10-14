// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HouseBorrowerPure.sol";

contract DeployPure is Script {
    function run() external {
        require(block.chainid == 421614, "Arbitrum Sepolia only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        HouseBorrowerPure borrower = new HouseBorrowerPure(
            0x680a232ba25ee598f8D4555Aa5c9c1ac80Ca9292,
            0x6560A8a8E77bed8D72566dCe993f465db27Eb104,
            0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
        );

        console.log("HouseBorrowerPure deployed at:", address(borrower));
        vm.stopBroadcast();
    }
}
