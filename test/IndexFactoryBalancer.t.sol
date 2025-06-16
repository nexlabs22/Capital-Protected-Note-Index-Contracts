// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "./OlympixUnitTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IndexFactoryBalancer} from "../src/factory/IndexFactoryBalancer.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {Vault} from "../src/vault/Vault.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import {IndexToken} from "../src/token/IndexToken.sol";
import {FeeVault} from "../src/vault/FeeVault.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBond, MockIDXc5, DummyCrypto5Factory} from "./IndexFactory.t.sol";
import {IRiskAssetFactory} from "../src/interfaces/IRiskAssetFactory.sol";

contract TestOracle is FunctionsOracle {
    function seed(uint8[] calldata t, address[] calldata a, uint256[] calldata s) external {
        _initData(t, a, s);
    }

    function setCurrent(address tok, uint256 bps1e18) external {
        tokenCurrentMarketShare[tok] = bps1e18;
    }
}

contract IndexFactoryBalancerTest is OlympixUnitTest("IndexFactoryBalancer") {
    MockUSDC usdc;
    MockBond bond;
    MockIDXc5 cr5;
    DummyCrypto5Factory c5Factory;

    Vault vault;
    IndexToken idx;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;
    FeeVault feeVault;
    TestOracle oracle;
    IndexFactoryBalancer balancer;
    IndexFactory factory;

    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_18 = 1e18;

    address feeRec = vm.addr(100);
    address nexBot = vm.addr(101);

    function setUp() public {
        usdc = new MockUSDC("USD Coin", "USDC");
        bond = new MockBond();
        cr5 = new MockIDXc5();
        c5Factory = new DummyCrypto5Factory(address(cr5));

        vault =
            Vault(address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(this))))));

        idx = IndexToken(
            address(
                new ERC1967Proxy(
                    address(new IndexToken()),
                    abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, feeRec, 10_000_000 ether))
                )
            )
        );

        store = IndexFactoryStorage(address(new ERC1967Proxy(address(new IndexFactoryStorage()), "")));

        feeVault = FeeVault(
            address(new ERC1967Proxy(address(new FeeVault()), abi.encodeCall(FeeVault.initialize, (address(store)))))
        );

        sca = StagingCustodyAccount(payable(address(new ERC1967Proxy(address(new StagingCustodyAccount()), ""))));

        oracle = TestOracle(payable(address(new ERC1967Proxy(address(new TestOracle()), ""))));

        balancer = IndexFactoryBalancer(
            address(
                new ERC1967Proxy(
                    address(new IndexFactoryBalancer()),
                    abi.encodeCall(IndexFactoryBalancer.initialize, (address(store), address(oracle)))
                )
            )
        );

        factory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));

        store.initialize(
            address(idx),
            address(factory),
            address(oracle),
            address(sca),
            address(vault),
            nexBot,
            address(c5Factory),
            address(usdc),
            address(bond),
            address(feeVault),
            address(balancer)
        );

        vm.roll(12 hours);

        // store.setFeeRate(0);

        factory.initialize(address(store), address(feeVault));

        sca.initialize(address(store));
        vault.setOperator(address(sca), true);
        vault.setOperator(address(balancer), true);
        vault.setOperator(address(factory), true);
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(balancer), true);
        oracle.setOperator(address(factory), true);
        oracle.setFactoryBalancer(address(balancer));
        vm.stopPrank();

        // vm.deal(address(balancer), 1 ether);
        vm.deal(address(nexBot), 1 ether);

        {
            uint8[] memory ty = new uint8[](2);
            address[] memory tk = new address[](2);
            uint256[] memory wt = new uint256[](2);

            ty[0] = 0;
            tk[0] = address(bond);
            wt[0] = 80e18; // 80%
            ty[1] = 1;
            tk[1] = address(cr5);
            wt[1] = 20e18; // 20%
            oracle.seed(ty, tk, wt);

            oracle.setCurrent(address(bond), 80e18);
            oracle.setCurrent(address(cr5), 20e18);

            // oracle.setCurrent(address(bond), 80e18);
            // oracle.setCurrent(address(cr5), 20e18);
        }

        // bond.mint(address(vault), 100 * ONE_18);
        // cr5.mint(address(vault), 50 * ONE_18);
    }

    function test_firstRebalanceAction() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        oracle.setCurrent(address(bond), 85e18);
        oracle.setCurrent(address(cr5), 15e18);

        uint256 bondBefore = bond.balanceOf(address(vault));
        uint256 cr5Before = cr5.balanceOf(address(vault));

        vm.recordLogs();
        vm.startPrank(nexBot);
        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        vm.stopPrank();
        assertEq(nonce, 1);

        assertLt(bond.balanceOf(address(vault)), bondBefore, "bond not sold");
        assertEq(cr5.balanceOf(address(vault)), cr5Before, "CR5 should stay put");

        // assertLt(bond.balanceOf(address(vault)), bondBefore, "bond not sold");
        // assertLt(cr5.balanceOf(address(vault)), cr5Before, "CR5 not redeemed");

        Vm.Log[] memory ev = vm.getRecordedLogs();
        bytes32 sig = keccak256("FirstRebalanceAction(uint256,address[],uint256[],uint256,uint256)");
        bool ok;
        for (uint256 i; i < ev.length; ++i) {
            if (ev[i].topics[0] == sig) {
                (address[] memory toks, uint256[] memory amts,,) =
                    abi.decode(ev[i].data, (address[], uint256[], uint256, uint256));
                //  assertEq(toks.length, 2, "should list 2 tokens");
                assertEq(toks.length, 1, "should list exactly 1 token");
                assertEq(toks.length, amts.length, "array size mismatch");
                ok = true;
                break;
            }
        }
        require(ok, "FirstRebalanceAction not logged");
    }

    function test_initialize_branch_functionsOracle_zero_address() public {
        IndexFactoryBalancer impl = new IndexFactoryBalancer();
        address validFactoryStorage = address(store); // already initialized in setUp
        address zeroOracle = address(0);
        vm.expectRevert(bytes("invalid functions oracle address"));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(IndexFactoryBalancer.initialize, (validFactoryStorage, zeroOracle))
        );
    }

    function test_setIndexFactoryStorage_branch78_true() public {
        IndexFactoryStorage newStore =
            IndexFactoryStorage(address(new ERC1967Proxy(address(new IndexFactoryStorage()), "")));
        vm.prank(balancer.owner());
        bool result = balancer.setIndexFactoryStorage(address(newStore));
        assertTrue(result, "setIndexFactoryStorage should return true");
        assertEq(address(balancer.factoryStorage()), address(newStore), "factoryStorage should be updated");
    }

    function test_setFunctionsOracle_branch_True() public {
        TestOracle newOracle = TestOracle(payable(address(new ERC1967Proxy(address(new TestOracle()), ""))));
        bool result = balancer.setFunctionsOracle(address(newOracle));
        assertTrue(result, "setFunctionsOracle should return true");
        assertEq(address(balancer.functionsOracle()), address(newOracle), "functionsOracle address should be updated");
    }

    function test_firstRebalanceAction_branch175_false() public {
        oracle.setCurrent(address(bond), 80e18); // 80% == 80%
        oracle.setCurrent(address(cr5), 20e18); // 20% == 20%

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;

        vm.recordLogs();
        uint256 nonce = balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        assertEq(nonce, 1);

        assertEq(bond.balanceOf(address(vault)), 100 * ONE_18, "bond should not be sold");
        assertEq(cr5.balanceOf(address(vault)), 50 * ONE_18, "cr5 should not be redeemed");

        Vm.Log[] memory ev = vm.getRecordedLogs();
        bytes32 sig = keccak256("FirstRebalanceAction(uint256,address[],uint256[],uint256,uint256)");
        bool ok;
        for (uint256 i; i < ev.length; ++i) {
            if (ev[i].topics[0] == sig) {
                (address[] memory toks, uint256[] memory amts,,) =
                    abi.decode(ev[i].data, (address[], uint256[], uint256, uint256));
                assertEq(toks.length, 0, "should list 0 tokens");
                assertEq(amts.length, 0, "should list 0 amounts");
                ok = true;
                break;
            }
        }
        require(ok, "FirstRebalanceAction not logged");
    }

    function test_checkFirstRebalanceOrdersStatus_branch_revert() public {
        uint256 invalidNonce = 1;
        vm.expectRevert("Wrong rebalance nonce!");
        balancer.checkFirstRebalanceOrdersStatus(invalidNonce);
    }

    function test_checkFirstRebalanceOrdersStatus_branch_True() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        vm.startPrank(nexBot);
        balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        bool result = balancer.checkFirstRebalanceOrdersStatus(1);
        vm.stopPrank();

        assertTrue(result, "Should return true for valid rebalance nonce");
    }

    function test_checkSecondRebalanceOrdersStatus_revert_branch() public {
        uint256 invalidNonce = 1;
        vm.expectRevert("Wrong rebalance nonce!");
        balancer.checkSecondRebalanceOrdersStatus(invalidNonce);
    }

    function test_checkSecondRebalanceOrdersStatus_branch_true() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        vm.startPrank(nexBot);
        balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        bool result = balancer.checkSecondRebalanceOrdersStatus(1);
        vm.stopPrank();

        assertTrue(result, "Should return true for valid rebalance nonce");
    }

    function test_pause_branch_True() public {
        assertTrue(!balancer.paused(), "Balancer should not be paused before test");
        vm.prank(balancer.owner());
        balancer.pause();
        assertTrue(balancer.paused(), "Balancer should be paused after calling pause");
    }

    function test_unpause_branch_291_true() public {
        vm.prank(balancer.owner());
        balancer.pause();
        assertTrue(balancer.paused(), "Balancer should be paused before calling unpause");

        vm.prank(balancer.owner());
        balancer.unpause();

        assertTrue(!balancer.paused(), "Balancer should be unpaused after calling unpause");
    }

    function test_pauseIndexFactory_branch_301_else() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        vm.startPrank(address(this));
        factory.pause();
        vm.stopPrank();
        assertTrue(factory.paused(), "IndexFactory should be paused");

        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
    }

    function test_initialize_branch_factoryStorage_zero_address() public {
        IndexFactoryBalancer impl = new IndexFactoryBalancer();
        address zeroFactoryStorage = address(0);
        address validOracle = address(oracle);
        vm.expectRevert(bytes("invalid token address"));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(IndexFactoryBalancer.initialize, (zeroFactoryStorage, validOracle))
        );
    }

    function test_secondRebalanceAction_branch_220_false() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));

        usdc.mint(address(balancer), 100 * ONE_USDC);
        oracle.setCurrent(address(bond), 70e18);
        oracle.setCurrent(address(cr5), 30e18);
        vm.prank(address(this));
        balancer.secondRebalanceAction{value: 10}(nonce, new address[](0), new uint24[](0));
        vm.expectRevert("rebalance: phase-2 already done");
        balancer.secondRebalanceAction(nonce, new address[](0), new uint24[](0));
    }

    function test_secondRebalanceAction_branch_224_true() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));

        oracle.setCurrent(address(bond), 70e18);
        oracle.setCurrent(address(cr5), 30e18);
        vm.expectRevert(bytes("no USDC to deploy"));
        balancer.secondRebalanceAction{value: 10}(nonce, new address[](0), new uint24[](0));
    }

    function test_secondRebalanceAction_branch_250_else() public {
        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        usdc.mint(address(balancer), 100 * ONE_USDC);
        oracle.setCurrent(address(bond), 80e18);
        oracle.setCurrent(address(cr5), 20e18);
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        vm.prank(address(this));
        balancer.secondRebalanceAction{value: 0}(nonce, new address[](0), new uint24[](0));
        uint256 vaultUsdcAfter = usdc.balanceOf(address(vault));
        assertEq(vaultUsdcAfter, vaultUsdcBefore + 100 * ONE_USDC, "USDC should be parked in Vault");
    }

    function test_secondRebalanceAction_bondDeficit_transfersToNexBot() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));

        uint256 proceeds = 200 * ONE_USDC;
        usdc.mint(address(balancer), proceeds);

        oracle.setCurrent(address(bond), 70e18); // 70 %
        oracle.setCurrent(address(cr5), 30e18); // 30 %

        uint256 nexBotBefore = usdc.balanceOf(nexBot);

        vm.prank(address(this));
        balancer.secondRebalanceAction{value: 10}(nonce, new address[](0), new uint24[](0));

        assertEq(usdc.balanceOf(address(balancer)), 0, "Balancer should hold no USDC");
        assertEq(usdc.balanceOf(nexBot), nexBotBefore + proceeds, "nexBot should receive USDC");
    }

    function test_secondRebalanceAction_cr5Deficit_mintsCrypto5() public {
        uint256 pBond = 2 * ONE_18; // bERNX = $2
        uint256 pCr5 = 1 * ONE_18; // CR-5 = $1

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        uint8[] memory ty = new uint8[](2);
        address[] memory tk = new address[](2);
        uint256[] memory wt = new uint256[](2);

        ty[0] = 0;
        tk[0] = address(bond);
        wt[0] = 80e18; // 80 %
        ty[1] = 1;
        tk[1] = address(idx);
        wt[1] = 20e18; // 20 %
        oracle.seed(ty, tk, wt);

        oracle.setCurrent(address(bond), 90e18); // 90 %
        oracle.setCurrent(address(idx), 10e18); // 10 %

        uint256 nonce = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));

        uint256 proceeds = 150 * ONE_USDC;
        usdc.mint(address(balancer), proceeds);

        uint256 scaUsdcBefore = usdc.balanceOf(address(sca));

        vm.prank(address(this));
        balancer.secondRebalanceAction{value: 10}(nonce, new address[](0), new uint24[](0));

        assertEq(usdc.balanceOf(address(balancer)), 0, "USDC should be emptied from Balancer");

        assertEq(usdc.balanceOf(address(sca)), scaUsdcBefore + proceeds, "SCA must receive all USDC");
    }

    // function test_completeRebalanceActions_transfersAndUnpauses() public {
    //     oracle.setCurrent(address(cr5), 25e18);

    //     uint256 pBond = 2 * ONE_18;
    //     uint256 pCr5 = 1 * ONE_18;

    //     bond.mint(address(vault), 100 * ONE_18);
    //     cr5.mint(address(vault), 50 * ONE_18);

    //     oracle.setCurrent(address(bond), 75e18); // 75 %
    //     oracle.setCurrent(address(cr5), 25e18); // 25 %

    //     vm.startPrank(nexBot);
    //     uint256 nonce = balancer.firstRebalanceAction{value: 10}(pBond, pCr5, new address[](0), new uint24[](0));
    //     vm.stopPrank();

    //     uint256 nav = 250 * ONE_18;
    //     uint256 sold = _calcSoldCr5(nav, 5e20, /*5 %*/ pCr5);

    //     uint256 wantC = 50 * ONE_18 - sold;

    //     assertEq(bond.balanceOf(address(vault)), 100 * ONE_18, "Vault bERNX unchanged");
    //     assertEq(cr5.balanceOf(address(vault)), wantC, "Vault CR-5 reduced");

    //     uint256 proceeds = 200 * ONE_USDC;
    //     usdc.mint(address(balancer), proceeds);
    //     uint256 nexBotPre = usdc.balanceOf(nexBot);

    //     vm.startPrank(nexBot);
    //     balancer.secondRebalanceAction{value: 0}(nonce, new address[](0), new uint24[](0));
    //     vm.stopPrank();

    //     assertEq(usdc.balanceOf(nexBot), nexBotPre + proceeds, "nexBot paid");

    //     uint256 fresh = 5 * ONE_18;
    //     bond.mint(address(balancer), fresh);

    //     uint256 bondPre = bond.balanceOf(address(vault));
    //     uint256 cr5Pre = cr5.balanceOf(address(vault));

    //     vm.startPrank(nexBot);
    //     balancer.completeRebalanceActions(nonce);
    //     vm.stopPrank();

    //     assertEq(bond.balanceOf(address(balancer)), 0, "balancer bond 0");
    //     assertEq(cr5.balanceOf(address(balancer)), 0, "balancer cr-5 0");

    //     assertEq(bond.balanceOf(address(vault)), bondPre + fresh, "vault got bonds");
    //     assertEq(cr5.balanceOf(address(vault)), cr5Pre, "vault CR-5 unchanged");
    //     assertTrue(!factory.paused(), "factory un-paused");
    // }

    function test_fullScenario_rebalanceEndToEnd() public {
        uint256 priceBond = 2 * ONE_18;
        uint256 priceCr5 = 1 * ONE_18;

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);

        oracle.setCurrent(address(bond), 70e18);
        oracle.setCurrent(address(cr5), 30e18);

        uint256 qtyCr5 = 25 * ONE_18;
        uint256 feeRedeem = store.getRedemptionFee(qtyCr5);

        uint256 nonce =
            balancer.firstRebalanceAction{value: feeRedeem}(priceBond, priceCr5, new address[](0), new uint24[](0));

        assertEq(cr5.balanceOf(address(vault)), 25 * ONE_18, "25 CR-5 should be withdrawn");

        uint256 proceeds = 25 * ONE_USDC;
        usdc.mint(address(balancer), proceeds);

        oracle.setCurrent(address(bond), 75e18);
        oracle.setCurrent(address(cr5), 25e18);

        uint256 nexBotUSDCBefore = usdc.balanceOf(nexBot);
        balancer.secondRebalanceAction{value: 0}(nonce, new address[](0), new uint24[](0));
        assertEq(usdc.balanceOf(nexBot), nexBotUSDCBefore + proceeds, "USDC not forwarded to nexBot");

        uint256 deliveredBond = 10 * ONE_18;
        bond.mint(address(balancer), deliveredBond);

        vm.prank(nexBot);
        balancer.completeRebalanceActions(nonce);

        assertEq(bond.balanceOf(address(balancer)), 0, "balancer still holds bERNX");
        assertEq(cr5.balanceOf(address(balancer)), 0, "balancer still holds CR-5");

        assertEq(bond.balanceOf(address(vault)), 100 * ONE_18 + deliveredBond, "vault did not get bonds");

        assertTrue(!factory.paused(), "factory still paused");
    }

    function _calcSoldCr5(uint256 nav18, uint256 overweight1e18, uint256 price18) internal pure returns (uint256) {
        uint256 usdToSell18 = nav18 * overweight1e18 / 1e18;
        return usdToSell18 * 1e18 / price18;
    }

    function test_rebalanceNonceIncrements() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;

        bond.mint(address(vault), 100 * ONE_18);

        vm.prank(nexBot);
        uint256 n1 = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        assertEq(n1, 1, "first nonce should be 1");

        oracle.setCurrent(address(bond), 85e18);
        vm.prank(nexBot);
        uint256 n2 = balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
        assertEq(n2, 2, "second nonce should be 2");

        assertEq(balancer.rebalanceNonce(), 2, "global nonce incorrect");
    }

    function test_firstRebalanceAction_onlyOwnerOrOperatorGuard() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        bond.mint(address(vault), 10 * ONE_18);

        address stranger = vm.addr(999);
        vm.prank(stranger);
        vm.expectRevert("Caller is not the owner or operator");
        balancer.firstRebalanceAction{value: 0}(pBond, pCr5, new address[](0), new uint24[](0));
    }

    function test_withdrawBondForNexBot() public {
        uint256 amount = 5 * ONE_18;
        bond.mint(address(balancer), amount);

        uint256 before = bond.balanceOf(nexBot);

        vm.prank(balancer.owner());
        balancer.withdrawBondForNexBot(amount);

        assertEq(bond.balanceOf(address(balancer)), 0, "balancer should be empty");
        assertEq(bond.balanceOf(nexBot), before + amount, "nexBot did not receive bond");
    }

    function test_redemptionFeeIsNonZero() public view {
        uint256 qty = 1 * ONE_18; // 1 unit
        uint256 fee = store.getRedemptionFee(qty);
        assertGt(fee, 0, "expected a positive fee");
    }
}
