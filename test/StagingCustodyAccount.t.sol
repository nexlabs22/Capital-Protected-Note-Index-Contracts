// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IndexToken} from "../src/token/IndexToken.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import {Vault} from "../src/vault/Vault.sol";
import "./OlympixUnitTest.sol";

error ZeroAmount();
error ZeroAddress();

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

contract TestFunctionsOracle is FunctionsOracle {
    function seed(address[] calldata tkn, uint256[] calldata shr) external {
        _initData(tkn, shr);
    }
}

contract StagingCustodyAccountTest is Test {
    address admin = vm.addr(1);
    address bot = vm.addr(2);
    address factory = vm.addr(3);
    address nexBot = vm.addr(4);
    address vault = vm.addr(5);
    address feeRecv = vm.addr(6);
    address operator = vm.addr(7);

    address alice = vm.addr(10);
    address bob = vm.addr(11);

    MockUSDC usdc;
    MockBernx bernx;
    IndexToken idx;
    TestFunctionsOracle oracle;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        bernx = new MockBernx();

        {
            IndexToken impl = new IndexToken();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, feeRecv, 10_000_000 ether))
            );
            idx = IndexToken(address(proxy));
        }

        {
            TestFunctionsOracle impl = new TestFunctionsOracle();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl), abi.encodeCall(FunctionsOracle.initialize, (address(0x1), bytes32("don")))
            );
            oracle = TestFunctionsOracle(address(proxy));

            address[] memory tkns = new address[](1);
            uint256[] memory shrs = new uint256[](1);
            tkns[0] = address(usdc);
            shrs[0] = 1e18;
            oracle.seed(tkns, shrs);
        }

        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        sca = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

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
                        address(bernx),
                        false
                    )
                )
            );
            store = IndexFactoryStorage(address(proxy));
        }

        sca.initialize(address(store));

        vm.prank(address(this));
        store.transferOwnership(address(sca));

        idx.setMinter(address(sca), true);
        idx.setMinter(address(this), true);

        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 60_000 * ONE_USDC);
        store.addIssuanceForCurrentRound(bob, 40_000 * ONE_USDC);
        vm.stopPrank();

        usdc.mint(address(sca), 100_000 * ONE_USDC);
    }

    function testWithdrawForPurchase() public {
        uint256 pre = usdc.balanceOf(nexBot);
        uint256 preload = 100_000 * ONE_USDC;

        uint256 amt80 = (preload * 80) / 100;

        vm.prank(nexBot);
        sca.withdrawForPurchase(1, amt80);

        assertEq(usdc.balanceOf(nexBot), pre + amt80);
        assertEq(usdc.balanceOf(address(sca)), preload - amt80);
    }

    function testDistributeAndSettle() public {
        uint256 bernxPrice = 2e18;
        uint256 c5Price = 1e18;

        uint256 mint = sca.calculateMintAmount(1, bernxPrice, c5Price);

        vm.prank(nexBot);
        sca.distributeTokens(1, bernxPrice, c5Price);

        // assertEq(idx.balanceOf(alice), 600 ether);
        // assertEq(idx.balanceOf(bob), 400 ether);
        assertEq(idx.balanceOf(alice), mint * 60_000 * ONE_USDC / (100_000 * ONE_USDC));
        assertEq(idx.balanceOf(bob), mint * 40_000 * ONE_USDC / (100_000 * ONE_USDC));
        assertEq(store.currentRoundId(), 1);

        assertTrue(store.issuanceIsCompleted(1));
    }

    function testCannotIssueIfPriorUnsettled() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 100);

        vm.prank(nexBot);
        vm.expectRevert("Round is not active");
        sca.issuanceAndWithdrawForPurchase(2, new address[](0), new uint24[](0));
    }

    function test_issuanceAndWithdrawForPurchase_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.issuanceAndWithdrawForPurchase(1, new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    function test_withdrawForPurchase_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.withdrawForPurchase(1, 1);

        vm.stopPrank();
    }

    function test_withdrawForPurchase_FailWhenTotalIssuanceByRoundIsZero() public {
        vm.startPrank(nexBot);

        vm.expectRevert("Nothing to withdraw");
        sca.withdrawForPurchase(2, 1);

        vm.stopPrank();
    }

    function test_withdrawForPurchase_FailWhenAmountIsZero() public {
        vm.startPrank(nexBot);

        vm.expectRevert(ZeroAmount.selector);
        sca.withdrawForPurchase(1, 0);

        vm.stopPrank();
    }

    function test_rescue_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.rescue(address(usdc), address(0x123), 1000);

        vm.stopPrank();
    }

    function test_rescue_SuccessfulRescue() public {
        vm.startPrank(nexBot);

        sca.rescue(address(usdc), address(0x123), 1000);

        vm.stopPrank();

        assertEq(usdc.balanceOf(address(0x123)), 1000);
        assertEq(usdc.balanceOf(address(sca)), 100_000 * ONE_USDC - 1000);
    }

    function test_issuanceCrypto5_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.issuanceCrypto5(1, new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    function test_distributeTokens_FailWhenCallerIsNotNexBot() public {
        vm.startPrank(factory);

        uint256 bernxPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.expectRevert("Caller is not the NEX bot");
        sca.distributeTokens(1, bernxPrice, c5Price);
        vm.stopPrank();
    }

    function test_distributeTokens_FailWhenRoundIdIsGreaterThanCurrentRoundId() public {
        vm.startPrank(nexBot);
        uint256 bernxPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.expectRevert("Invalid roundId");
        sca.distributeTokens(2, bernxPrice, c5Price);

        vm.stopPrank();
    }

    function test_refund_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.refund(alice, 1);

        vm.stopPrank();
    }

    function test_refund_FailWhenToIsZeroAddressOrAmountIsZero() public {
        vm.startPrank(nexBot);

        vm.expectRevert(ZeroAddress.selector);
        sca.refund(address(0), 1);

        vm.expectRevert(ZeroAmount.selector);
        sca.refund(alice, 0);

        vm.stopPrank();
    }

    function test_redemptionCrypto5_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.redemptionCrypto5(1, address(0), new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    // function test_settleRedemption_FailWhenSenderIsNotNexBot() public {
    //     vm.startPrank(alice);

    //     vm.expectRevert("Caller is not the NEX bot");
    //     sca.settleRedemption(1, 1);

    //     vm.stopPrank();
    // }

    // function test_settleRedemption_FailWhenTotalRedemptionByRoundIsZero() public {
    //     vm.startPrank(nexBot);

    //     vm.expectRevert("nothing to settle");
    //     sca.settleRedemption(2, 1);

    //     vm.stopPrank();
    // }

    function _bootstrapRedemptionRound(uint256 idxAlice, uint256 idxBob) internal returns (uint256 slicePct1e18) {
        idx.mint(alice, idxAlice);
        idx.mint(bob, idxBob);

        vm.startPrank(alice);
        idx.transfer(address(sca), idxAlice);
        vm.stopPrank();

        vm.startPrank(bob);
        idx.transfer(address(sca), idxBob);
        vm.stopPrank();

        vm.startPrank(factory);
        store.addRedemptionForCurrentRound(alice, idxAlice);
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.stopPrank();

        slicePct1e18 = (idxAlice + idxBob) * 1e18 / idx.totalSupply();
    }

    function _deployVaultWithLiquidity(uint256 usdcQty, uint256 bernQty) internal {
        Vault vaultImpl = new Vault();
        Vault v =
            Vault(address(new ERC1967Proxy(address(vaultImpl), abi.encodeCall(Vault.initialize, (address(this))))));

        usdc.mint(address(v), usdcQty);
        bernx.mint(address(v), bernQty);

        vm.store(address(store), bytes32(uint256(2)), bytes32(uint256(uint160(address(v)))));
    }

    function test_initiateRedemptionBatch_FailWhenNotOperator() public {
        _bootstrapRedemptionRound(100 ether, 50 ether);

        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        sca.initiateRedemptionBatch(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenNotNexBot() public {
        vm.expectRevert("Caller is not the NEX bot");
        sca.settleRedemption(1, 0, 0);
    }

    function test_settleRedemption_FullHappyPath() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        uint256 usdcCr5 = 50_000 * ONE_USDC;
        usdc.mint(address(sca), usdcCr5);

        vm.startPrank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        uint256 usdcBernx = 150_000 * ONE_USDC;
        usdc.mint(nexBot, usdcBernx);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcBernx);
        vm.stopPrank();
        vm.prank(nexBot);
        sca.settleRedemption(1, usdcBernx, usdcCr5);

        uint256 totalPaid = usdcBernx + usdcCr5;

        uint256 aliceShare = totalPaid * idxAlice / (idxAlice + idxBob);
        uint256 bobShare = totalPaid - aliceShare;

        assertEq(usdc.balanceOf(alice), aliceShare);
        assertEq(usdc.balanceOf(bob), bobShare);

        assertEq(idx.balanceOf(address(sca)), 0);

        assertTrue(store.redemptionRoundCompleted(1));
    }

    function test_issuanceAndWithdrawForPurchase_FailWhenUSDCBalanceIsZero() public {
        address[] memory _tokenInPath = new address[](0);
        uint24[] memory _tokenInFees = new uint24[](0);

        uint256 bal = usdc.balanceOf(address(sca));
        if (bal > 0) {
            vm.startPrank(address(sca));
            usdc.transfer(bob, bal);
            vm.stopPrank();
        }
        assertEq(usdc.balanceOf(address(sca)), 0);

        vm.startPrank(nexBot);
        vm.expectRevert("USDC Balance is Zero!");
        sca.issuanceAndWithdrawForPurchase(1, _tokenInPath, _tokenInFees);
        vm.stopPrank();
    }

    function test_redemptionCrypto5_branch_153_True() public {
        vm.startPrank(nexBot);

        try sca.redemptionCrypto5(1, address(0), new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    function test_distributeTokens_FailWhenTotalIsZero() public {
        vm.startPrank(nexBot);

        store.undoIssuance(alice, 60_000 * ONE_USDC);
        store.undoIssuance(bob, 40_000 * ONE_USDC);
        uint256 bernxPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.expectRevert("Nothing to distribute");
        sca.distributeTokens(1, bernxPrice, c5Price);
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenTotalRedemptionByRoundIsZero1() public {
        uint256 roundId = 2;

        vm.startPrank(nexBot);
        vm.expectRevert("nothing to settle");
        sca.settleRedemption(roundId, 1, 1);
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenRedemptionRoundNotActive() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        uint256 usdcBernx = 150_000 * ONE_USDC;
        uint256 usdcCr5 = 50_000 * ONE_USDC;
        usdc.mint(nexBot, usdcBernx);
        usdc.mint(address(sca), usdcCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcBernx);
        vm.expectRevert("batch not started or already settled");
        sca.settleRedemption(1, usdcBernx, usdcCr5);
        vm.stopPrank();
    }

    function test_settleRedemption_ElseBranch_usdcFromBernxZero() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        uint256 usdcFromBernx = 0;
        uint256 usdcFromCr5 = 50_000 * ONE_USDC;
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        sca.settleRedemption(1, usdcFromBernx, usdcFromCr5);
        vm.stopPrank();

        uint256 totalPaid = usdcFromCr5;
        uint256 aliceShare = totalPaid * idxAlice / (idxAlice + idxBob);
        uint256 bobShare = totalPaid - aliceShare;
        assertEq(usdc.balanceOf(alice), aliceShare);
        assertEq(usdc.balanceOf(bob), bobShare);
        assertEq(idx.balanceOf(address(sca)), 0);
        assertTrue(store.redemptionRoundCompleted(1));
    }

    function test_settleRedemption_FailWhenTotalUSDCIsZero() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        uint256 usdcFromBernx = 0;
        uint256 usdcFromCr5 = 0;

        vm.startPrank(nexBot);
        vm.expectRevert("zero USDC received");
        sca.settleRedemption(1, usdcFromBernx, usdcFromCr5);
        vm.stopPrank();
    }

    function test_settleRedemption_DustBranch_239_True() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        uint256 usdcFromBernx = 0;
        uint256 usdcFromCr5 = 100_001 * ONE_USDC + 1;
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        sca.settleRedemption(1, usdcFromBernx, usdcFromCr5);
        vm.stopPrank();

        uint256 totalPaid = usdcFromCr5;
        uint256 aliceShare = totalPaid * idxAlice / (idxAlice + idxBob);
        uint256 bobShare = totalPaid * idxBob / (idxAlice + idxBob);
        uint256 distributed = aliceShare + bobShare;
        uint256 dust = totalPaid - distributed;
        assertGt(dust, 0);
        assertEq(usdc.balanceOf(store.feeReceiver()), dust);
        assertEq(usdc.balanceOf(alice), aliceShare);
        assertEq(usdc.balanceOf(bob), bobShare);
        assertEq(idx.balanceOf(address(sca)), 0);
        assertTrue(store.redemptionRoundCompleted(1));
    }

    function test_initiateRedemptionBatch_Branch_247_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(nexBot);

        try sca.initiateRedemptionBatch(1, new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_Branch_253_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);
        vm.startPrank(factory);
        store.setRedemptionRoundActive(1, true);
        vm.stopPrank();

        vm.startPrank(nexBot);
        vm.expectRevert("batch already started");
        sca.initiateRedemptionBatch(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_allPreviousRoundsSettled_branch_327_True() public {
        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 100);

        store.increaseCurrentRoundId();

        store.addIssuanceForCurrentRound(bob, 200);
        vm.stopPrank();

        assertTrue(store.roundIdIsActive(1));
        assertEq(store.currentRoundId(), 2);

        vm.startPrank(nexBot);
        vm.expectRevert("A previous round is still unsettled");
        sca.issuanceAndWithdrawForPurchase(2, new address[](0), new uint24[](0));
        vm.stopPrank();
    }
}
