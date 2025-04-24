// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/factory/IndexFactoryStorage.sol";

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract IndexFactoryStorageTest is Test {
    address factory = vm.addr(1);
    address vault = vm.addr(2);
    address nexBot = vm.addr(3);
    address newRecv = vm.addr(9);
    address owner = vm.addr(11);

    IndexFactoryStorage store;

    address alice = vm.addr(4);
    address bob = vm.addr(5);

    function setUp() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();

        IndexFactoryStorage impl = new IndexFactoryStorage();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(IndexFactoryStorage.initialize, (factory, address(oracle), vault, false, nexBot))
        );
        store = IndexFactoryStorage(address(proxy));
        vm.stopPrank();
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
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 80);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(bob, 20);

        vm.prank(nexBot);
        store.settleRound(1);

        assertEq(store.currentRoundId(), 2);
        assertEq(store.totalIssuanceByRound(1), 0);
        assertEq(store.addressesInRound(1).length, 0);
        assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
    }

    function testSetIssuanceInputAmount() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceInputAmount(1, 100);

        vm.prank(factory);
        vm.expectRevert("Invalid issuance input amount");
        store.setIssuanceInputAmount(1, 0);

        vm.prank(factory);
        store.setIssuanceInputAmount(1, 250);
        assertEq(store.issuanceInputAmount(1), 250);
    }

    function testSetRedemptionInputAmount() public {
        vm.prank(factory);
        vm.expectRevert("Invalid redemption input amount");
        store.setRedemptionInputAmount(1, 0);

        vm.prank(factory);
        store.setRedemptionInputAmount(1, 500);
        assertEq(store.redemptionInputAmount(1), 500);
    }

    function testSetBurnedTokenAmount() public {
        vm.prank(factory);
        vm.expectRevert("Invalid burn amount");
        store.setBurnedTokenAmountByNonce(1, 0);

        vm.prank(factory);
        store.setBurnedTokenAmountByNonce(1, 77);
        assertEq(store.burnedTokenAmountByNonce(1), 77);
    }

    function testSetRoundIdToAddresses() public {
        address[] memory arr = new address[](2);
        arr[0] = alice;
        arr[1] = bob;

        vm.prank(factory);
        vm.expectRevert("Invalid roundId amount");
        store.setRoundIdToAddresses(0, arr);

        vm.prank(factory);
        store.setRoundIdToAddresses(5, arr);
        address[] memory stored = store.addressesInRound(5);
        assertEq(stored.length, 2);
        assertEq(stored[1], bob);
    }

    function testSetFeeReceiver() public {
        address user = address(10);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        store.setFeeReceiver(newRecv);
        vm.stopPrank();

        vm.prank(owner);
        store.setFeeReceiver(newRecv);

        assertEq(store.feeReceiver(), newRecv);
    }
}
