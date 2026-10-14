// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HouseBorrower.sol";

contract DeployBorrower is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        HouseBorrower borrower = new HouseBorrower(
            0x680a232ba25ee598f8D4555Aa5c9c1ac80Ca9292,
            0x6560A8a8E77bed8D72566dCe993f465db27Eb104,
            0x980B62Da83eFf3D4576C647993b0c1D7faf17c73,
            0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff
        );

        console.log("New HouseBorrower deployed at:", address(borrower));

        vm.stopBroadcast();
    }
}
