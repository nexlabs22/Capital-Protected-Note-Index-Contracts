// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IndexToken} from "../src/token/IndexToken.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import "./OlympixUnitTest.sol";

error ZeroAmount();
error InvalidAddress();

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract IndexFactoryStorageTest is OlympixUnitTest("IndexFactoryStorage") {
    address factory = vm.addr(1);
    address vault = vm.addr(2);
    address nexBot = vm.addr(3);
    address alice = vm.addr(4);
    address bob = vm.addr(5);
    address newRecv = vm.addr(9);
    address owner = vm.addr(11);
    address bond = vm.addr(12);
    address feeVault = vm.addr(13);
    address cr5 = vm.addr(14);

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
                        bond,
                        feeVault,
                        address(1)
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

        address[] memory list = store.addressesInIssuanceRound(1);
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

        assertEq(store.issuanceRoundId(), 1);
        assertEq(store.totalIssuanceByRound(1), 0);
        assertEq(store.addressesInIssuanceRound(1).length, 0);
        assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
    }

    function testSetIssuanceInputAmount() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceInputAmount(1, 100);

        vm.prank(factory);
        vm.expectRevert(ZeroAmount.selector);
        store.setIssuanceInputAmount(1, 0);

        vm.prank(factory);
        store.setIssuanceInputAmount(1, 250);
        assertEq(store.issuanceInputAmount(1), 250);
    }

    function testSetRedemptionInputAmount() public {
        vm.prank(factory);
        vm.expectRevert(ZeroAmount.selector);
        store.setRedemptionInputAmount(1, 0);

        vm.prank(factory);
        store.setRedemptionInputAmount(1, 500);
        assertEq(store.redemptionInputAmount(1), 500);
    }

    // function testSetBurnedTokenAmount() public {
    //     vm.prank(factory);
    //     vm.expectRevert(ZeroAmount.selector);
    //     store.setBurnedTokenAmountByNonce(1, 0);

    //     vm.prank(factory);
    //     store.setBurnedTokenAmountByNonce(1, 77);
    //     assertEq(store.burnedTokenAmountByNonce(1), 77);
    // }

    function testSetRoundIdToAddresses() public {
        address[] memory arr = new address[](2);
        arr[0] = alice;
        arr[1] = bob;

        vm.prank(factory);
        vm.expectRevert("Invalid roundId amount");
        store.setIssuanceRoundIdToAddresses(0, arr);

        vm.prank(factory);
        store.setIssuanceRoundIdToAddresses(5, arr);
        address[] memory stored = store.addressesInIssuanceRound(5);
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
        vm.expectRevert("Invalid _indexFactory address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(1),
                    address(0),
                    address(oracle),
                    address(0),
                    vault,
                    nexBot,
                    address(0),
                    address(0),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );

        vm.stopPrank();
    }

    function test_initialize_FailWhenFunctionsOracleAddressIsInvalid() public {
        vm.startPrank(owner);

        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _functionsOracle address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(1),
                    factory,
                    address(0),
                    address(1),
                    vault,
                    nexBot,
                    address(2),
                    address(3),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function testSetFeeReceiverFailWhenFeeReceiverIsInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert(InvalidAddress.selector);
        store.setFeeReceiver(address(0));
        vm.stopPrank();
    }

    function test_setRedemptionInputAmount_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.setRedemptionInputAmount(1, 100);
    }

    // function test_setBurnedTokenAmountByNonce_FailWhenSenderIsNotFactory() public {
    //     vm.expectRevert("Caller is not a factory contract");
    //     store.setBurnedTokenAmountByNonce(1, 1);
    // }

    function testSetRoundIdToAddresses_FailWhenSenderIsNotFactory() public {
        address[] memory arr = new address[](2);
        arr[0] = alice;
        arr[1] = bob;

        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceRoundIdToAddresses(1, arr);
    }

    function test_increaseCurrentRoundId_FailWhenSenderIsNotFactory() public {
        vm.expectRevert("Caller is not a factory contract");
        store.increaseIssuanceRoundId();
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

    // function test_undoIssuance_FailWhenSenderIsNotFactory() public {
    //     vm.expectRevert("Caller is not a factory contract");
    //     store.undoIssuance(alice, 1);
    // }

    // function test_undoIssuance_SuccessfulUndo() public {
    //     vm.startPrank(factory);
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     store.addIssuanceForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoIssuance(alice, 30);
    //     vm.stopPrank();

    //     assertEq(store.issuanceAmountByRoundUser(1, alice), 70);
    //     assertEq(store.totalIssuanceByRound(1), 120);
    // }

    // function test_undoIssuance_FailWhenAmountIsInvalid() public {
    //     vm.startPrank(factory);
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     vm.expectRevert("bad amount");
    //     store.undoIssuance(alice, 200);
    //     vm.stopPrank();
    // }

    // function test_undoIssuance_SuccessfulUndoWhenIssuanceAmountIsZero() public {
    //     vm.startPrank(factory);
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     store.addIssuanceForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoIssuance(alice, 100);
    //     vm.stopPrank();

    //     assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
    //     assertEq(store.totalIssuanceByRound(1), 50);
    // }

    // function test_undoIssuance_SuccessfulUndoWhenRoundIdIsNotActive() public {
    //     vm.startPrank(factory);
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     store.addIssuanceForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoIssuance(alice, 100);
    //     store.undoIssuance(bob, 50);
    //     vm.stopPrank();

    //     assertEq(store.issuanceAmountByRoundUser(1, alice), 0);
    //     assertEq(store.issuanceAmountByRoundUser(1, bob), 0);
    //     assertEq(store.totalIssuanceByRound(1), 0);
    //     assertEq(store.issuanceRoundActive(1), false);
    // }

    // function test_undoRedemption_FailWhenSenderIsNotFactory() public {
    //     vm.expectRevert("Caller is not a factory contract");
    //     store.undoRedemption(alice, 1);
    // }

    // function test_undoRedemption_SuccessfulUndo() public {
    //     vm.startPrank(factory);
    //     store.addRedemptionForCurrentRound(alice, 100);
    //     store.addRedemptionForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoRedemption(alice, 30);
    //     vm.stopPrank();

    //     assertEq(store.redemptionAmountByRoundUser(1, alice), 70);
    //     assertEq(store.totalRedemptionByRound(1), 120);
    // }

    // function test_undoRedemption_FailWhenAmountIsInvalid() public {
    //     vm.startPrank(factory);
    //     store.addRedemptionForCurrentRound(alice, 100);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     vm.expectRevert("bad amount");
    //     store.undoRedemption(alice, 0);
    //     vm.stopPrank();
    // }

    function test_settleRedemption_FailWhenSenderIsNotOwnerOrOperator() public {
        vm.prank(factory);
        store.addRedemptionForCurrentRound(alice, 80);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(bob, 20);

        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        store.settleRedemption(1);
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

    function test_increaseCurrentRoundId_Success() public {
        vm.prank(factory);
        store.increaseIssuanceRoundId();
        assertEq(store.issuanceRoundId(), 2);
    }

    // function test_initialize_FailWhenIndexTokenAddressIsInvalid() public {
    //     vm.startPrank(owner);

    //     DummyOracle oracle = new DummyOracle();
    //     IndexFactoryStorage impl = new IndexFactoryStorage();

    //     vm.expectRevert("Invalid _indexToken address");
    //     new ERC1967Proxy(
    //         address(impl),
    //         abi.encodeCall(
    //             IndexFactoryStorage.initialize,
    //             (
    //                 address(0),
    //                 factory,
    //                 address(oracle),
    //                 address(0x1234),
    //                 vault,
    //                 nexBot,
    //                 address(0xDEAD),
    //                 address(0xBEEF),
    //                 bond,
    //                 feeVault,
    //                 address(1)
    //             )
    //         )
    //     );
    //     vm.stopPrank();
    // }

    function test_initialize_FailWhenStagingCustodyAccountAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _stagingCustodyAccount address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx),
                    factory,
                    address(oracle),
                    address(0),
                    vault,
                    nexBot,
                    address(0xDEAD),
                    address(0xBEEF),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_initialize_FailWhenVaultAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexToken implIdx = new IndexToken();
        ERC1967Proxy proxyIdx = new ERC1967Proxy(
            address(implIdx), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
        );
        IndexToken idx1 = IndexToken(address(proxyIdx));
        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));
        MockUSDC usdc = new MockUSDC();
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _vault address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx1),
                    factory,
                    address(oracle),
                    address(sca),
                    address(0),
                    nexBot,
                    address(0xDEAD),
                    address(usdc),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_initialize_FailWhenNexBotAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexToken implIdx = new IndexToken();
        ERC1967Proxy proxyIdx = new ERC1967Proxy(
            address(implIdx), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
        );
        IndexToken idx1 = IndexToken(address(proxyIdx));
        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));
        MockUSDC usdc = new MockUSDC();
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _nexBot address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx1),
                    factory,
                    address(oracle),
                    address(sca),
                    vault,
                    address(0),
                    address(0xDEAD),
                    address(usdc),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_setNexBotAddress_RevertOnZeroAddress() public {
        vm.startPrank(vm.addr(11));
        vm.expectRevert(InvalidAddress.selector);
        store.setNexBotAddress(address(0));
        vm.stopPrank();
    }

    function test_setSCA_FailWhenSCAIsZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(InvalidAddress.selector);
        store.setSCA(address(0));
        vm.stopPrank();
    }

    function test_setSCA_ElseBranchInRequire() public {
        vm.startPrank(vm.addr(11));
        address newSCA = address(0x123456);
        store.setSCA(newSCA);
        assertEq(address(store.sca()), newSCA);
        vm.stopPrank();
    }

    // function test_undoIssuance_ElseBranchInPruneLoop() public {
    //     address charlie = vm.addr(6);
    //     vm.startPrank(factory);
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     store.addIssuanceForCurrentRound(bob, 50);
    //     store.addIssuanceForCurrentRound(charlie, 25);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoIssuance(alice, 100);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoIssuance(bob, 50);
    //     vm.stopPrank();

    //     address[] memory list = store.addressesInIssuanceRound(1);
    //     assertEq(list.length, 1);
    //     assertEq(list[0], charlie);
    // }

    // function test_undoRedemption_PruneAddressWhenRedemptionAmountIsZero() public {
    //     vm.startPrank(factory);
    //     store.addRedemptionForCurrentRound(alice, 100);
    //     store.addRedemptionForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoRedemption(alice, 100);
    //     vm.stopPrank();

    //     address[] memory list = store.addressesInRedemptionRound(1);
    //     assertEq(list.length, 1);
    //     assertEq(list[0], bob);
    //     assertEq(store.redemptionAmountByRoundUser(1, alice), 0);
    //     assertEq(store.totalRedemptionByRound(1), 50);
    // }

    function test_nextProcessableRoundId_revertsOnUnsettledRound() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 100);

        vm.prank(factory);
        store.increaseIssuanceRoundId();
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("UnsettledRound(uint256)")), 1));
        store.nextProcessableRoundIdForIssuance();
    }

    function test_nextProcessableRoundId_returnsCurrentRoundIdWhenNoUnsettledRounds() public {
        vm.prank(factory);
        store.increaseIssuanceRoundId();
        vm.prank(factory);
        store.increaseIssuanceRoundId();
        uint256 nextId = store.nextProcessableRoundIdForIssuance();
        assertEq(nextId, 3);
    }

    function test_initialize_FailWhenCrypto5FactoryAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexToken implIdx = new IndexToken();
        ERC1967Proxy proxyIdx = new ERC1967Proxy(
            address(implIdx), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
        );
        IndexToken idx1 = IndexToken(address(proxyIdx));
        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));
        MockUSDC usdc = new MockUSDC();
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _riskAssetFactoryAddress address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx1),
                    factory,
                    address(oracle),
                    address(sca),
                    vault,
                    nexBot,
                    address(0),
                    address(usdc),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_initialize_FailWhenUSDCAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexToken implIdx = new IndexToken();
        ERC1967Proxy proxyIdx = new ERC1967Proxy(
            address(implIdx), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
        );
        IndexToken idx1 = IndexToken(address(proxyIdx));
        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _usdc address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx1),
                    factory,
                    address(oracle),
                    address(sca),
                    vault,
                    nexBot,
                    address(0xDEAD),
                    address(0),
                    bond,
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_initialize_FailWhenBondAddressIsInvalid() public {
        vm.startPrank(owner);
        DummyOracle oracle = new DummyOracle();
        IndexToken implIdx = new IndexToken();
        ERC1967Proxy proxyIdx = new ERC1967Proxy(
            address(implIdx), abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, newRecv, 10e18))
        );
        IndexToken idx1 = IndexToken(address(proxyIdx));
        StagingCustodyAccount sca =
            StagingCustodyAccount(address(new ERC1967Proxy(address(new StagingCustodyAccount()), "")));
        MockUSDC usdc = new MockUSDC();
        IndexFactoryStorage impl = new IndexFactoryStorage();
        vm.expectRevert("Invalid _bond address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx1),
                    factory,
                    address(oracle),
                    address(sca),
                    vault,
                    nexBot,
                    address(0xDEAD),
                    address(usdc),
                    address(0),
                    feeVault,
                    address(1)
                )
            )
        );
        vm.stopPrank();
    }

    function test_increaseRedemptionRoundId_SuccessWhenSenderIsFactory() public {
        uint256 before = store.redemptionRoundId();
        vm.prank(factory);
        store.increaseRedemptionRoundId();
        assertEq(store.redemptionRoundId(), before + 1);
    }

    function test_setRedemptionRequesterByNonce_FailsWhenNotFactoryNexBotOrSCA() public {
        uint256 nonce = 42;
        address requester = address(0xBEEF);
        address notAllowed = address(0xDEAD);
        vm.prank(notAllowed);
        vm.expectRevert("Caller is not a factory contract");
        store.setRedemptionRequesterByNonce(nonce, requester);
    }

    // function test_undoRedemption_ElseBranchInPruneLoop() public {
    //     address charlie = vm.addr(6);
    //     vm.startPrank(factory);
    //     store.addRedemptionForCurrentRound(alice, 100);
    //     store.addRedemptionForCurrentRound(bob, 50);
    //     store.addRedemptionForCurrentRound(charlie, 25);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoRedemption(bob, 50);
    //     vm.stopPrank();

    //     address[] memory list = store.addressesInRedemptionRound(1);
    //     assertEq(list.length, 2);
    //     assertEq(list[0], alice);
    //     assertEq(list[1], charlie);
    //     assertEq(store.redemptionAmountByRoundUser(1, bob), 0);
    //     assertEq(store.totalRedemptionByRound(1), 125);
    // }

    // function test_undoRedemption_PruneAddressWhenRedemptionAmountIsZero_LastAddress() public {
    //     // address charlie = vm.addr(6);
    //     vm.startPrank(factory);
    //     store.addRedemptionForCurrentRound(alice, 100);
    //     store.addRedemptionForCurrentRound(bob, 50);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoRedemption(alice, 100);
    //     vm.stopPrank();

    //     vm.startPrank(factory);
    //     store.undoRedemption(bob, 50);
    //     vm.stopPrank();

    //     address[] memory list = store.addressesInRedemptionRound(1);
    //     assertEq(list.length, 0);
    //     assertEq(store.redemptionAmountByRoundUser(1, bob), 0);
    //     assertEq(store.totalRedemptionByRound(1), 0);
    //     assertEq(store.redemptionRoundActive(1), false);
    // }

    function test_nextProcessableRoundIdForRedemption_revertsOnUnsettledRound() public {
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, 100);
        store.setRedemptionRoundActive(1, true);
        store.increaseRedemptionRoundId();
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("UnsettledRound(uint256)")), 1));
        store.nextProcessableRoundIdForRedemption();
    }

    function test_nextProcessableRoundIdForRedemption_ElseBranch() public {
        vm.prank(factory);
        store.increaseRedemptionRoundId();
        vm.prank(factory);
        store.increaseRedemptionRoundId();
        uint256 nextId = store.nextProcessableRoundIdForRedemption();
        assertEq(nextId, 3, "Should return current redemptionRoundId");
    }

    function test_currentIssuanceRoundWithStatus_ElseBranch() public {
        vm.prank(factory);
        store.increaseIssuanceRoundId();
        vm.prank(factory);
        store.increaseIssuanceRoundId();

        (bool allSettled, uint256 roundId) = store.currentIssuanceRoundWithStatus();
        assertTrue(allSettled, "Should be all settled");
        assertEq(roundId, 3, "Should return current issuanceRoundId");
    }

    function test_currentRedemptionRoundWithStatus_ElseBranch() public {
        vm.prank(factory);
        store.increaseRedemptionRoundId();
        vm.prank(factory);
        store.increaseRedemptionRoundId();

        (bool allSettled, uint256 roundId) = store.currentRedemptionRoundWithStatus();
        assertTrue(allSettled);
        assertEq(roundId, 3);
    }

    function test_setRedemptionCompleted_SuccessWhenSenderIsFactory() public {
        uint256 nonce = 7;
        assertEq(store.redemptionIsCompleted(nonce), false);
        vm.prank(factory);
        store.setRedemptionCompleted(nonce, true);
        assertEq(store.redemptionIsCompleted(nonce), true);
    }

    function test_currentIssuanceRoundWithStatus_TrueBranch() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(vm.addr(100), 1e18);
        vm.prank(factory);
        store.increaseIssuanceRoundId();
        (bool allSettled, uint256 roundId) = store.currentIssuanceRoundWithStatus();
        assertFalse(allSettled, "Should not be all settled");
        assertEq(roundId, 1, "Should return the first unsettled roundId");
    }

    function test_currentRedemptionRoundWithStatus_TrueBranch() public {
        vm.prank(factory);
        store.addRedemptionForCurrentRound(vm.addr(100), 1e18);
        vm.prank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.prank(factory);
        store.increaseRedemptionRoundId();

        (bool allSettled, uint256 roundId) = store.currentRedemptionRoundWithStatus();

        assertFalse(allSettled, "Should not be all settled");
        assertEq(roundId, 1, "Should return the first unsettled roundId");
    }

    function test_increaseTokenPendingRebalanceAmount_success() public {
        // factory is an authorised caller (`onlyFactory`)
        uint256 nonce = 42;
        uint256 delta = 7 ether;

        vm.prank(factory);
        store.increaseTokenPendingRebalanceAmount(address(bond), nonce, delta);

        assertEq(store.tokenPendingRebalanceAmount(address(bond)), delta, "global counter");
        assertEq(store.tokenPendingRebalanceAmountByNonce(address(bond), nonce), delta, "per-nonce counter");
    }

    function test_increaseTokenPendingRebalanceAmount_revertsOnBadInput() public {
        uint256 nonce = 1;
        vm.startPrank(factory);

        vm.expectRevert("invalid token address");
        store.increaseTokenPendingRebalanceAmount(address(0), nonce, 1);

        vm.expectRevert("Invalid amount");
        store.increaseTokenPendingRebalanceAmount(address(bond), nonce, 0);

        // unauthorised caller
        vm.stopPrank();
        vm.expectRevert("Caller is not a factory contract");
        store.increaseTokenPendingRebalanceAmount(address(bond), nonce, 1);
    }

    function test_decreaseTokenPendingRebalanceAmount_success() public {
        uint256 nonce = 7;
        uint256 add = 5 ether;
        uint256 sub = 2 ether;

        vm.prank(factory);
        store.increaseTokenPendingRebalanceAmount(address(cr5), nonce, add);

        vm.prank(factory);
        store.decreaseTokenPendingRebalanceAmount(address(cr5), nonce, sub);

        assertEq(store.tokenPendingRebalanceAmount(address(cr5)), add - sub, "global counter decreased");
        assertEq(
            store.tokenPendingRebalanceAmountByNonce(address(cr5), nonce), add - sub, "per-nonce counter decreased"
        );
    }

    // function test_resetTokenPendingRebalanceAmount_and_resetAll() public {
    //     uint256 nonce = 11;
    //     uint256 amt = 3 ether;

    //     // seed some pending amounts (factory authorised)
    //     vm.prank(factory);
    //     store.increaseTokenPendingRebalanceAmount(address(bond), nonce, amt);
    //     vm.prank(factory);
    //     store.increaseTokenPendingRebalanceAmount(address(cr5), nonce, amt);

    //     // owner acts as Operator -> can call reset helpers
    //     vm.prank(store.owner());
    //     store.resetTokenPendingRebalanceAmount(address(bond), nonce);

    //     assertEq(store.tokenPendingRebalanceAmount(address(bond)), 0, "bond reset");
    //     assertEq(store.tokenPendingRebalanceAmountByNonce(address(bond), nonce), 0, "bond reset-nonce");

    //     // reset *all* remaining (will clear CR-5 entry)
    //     vm.prank(store.owner());
    //     store.resetAllTokenPendingRebalanceAmount(nonce);

    //     assertEq(store.tokenPendingRebalanceAmount(address(cr5)), 0, "cr5 reset by resetAll");
    //     assertEq(store.tokenPendingRebalanceAmountByNonce(address(cr5), nonce), 0, "cr5 reset-nonce");
    // }

    function test_decreaseTokenPendingRebalanceAmount_revertsOnBadInput() public {
        uint256 nonce = 99;
        address token = address(bond);
        uint256 add = 5 ether;
        uint256 sub = 10 ether;

        vm.prank(factory);
        store.increaseTokenPendingRebalanceAmount(token, nonce, add);

        vm.prank(factory);
        vm.expectRevert("invalid token address");
        store.decreaseTokenPendingRebalanceAmount(address(0), nonce, 1);

        vm.prank(factory);
        vm.expectRevert("Invalid amount");
        store.decreaseTokenPendingRebalanceAmount(token, nonce, 0);

        vm.prank(factory);
        vm.expectRevert("Insufficient pending rebalance amount");
        store.decreaseTokenPendingRebalanceAmount(token, nonce, sub);

        vm.expectRevert("Caller is not a factory contract");
        store.decreaseTokenPendingRebalanceAmount(token, nonce, 1);
    }
}
