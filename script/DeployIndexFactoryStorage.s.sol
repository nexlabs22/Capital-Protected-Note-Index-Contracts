// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";

import "../src/factory/IndexFactoryStorage.sol";

contract DeployIndexFactoryStorage is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        string memory targetChain = "sepolia";

        address owner = vm.addr(deployerPrivateKey);

        address indexTokenProxy;
        address indexFactoryProxy;
        address functionsOracleProxy;
        address stagingCustodyAccount;
        address vaultProxy;
        address nexBot;
        address riskAssetFactoryAddress;
        address usdc;
        address bond;
        address feeVault;
        address indexFactoryBalancerProxy;

        if (keccak256(bytes(targetChain)) == keccak256("sepolia")) {
            indexTokenProxy = vm.envAddress("SEPOLIA_INDEX_TOKEN_PROXY_ADDRESS");
            indexFactoryProxy = vm.envAddress("SEPOLIA_INDEX_FACTORY_PROXY_ADDRESS");
            stagingCustodyAccount = vm.envAddress("SEPOLIA_SCA_PROXY_ADDRESS");
            functionsOracleProxy = vm.envAddress("SEPOLIA_FUNCTIONS_ORACLE_PROXY_ADDRESS");
            nexBot = vm.envAddress("SEPOLIA_NEX_BOT_ADDRESS");
            riskAssetFactoryAddress = vm.envAddress("SEPOLIA_RISK_ASSET_ADDRESS");
            vaultProxy = vm.envAddress("SEPOLIA_VAULT_PROXY_ADDRESS");
            usdc = vm.envAddress("SEPOLIA_USDC_ADDRESS");
            bond = vm.envAddress("SEPOLIA_BOND_ADDRESS");
            feeVault = vm.envAddress("SEPOLIA_FEE_VAULT_PROXY_ADDRESS");
            indexFactoryBalancerProxy = vm.envAddress("SEPOLIA_INDEX_FACTORY_BALANCER_PROXY_ADDRESS");
            // usdcDecimals = uint8(vm.envUint("SEPOLIA_USDC_DECIMALS"));
        } else if (keccak256(bytes(targetChain)) == keccak256("arbitrum_mainnet")) {
            indexTokenProxy = vm.envAddress("ARBITRUM_INDEX_TOKEN_PROXY_ADDRESS");
            indexFactoryProxy = vm.envAddress("ARBITRUM_INDEX_FACTORY_PROXY_ADDRESS");
            stagingCustodyAccount = vm.envAddress("ARBITRUM_SCA_PROXY_ADDRESS");
            functionsOracleProxy = vm.envAddress("ARBITRUM_FUNCTIONS_ORACLE_PROXY_ADDRESS");
            nexBot = vm.envAddress("ARBITRUM_NEX_BOT_ADDRESS");
            riskAssetFactoryAddress = vm.envAddress("ARBITRUM_RISK_ASSET_ADDRESS");
            vaultProxy = vm.envAddress("ARBITRUM_VAULT_PROXY_ADDRESS");
            usdc = vm.envAddress("ARBITRUM_USDC_ADDRESS");
            bond = vm.envAddress("ARBITRUM_BOND_ADDRESS");
            feeVault = vm.envAddress("ARBITRUM_FEE_VAULT_PROXY_ADDRESS");
            indexFactoryBalancerProxy = vm.envAddress("ARBITRUM_INDEX_FACTORY_BALANCER_PROXY_ADDRESS");
        } else {
            revert("Unsupported target chain");
        }

        vm.startBroadcast(deployerPrivateKey);

        address proxy = Upgrades.deployTransparentProxy(
            "IndexFactoryStorage.sol",
            owner,
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    indexTokenProxy,
                    indexFactoryProxy,
                    functionsOracleProxy,
                    stagingCustodyAccount,
                    vaultProxy,
                    nexBot,
                    riskAssetFactoryAddress,
                    usdc,
                    bond,
                    feeVault,
                    indexFactoryBalancerProxy
                )
            )
        );

        IndexFactoryStorage indexFactoryStorageImplementation = IndexFactoryStorage(proxy);
        address proxyAdmin = Upgrades.getAdminAddress(proxy);

        console.log("IndexFactoryStorage implementation deployed at:", address(indexFactoryStorageImplementation));
        console.log("IndexFactoryStorage proxy deployed at:", address(proxy));
        console.log("ProxyAdmin for IndexFactoryStorage deployed at:", address(proxyAdmin));

        vm.stopBroadcast();
    }
}
