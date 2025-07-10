// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import {FunctionsOracle} from "../../src/factory/FunctionsOracle.sol";

contract PokeOracle is Script, FunctionsOracle {
    function run() external {
        address oracleProxy = vm.envAddress("SEPOLIA_FUNCTIONS_ORACLE_PROXY_ADDRESS"); // the FunctionsOracle proxy
        address bondToken = vm.envAddress("SEPOLIA_BOND_ADDRESS"); // ERC-20 of the bond
        address riskAsset = vm.envAddress("SEPOLIA_RISK_ASSET_TOKEN_ADDRESS"); // ERC-20 of the risky asset
        uint256 pk = vm.envUint("PRIVATE_KEY"); // oracle-owner key

        uint8[] memory assetType = new uint8[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory mktShare = new uint256[](2);

        assetType[0] = 0; // bond
        assetType[1] = 1; // risk asset

        tokens[0] = bondToken;
        tokens[1] = riskAsset;

        mktShare[0] = 80e18; // 80 %
        mktShare[1] = 20e18; // 20 %

        // bytes32 dummyRequestId = bytes32(uint256(1)); // any non-zero value is fine
        // bytes memory response = abi.encode(assetType, tokens, mktShare);
        // bytes memory emptyErr = "";

        vm.startBroadcast(pk);
        FunctionsOracle(oracleProxy).mockFulFill(assetType, tokens, mktShare);
        vm.stopBroadcast();
    }
}
