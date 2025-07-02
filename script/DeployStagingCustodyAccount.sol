// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";

contract DeployStagingCustodyAccount is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory targetChain = "sepolia";
        // string memory targetChain = "arbitrum_mainnet";

        address indexFactoryStorageProxy;
        // address indexFactoryStorageProxy = 0xfff04455959AFf67d30E5F5c9C2010BfAE5dFd76;

        address owner = vm.addr(deployerPrivateKey);

        if (keccak256(bytes(targetChain)) == keccak256("sepolia")) {
            indexFactoryStorageProxy = vm.envAddress("SEPOLIA_INDEX_FACTORY_STORAGE_PROXY_ADDRESS");
        } else if (keccak256(bytes(targetChain)) == keccak256("arbitrum_mainnet")) {
            indexFactoryStorageProxy = vm.envAddress("ARBITRUM_INDEX_FACTORY_STORAGE_PROXY_ADDRESS");
        } else {
            revert("Unsupported target chain");
        }
        vm.startBroadcast(deployerPrivateKey);

        address proxy = Upgrades.deployTransparentProxy(
            "StagingCustodyAccount.sol",
            owner,
            abi.encodeCall(StagingCustodyAccount.initialize, (indexFactoryStorageProxy))
        );

        StagingCustodyAccount stagingCustodyAccountImplementation = StagingCustodyAccount(proxy);

        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        console.log("StagingCustodyAccount implementation deployed at:", address(stagingCustodyAccountImplementation));
        console.log("StagingCustodyAccount proxy deployed at:", address(proxy));
        console.log("ProxyAdmin for StagingCustodyAccount deployed at:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
