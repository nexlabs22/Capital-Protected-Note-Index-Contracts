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
        store.settleIssuance(1);

        // assertEq(store.currentRoundId(), 2);
        assertEq(store.currentRoundId(), 1);
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

    function test_initialize_FailWhenIndexFactoryAddressIsInvalid() public {
        vm.startPrank(owner);

        DummyOracle oracle = new DummyOracle();

        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("invalid index factory address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(IndexFactoryStorage.initialize, (address(0), address(oracle), vault, false, nexBot))
        );

        vm.stopPrank();
    }

    function test_initialize_FailWhenFunctionsOracleAddressIsInvalid() public {
        vm.startPrank(owner);

        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("invalid functions oracle address");
        new ERC1967Proxy(
            address(impl), abi.encodeCall(IndexFactoryStorage.initialize, (factory, address(0), vault, false, nexBot))
        );
        vm.stopPrank();
    }

    function testSetFeeReceiverFailWhenFeeReceiverIsInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert("invalid fee receiver address");
        store.setFeeReceiver(address(0));
        vm.stopPrank();
    }

    function test_setRedemptionInputAmount_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setRedemptionInputAmount(1, 100);
    }

    function test_setBurnedTokenAmountByNonce_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setBurnedTokenAmountByNonce(1, 1);
    }

    function testSetRoundIdToAddresses_FailWhenSenderIsNotFactory() public {
        address[] memory arr = new address[](2);
        arr[0] = alice;
        arr[1] = bob;

        vm.expectRevert("Caller is not a factory contract");
        store.setRoundIdToAddresses(1, arr);
    }

    function test_increaseCurrentRoundId_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.increaseCurrentRoundId();
    }

    function test_addIssuanceForCurrentRound_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.addIssuanceForCurrentRound(alice, 100);
    }

    function testSettleRound_FailWhenCallerIsNotOwnerOrOperator() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 80);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(bob, 20);

        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        store.settleIssuance(1);
    }

    function test_setIssuanceCompleted_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceCompleted(1, true);
    }

    function test_setIssuanceCompleted_SuccessfulSetIssuanceCompleted() public {
        vm.prank(factory);
        store.setIssuanceCompleted(1, true);
        assertEq(store.issuanceIsCompleted(1), true);
    }

    function test_addRedemptionForCurrentRound_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.addRedemptionForCurrentRound(alice, 100);
    }

    function test_addRedemptionForCurrentRound_SuccessfulAddRedemption() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 100);
        store.addRedemptionForCurrentRound(alice, 50);
        vm.stopPrank();

        assertEq(store.redemptionAmountByRoundUser(1, alice), 150);
        assertEq(store.totalRedemptionByRound(1), 150);
    }

    function test_setIssuanceRequesterByNonce_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceRequesterByNonce(1, alice);
    }

    function test_undoIssuance_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.undoIssuance(alice, 1);
    }

    function test_undoIssuance_SuccessfulUndo() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        store.addIssuanceForCurrentRound(bob, 50);
        vm.stopPrank();

        vm.startPrank(factory);
        store.undoIssuance(alice, 30);
        vm.stopPrank();

        assertEq(store.issuanceAmountByRoundUser(1, alice), 70);
        assertEq(store.totalIssuanceByRound(1), 120);
    }

    function test_undoIssuance_FailWhenAmountIsInvalid() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        vm.stopPrank();

        vm.startPrank(factory);
        vm.expectRevert("bad amount");
        store.undoIssuance(alice, 200);
        vm.stopPrank();
    }

    function test_undoIssuance_SuccessfulUndoWhenIssuanceAmountIsZero() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        store.addIssuanceForCurrentRound(bob, 50);
        vm.stopPrank();

        vm.startPrank(factory);
        store.undoIssuance(alice, 100);
        vm.stopPrank();

        assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
        assertEq(store.totalIssuanceByRound(1), 50);
    }

    function test_undoIssuance_SuccessfulUndoWhenRoundIdIsNotActive() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        store.addIssuanceForCurrentRound(bob, 50);
        vm.stopPrank();

        vm.startPrank(factory);
        store.undoIssuance(alice, 100);
        store.undoIssuance(bob, 50);
        vm.stopPrank();

        assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
        assertEq(store.issuanceAmountByRoundUser(1, bob), 0);
        assertEq(store.totalIssuanceByRound(1), 0);
        assertEq(store.roundIdIsActive(1), false);
    }

    function test_undoRedemption_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.undoRedemption(alice, 1);
    }

    function test_undoRedemption_SuccessfulUndo() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 100);
        store.addRedemptionForCurrentRound(bob, 50);
        vm.stopPrank();

        vm.startPrank(factory);
        store.undoRedemption(alice, 30);
        vm.stopPrank();

        assertEq(store.redemptionAmountByRoundUser(1, alice), 70);
        assertEq(store.totalRedemptionByRound(1), 120);
    }

    function test_undoRedemption_FailWhenAmountIsInvalid() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 100);
        vm.stopPrank();

        vm.startPrank(factory);
        vm.expectRevert("bad amount");
        store.undoRedemption(alice, 0);
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenSenderIsNotOwnerOrOperator() public {
        vm.prank(factory);
        store.addRedemptionForCurrentRound(alice, 80);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(bob, 20);

        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        store.settleRedemption(1);
    }

    function test_settleRedemption_SuccessfulSettleRedemption() public {
        vm.prank(factory);
        store.addRedemptionForCurrentRound(alice, 80);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(bob, 20);

        vm.prank(nexBot);
        store.settleRedemption(1);

        assertEq(store.redemptionRoundId(), 2);
        assertEq(store.totalRedemptionByRound(1), 0);
        assertEq(store.redemptionAmountByRoundUser(1, alice), 0);
        assertEq(store.redemptionAmountByRoundUser(1, bob), 0);
    }
}
