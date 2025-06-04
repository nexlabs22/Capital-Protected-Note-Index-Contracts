// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import "./OlympixUnitTest.sol";

contract OracleHarness is FunctionsOracle {
    function exposed_initData(uint8[] memory types, address[] calldata tokens, uint256[] calldata shares) external {
        _initData(types, tokens, shares);
    }
}

contract FunctionsOracleTest is Test {
    address owner = vm.addr(1);
    address operator = vm.addr(2);
    address balancer = vm.addr(3);

    OracleHarness oracle;

    address tokenA = address(0xA);
    address tokenB = address(0xB);

    function setUp() public {
        OracleHarness impl = new OracleHarness();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(FunctionsOracle.initialize, (address(0xF00), bytes32("don")))
        );

        oracle = OracleHarness(payable(address(proxy)));

        vm.startPrank(address(this));
        oracle.transferOwnership(owner);
        vm.stopPrank();

        vm.prank(owner);
        oracle.acceptOwnership();
    }

    function testInitialState() public view {
        assertEq(oracle.owner(), owner);
        assertEq(oracle.functionsRouterAddress(), address(0xF00));
        assertEq(oracle.donId(), bytes32("don"));
    }

    function testOwnerSetters() public {
        vm.startPrank(owner);

        oracle.setOperator(operator, true);
        assertTrue(oracle.isOperator(operator));

        oracle.setDonId(bytes32("NEW"));
        assertEq(oracle.donId(), bytes32("NEW"));

        oracle.setFunctionsRouterAddress(address(0xBEEF));
        assertEq(oracle.functionsRouterAddress(), address(0xBEEF));

        oracle.setFactoryBalancer(balancer);
        assertEq(oracle.factoryBalancerAddress(), balancer);

        vm.stopPrank();
    }

    function testOwnerSetterRevertsForNonOwner() public {
        vm.expectRevert("Only callable by owner");
        oracle.setDonId(bytes32("x"));
    }

    function testInitDataAndUpdate() public {
        address[] memory tokens = new address[](2);
        uint256[] memory shares = new uint256[](2);
        uint8[] memory types = new uint8[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        shares[0] = 70e18;
        shares[1] = 30e18;
        types[1] = 0;
        types[1] = 1;

        vm.prank(owner);
        oracle.exposed_initData(types, tokens, shares);

        assertEq(oracle.oracleList(0), tokenA);
        assertEq(oracle.tokenOracleMarketShare(tokenB), 30e18);
        assertEq(oracle.totalOracleList(), 2);

        assertEq(oracle.currentList(1), tokenB);
        assertEq(oracle.totalCurrentList(), 2);

        vm.prank(owner);
        oracle.setFactoryBalancer(balancer);

        vm.prank(balancer);
        oracle.updateCurrentList();
        assertEq(oracle.tokenCurrentMarketShare(tokenA), 70e18);
    }

    function testUpdateCurrentListBadCaller() public {
        vm.prank(owner);
        oracle.setFactoryBalancer(balancer);

        vm.expectRevert("caller must be factory balancer");
        oracle.updateCurrentList();
    }

    function test_setFunctionsRouterAddress_FailWhenFunctionsRouterAddressIsZero() public {
        vm.startPrank(owner);

        vm.expectRevert("invalid functions router address");
        oracle.setFunctionsRouterAddress(address(0));

        vm.stopPrank();
    }

    function test_setFactoryBalancer_FailWhenFactoryBalancerAddressIsInvalid() public {
        vm.startPrank(owner);

        vm.expectRevert("invalid factory balancer address");
        oracle.setFactoryBalancer(address(0));

        vm.stopPrank();
    }

    function test_requestAssetsData_FailWhenSenderIsNotOwnerOrOperator() public {
        vm.expectRevert("Caller is not the owner or operator.");
        oracle.requestAssetsData("", 0, 0);
    }

    function test_initData_SuccessfulInitData() public {
        address[] memory tokens = new address[](2);
        uint256[] memory shares = new uint256[](2);
        uint8[] memory types = new uint8[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        shares[0] = 70e18;
        shares[1] = 30e18;
        types[1] = 0;
        types[1] = 1;

        vm.prank(owner);
        oracle.exposed_initData(types, tokens, shares);

        assertEq(oracle.oracleList(0), tokenA);
        assertEq(oracle.tokenOracleMarketShare(tokenB), 30e18);
        assertEq(oracle.totalOracleList(), 2);

        assertEq(oracle.currentList(1), tokenB);
        assertEq(oracle.totalCurrentList(), 2);

        vm.prank(owner);
        oracle.exposed_initData(types, tokens, shares);

        assertEq(oracle.oracleList(0), tokenA);
        assertEq(oracle.tokenOracleMarketShare(tokenB), 30e18);
        assertEq(oracle.totalOracleList(), 2);

        assertEq(oracle.currentList(1), tokenB);
        assertEq(oracle.totalCurrentList(), 2);
    }

    function test_initialize_revertOnZeroRouterAddress() public {
        OracleHarness impl = new OracleHarness();
        bytes memory initData = abi.encodeCall(FunctionsOracle.initialize, (address(0), bytes32("don")));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OracleHarness testOracle = OracleHarness(payable(address(proxy)));
        vm.expectRevert("invalid functions router address");
        testOracle.initialize(address(0), bytes32("don"));
    }
}
