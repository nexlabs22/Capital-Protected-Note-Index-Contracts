// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

import {IndexFactory} from "../src/factory/IndexFactory.sol";
import "../src/token/IndexToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/IRiskAssetFactory.sol";
import "../src/SCA/StagingCustodyAccount.sol";
import "../src/factory/FunctionsOracle.sol";
import "../src/factory/IndexFactoryBalancer.sol";

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
    address indexFactoryBalancer = vm.envAddress("SEPOLIA_INDEX_FACTORY_BALANCER_PROXY_ADDRESS");

    function run() external {
        indexToken = IndexToken(payable(indexTokenProxy));
        // //// USER //////////////
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // setMockFulFill();
        // firstRebalanceAction();
        // secondRebalanceAction();
        completeRebalance();

        // issuanceIndexTokens();

        // redemption();
        // completeRedemption();
        // cancelIssuance();
        // requestIssuance();

        // cancelRedemption();

        vm.stopBroadcast();

        ////////// TEST USER //////////////

        // uint256 testUserPrivateKey = vm.envUint("TEST_USER_PRIVATE_KEY");
        // vm.startBroadcast(testUserPrivateKey);

        // // // issuanceIndexTokens();
        // // // cancelIssuance();
        // redemption();

        // vm.stopBroadcast();

        //////////// NEX BOT //////////////

        // uint256 nexBotPrivateKey = vm.envUint("NEX_BOT_PRIVATE_KEY");
        // vm.startBroadcast(nexBotPrivateKey);

        // // requestIssuance();
        // completeIssuance();
        // // requestRedemption();
        // // completeRedemption();

        // vm.stopBroadcast();
    }

    function issuanceIndexTokens() public {
        uint256 inputAmount = 15e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint256 issuanceFee =
            IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);
        IERC20(usdc).approve(address(indexFactoryProxy), (inputAmount * 1001) / 1000);

        IndexFactory(payable(indexFactoryProxy)).issuanceIndexTokens{value: issuanceFee}(
            address(usdc), path, fees, inputAmount
        );
    }

    function redemption() public {
        // uint256 balance = IERC20(indexTokenProxy).balanceOf(address(user));
        uint256 redemptionFee = IRiskAssetFactory(payable(cr5FactoryAddress)).getRedemptionFee(50000000000000000);
        IERC20(indexTokenProxy).approve(address(indexFactoryProxy), 50000000000000000);

        IndexFactory(payable(indexFactoryProxy)).redemption{value: redemptionFee}(50000000000000000);
    }

    function requestIssuance() public {
        uint256 inputAmount = 22e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint256 issuanceFee =
            IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);

        StagingCustodyAccount(payable(scaProxy)).requestIssuance{value: issuanceFee}(1, path, fees);
    }

    function requestRedemption() public {
        uint256 redemptionFee = IRiskAssetFactory(payable(cr5FactoryAddress)).getRedemptionFee(70000000000000000);

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;

        StagingCustodyAccount(payable(scaProxy)).requestRedemption{value: redemptionFee}(1, path, fees);
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

        StagingCustodyAccount(payable(scaProxy)).completeIssuance(1, 6410000000000000000, 126750000000000000000);
        // StagingCustodyAccount(payable(scaProxy)).completeIssuance(2, 6450000000000000000, 133140000000000000000);
    }

    function completeRedemption() public {
        IERC20(usdc).approve(address(scaProxy), 5677000000000000000);

        StagingCustodyAccount(payable(scaProxy)).completeRedemption(1, 5677000, 1440000);
    }

    function cancelIssuance() public {
        IndexFactory(payable(indexFactoryProxy)).cancelIssuance(5);
    }

    function cancelRedemption() public {
        IndexFactory(payable(indexFactoryProxy)).cancelRedemption(1);
    }

    function firstRebalanceAction() public {
        uint256 redemptionFee = IRiskAssetFactory(payable(cr5FactoryAddress)).getRedemptionFee(30000000000000000);
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        IndexFactoryBalancer(payable(indexFactoryBalancer)).firstRebalanceAction{value: redemptionFee}(
            6400000000000000000, 140430000000000000000, path, fees
        );
    }

    function secondRebalanceAction() public {
        uint256 inputAmount = 22e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint256 issuanceFee =
            IRiskAssetFactory(payable(cr5FactoryAddress)).getIssuanceFee(address(usdc), path, fees, inputAmount);
        IndexFactoryBalancer(payable(indexFactoryBalancer)).secondRebalanceAction{value: 0}(2, path, fees);
    }

    function completeRebalance() public {
        IndexFactoryBalancer(payable(indexFactoryBalancer)).completeRebalanceActions(2);
    }

    function setMockFulFill() public {
        address oracleProxy = vm.envAddress("SEPOLIA_FUNCTIONS_ORACLE_PROXY_ADDRESS"); // the FunctionsOracle proxy
        address bondToken = vm.envAddress("SEPOLIA_BOND_ADDRESS"); // ERC-20 of the bond
        address riskAsset = vm.envAddress("SEPOLIA_RISK_ASSET_TOKEN_ADDRESS"); // ERC-20 of the risky asset
        // uint256 pk = vm.envUint("PRIVATE_KEY"); // oracle-owner key

        uint8[] memory assetType = new uint8[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory mktShare = new uint256[](2);

        assetType[0] = 0; // bond
        assetType[1] = 1; // risk asset

        tokens[0] = bondToken;
        tokens[1] = riskAsset;

        mktShare[0] = 80e18; // 80 %
        mktShare[1] = 20e18; // 20 %

        // mktShare[0] = 50e18; // 50 %
        // mktShare[1] = 50e18; // 50 %

        // mktShare[0] = 60e18; // 60 %
        // mktShare[1] = 40e18; // 40 %

        // bytes32 dummyRequestId = bytes32(uint256(1)); // any non-zero value is fine
        // bytes memory response = abi.encode(assetType, tokens, mktShare);
        // bytes memory emptyErr = "";

        // vm.startBroadcast(pk);
        FunctionsOracle(oracleProxy).mockFulFill(assetType, tokens, mktShare);
        // vm.stopBroadcast();
    }

    // 5.677 bond
    // 1.44 crypto5
}
