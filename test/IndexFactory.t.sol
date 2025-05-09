// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IndexToken} from "../src/token/IndexToken.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {Vault} from "../src/vault/Vault.sol";
import {LinkToken} from "./helpers/LinkToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/factory/FunctionsOracle.sol";
import "./OlympixUnitTest.sol";

error ZeroAmount();

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address t, uint256 a) external {
        _mint(t, a);
    }
}

contract MockBERNX is ERC20("Bernx", "BERNX") {
    function mint(address t, uint256 a) external {
        _mint(t, a);
    }
}

contract MockIDXc5 is ERC20("Crypto-5", "IDXc5") {
    function mint(address t, uint256 a) external {
        _mint(t, a);
    }
}

contract DummyCrypto5Factory {
    MockIDXc5 public immutable idxc5;

    constructor(address _idxc5) {
        idxc5 = MockIDXc5(_idxc5);
    }

    function issuanceIndexTokens(address, address[] calldata, uint24[] calldata, uint256 amt) external {
        idxc5.mint(msg.sender, amt);
    }

    function redemption(uint256, address, address[] calldata, uint24[] calldata) external {}
}

contract TestFunctionsOracle is FunctionsOracle {
    function seed(address[] calldata comps, uint256[] calldata shares) external {
        _initData(comps, shares);
    }
}

contract DummyReceiver {}

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract IndexFactoryTest is OlympixUnitTest("IndexFactory") {
    address owner = address(this);
    address feeRec = vm.addr(1);
    address nexBot = vm.addr(2);
    address alice = vm.addr(3);
    address bob = vm.addr(4);

    MockUSDC usdc;
    MockBERNX bernx;
    MockIDXc5 idxc5;
    DummyCrypto5Factory cr5;
    IndexToken idx;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;
    IndexFactory factory;
    Vault vault;
    TestFunctionsOracle oracle;
    LinkToken link;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        bernx = new MockBERNX();
        idxc5 = new MockIDXc5();
        cr5 = new DummyCrypto5Factory(address(idxc5));

        vault = Vault(address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (owner)))));

        idx = IndexToken(
            address(
                new ERC1967Proxy(
                    address(new IndexToken()),
                    abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, feeRec, 10_000_000 ether))
                )
            )
        );

        store = IndexFactoryStorage(address(new ERC1967Proxy(address(new IndexFactoryStorage()), "")));

        sca = StagingCustodyAccount(payable(address(new ERC1967Proxy(address(new StagingCustodyAccount()), ""))));

        factory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));

        oracle = TestFunctionsOracle(payable(address(new ERC1967Proxy(address(new TestFunctionsOracle()), ""))));

        address[] memory comps = new address[](2);
        uint256[] memory shares = new uint256[](2);
        comps[0] = address(bernx);
        shares[0] = 80e18;
        comps[1] = address(idxc5);
        shares[1] = 20e18;
        oracle.seed(comps, shares);

        link = new LinkToken();

        store.initialize(
            address(idx),
            address(factory),
            address(oracle),
            address(sca),
            address(vault),
            nexBot,
            address(cr5),
            address(usdc),
            address(bernx),
            false
        );
        store.setFeeReceiver(feeRec);

        sca.initialize(address(store));
        vault.setOperator(address(sca), true);
        sca.transferOwnership(address(factory));
        factory.initialize(address(store));

        idx.setMinter(owner, true);

        usdc.mint(alice, 1_000_000 * ONE_USDC);
        usdc.mint(bob, 1_000_000 * ONE_USDC);
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(factory), type(uint256).max);
    }

    function testIncreaseRoundIdNonOwnerAddr() public {
        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        factory.increaseCurrentRoundId();
    }

    function testCancelIssuanceWithNonRequesterAddress() public {
        uint256 inputAmount = 10e18;
        deal(address(usdc), alice, 20e18);
        vm.startPrank(alice);
        IERC20(usdc).approve(address(factory), inputAmount + 1e16);
        factory.issuanceIndexToken(inputAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("Only requester can cancel");
        factory.cancelIssuance(1);
        vm.stopPrank();
    }

    function testIssuanceHappyPath() public {
        uint256 inAmt = 10_000 * ONE_USDC;
        uint256 fee = inAmt * store.feeRate() / 10_000;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), inAmt, 0, block.timestamp);
        uint256 nonce = factory.issuanceIndexToken(inAmt);

        assertEq(nonce, 1);
        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), inAmt);
        assertEq(usdc.balanceOf(feeRec), fee);
    }

    function testIssuanceZeroRevert() public {
        vm.expectRevert(ZeroAmount.selector);
        factory.issuanceIndexToken(0);
    }

    function test_cancelIssuance_FailWhenIssuanceIsCompleted() public {
        uint256 inAmt = 10_000 * ONE_USDC;

        vm.prank(alice);
        uint256 nonce = factory.issuanceIndexToken(inAmt);

        vm.prank(address(this));
        store.settleIssuance(1);

        vm.prank(alice);
        vm.expectRevert("Issuance is completed");
        factory.cancelIssuance(nonce);
    }

    function test_cancelIssuance_FailWhenSenderIsNotRequester() public {
        uint256 inAmt = 10_000 * ONE_USDC;

        vm.prank(alice);
        uint256 nonce = factory.issuanceIndexToken(inAmt);

        vm.prank(address(this));
        vm.expectRevert("Only requester can cancel");
        factory.cancelIssuance(nonce);
    }

    function test_increaseCurrentRoundId_FailWhenSenderIsNotOwnerOrOperator() public {
        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        factory.increaseCurrentRoundId();
        vm.stopPrank();
    }

    function test_increaseCurrentRoundId_SuccessfulIncreaseCurrentRoundId() public {
        vm.prank(address(this));
        factory.increaseCurrentRoundId();
        assertEq(store.currentRoundId(), 2);
    }

    function test_redemption_FailWhenAmountIsInvalid() public {
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        factory.redemption(0);
        vm.stopPrank();
    }

    function test_increaseRoundId_requiresOwnerOrOperator() public {
        vm.prank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        factory.increaseCurrentRoundId();
    }

    function testIssuance_HappyPath() public {
        uint256 amount = 10_000 * ONE_USDC;
        uint256 fee = amount * store.feeRate() / 10_000;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), amount, 0, block.timestamp);
        factory.issuanceIndexToken(amount);

        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), amount);
        assertEq(usdc.balanceOf(feeRec), fee);
        assertEq(store.issuanceInputAmount(1), amount);
    }

    function testIssuance_zeroReverts() public {
        vm.expectRevert(ZeroAmount.selector);
        factory.issuanceIndexToken(0);
    }

    // function testCancelIssuance_HappyPath() public {
    //     uint256 amt = 5_000 * ONE_USDC;
    //     vm.prank(alice);
    //     uint256 n = factory.issuanceIndexToken(amt);

    //     uint256 balBefore = usdc.balanceOf(alice);
    //     vm.prank(alice);
    //     factory.cancelIssuance(n);
    //     uint256 balAfter = usdc.balanceOf(alice);

    //     assertEq(balAfter - balBefore, amt, "refund missing");
    //     assertTrue(store.issuanceIsCompleted(n));
    // }

    function _mintAndApproveIdx(address user, uint256 qty) internal {
        idx.mint(user, qty);
        vm.prank(user);
        idx.approve(address(factory), qty);
    }

    function testRedemption_HappyPath() public {
        uint256 aliceIdx = 80 ether;
        uint256 bobIdx = 20 ether;

        _mintAndApproveIdx(alice, aliceIdx);
        _mintAndApproveIdx(bob, bobIdx);

        vm.prank(alice);
        uint256 n1 = factory.redemption(aliceIdx);

        vm.prank(bob);
        uint256 n2 = factory.redemption(bobIdx);

        assertEq(n2, 2);
        assertEq(factory.redemptionNonce(), 2);

        assertEq(idx.balanceOf(address(sca)), aliceIdx + bobIdx);

        assertEq(store.totalRedemptionByRound(1), aliceIdx + bobIdx);
        assertEq(store.redemptionAmountByRoundUser(1, alice), aliceIdx);
        assertEq(store.redemptionAmountByRoundUser(1, bob), bobIdx);
    }

    function testRedemption_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        factory.redemption(0);
    }

    function testCancelIssuance_failsIfCompleted() public {
        vm.prank(alice);
        uint256 n = factory.issuanceIndexToken(1_000 * ONE_USDC);

        vm.prank(address(this));
        store.settleIssuance(1);

        vm.prank(alice);
        vm.expectRevert("Issuance is completed");
        factory.cancelIssuance(n);
    }

    function testCancelIssuance_nonRequesterReverts() public {
        vm.prank(alice);
        uint256 n = factory.issuanceIndexToken(1_000 * ONE_USDC);

        vm.prank(bob);
        vm.expectRevert("Only requester can cancel");
        factory.cancelIssuance(n);
    }

    function testIssuance_updatesStorageAndRoundData() public {
        uint256 amt = 25_000 * ONE_USDC;
        uint256 fee = amt * store.feeRate() / 10_000;

        vm.prank(alice);
        uint256 n = factory.issuanceIndexToken(amt);

        assertEq(n, 1);
        assertEq(factory.issuanceNonce(), 1);

        assertEq(usdc.balanceOf(address(sca)), amt);
        assertEq(usdc.balanceOf(feeRec), fee);

        assertEq(store.totalIssuanceByRound(1), amt);
        assertEq(store.issuanceAmountByRoundUser(1, alice), amt);
        assertEq(store.issuanceInputAmount(n), amt);
        assertEq(store.issuanceRequesterByNonce(n), alice);
        assertEq(store.roundIdIsActive(1), true);
    }

    function testIssuance_feeChargedExactly() public {
        uint256 amt = 42_000 * ONE_USDC;
        uint256 fee = amt * store.feeRate() / 10_000;

        uint256 before = usdc.balanceOf(feeRec);
        vm.prank(alice);
        factory.issuanceIndexToken(amt);
        uint256 afterBal = usdc.balanceOf(feeRec);

        assertEq(afterBal - before, fee, "fee mismatch");
    }

    function testIssuance_emitsCorrectEvent() public {
        uint256 amt = 5_555 * ONE_USDC;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), amt, 0, block.timestamp);
        factory.issuanceIndexToken(amt);
    }

    function testCancelIssuance_HappyPath() public {
        uint256 amt = 8_000 * ONE_USDC;

        vm.prank(alice);
        uint256 nonce = factory.issuanceIndexToken(amt);

        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.cancelIssuance(nonce);

        uint256 balAfter = usdc.balanceOf(alice);
        assertEq(balAfter - balBefore, amt, "refund missing");

        assertTrue(store.issuanceIsCompleted(nonce));
        assertEq(store.totalIssuanceByRound(1), 0);
        assertEq(store.roundIdIsActive(1), false);
    }

    function testFullIssuanceFlow_Single() public {
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(sca), true);
        vm.stopPrank();

        vm.startPrank(idx.owner());
        idx.setMinter(address(sca), true);
        vm.stopPrank();
        // oracle.setOperator(address(sca), true);
        // idx.setMinter(address(sca), true);

        uint256 inAmt = 100_000 * ONE_USDC;

        vm.prank(alice);
        factory.issuanceIndexToken(inAmt);
        assertEq(usdc.balanceOf(address(sca)), inAmt);

        vm.prank(nexBot);
        sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

        uint256 toBot = inAmt * 80 / 100;
        assertEq(usdc.balanceOf(nexBot), toBot);

        uint256 bernQty = 50_000 ether;
        bernx.mint(address(sca), bernQty);

        // uint256 mintQty = 1_000 ether;
        // uint256 bernxPrice = 2e18;
        // uint256 c5Price = 1e18;
        // vm.prank(nexBot);
        // sca.distributeTokens(1, bernxPrice, c5Price);

        uint256 bernxPrice = 2e18; // 2 USD  (18-dec)
        uint256 c5Price = 1e18; // 1 USD
        uint256 expectedMint = sca.calculateMintAmount(1, bernxPrice, c5Price);
        vm.prank(nexBot);
        sca.distributeTokens(1, bernxPrice, c5Price);

        // assertEq(idx.balanceOf(alice), mintQty);
        assertEq(idx.balanceOf(alice), expectedMint);
        assertEq(bernx.balanceOf(address(vault)), bernQty);
        assertEq(idxc5.balanceOf(address(vault)), inAmt / 5);

        assertTrue(store.issuanceIsCompleted(1));
    }

    function testFullIssuanceFlow_ThreeUsers() public {
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(sca), true);
        vm.stopPrank();

        vm.startPrank(idx.owner());
        idx.setMinter(address(sca), true);
        vm.stopPrank();
        // oracle.setOperator(address(sca), true);
        // idx.setMinter(address(sca), true);

        address carol = vm.addr(9);
        usdc.mint(carol, 1_000_000 * ONE_USDC);
        vm.prank(carol);
        usdc.approve(address(factory), type(uint256).max);

        uint256 aAmt = 60_000 * ONE_USDC;
        uint256 bAmt = 30_000 * ONE_USDC;
        uint256 cAmt = 10_000 * ONE_USDC;
        uint256 totalIn = aAmt + bAmt + cAmt;

        vm.prank(alice);
        factory.issuanceIndexToken(aAmt);
        vm.prank(bob);
        factory.issuanceIndexToken(bAmt);
        vm.prank(carol);
        factory.issuanceIndexToken(cAmt);

        vm.prank(nexBot);
        sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

        bernx.mint(address(sca), 77_000 ether);

        // uint256 mintQty = 1_000 ether;
        // uint256 bernxPrice = 2e18;
        // uint256 c5Price = 1e18;
        uint256 bernxPrice = 2e18; // 2 USD
        uint256 c5Price = 1e18; // 1 USD
        uint256 expectedMint = sca.calculateMintAmount(1, bernxPrice, c5Price);
        vm.prank(nexBot);
        sca.distributeTokens(1, bernxPrice, c5Price);

        // assertEq(idx.balanceOf(alice), mintQty * aAmt / totalIn);
        // assertEq(idx.balanceOf(bob), mintQty * bAmt / totalIn);
        // assertEq(idx.balanceOf(carol), mintQty * cAmt / totalIn);

        assertEq(idx.balanceOf(alice), expectedMint * aAmt / totalIn);
        assertEq(idx.balanceOf(bob), expectedMint * bAmt / totalIn);
        assertEq(idx.balanceOf(carol), expectedMint * cAmt / totalIn);

        assertEq(idxc5.balanceOf(address(vault)), totalIn / 5);
        assertTrue(store.issuanceIsCompleted(1));
    }

    // function testFullIssuanceFlow() public {
    //     vm.startPrank(oracle.owner());
    //     oracle.setOperator(address(sca), true);
    //     vm.stopPrank();

    //     vm.startPrank(idx.owner());
    //     idx.setMinter(address(sca), true);
    //     vm.stopPrank();

    //     uint256 inAmt = 100_000 * ONE_USDC;

    //     vm.prank(alice);
    //     uint256 nonce = factory.issuanceIndexToken(inAmt);
    //     assertEq(nonce, 1);

    //     assertEq(usdc.balanceOf(address(sca)), inAmt);

    //     uint256 scaBalBefore = usdc.balanceOf(address(sca));

    //     vm.prank(nexBot);
    //     sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

    //     uint256 eighties = (inAmt * 80) / 100;
    //     assertEq(usdc.balanceOf(nexBot), eighties);
    //     assertEq(usdc.balanceOf(address(sca)) + eighties, scaBalBefore, "unexpected USDC delta");

    //     assertEq(store.currentRoundId(), 2);

    //     uint256 mintAmt = 1_000 ether;

    //     vm.prank(nexBot);
    //     sca.distributeTokens(mintAmt, 1);

    //     assertEq(idx.balanceOf(alice), mintAmt);

    //     assertTrue(store.issuanceIsCompleted(1));
    //     assertEq(store.totalIssuanceByRound(1), 0);
    // }

    // function testFullIssuanceFlow_Multi() public {
    //     vm.startPrank(oracle.owner());
    //     oracle.setOperator(address(sca), true);
    //     vm.stopPrank();

    //     vm.startPrank(idx.owner());
    //     idx.setMinter(address(sca), true);
    //     vm.stopPrank();

    //     address carol = vm.addr(9);
    //     usdc.mint(carol, 1_000_000 * ONE_USDC);
    //     vm.prank(carol);
    //     usdc.approve(address(factory), type(uint256).max);

    //     uint256 aAmt = 60_000 * ONE_USDC;
    //     uint256 bAmt = 30_000 * ONE_USDC;
    //     uint256 cAmt = 10_000 * ONE_USDC;

    //     vm.prank(alice);
    //     factory.issuanceIndexToken(aAmt);
    //     vm.prank(bob);
    //     factory.issuanceIndexToken(bAmt);
    //     vm.prank(carol);
    //     factory.issuanceIndexToken(cAmt);

    //     uint256 totalIn = aAmt + bAmt + cAmt;
    //     assertEq(usdc.balanceOf(address(sca)), totalIn, "all USDC parked in SCA");

    //     uint256 beforeBot = usdc.balanceOf(nexBot);

    //     vm.prank(nexBot);
    //     sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

    //     uint256 expectedToBot = (totalIn * 80) / 100;
    //     assertEq(usdc.balanceOf(nexBot) - beforeBot, expectedToBot, "80 % to bot");
    //     assertEq(store.currentRoundId(), 2, "round id bumped");

    //     idx.setMinter(address(sca), true);

    //     uint256 mintAmt = 1_000 ether;
    //     vm.prank(nexBot);
    //     sca.distributeTokens(mintAmt, 1);

    //     uint256 aliceShare = (mintAmt * aAmt) / totalIn;
    //     uint256 bobShare = (mintAmt * bAmt) / totalIn;
    //     uint256 carolShare = (mintAmt * cAmt) / totalIn;

    //     assertEq(idx.balanceOf(alice), aliceShare);
    //     assertEq(idx.balanceOf(bob), bobShare);
    //     assertEq(idx.balanceOf(carol), carolShare);
    //     assertTrue(store.issuanceIsCompleted(1), "round settled");
    // }
}
