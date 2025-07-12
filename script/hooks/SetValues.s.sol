// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

contract SetValue is Script {
    function run() external {
        // set sca as minter in IndexToken
        // set sca as operator in FunctionsOracle
        // set sca as operator in Vault
        // set sca as operator the index factory in FunctionsOracle
        // set balancer as operator in vault
        // set balancer as operator in FunctionsOracle
        // set index factory balancer in FunctionsOracle
    }
}
