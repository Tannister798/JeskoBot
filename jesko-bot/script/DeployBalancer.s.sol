// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HouseBorrowerBalancer.sol";

contract DeployBalancer is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        HouseBorrowerBalancer borrower = new HouseBorrowerBalancer(
            0x680a232ba25ee598f8D4555Aa5c9c1ac80Ca9292,
            0x6560A8a8E77bed8D72566dCe993f465db27Eb104,
            0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
        );

        console.log("HouseBorrowerBalancer deployed at:", address(borrower));
        vm.stopBroadcast();
    }
}
