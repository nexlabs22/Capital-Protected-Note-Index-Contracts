// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import {FeeVault} from "../src/vault/FeeVault.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import "./OlympixUnitTest.sol";

contract DummyIndexFactory {}

error OwnableUnauthorizedAccount(address account);

contract FeeVaultTest is OlympixUnitTest("FeeVault") {
    address owner = address(this);
    address operator = vm.addr(1);
    address nexBot = vm.addr(2);
    address alice = vm.addr(3);

    MockUSDC usdc;
    FunctionsOracle oracle;
    DummyIndexFactory factory;

    IndexFactoryStorage store;
    FeeVault vault;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC("MOCK", "M");
        oracle = new FunctionsOracle();
        factory = new DummyIndexFactory();

        vm.startPrank(oracle.owner());
        oracle.setOperator(operator, true);
        vm.stopPrank();

        store = IndexFactoryStorage(address(new ERC1967Proxy(address(new IndexFactoryStorage()), "")));
        store.initialize(
            address(1),
            address(factory),
            address(oracle),
            address(2),
            address(3),
            nexBot,
            address(4),
            address(usdc),
            address(5),
            address(6),
            address(7)
        );

        vault = FeeVault(
            address(new ERC1967Proxy(address(new FeeVault()), abi.encodeCall(FeeVault.initialize, (address(store)))))
        );

        usdc.mint(address(vault), 100 * ONE_USDC);
    }

    function testRefundByOwner() public {
        uint256 amt = 10 * ONE_USDC;
        uint256 before = usdc.balanceOf(alice);

        vault.refund(alice, amt);

        assertEq(usdc.balanceOf(alice) - before, amt);
    }

    function testRefundByOperator() public {
        uint256 amt = 5 * ONE_USDC;
        vm.prank(operator);
        vault.refund(alice, amt);
    }

    function testRefundByNexBot() public {
        uint256 amt = 5 * ONE_USDC;
        vm.prank(nexBot);
        vault.refund(alice, amt);
    }

    function testRefundByFactory() public {
        uint256 amt = 5 * ONE_USDC;
        vm.prank(address(factory));
        vault.refund(alice, amt);
    }

    function testRefundRevertsForRandomAddress() public {
        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        vault.refund(alice, 1 * ONE_USDC);
    }

    function testRefundRevertsOnBadParams() public {
        vm.expectRevert("FeeVault: bad params");
        vault.refund(address(0), 0);
    }

    function testOwnerWithdrawUsdc() public {
        uint256 amt = 20 * ONE_USDC;
        uint256 before = usdc.balanceOf(owner);

        vault.withdrawUsdc(owner, amt);

        assertEq(usdc.balanceOf(owner) - before, amt);
    }

    function testWithdrawUsdcNonOwnerReverts() public {
        vm.prank(alice);
        bytes memory err = abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(err);
        vault.withdrawUsdc(operator, 1 * ONE_USDC);
    }

    function testWithdrawEthNonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        vault.withdrawEth(operator, 1 * ONE_USDC);
    }

    function testWithdrawAllUsdc() public {
        uint256 vaultBal = usdc.balanceOf(address(vault));
        uint256 before = usdc.balanceOf(owner);

        vault.withdrawAllUsdc();

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(owner) - before, vaultBal);
    }

    function testWithdrawEth() public {
        deal(address(vault), 100);

        vault.withdrawEth(operator, 100);

        assertEq(address(vault).balance, 0);
    }

    function testInitializeRevertsOnZeroAddress() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(new FeeVault()), "");
        FeeVault newVault = FeeVault(address(proxy));
        vm.expectRevert("FeeVault: zero addr");
        newVault.initialize(address(0));
    }

    function testWithdrawEthRevertsIfAmountTooLarge() public {
        deal(address(vault), 1 ether);
        uint256 over = 1 ether + 1;
        vm.expectRevert("Invalid amount");
        vault.withdrawEth(owner, over);
    }
}
