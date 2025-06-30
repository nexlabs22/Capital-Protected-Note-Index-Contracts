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
    string private prefix;

    function A(string memory k) internal view returns (address) {
        return vm.envAddress(string.concat(prefix, k));
    }

    function U(string memory k) internal view returns (uint256) {
        return vm.envUint(string.concat(prefix, k));
    }

    function B(string memory k) internal view returns (bytes32) {
        return vm.envBytes32(string.concat(prefix, k));
    }

    function S(string memory k) internal view returns (string memory) {
        return vm.envString(string.concat(prefix, k));
    }

    function run() external {
        string memory net = vm.envString("TARGET_CHAIN"); // "sepolia" | "arbitrum_mainnet"
        prefix = keccak256(bytes(net)) == keccak256("sepolia") ? "SEPOLIA_" : "ARBITRUM_";

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);

        address storageProxy = Upgrades.deployTransparentProxy(
            "IndexFactoryStorage.sol",
            owner,
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(0),
                    address(0),
                    address(0),
                    address(0),
                    address(0),
                    A("NEX_BOT_ADDRESS"),
                    A("RISK_ASSET_ADDRESS"),
                    A("USDC_ADDRESS"),
                    A("BOND_ADDRESS"),
                    address(0),
                    address(0)
                )
            )
        );
        IndexFactoryStorage ifs = IndexFactoryStorage(storageProxy);

        address vaultProxy =
            Upgrades.deployTransparentProxy("Vault.sol", owner, abi.encodeCall(Vault.initialize, (owner)));

        address feeVaultProxy =
            Upgrades.deployTransparentProxy("FeeVault.sol", owner, abi.encodeCall(FeeVault.initialize, (storageProxy)));

        address functionsOracleProxy = Upgrades.deployTransparentProxy(
            "FunctionsOracle.sol",
            owner,
            abi.encodeCall(FunctionsOracle.initialize, (A("FUNCTIONS_ROUTER_ADDRESS"), B("NEW_DON_ID")))
        );

        address indexTokenProxy = Upgrades.deployTransparentProxy(
            "IndexToken.sol",
            owner,
            abi.encodeCall(
                IndexToken.initialize,
                (
                    S("TOKEN_NAME"),
                    S("TOKEN_SYMBOL"),
                    U("FEE_RATE_PER_DAY_SCALED"),
                    A("FEE_RECEIVER"),
                    U("SUPPLY_CEILING")
                )
            )
        );

        address indexFactoryProxy = Upgrades.deployTransparentProxy(
            "IndexFactory.sol", owner, abi.encodeCall(IndexFactory.initialize, (storageProxy, feeVaultProxy))
        );

        address scaProxy = Upgrades.deployTransparentProxy(
            "StagingCustodyAccount.sol", owner, abi.encodeCall(StagingCustodyAccount.initialize, (storageProxy))
        );

        // address balancerProxy = Upgrades.deployTransparentProxy(
        //     "IndexFactoryBalancer.sol",
        //     owner,
        //     abi.encodeCall(IndexFactoryBalancer.initialize, (storageProxy, functionsOracleProxy))
        // );

        ifs.setIndexToken(indexTokenProxy);
        ifs.setVault(vaultProxy);
        ifs.setFeeVault(feeVaultProxy);
        ifs.setFunctionsOracle(functionsOracleProxy);
        ifs.setIndexFactory(indexFactoryProxy);
        ifs.setSCA(scaProxy);
        // ifs.setIndexFactoryBalancer(balancerProxy);

        vm.stopBroadcast();

        console.log("\n=== Deployment (%s) ===", net);
        console.log("IndexFactoryStorage  ..... ", storageProxy);
        console.log("Vault .................... ", vaultProxy);
        console.log("FeeVault ..................", feeVaultProxy);
        console.log("FunctionsOracle ...........", functionsOracleProxy);
        console.log("IndexToken ................", indexTokenProxy);
        console.log("IndexFactory ..............", indexFactoryProxy);
        console.log("StagingCustodyAccount .....", scaProxy);
        console.log("===========================================\n");
    }
}
