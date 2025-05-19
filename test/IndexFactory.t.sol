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
import {Token} from "./helpers/Token.sol";
import "../src/factory/FunctionsOracle.sol";
import "./OlympixUnitTest.sol";

error ZeroAmount();

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address t, uint256 a) external {
        _mint(t, a);
    }
}

contract MockBond is ERC20("Bond", "BND") {
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
    MockBond bond;
    MockIDXc5 idxc5;
    DummyCrypto5Factory cr5;
    IndexToken idx;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;
    IndexFactory factory;
    Vault vault;
    TestFunctionsOracle oracle;
    // FunctionsOracle oracle;
    LinkToken link;
    Token token0;
    Token token1;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
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
        comps[0] = address(bond);
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
            address(bond),
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
        uint256 pureAmount = inAmt - (inAmt * 10) / 10000;
        uint256 fee = (inAmt * 10) / 10000;
        // uint256 fee = inAmt * store.feeRate() / 10_000;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), pureAmount, 0, block.timestamp);
        uint256 nonce = factory.issuanceIndexToken(inAmt);

        assertEq(nonce, 1);
        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), pureAmount);
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
        assertEq(store.issuanceRoundId(), 2);
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
        uint256 pureAmount = amount - (amount * 10) / 10000;
        uint256 fee = (amount * 10) / 10000;
        // uint256 fee = amount * store.feeRate() / 10_000;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), pureAmount, 0, block.timestamp);
        factory.issuanceIndexToken(amount);

        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), pureAmount);
        assertEq(usdc.balanceOf(feeRec), fee);
        assertEq(store.issuanceInputAmount(1), pureAmount);
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
        uint256 fee = (amt * 10) / 10000;
        uint256 pureAmount = amt - (amt * 10) / 10000;

        vm.prank(alice);
        uint256 n = factory.issuanceIndexToken(amt);

        assertEq(n, 1);
        assertEq(factory.issuanceNonce(), 1);

        assertEq(usdc.balanceOf(address(sca)), pureAmount);
        assertEq(usdc.balanceOf(feeRec), fee);

        assertEq(store.totalIssuanceByRound(1), pureAmount);
        assertEq(store.issuanceAmountByRoundUser(1, alice), pureAmount);
        assertEq(store.issuanceInputAmount(n), pureAmount);
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
        uint256 pureAmount = amt - (amt * 10) / 10000;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(1, alice, address(usdc), pureAmount, 0, block.timestamp);
        factory.issuanceIndexToken(amt);
    }

    function testCancelIssuance_HappyPath() public {
        uint256 amt = 8_000 * ONE_USDC;
        uint256 pureAmount = amt - (amt * 10) / 10000;

        vm.prank(alice);
        uint256 nonce = factory.issuanceIndexToken(amt);

        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        factory.cancelIssuance(nonce);

        uint256 balAfter = usdc.balanceOf(alice);
        assertEq(balAfter - balBefore, pureAmount, "refund missing");

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
        uint256 pureAmount = inAmt - (inAmt * 10) / 10000;

        vm.prank(alice);
        factory.issuanceIndexToken(inAmt);
        assertEq(usdc.balanceOf(address(sca)), pureAmount);

        vm.prank(nexBot);
        sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

        uint256 toBot = pureAmount * 80 / 100;
        assertEq(usdc.balanceOf(nexBot), toBot);

        uint256 bernQty = 50_000 ether;
        bond.mint(address(sca), bernQty);

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        // uint256 expectedMint = sca.calculateMintAmount(1, bondPrice, c5Price);
        vm.prank(nexBot);
        sca.settleIssuance(1, bondPrice, c5Price);

        // assertEq(idx.balanceOf(alice), expectedMint);
        assertEq(bond.balanceOf(address(vault)), bernQty);
        assertEq(idxc5.balanceOf(address(vault)), pureAmount / 5);

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
        uint256 pureAAmount = aAmt - (aAmt * 10) / 10000;
        uint256 bAmt = 30_000 * ONE_USDC;
        uint256 pureBAmount = bAmt - (bAmt * 10) / 10000;
        uint256 cAmt = 10_000 * ONE_USDC;
        uint256 pureCAmount = cAmt - (cAmt * 10) / 10000;
        uint256 totalIn = pureAAmount + pureBAmount + pureCAmount;

        vm.prank(alice);
        factory.issuanceIndexToken(aAmt);
        vm.prank(bob);
        factory.issuanceIndexToken(bAmt);
        vm.prank(carol);
        factory.issuanceIndexToken(cAmt);

        vm.prank(nexBot);
        sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

        bond.mint(address(sca), 77_000 ether);

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        // uint256 expectedMint = sca.calculateMintAmount(1, bondPrice, c5Price);
        vm.prank(nexBot);
        sca.settleIssuance(1, bondPrice, c5Price);

        // assertEq(idx.balanceOf(alice), expectedMint * pureAAmount / totalIn);
        // assertEq(idx.balanceOf(bob), expectedMint * pureBAmount / totalIn);
        // assertEq(idx.balanceOf(carol), expectedMint * pureCAmount / totalIn);

        assertEq(idxc5.balanceOf(address(vault)), totalIn / 5);
        assertTrue(store.issuanceIsCompleted(1));
    }

    function test_cancelIssuance_revertsWhenAmtIsZero() public {
        vm.prank(address(factory));
        store.setIssuanceRequesterByNonce(1, alice);

        vm.startPrank(alice);
        vm.expectRevert("nothing to refund");
        factory.cancelIssuance(1);
        vm.stopPrank();
    }

    // function updateOracleList() public {
    //     address[] memory assetList = new address[](10);
    //     assetList[0] = address(token0);
    //     assetList[1] = address(token1);

    //     uint256[] memory tokenShares = new uint256[](10);
    //     tokenShares[0] = 80e18;
    //     tokenShares[1] = 20e18;

    //     link.transfer(address(oracle), 1e17);
    //     // bytes32 requestId = factoryStorage.requestAssetsData();
    //     // oracle.fulfillOracleFundingRateRequest(requestId, assetList, tokenShares);
    //     bytes32 requestId = oracle.requestAssetsData("console.log('Hello, World!');", 0, 0);
    //     bytes memory data = abi.encode(assetList, tokenShares);
    //     oracle.fulfillRequest(address(oracle), requestId, data);
    // }
}
