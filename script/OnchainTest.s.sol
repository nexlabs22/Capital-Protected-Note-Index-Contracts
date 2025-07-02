// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

import {IndexFactory} from "../src/factory/IndexFactory.sol";
import "../src/token/IndexToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/IRiskAssetFactory.sol";
import "../src/SCA/StagingCustodyAccount.sol";

// import "../../contracts/factory/IndexFactoryProcessor.sol";
// import "../contracts/factory/IndexFactoryBalancer.sol";
// import "../contracts/factory/IndexFactoryStorage.sol";

contract OnchainTest is Script {
    IndexToken indexToken;

    // // Mainnet
    // address user = vm.envAddress("USER");
    // address weth = vm.envAddress("ARBITRUM_WETH_ADDRESS");
    // address usdc = vm.envAddress("ARBITRUM_USDC_ADDRESS");
    // address indexFactoryProxy = vm.envAddress("CR5_ARBITRUM_INDEX_FACTORY_PROXY_ADDRESS");
    // address indexTokenProxy = vm.envAddress("CR5_ARBITRUM_INDEX_TOKEN_PROXY_ADDRESS");

    // Testnet
    address user = vm.envAddress("USER");
    address weth = vm.envAddress("SEPOLIA_WETH_ADDRESS");
    address usdc = vm.envAddress("SEPOLIA_USDC_ADDRESS");
    address indexFactoryProxy = vm.envAddress("SEPOLIA_INDEX_FACTORY_PROXY_ADDRESS");
    address cr5FactoryAddress = vm.envAddress("SEPOLIA_RISK_ASSET_ADDRESS");
    address indexTokenProxy = vm.envAddress("SEPOLIA_INDEX_TOKEN_PROXY_ADDRESS");
    address scaProxy = vm.envAddress("SEPOLIA_SCA_PROXY_ADDRESS");
    // address indexFactoryBalancer = vm.envAddress("SEPOLIA_INDEX_FACTORY_BALANCER_PROXY_ADDRESS");

    function run() external {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        ////////////// USER //////////////

        // indexToken = IndexToken(payable(indexTokenProxy));
        // vm.startBroadcast(deployerPrivateKey);

        // issuanceIndexTokens();

        // // requestIssuance();

        // vm.stopBroadcast();

        //////////// TEST USER //////////////

        uint256 testUserPrivateKey = vm.envUint("TEST_USER_PRIVATE_KEY");
        vm.startBroadcast(testUserPrivateKey);

        // issuanceIndexTokens();
        cancelIssuance();

        vm.stopBroadcast();

        ////////////// NEX BOT //////////////

        // uint256 nexBotPrivateKey = vm.envUint("NEX_BOT_PRIVATE_KEY");
        // vm.startBroadcast(nexBotPrivateKey);

        // // completeIssuance();
        // requestIssuance();

        // vm.stopBroadcast();
    }

    function issuanceIndexTokens() public {
        uint256 inputAmount = 11e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint256 issuanceFee =
            IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);
        IERC20(usdc).approve(address(indexFactoryProxy), (inputAmount * 1001) / 1000);

        IndexFactory(payable(indexFactoryProxy)).issuanceIndexToken{value: issuanceFee}(
            address(usdc), path, fees, inputAmount
        );
    }

    function requestIssuance() public {
        uint256 inputAmount = 3e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 100;
        uint256 issuanceFee =
            IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);

        StagingCustodyAccount(payable(scaProxy)).requestIssuance{value: issuanceFee}(2, path, fees);
    }

    function completeIssuance() public {
        // uint256 inputAmount = 3e6;
        // address[] memory path = new address[](2);
        // path[0] = address(usdc);
        // path[1] = address(weth);
        // uint24[] memory fees = new uint24[](1);
        // fees[0] = 100;
        // uint256 issuanceFee =
        //     IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);

        StagingCustodyAccount(payable(scaProxy)).completeIssuance(1, 6450000000000000000, 122000000000000000000);
    }

    function cancelIssuance() public {
        IndexFactory(payable(indexFactoryProxy)).cancelIssuance(5);
    }
}
