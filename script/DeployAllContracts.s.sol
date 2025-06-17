// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Vault} from "../src/vault/Vault.sol";
import {FeeVault} from "../src/vault/FeeVault.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import {IndexToken} from "../src/token/IndexToken.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {IndexFactoryBalancer} from "../src/factory/IndexFactoryBalancer.sol";

contract DeployAllContracts is Script {
    string private prefix; // "SEPOLIA_" or "ARBITRUM_"

    function a(string memory key) internal view returns (address) {
        return vm.envAddress(string.concat(prefix, key));
    }

    function u(string memory key) internal view returns (uint256) {
        return vm.envUint(string.concat(prefix, key));
    }

    function b32(string memory key) internal view returns (bytes32) {
        return vm.envBytes32(string.concat(prefix, key));
    }

    function s(string memory key) internal view returns (string memory) {
        return vm.envString(string.concat(prefix, key));
    }

    function run() external {
        string memory net = vm.envString("TARGET_CHAIN"); // "sepolia" | "arbitrum_mainnet"
        prefix = keccak256(bytes(net)) == keccak256("sepolia") ? "SEPOLIA_" : "ARBITRUM_";

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);

        address vaultProxy =
            Upgrades.deployTransparentProxy("Vault.sol", owner, abi.encodeCall(Vault.initialize, (address(0))));

        address functionsOracleProxy = Upgrades.deployTransparentProxy(
            "FunctionsOracle.sol",
            owner,
            abi.encodeCall(FunctionsOracle.initialize, (a("FUNCTIONS_ROUTER_ADDRESS"), b32("NEW_DON_ID")))
        );

        address indexTokenProxy = Upgrades.deployTransparentProxy(
            "IndexToken.sol",
            owner,
            abi.encodeCall(
                IndexToken.initialize,
                (
                    s("TOKEN_NAME"),
                    s("TOKEN_SYMBOL"),
                    u("FEE_RATE_PER_DAY_SCALED"),
                    a("FEE_RECEIVER"),
                    u("SUPPLY_CEILING")
                )
            )
        );

        address storageProxy = Upgrades.deployTransparentProxy("IndexFactoryStorage.sol", owner, bytes(""));

        address feeVaultProxy =
            Upgrades.deployTransparentProxy("FeeVault.sol", owner, abi.encodeCall(FeeVault.initialize, (storageProxy)));

        address indexFactoryProxy = Upgrades.deployTransparentProxy(
            "IndexFactory.sol", owner, abi.encodeCall(IndexFactory.initialize, (storageProxy, feeVaultProxy))
        );

        address scaProxy = Upgrades.deployTransparentProxy(
            "StagingCustodyAccount.sol", owner, abi.encodeCall(StagingCustodyAccount.initialize, (storageProxy))
        );

        address balancerProxy = Upgrades.deployTransparentProxy(
            "IndexFactoryBalancer.sol",
            owner,
            abi.encodeCall(IndexFactoryBalancer.initialize, (storageProxy, functionsOracleProxy))
        );

        IndexFactoryStorage(storageProxy).initialize(
            indexTokenProxy,
            indexFactoryProxy,
            functionsOracleProxy,
            scaProxy,
            vaultProxy,
            a("NEX_BOT_ADDRESS"),
            a("RISK_ASSET_ADDRESS"),
            a("USDC_ADDRESS"),
            a("BOND_ADDRESS"),
            feeVaultProxy,
            balancerProxy
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment (%s) ===", net);
        console.log("Vault.....................", vaultProxy);
        console.log("FunctionsOracle...........", functionsOracleProxy);
        console.log("IndexToken................", indexTokenProxy);
        console.log("FeeVault..................", feeVaultProxy);
        console.log("IndexFactory..............", indexFactoryProxy);
        console.log("StagingCustodyAccount.....", scaProxy);
        console.log("IndexFactoryBalancer......", balancerProxy);
        console.log("IndexFactoryStorage.......", storageProxy);
        console.log("===========================");
    }
}
