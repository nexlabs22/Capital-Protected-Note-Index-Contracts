// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/factory/IndexFactory.sol";

contract DeployIndexFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory targetChain = "sepolia";
        // string memory targetChain = "arbitrum_mainnet";

        address owner = vm.addr(deployerPrivateKey);

        if (keccak256(bytes(targetChain)) == keccak256("sepolia")) {} else if (
            keccak256(bytes(targetChain)) == keccak256("arbitrum_mainnet")
        ) {} else {
            revert("Unsupported target chain");
        }

        vm.startBroadcast(deployerPrivateKey);

        address proxy = Upgrades.deployTransparentProxy(
            "IndexFactory.sol", owner, abi.encodeCall(IndexFactory.initialize, (address(0), address(0)))
        );

        IndexFactory indexFactoryImplementation = IndexFactory(proxy);

        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        console.log("IndexFactory implementation deployed at:", address(indexFactoryImplementation));
        console.log("IndexFactory proxy deployed at:", address(proxy));
        console.log("ProxyAdmin for IndexFactory deployed at:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
