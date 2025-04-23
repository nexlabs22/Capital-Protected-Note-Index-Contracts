// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "../src/factory/IndexFactoryStorage.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract IndexFactoryStorageTest is Test {
    address factory = vm.addr(1);
    address oracle = vm.addr(2);
    address vault = vm.addr(3);
    address nexBot = vm.addr(4);

    IndexFactoryStorage store;
    address alice = vm.addr(4);
    address bob = vm.addr(5);

    function setUp() public {
        IndexFactoryStorage impl = new IndexFactoryStorage();

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(IndexFactoryStorage.initialize, (factory, oracle, vault, false, nexBot))
        );

        store = IndexFactoryStorage(address(proxy));
    }

    function testAddIssuanceUnique() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 50);

        address[] memory list = store.addressesInRound(1);
        assertEq(list.length, 1);
        assertEq(store.totalIssuanceByRound(1), 150);
    }

    function testSettleRound() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 80);
        store.addIssuanceForCurrentRound(bob, 20);
        store.settleRound(1);
        vm.stopPrank();

        assertEq(store.currentRoundId(), 2);
        assertEq(store.totalIssuanceByRound(1), 0);
        assertEq(store.addressesInRound(1).length, 0);
        assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
    }
}
