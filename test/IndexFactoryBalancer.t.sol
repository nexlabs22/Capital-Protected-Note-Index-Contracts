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
import "../src/vault/FeeVault.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockBond, MockIDXc5, DummyCrypto5Factory} from "./IndexFactory.t.sol";

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

        factory.initialize(address(store), address(feeVault));

        sca.initialize(address(store));
        vault.setOperator(address(sca), true);
        vault.setOperator(address(balancer), true);
        vault.setOperator(address(factory), true);
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(balancer), true);
        oracle.setOperator(address(factory), true);
        vm.stopPrank();

        vm.deal(address(balancer), 1 ether);

        {
            uint8[] memory ty = new uint8[](2);
            address[] memory tk = new address[](2);
            uint256[] memory wt = new uint256[](2);

            ty[0] = 0;
            tk[0] = address(bond);
            wt[0] = 80e16; // 80%
            ty[1] = 1;
            tk[1] = address(cr5);
            wt[1] = 20e16; // 20%
            oracle.seed(ty, tk, wt);

            oracle.setCurrent(address(bond), 90e16);
            oracle.setCurrent(address(cr5), 30e16);
        }

        bond.mint(address(vault), 100 * ONE_18);
        cr5.mint(address(vault), 50 * ONE_18);
    }

    function test_firstRebalanceAction() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;

        uint256 bondBefore = bond.balanceOf(address(vault));
        uint256 cr5Before = cr5.balanceOf(address(vault));

        vm.recordLogs();
        uint256 nonce = balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        assertEq(nonce, 1);

        assertLt(bond.balanceOf(address(vault)), bondBefore, "bond not sold");
        assertLt(cr5.balanceOf(address(vault)), cr5Before, "CR5 not redeemed");

        Vm.Log[] memory ev = vm.getRecordedLogs();
        bytes32 sig = keccak256("FirstRebalanceAction(uint256,address[],uint256[],uint256,uint256)");
        bool ok;
        for (uint256 i; i < ev.length; ++i) {
            if (ev[i].topics[0] == sig) {
                (address[] memory toks, uint256[] memory amts,,) =
                    abi.decode(ev[i].data, (address[], uint256[], uint256, uint256));
                assertEq(toks.length, 2, "should list 2 tokens");
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
        oracle.setCurrent(address(bond), 80e16); // 80% == 80%
        oracle.setCurrent(address(cr5), 20e16); // 20% == 20%

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

    function test_secondRebalanceAction_branch_firstDone_true() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        uint256 nonce = balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        vm.recordLogs();
        balancer.secondRebalanceAction(nonce);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SecondRebalanceAction(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (uint256 evNonce, uint256 ts) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(evNonce, nonce, "Event nonce mismatch");
                found = true;
                break;
            }
        }
        require(found, "SecondRebalanceAction event not emitted");
    }

    function test_checkFirstRebalanceOrdersStatus_branch_revert() public {
        uint256 invalidNonce = 1;
        vm.expectRevert("Wrong rebalance nonce!");
        balancer.checkFirstRebalanceOrdersStatus(invalidNonce);
    }

    function test_checkFirstRebalanceOrdersStatus_branch_True() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        bool result = balancer.checkFirstRebalanceOrdersStatus(1);
        assertTrue(result, "Should return true for valid rebalance nonce");
    }

    function test_checkSecondRebalanceOrdersStatus_revert_branch() public {
        uint256 invalidNonce = 1;
        vm.expectRevert("Wrong rebalance nonce!");
        balancer.checkSecondRebalanceOrdersStatus(invalidNonce);
    }

    function test_checkSecondRebalanceOrdersStatus_branch_true() public {
        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        bool result = balancer.checkSecondRebalanceOrdersStatus(1);
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
        vm.startPrank(address(this));
        factory.pause();
        vm.stopPrank();
        assertTrue(factory.paused(), "IndexFactory should be paused");

        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
    }

    function test_unpauseIndexFactory_branch309_true() public {
        IndexFactory indexFactory = IndexFactory(payable(address(store.indexFactory())));
        if (!indexFactory.paused()) {
            indexFactory.pause();
        }
        assertTrue(indexFactory.paused(), "IndexFactory should be paused before test");

        uint256 pBond = 2 * ONE_18;
        uint256 pCr5 = 1 * ONE_18;
        uint256 nonce = balancer.firstRebalanceAction(pBond, pCr5, new address[](0), new uint24[](0));
        balancer.completeRebalanceActions(nonce);
        assertTrue(!indexFactory.paused(), "IndexFactory should be unpaused after completeRebalanceActions");
    }
}
