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

error ZeroAmount();

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockBernx is ERC20("Bernx", "Bernx") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract DummyReceiver {}

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract IndexFactoryTest is Test {
    address owner = address(this);
    address feeRec = vm.addr(1);
    address nexBot = vm.addr(2);
    address oracle = vm.addr(3);
    address alice = vm.addr(4);
    address bob = vm.addr(5);

    MockUSDC usdc;
    MockBernx bernx;
    IndexToken idx;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;
    IndexFactory factory;
    Vault vault;
    LinkToken link;

    MockERC20 token0;
    MockERC20 token1;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        bernx = new MockBernx();

        {
            Vault impl = new Vault();
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (address(this))));
            vault = Vault(address(proxy));
        }

        {
            IndexToken impl = new IndexToken();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, feeRec, 10_000_000 ether))
            );
            idx = IndexToken(address(proxy));
        }

        {
            IndexFactoryStorage impl = new IndexFactoryStorage();
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
            store = IndexFactoryStorage(address(proxy));
        }

        {
            StagingCustodyAccount impl = new StagingCustodyAccount();
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
            sca = StagingCustodyAccount(payable(address(proxy)));
        }

        {
            IndexFactory impl = new IndexFactory();
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
            factory = IndexFactory(address(proxy));
        }

        DummyOracle OR = new DummyOracle();

        store.initialize(
            address(idx),
            address(factory),
            address(OR),
            address(sca),
            address(vault),
            nexBot,
            address(0),
            address(usdc),
            false
        );

        link = new LinkToken();

        store.setFeeReceiver(feeRec);

        sca.initialize(address(store));

        vault.setOperator(address(sca), true);

        sca.transferOwnership(address(factory));

        // sca = StagingCustodyAccount(payable(address(proxy)));

        factory.initialize(address(store));

        idx.setMinter(address(this), true);
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

    function updateOracleList() public view {
        address[] memory assetList = new address[](10);
        assetList[0] = address(token0);
        assetList[1] = address(token1);

        uint256[] memory tokenShares = new uint256[](10);
        tokenShares[0] = 10e18;
        tokenShares[1] = 10e18;
        tokenShares[2] = 10e18;
        tokenShares[3] = 10e18;
        tokenShares[4] = 10e18;
        tokenShares[5] = 10e18;
        tokenShares[6] = 10e18;
        tokenShares[7] = 10e18;
        tokenShares[8] = 10e18;
        tokenShares[9] = 10e18;

        // link.transfer(address(functionsOracle), 1e17);
        // // bytes32 requestId = factoryStorage.requestAssetsData();
        // // oracle.fulfillOracleFundingRateRequest(requestId, assetList, tokenShares);
        // bytes32 requestId = functionsOracle.requestAssetsData("console.log('Hello, World!');", 0, 0);
        // bytes memory data = abi.encode(assetList, tokenShares);
        // oracle.fulfillRequest(address(functionsOracle), requestId, data);
    }
}
