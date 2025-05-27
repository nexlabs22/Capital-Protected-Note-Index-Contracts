// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/vault/FeeVault.sol";

contract DeployFeeVault is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address owner = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address proxy =
            Upgrades.deployTransparentProxy("FeeVault.sol", owner, abi.encodeCall(FeeVault.initialize, (address(0))));

        FeeVault nexVaultImplementation = FeeVault(proxy);

        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        console.log("FeeVault implementation deployed at:", address(nexVaultImplementation));
        console.log("FeeVault proxy deployed at:", address(proxy));
        console.log("ProxyAdmin for NexVault deployed at:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
