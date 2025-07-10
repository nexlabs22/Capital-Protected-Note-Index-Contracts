// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeStagingCustodyAccount is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        string memory targetChain = "sepolia";
        // string memory targetChain = "arbitrum_mainnet";

        address stagingCustodyAccountProxyAddress;

        address owner = vm.addr(deployerPrivateKey);

        if (keccak256(bytes(targetChain)) == keccak256("sepolia")) {
            stagingCustodyAccountProxyAddress = vm.envAddress("SEPOLIA_SCA_PROXY_ADDRESS");
        } else if (keccak256(bytes(targetChain)) == keccak256("arbitrum_mainnet")) {
            stagingCustodyAccountProxyAddress = vm.envAddress("ARBITRUM_SCA_PROXY_ADDRESS");
        } else {
            revert("Unsupported target chain");
        }

        Upgrades.upgradeProxy(stagingCustodyAccountProxyAddress, "StagingCustodyAccountV2.sol", "", owner);

        address implAddrV2 = Upgrades.getImplementationAddress(stagingCustodyAccountProxyAddress);

        console.log("StagingCustodyAccount proxy upgraded to new implementation at: ", address(implAddrV2));

        vm.stopBroadcast();
    }
}
