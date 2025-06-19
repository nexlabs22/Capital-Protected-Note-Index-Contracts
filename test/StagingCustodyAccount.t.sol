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
import {FeeCalculation} from "../src/libraries/FeeCalculation.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";
import "./OlympixUnitTest.sol";

error ZeroAmount();
error ZeroAddress();
error RedemptionAmountIsZero();
error InvalidRoundId();

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockBond is ERC20("Bond", "BND") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockIDXc5 is ERC20("Crypto-5", "IDXc5") {
    function mint(address t, uint256 a) external {
        _mint(t, a);
    }
}

contract TestFunctionsOracle is FunctionsOracle {
    function seed(uint8[] memory types, address[] calldata tokens, uint256[] calldata shares) external {
        _initData(types, tokens, shares);
    }
}

contract StagingCustodyAccountTest is OlympixUnitTest("StagingCustodyAccount") {
    address admin = vm.addr(1);
    address bot = vm.addr(2);
    // address factory = vm.addr(3);
    address nexBot = vm.addr(4);
    // address vault = vm.addr(5);
    address feeRecv = vm.addr(6);
    address operator = vm.addr(7);

    address alice = vm.addr(10);
    address bob = vm.addr(11);
    address feeVault = vm.addr(12);
    address owner = address(this);

    MockUSDC usdc;
    MockBond bond;
    IndexToken idx;
    MockIDXc5 idxc5;
    TestFunctionsOracle oracle;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;
    IndexFactory factory;
    Vault vault;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        bond = new MockBond();
        idxc5 = new MockIDXc5();

        vault = Vault(address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (owner)))));

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

            address[] memory tkns = new address[](2);
            uint256[] memory shrs = new uint256[](2);
            uint8[] memory types = new uint8[](2);
            tkns[0] = address(bond);
            shrs[0] = 80e18;
            types[0] = 0;

            tkns[1] = address(idxc5);
            shrs[1] = 20e18;
            types[1] = 1;

            oracle.seed(types, tkns, shrs);
        }

        Vault vaultImpl = new Vault();
        Vault v = Vault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(Vault.initialize, (address(sca))) // ✅ SCA is deployed
                )
            )
        );
        address vaultAddr = address(v);

        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        sca = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

        factory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));

        {
            IndexFactoryStorage impl = new IndexFactoryStorage();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    IndexFactoryStorage.initialize,
                    (
                        address(idx),
                        address(factory),
                        address(oracle),
                        address(sca),
                        vaultAddr,
                        nexBot,
                        address(0xDEAD),
                        address(usdc),
                        address(bond),
                        feeVault,
                        address(1)
                    )
                )
            );
            store = IndexFactoryStorage(address(proxy));
        }

        factory.initialize(address(store), address(feeVault));

        sca.initialize(address(store));

        vm.prank(address(this));
        store.transferOwnership(address(sca));

        idx.setMinter(address(sca), true);
        idx.setMinter(address(this), true);
        vault.setOperator(address(sca), true);

        vm.startPrank(address(factory));
        store.addIssuanceForCurrentRound(alice, 60_000 * ONE_USDC);
        store.addIssuanceForCurrentRound(bob, 40_000 * ONE_USDC);
        vm.stopPrank();

        usdc.mint(address(sca), 100_000 * ONE_USDC);
        usdc.mint(alice, 1_000_000 * ONE_USDC);
        usdc.mint(bob, 1_000_000 * ONE_USDC);

        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(factory), type(uint256).max);
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

    function testCannotIssueIfPriorUnsettled() public {
        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(alice, 100);

        vm.prank(nexBot);
        vm.expectRevert(InvalidRoundId.selector);
        sca.requestIssuance(2, new address[](0), new uint24[](0));
    }

    function test_issuanceAndWithdrawForPurchase_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.requestIssuance(1, new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    function test_withdrawForPurchase_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.withdrawForPurchase(1, 1);

        vm.stopPrank();
    }

    function test_withdrawForPurchase_FailWhenTotalIssuanceByRoundIsZero() public {
        vm.startPrank(address(factory));
        store.setIssuanceRoundActive(2, true);
        vm.stopPrank();

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
        sca.issuanceRiskAsset(1, new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    function test_distributeTokens_FailWhenCallerIsNotNexBot() public {
        vm.startPrank(address(factory));

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.expectRevert("Caller is not the NEX bot");
        sca.completeIssuance(1, bondPrice, c5Price);
        vm.stopPrank();
    }

    function test_distributeTokens_FailWhenRoundIdIsGreaterThanCurrentRoundId() public {
        vm.startPrank(address(factory));
        store.addNonceToIssuanceRound(2, 1);
        store.addNonceToIssuanceRound(2, 2);
        vm.stopPrank();

        vm.startPrank(nexBot);
        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.expectRevert(InvalidRoundId.selector);
        sca.completeIssuance(2, bondPrice, c5Price);

        vm.stopPrank();
    }

    function test_refund_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        // uint256 roundId =
        sca.refund(1, alice, 1);

        vm.stopPrank();
    }

    function test_refund_FailWhenToIsZeroAddressOrAmountIsZero() public {
        vm.startPrank(nexBot);

        vm.expectRevert(ZeroAddress.selector);
        sca.refund(1, address(0), 1);

        vm.expectRevert(ZeroAmount.selector);
        sca.refund(1, alice, 0);

        vm.stopPrank();
    }

    function test_redemptionCrypto5_FailWhenSenderIsNotOwnerOrOperatorOrNexBot() public {
        vm.startPrank(alice);

        vm.expectRevert("Caller is not the owner or operator");
        sca.redemptionRiskAsset(1, address(0), new address[](0), new uint24[](0));

        vm.stopPrank();
    }

    function _bootstrapRedemptionRound(uint256 idxAlice, uint256 idxBob) internal returns (uint256 slicePct1e18) {
        idx.mint(alice, idxAlice);
        idx.mint(bob, idxBob);

        idx.mint(address(0xDEAD), 1);

        vm.startPrank(alice);
        idx.transfer(address(sca), idxAlice);
        vm.stopPrank();

        vm.startPrank(bob);
        idx.transfer(address(sca), idxBob);
        vm.stopPrank();

        vm.startPrank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.stopPrank();

        slicePct1e18 = (idxAlice + idxBob) * 1e18 / idx.totalSupply();
    }

    function _deployVaultWithLiquidity(uint256 usdcQty, uint256 bernQty) internal {
        // Vault vaultImpl = new Vault();
        // Vault v =
        //     Vault(address(new ERC1967Proxy(address(vaultImpl), abi.encodeCall(Vault.initialize, (address(this))))));

        // usdc.mint(address(v), usdcQty);
        // bond.mint(address(v), bernQty);

        // vm.store(address(store), bytes32(uint256(2)), bytes32(uint256(uint160(address(v)))));

        Vault v = Vault(store.vault());
        usdc.mint(address(v), usdcQty);
        bond.mint(address(v), bernQty);
    }

    function test_initiateRedemptionBatch_FailWhenNotOperator() public {
        _bootstrapRedemptionRound(100 ether, 50 ether);

        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        sca.requestRedemption(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenNotNexBot() public {
        vm.expectRevert("Caller is not the NEX bot");
        sca.completeIssuance(1, 0, 0);
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
        sca.requestIssuance(1, _tokenInPath, _tokenInFees);
        vm.stopPrank();
    }

    function test_redemptionCrypto5_branch_153_True() public {
        vm.startPrank(nexBot);

        try sca.redemptionRiskAsset(1, address(0), new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    function test_settleRedemption_FailWhenTotalUSDCIsZero() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.startPrank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.stopPrank();

        uint256 usdcFromBond = 0;
        uint256 usdcFromCr5 = 0;

        vm.startPrank(nexBot);
        vm.expectRevert("zero USDC received");
        sca.completeRedemption(1, usdcFromBond, usdcFromCr5);
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_Branch_247_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);

        vm.startPrank(nexBot);

        try sca.requestRedemption(1, new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    // function test_allPreviousRoundsSettled_branch_327_True() public {
    //     vm.startPrank(address(factory));
    //     store.addIssuanceForCurrentRound(alice, 100);

    //     store.increaseIssuanceRoundId();

    //     store.addIssuanceForCurrentRound(bob, 200);
    //     vm.stopPrank();

    //     assertTrue(store.issuanceRoundActive(1));
    //     assertEq(store.issuanceRoundId(), 2);

    //     vm.startPrank(nexBot);
    //     vm.expectRevert("Prev round still active");
    //     sca.requestIssuance(2, new address[](0), new uint24[](0));
    //     vm.stopPrank();
    // }

    function _createFullRedemptionRound(uint256 toAlice, uint256 toBob) internal {
        _bootstrapRedemptionRound(toAlice, toBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);
    }

    function test_initiateRedemptionBatch_RevertsWhenSupplyZero() public {
        uint256 total = 100 ether;
        idx.mint(address(sca), total);

        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, total);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);

        vm.prank(nexBot);
        vm.expectRevert("IDX supply is zero");
        sca.requestRedemption(1, new address[](0), new uint24[](0));
    }

    function test_rescue_RevertWhenTokenIsZeroAddress_branch_129_True() public {
        vm.startPrank(nexBot);
        address to = address(0x123);
        uint256 amount = 1000;
        vm.expectRevert(ZeroAddress.selector);
        sca.rescue(address(0), to, amount);
        vm.stopPrank();
    }

    function test_rescue_RevertWhenToIsZeroAddress_branch_130_True() public {
        vm.startPrank(nexBot);
        address token = address(usdc);
        address to = address(0);
        uint256 amount = 1000;
        vm.expectRevert(ZeroAddress.selector);
        sca.rescue(token, to, amount);
        vm.stopPrank();
    }

    function test_rescue_RevertWhenAmountIsZero_branch_131_True() public {
        vm.startPrank(nexBot);
        address token = address(usdc);
        address to = address(0x123);
        uint256 amount = 0;
        vm.expectRevert(ZeroAmount.selector);
        sca.rescue(token, to, amount);
        vm.stopPrank();
    }

    function test_settleRedemption_branch_264_Else() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        address charlie = vm.addr(12);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(charlie, 0);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);

        uint256 usdcFromBond = 100_000 * ONE_USDC;
        uint256 usdcFromCr5 = 0;
        usdc.mint(nexBot, usdcFromBond);
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcFromBond);

        sca.completeRedemption(1, usdcFromBond, usdcFromCr5);
        vm.stopPrank();

        uint256 totalPaid = usdcFromBond + usdcFromCr5;
        uint256 feeAmount = FeeCalculation.calculateFee(totalPaid, 10);
        uint256 pureTotalAmount = totalPaid - feeAmount;
        uint256 aliceShare = pureTotalAmount * idxAlice / (idxAlice + idxBob);
        uint256 bobShare = pureTotalAmount * idxBob / (idxAlice + idxBob);
        assertEq(usdc.balanceOf(alice), aliceShare + 1_000_000 * ONE_USDC);
        assertEq(usdc.balanceOf(bob), bobShare + 1_000_000 * ONE_USDC);
        assertEq(usdc.balanceOf(charlie), 0);
        assertTrue(store.redemptionIsCompleted(1));
    }

    function test_initiateRedemptionBatch_InvalidRoundId() public {
        uint256 roundId = 2;
        address[] memory tokenOutPath = new address[](0);
        uint24[] memory tokenOutFees = new uint24[](0);

        vm.startPrank(nexBot);
        vm.expectRevert(InvalidRoundId.selector);
        sca.requestRedemption(roundId, tokenOutPath, tokenOutFees);
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_RoundNotActive() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);

        vm.startPrank(nexBot);
        vm.expectRevert("Round not active");
        sca.requestRedemption(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_branch_344_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);

        Vault v = Vault(store.vault());
        bond.mint(address(v), 1_000_000 * 1e18);

        vm.startPrank(nexBot);
        try sca.requestRedemption(1, new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    function test_calculateMintAmount_branch_409_Else() public {
        idx.mint(address(sca), 100 ether);
        uint256 oldValue = 1e18;
        uint256 newValue = 2e18;

        uint256 mintAmount = store.calculateMintAmount(oldValue, newValue);
        uint256 expected = (idx.totalSupply() * (newValue - oldValue)) / oldValue;
        assertEq(mintAmount, expected);
    }

    // function test_allPreviousRoundsSettled_branch_422_Else() public {
    //     vm.prank(address(sca));
    //     store.settleIssuance(1);
    //     assertFalse(store.issuanceRoundActive(1));

    //     vm.prank(address(factory));
    //     store.increaseIssuanceRoundId();
    //     vm.prank(address(factory));
    //     store.addIssuanceForCurrentRound(alice, 100);
    //     assertEq(store.issuanceRoundId(), 2);

    //     usdc.mint(address(sca), 1e6);

    //     vm.startPrank(nexBot);

    //     address[] memory tokenInPath = new address[](0);
    //     uint24[] memory tokenInFees = new uint24[](0);
    //     try sca.requestIssuance(2, tokenInPath, tokenInFees) {} catch {}
    //     vm.stopPrank();
    // }

    function test_initialize_branch_60_True() public {
        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount scaProxy = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

        vm.expectRevert("Invalid address for _indexFactoryStorageAddress");
        scaProxy.initialize(address(0));
    }

    function test_completeIssuance_branch_253_True() public {
        address charlie = vm.addr(12);

        vm.startPrank(address(factory));
        store.addNonceToIssuanceRound(1, 1);
        store.addNonceToIssuanceRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(charlie, 0);

        Vault v = Vault(store.vault());
        uint256 bondBal = 1000 * 1e18;
        bond.mint(address(v), bondBal);
        bond.mint(address(sca), 100 * 1e18);
        uint256 bondPrice = 2e18;
        uint256 crypto5Price = 1e18;

        idx.mint(address(sca), 100 ether);

        vm.startPrank(nexBot);
        store.setIssuanceRoundActive(1, false);
        vm.stopPrank();

        vm.startPrank(nexBot);
        sca.completeIssuance(1, bondPrice, crypto5Price);
        vm.stopPrank();

        assertEq(idx.balanceOf(charlie), 0);
    }

    function test_initiateRedemptionBatch_branch_357_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);

        Vault v = Vault(store.vault());
        uint256 bondBal = 1_000_000 * 1e18;
        bond.mint(address(v), bondBal);

        v.setOperator(address(sca), true);

        vm.startPrank(nexBot);
        try sca.requestRedemption(1, new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();

        // uint256 pct1e18 = (idxAlice + idxBob) * 1e18 / idx.totalSupply();
        // uint256 expectedSlice = bondBal * pct1e18 / 1e18;
    }

    function test_getPortfolioValue_branch_399_Else() public {
        TestFunctionsOracle impl = new TestFunctionsOracle();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FunctionsOracle.initialize, (address(0x1), bytes32("don"))));
        TestFunctionsOracle singleOracle = TestFunctionsOracle(address(proxy));

        address[] memory tkns = new address[](1);
        uint256[] memory shrs = new uint256[](1);
        uint8[] memory types = new uint8[](1);
        tkns[0] = address(bond);
        shrs[0] = 100e18;
        types[0] = 0;
        singleOracle.seed(types, tkns, shrs);

        IndexFactoryStorage implStore = new IndexFactoryStorage();
        ERC1967Proxy proxyStore = new ERC1967Proxy(
            address(implStore),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx),
                    address(factory),
                    address(singleOracle),
                    address(sca),
                    address(store.vault()),
                    nexBot,
                    address(0xDEAD),
                    address(usdc),
                    address(bond),
                    feeVault,
                    address(1)
                )
            )
        );
        IndexFactoryStorage singleStore = IndexFactoryStorage(address(proxyStore));

        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount singleSCA = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));
        singleSCA.initialize(address(singleStore));

        Vault v = Vault(singleStore.vault());
        uint256 bondBal = 1000 * 1e18;
        bond.mint(address(v), bondBal);
        uint256 bondPrice = 2e18;
        uint256 crypto5Price = 1e18;

        uint256 expected = (bondBal * bondPrice) / 1e18;
        uint256 val = store.getPortfolioValue(bondPrice, crypto5Price);
        assertEq(val, expected);
    }

    function test_issuanceAndWithdrawForPurchase_branch_104_True() public {
        uint256 roundId = 1;

        vm.prank(address(factory));
        store.setIssuanceRoundActive(roundId, true);
        vm.prank(address(factory));
        store.setIssuanceCompleted(roundId, true);

        vm.startPrank(nexBot);
        vm.expectRevert("Round already completed");
        sca.requestIssuance(roundId, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_completeIssuance_branch_233_True() public {
        uint256 bondPrice = 2e18;
        uint256 crypto5Price = 1e18;
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;

        vm.startPrank(address(factory));
        store.addIssuanceForCurrentRound(alice, idxAlice);
        store.addIssuanceForCurrentRound(bob, idxBob);
        vm.stopPrank();

        vm.startPrank(address(factory));
        store.addNonceToIssuanceRound(2, 1);
        store.addNonceToIssuanceRound(2, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setIssuanceRoundActive(1, false);
        vm.prank(address(factory));
        store.setIssuanceCompleted(1, true);

        vm.prank(address(factory));
        store.increaseIssuanceRoundId();

        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(bob, idxBob);

        bond.mint(address(sca), 1000 * 1e18);
        idxc5.mint(address(sca), 500 * 1e18);

        idx.mint(address(sca), 100 ether);

        vm.startPrank(nexBot);
        store.setIssuanceRoundActive(2, false);
        sca.completeIssuance(2, bondPrice, crypto5Price);
        vm.stopPrank();

        assertTrue(store.issuanceIsCompleted(2));
    }

    function test_completeIssuance_branch_239_True() public {
        uint256 roundId = 1;

        vm.startPrank(address(factory));
        store.addNonceToIssuanceRound(roundId, 1);
        store.addNonceToIssuanceRound(roundId, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setIssuanceRoundActive(roundId, true);
        vm.prank(address(factory));
        store.setIssuanceCompleted(roundId, false);

        vm.startPrank(nexBot);
        vm.expectRevert("Round is active");
        sca.completeIssuance(roundId, 2e18, 1e18);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_290_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(2, 1);
        store.addNonceToRedemptionRound(2, 2);
        vm.stopPrank();

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, true);

        vm.prank(address(factory));
        store.increaseRedemptionRoundId();

        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, false);

        uint256 usdcFromBond = 100_000 * ONE_USDC;
        uint256 usdcFromCr5 = 0;
        usdc.mint(nexBot, usdcFromBond);
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcFromBond);
        sca.completeRedemption(2, usdcFromBond, usdcFromCr5);
        vm.stopPrank();

        assertTrue(store.redemptionIsCompleted(2));
    }

    function test_completeRedemption_branch_296_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, false);

        uint256 usdcFromBond = 100_000 * ONE_USDC;
        uint256 usdcFromCr5 = 0;
        usdc.mint(nexBot, usdcFromBond);
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcFromBond);
        vm.expectRevert("Round still active");
        sca.completeRedemption(1, usdcFromBond, usdcFromCr5);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_297_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, true);

        uint256 usdcFromBond = 100_000 * ONE_USDC;
        uint256 usdcFromCr5 = 0;
        usdc.mint(nexBot, usdcFromBond);
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcFromBond);
        vm.expectRevert("Round already completed");
        sca.completeRedemption(1, usdcFromBond, usdcFromCr5);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_299_True() public {
        uint256 roundId = 1;

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(roundId, 1);
        store.addNonceToRedemptionRound(roundId, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(roundId, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(roundId, false);
        vm.startPrank(nexBot);
        vm.expectRevert("No tokens to redeem");
        sca.completeRedemption(roundId, 0, 0);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_335_True() public {
        uint256 idxAlice = 80 ether;
        uint256 idxBob = 20 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(1, 1);
        store.addNonceToRedemptionRound(1, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, false);

        uint256 usdcFromBond = 100_001 * ONE_USDC + 1;
        uint256 usdcFromCr5 = 0;
        usdc.mint(nexBot, usdcFromBond);
        usdc.mint(address(sca), usdcFromCr5);

        vm.startPrank(nexBot);
        usdc.approve(address(sca), usdcFromBond);
        sca.completeRedemption(1, usdcFromBond, usdcFromCr5);
        vm.stopPrank();

        uint256 totalPaid = usdcFromBond + usdcFromCr5;
        uint256 feeAmount = FeeCalculation.calculateFee(totalPaid, 10);
        uint256 pureTotalAmount = totalPaid - feeAmount;
        uint256 aliceShare = pureTotalAmount * idxAlice / (idxAlice + idxBob);
        uint256 bobShare = pureTotalAmount * idxBob / (idxAlice + idxBob);
        uint256 paid = aliceShare + bobShare;
        uint256 dust = pureTotalAmount - paid;
        assertEq(usdc.balanceOf(address(this)), feeAmount + dust);
        assertEq(usdc.balanceOf(alice), aliceShare + 1_000_000 * ONE_USDC);
        assertEq(usdc.balanceOf(bob), bobShare + 1_000_000 * ONE_USDC);
        assertTrue(store.redemptionIsCompleted(1));
    }

    function test_initiateRedemptionBatch_branch_356_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, true);

        vm.prank(address(factory));
        store.increaseRedemptionRoundId();

        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, true);

        vm.startPrank(nexBot);
        try sca.requestRedemption(2, new address[](0), new uint24[](0)) {} catch {}
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_branch_358_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);

        vm.prank(address(factory));
        store.increaseRedemptionRoundId();
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, true);

        vm.startPrank(nexBot);
        vm.expectRevert("Prev redemption not completed");
        sca.requestRedemption(2, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_branch_363_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, true);

        vm.startPrank(nexBot);
        vm.expectRevert("Round already completed");
        sca.requestRedemption(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_initiateRedemptionBatch_branch_366_True() public {
        uint256 roundId = 1;
        vm.prank(address(factory));
        store.setRedemptionRoundActive(roundId, true);
        vm.startPrank(nexBot);
        vm.expectRevert(RedemptionAmountIsZero.selector);
        sca.requestRedemption(roundId, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_getPortfolioValue_branch_437_Else() public {
        TestFunctionsOracle impl = new TestFunctionsOracle();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FunctionsOracle.initialize, (address(0x1), bytes32("don"))));
        TestFunctionsOracle customOracle = TestFunctionsOracle(address(proxy));

        address[] memory tkns = new address[](2);
        uint256[] memory shrs = new uint256[](2);
        uint8[] memory types = new uint8[](2);
        tkns[0] = address(bond);
        shrs[0] = 80e18;
        types[0] = 0;
        tkns[1] = address(0);
        shrs[1] = 20e18;
        types[1] = 1;
        customOracle.seed(types, tkns, shrs);

        IndexFactoryStorage implStore = new IndexFactoryStorage();
        ERC1967Proxy proxyStore = new ERC1967Proxy(
            address(implStore),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx),
                    address(factory),
                    address(customOracle),
                    address(sca),
                    address(store.vault()),
                    nexBot,
                    address(0xDEAD),
                    address(usdc),
                    address(bond),
                    feeVault,
                    address(1)
                )
            )
        );
        IndexFactoryStorage customStore = IndexFactoryStorage(address(proxyStore));

        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount customSCA = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));
        customSCA.initialize(address(customStore));

        Vault v = Vault(customStore.vault());
        uint256 bondBal = 1000 * 1e18;
        bond.mint(address(v), bondBal);
        uint256 bondPrice = 2e18;
        uint256 crypto5Price = 1e18;

        uint256 expected = (bondBal * bondPrice) / 1e18;
        uint256 val = store.getPortfolioValue(bondPrice, crypto5Price);
        assertEq(val, expected);
    }

    function test_completeIssuance_branch_240_True() public {
        uint256 bondPrice = 2e18;
        uint256 crypto5Price = 1e18;
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;

        vm.startPrank(address(factory));
        store.addNonceToIssuanceRound(1, 1);
        store.addNonceToIssuanceRound(2, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(bob, idxBob);

        vm.prank(address(factory));
        store.setIssuanceRoundActive(1, true);
        vm.prank(address(factory));
        store.setIssuanceCompleted(1, false);

        vm.prank(address(factory));
        store.increaseIssuanceRoundId();
        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addIssuanceForCurrentRound(bob, idxBob);
        vm.prank(address(factory));
        store.setIssuanceRoundActive(2, false);
        vm.prank(address(factory));
        store.setIssuanceCompleted(2, false);

        vm.startPrank(nexBot);
        vm.expectRevert("Prev round still active");
        sca.completeIssuance(2, bondPrice, crypto5Price);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_303_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(2, 1);
        store.addNonceToRedemptionRound(2, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, false);

        vm.prank(address(factory));
        store.increaseRedemptionRoundId();
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(2, false);

        vm.startPrank(nexBot);
        vm.expectRevert("Prev redemption round active");
        sca.completeRedemption(2, 0, 0);
        vm.stopPrank();
    }

    function test_completeRedemption_branch_304_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.startPrank(address(factory));
        store.addNonceToRedemptionRound(2, 1);
        store.addNonceToRedemptionRound(2, 2);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, false);

        vm.prank(address(factory));
        store.increaseRedemptionRoundId();
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(2, false);

        vm.startPrank(nexBot);
        vm.expectRevert("Prev redemption not completed");
        sca.completeRedemption(2, 0, 0);
        vm.stopPrank();
    }

    function test_requestRedemption_branch_370_True() public {
        uint256 idxAlice = 100 ether;
        uint256 idxBob = 50 ether;
        _bootstrapRedemptionRound(idxAlice, idxBob);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        vm.prank(address(factory));
        store.setRedemptionCompleted(1, true);
        vm.prank(address(factory));
        store.increaseRedemptionRoundId();

        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(alice, idxAlice);
        vm.prank(address(factory));
        store.addRedemptionForCurrentRound(bob, idxBob);
        vm.prank(address(factory));
        store.setRedemptionRoundActive(2, true);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);

        vm.startPrank(nexBot);
        vm.expectRevert("Prev redemption round active");
        sca.requestRedemption(2, new address[](0), new uint24[](0));
        vm.stopPrank();
    }

    function test_setNexBotAddress_RevertWhenZeroAddress_branch_77_True() public {
        vm.expectRevert(ZeroAddress.selector);
        sca.setNexBotAddress(address(0));
    }

    function test_setRiskAssetFactoryAddress_branch_82_True() public {
        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount scaProxy = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

        scaProxy.initialize(address(store));

        vm.expectRevert(ZeroAddress.selector);
        scaProxy.setRiskAssetFactoryAddress(address(0));
    }

    function test_setBondAddress_RevertWhenZeroAddress_branch_87_True() public {
        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount scaProxy = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

        scaProxy.initialize(address(store));

        vm.expectRevert(ZeroAddress.selector);
        scaProxy.setBondAddress(address(0));
    }

    function test_setIndexFactoryStorageAddress_branch_92_True() public {
        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount scaProxy = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));

        scaProxy.initialize(address(store));

        vm.expectRevert(ZeroAddress.selector);
        scaProxy.setIndexFactoryStorageAddress(address(0));
    }

    function test_requestIssuance_branch_238_Else() public {
        TestFunctionsOracle impl = new TestFunctionsOracle();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(FunctionsOracle.initialize, (address(0x1), bytes32("don"))));
        TestFunctionsOracle singleOracle = TestFunctionsOracle(address(proxy));

        address[] memory tkns = new address[](1);
        uint256[] memory shrs = new uint256[](1);
        uint8[] memory types = new uint8[](1);
        tkns[0] = address(bond);
        shrs[0] = 100e18;
        types[0] = 0;
        singleOracle.seed(types, tkns, shrs);

        IndexFactoryStorage implStore = new IndexFactoryStorage();
        ERC1967Proxy proxyStore = new ERC1967Proxy(
            address(implStore),
            abi.encodeCall(
                IndexFactoryStorage.initialize,
                (
                    address(idx),
                    address(factory),
                    address(singleOracle),
                    address(sca),
                    address(store.vault()),
                    nexBot,
                    address(0xDEAD),
                    address(usdc),
                    address(bond),
                    feeVault,
                    address(1)
                )
            )
        );
        IndexFactoryStorage singleStore = IndexFactoryStorage(address(proxyStore));

        StagingCustodyAccount scaImpl = new StagingCustodyAccount();
        StagingCustodyAccount singleSCA = StagingCustodyAccount(address(new ERC1967Proxy(address(scaImpl), "")));
        singleSCA.initialize(address(singleStore));

        vm.prank(address(factory));
        singleStore.addIssuanceForCurrentRound(alice, 100_000 * ONE_USDC);
        usdc.mint(address(singleSCA), 100_000 * ONE_USDC);
        vm.prank(address(factory));
        singleStore.setIssuanceRoundActive(1, true);

        vm.startPrank(nexBot);
        vm.expectRevert("Caller is not a factory contract");
        singleSCA.requestIssuance{value: 0}(1, new address[](0), new uint24[](0));
        vm.stopPrank();
    }
}
