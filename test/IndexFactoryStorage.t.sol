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
        vm.expectRevert("Invalid _riskAssetFactoryAddress address");
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

    function test_setFeeRate_Require12HoursSinceLastUpdate() public {
        vm.startPrank(owner);
        store.latestFeeUpdate();
        uint256 nowTime = 1000000;
        vm.warp(nowTime);
        store.setFeeRate(10);
        vm.expectRevert("You should wait at least 12 hours after the latest update");
        store.setFeeRate(20);
        vm.warp(nowTime + 43200);
        store.setFeeRate(30);
        assertEq(store.feeRate(), 30);
        vm.stopPrank();
    }

    function test_setRedemptionFeeByNonce_SuccessWhenSenderIsFactory() public {
        uint256 nonce = 1;
        uint256 fee = 1234;
        assertEq(store.redemptionFeeByNonce(nonce), 0);
        vm.prank(factory);
        store.setRedemptionFeeByNonce(nonce, fee);
        assertEq(store.redemptionFeeByNonce(nonce), fee);
    }

    function test_setIssuanceRequestCancelled_SuccessWhenSenderIsFactory() public {
        uint256 nonce = 123;
        assertEq(store.issuanceRequestCancelled(nonce), false);
        vm.prank(factory);
        store.setIssuanceRequestCancelled(nonce, true);
        assertEq(store.issuanceRequestCancelled(nonce), true);
    }

    function test_setRedemptionRequestCancelled_SuccessWhenSenderIsFactory() public {
        uint256 nonce = 456;
        assertEq(store.redemptionRequestCancelled(nonce), false);
        vm.prank(factory);
        store.setRedemptionRequestCancelled(nonce, true);
        assertEq(store.redemptionRequestCancelled(nonce), true);
    }

    function test_undoIssuanceForRound_RequireElseBranch() public {
        address charlie = vm.addr(6);
        uint256 nonce = 1;
        uint256 roundId = 1;
        uint256 amount = 100;
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, amount);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(charlie, amount);
        vm.prank(factory);
        store.undoIssuanceForRound(roundId, nonce, alice, amount);
        assertEq(store.issuanceAmountByRoundUser(roundId, alice), 0);
        assertEq(store.issuanceAmountByRoundUser(roundId, charlie), amount);
        address[] memory list = store.addressesInIssuanceRound(roundId);
        assertEq(list.length, 1);
        assertEq(list[0], charlie);
    }

    function test_undoIssuanceForRound_elseBranch() public {
        address charlie = vm.addr(6);
        uint256 nonce = 1;
        uint256 roundId = 1;
        uint256 amount = 100;
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, amount);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, amount); // alice now has 200
        vm.prank(factory);
        store.addIssuanceForCurrentRound(charlie, amount);
        vm.prank(factory);
        store.undoIssuanceForRound(roundId, nonce, alice, amount); // alice will have 100 left
        address[] memory list = store.addressesInIssuanceRound(roundId);
        assertEq(list.length, 2);
        bool foundAlice = false;
        bool foundCharlie = false;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == alice) foundAlice = true;
            if (list[i] == charlie) foundCharlie = true;
        }
        assertTrue(foundAlice, "alice should remain");
        assertTrue(foundCharlie, "charlie should remain");
        assertEq(store.issuanceAmountByRoundUser(roundId, alice), 100);
        assertEq(store.issuanceAmountByRoundUser(roundId, charlie), 100);
    }

    function test_pruneAddressFromIssuance_elseBranch() public {
        address charlie = vm.addr(6);
        address dave = vm.addr(7);
        uint256 nonce = 1;
        uint256 roundId = 1;
        uint256 amount = 100;
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, amount);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(charlie, amount);
        vm.prank(factory);
        store.addIssuanceForCurrentRound(dave, amount);
        vm.prank(factory);
        store.undoIssuanceForRound(roundId, nonce, dave, amount);
        address[] memory list = store.addressesInIssuanceRound(roundId);
        assertEq(list.length, 2);
        bool foundAlice = false;
        bool foundCharlie = false;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == alice) foundAlice = true;
            if (list[i] == charlie) foundCharlie = true;
        }
        assertTrue(foundAlice, "alice should remain");
        assertTrue(foundCharlie, "charlie should remain");
        // dave should be gone
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(list[i] != dave, "dave should be pruned");
        }
    }

    function test_removeIssuanceNonce_successfulRemove() public {
        uint256 roundId = 1;
        uint256 nonce = 99;
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 100);
        vm.prank(factory);
        store.addNonceToIssuanceRound(roundId, nonce);
        uint256[] memory beforeArr = store.getIssuanceRoundIdToNonces(roundId);
        bool found = false;
        for (uint256 i = 0; i < beforeArr.length; ++i) {
            if (beforeArr[i] == nonce) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Nonce should be present before removal");
        vm.prank(factory);
        store.removeIssuanceNonce(roundId, nonce);
        uint256[] memory afterArr = store.getIssuanceRoundIdToNonces(roundId);
        for (uint256 i = 0; i < afterArr.length; ++i) {
            assertTrue(afterArr[i] != nonce, "Nonce should be removed");
        }
    }

    function test_removeIssuanceNonce_elseBranch() public {
        uint256 roundId = 1;
        uint256 nonce1 = 100;
        uint256 nonce2 = 200;
        uint256 nonce3 = 300;
        vm.prank(factory);
        store.addNonceToIssuanceRound(roundId, nonce1);
        vm.prank(factory);
        store.addNonceToIssuanceRound(roundId, nonce2);
        vm.prank(factory);
        store.addNonceToIssuanceRound(roundId, nonce3);
        uint256[] memory before = store.getIssuanceRoundIdToNonces(roundId);
        assertEq(before.length, 3);
        assertEq(before[0], nonce1);
        assertEq(before[1], nonce2);
        assertEq(before[2], nonce3);
        vm.prank(factory);
        store.removeIssuanceNonce(roundId, nonce2);
        uint256[] memory afterArr = store.getIssuanceRoundIdToNonces(roundId);
        assertEq(afterArr.length, 2);
        bool found1 = false;
        bool found3 = false;
        for (uint256 i = 0; i < afterArr.length; ++i) {
            if (afterArr[i] == nonce1) found1 = true;
            if (afterArr[i] == nonce3) found3 = true;
        }
        assertTrue(found1, "nonce1 should remain");
        assertTrue(found3, "nonce3 should remain");
    }

    function test_undoRedemption_requireElseBranch() public {
        uint256 roundId = 1;
        uint256 nonce = 77;
        uint256 amount = 100;
        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, amount);
        store.addRedemptionForCurrentRound(alice, amount);
        store.undoRedemptionForRound(roundId, nonce, alice, amount);
        vm.stopPrank();
        address[] memory list = store.addressesInRedemptionRound(roundId);
        assertEq(list.length, 1);
        assertEq(list[0], alice);
        assertEq(store.redemptionAmountByRoundUser(roundId, alice), 100);
    }

    function test_undoRedemptionForRound_pruneAddressWhenRedemptionAmountIsZero() public {
        uint256 roundId = 1;
        uint256 nonce = 77;
        uint256 amountAlice = 100;
        uint256 amountBob = 50;
        vm.prank(factory);
        store.addRedemptionForCurrentRound(alice, amountAlice);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(bob, amountBob);
        vm.prank(factory);
        store.undoRedemptionForRound(roundId, nonce, alice, amountAlice);
        assertEq(store.redemptionAmountByRoundUser(roundId, alice), 0);
        assertEq(store.redemptionAmountByRoundUser(roundId, bob), amountBob);
        address[] memory list = store.addressesInRedemptionRound(roundId);
        assertEq(list.length, 1);
        assertEq(list[0], bob);
    }

    function test__pruneAddressFromRedemption_elseBranch() public {
        uint256 roundId = 1;
        address user1 = alice;
        address user2 = bob;
        address user3 = vm.addr(0xDEAD);
        uint256 nonce = 42;
        // Add user1, user2, user3 to the round
        vm.prank(factory);
        store.addRedemptionForCurrentRound(user1, 100);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(user2, 50);
        vm.prank(factory);
        store.addRedemptionForCurrentRound(user3, 25);
        vm.prank(factory);
        store.undoRedemptionForRound(roundId, nonce, user3, 25);
        address[] memory list = store.addressesInRedemptionRound(roundId);
        assertEq(list.length, 2);
        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == user1) found1 = true;
            if (list[i] == user2) found2 = true;
        }
        assertTrue(found1, "user1 should remain");
        assertTrue(found2, "user2 should remain");
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(list[i] != user3, "user3 should be pruned");
        }
    }

    function test_removeRedemptionNonce_revertsForUnauthorizedCaller() public {
        uint256 roundId = 1;
        uint256 nonce = 42;
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce);
        vm.prank(alice);
        vm.expectRevert("Caller is not a factory contract");
        store.removeRedemptionNonce(roundId, nonce);
    }

    function test_removeRedemptionNonce_success_authorized() public {
        uint256 roundId = 1;
        uint256 nonce1 = 42;
        uint256 nonce2 = 43;
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce1);
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce2);
        uint256[] memory before = store.getRedemptionRoundIdToNonces(roundId);
        assertEq(before.length, 2);
        assertEq(before[0], nonce1);
        assertEq(before[1], nonce2);
        vm.prank(factory);
        store.removeRedemptionNonce(roundId, nonce1);
        uint256[] memory afterArr = store.getRedemptionRoundIdToNonces(roundId);
        assertEq(afterArr.length, 1);
        assertEq(afterArr[0], nonce2);
    }

    function test_removeRedemptionNonce_elseBranch() public {
        uint256 roundId = 1;
        uint256 nonce1 = 100;
        uint256 nonce2 = 200;
        uint256 nonce3 = 300;
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce1);
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce2);
        vm.prank(factory);
        store.addNonceToRedemptionRound(roundId, nonce3);
        // Confirm all are present
        uint256[] memory before = store.getRedemptionRoundIdToNonces(roundId);
        assertEq(before.length, 3);
        assertEq(before[0], nonce1);
        assertEq(before[1], nonce2);
        assertEq(before[2], nonce3);
        vm.prank(factory);
        store.removeRedemptionNonce(roundId, nonce2);
        uint256[] memory afterArr = store.getRedemptionRoundIdToNonces(roundId);
        assertEq(afterArr.length, 2);
        bool found1 = false;
        bool found3 = false;
        for (uint256 i = 0; i < afterArr.length; ++i) {
            if (afterArr[i] == nonce1) found1 = true;
            if (afterArr[i] == nonce3) found3 = true;
        }
        assertTrue(found1, "nonce1 should remain");
        assertTrue(found3, "nonce3 should remain");
    }
}
