// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IndexToken} from "../src/token/IndexToken.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract IndexFactoryStorageTest is Test {
    address factory = vm.addr(1);
    address vault = vm.addr(2);
    address nexBot = vm.addr(3);
    address alice = vm.addr(4);
    address bob = vm.addr(5);
    address newRecv = vm.addr(9);
    address owner = vm.addr(11);

    IndexFactoryStorage store;
    IndexToken idx;

    function setUp() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();

        {
            IndexToken impl = new IndexToken();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
            );
            idx = IndexToken(address(proxy));
        }

        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));

        MockUSDC usdc = new MockUSDC();

        {
            IndexFactoryStorage impl = new IndexFactoryStorage();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    IndexFactoryStorage.initialize,
                    (
                        address(idx),
                        factory,
                        address(oracle),
                        address(sca),
                        vault,
                        nexBot,
                        address(0xDEAD),
                        address(usdc),
                        false
                    )
                )
            );
            store = IndexFactoryStorage(address(proxy));
        }

        vm.stopPrank();
    }

    function testSetIssuanceRequesterByNonceOtherAddress() public {
        vm.startPrank(owner);
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceRequesterByNonce(1, alice);
    }

    function testCallNotActiveRoundId() public {
        vm.startPrank(owner);
        store.settleIssuance(1);
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 1e18);
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
        vm.expectRevert("Invalid IndexFactory address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (address(1), address(0), address(oracle), address(0), vault, nexBot, address(0), address(0), false)
            )
        );

        vm.stopPrank();
    }

    function test_initialize_FailWhenFunctionsOracleAddressIsInvalid() public {
        vm.startPrank(owner);

        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid FunctionsOracle address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (address(1), factory, address(0), address(1), vault, nexBot, address(2), address(3), false)
            )
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

    function test_setRedemptionRoundActive_FailWhenSenderNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setRedemptionRoundActive(1, true);
    }

    function test_setRedemptionRoundActive_Success() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 1 ether);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        bool active = store.getRedemptionRoundActive(1);
        assertTrue(active);
    }

    function test_addressesInRedemptionRound_ReturnsUniqueList() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 50);
        store.addRedemptionForCurrentRound(alice, 25);
        store.addRedemptionForCurrentRound(bob, 10);
        vm.stopPrank();

        address[] memory list = store.addressesInRedemptionRound(1);
        assertEq(list.length, 2);
        assertEq(list[0], alice);
        assertEq(list[1], bob);
    }

    function test_RedemptionStateIsolatedAcrossRounds() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 100);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        vm.startPrank(owner);
        store.settleRedemption(1);
        vm.stopPrank();

        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(bob, 200);
        vm.stopPrank();

        assertEq(store.totalRedemptionByRound(1), 0);
        assertEq(store.redemptionAmountByRoundUser(1, alice), 0);
        assertEq(store.redemptionRoundId(), 2);
        assertEq(store.totalRedemptionByRound(2), 200);
        assertEq(store.redemptionAmountByRoundUser(2, bob), 200);
    }

    function test_increaseCurrentRoundId_Success() public {
        vm.prank(factory);
        store.increaseCurrentRoundId();
        assertEq(store.currentRoundId(), 2);
    }
}
