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
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";
import {IRiskAssetFactory} from "../src/interfaces/IRiskAssetFactory.sol";
import {FeeVault} from "../src/vault/FeeVault.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";
import "../src/libraries/FeeCalculation.sol";

error ZeroAmount();
error OrderAlreadyCancelled();
error WrongETHAmount();
error InvalidRoundId();

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

contract DummyCrypto5Factory is IRiskAssetFactory {
    MockIDXc5 public immutable idxc5;

    constructor(address _idxc5) {
        idxc5 = MockIDXc5(_idxc5);
    }

    function issuanceIndexTokens(address, address[] calldata, uint24[] calldata, uint256 amt) external payable {
        idxc5.mint(msg.sender, amt);
    }

    function redemption(uint256, address, address[] calldata, uint24[] calldata) external payable {}

    function getIssuanceFee(address, address[] calldata, uint24[] calldata, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 10;
    }

    function getRedemptionFee(uint256) external pure override returns (uint256) {
        return 10;
    }
}

contract TestFunctionsOracle is FunctionsOracle {
    function seed(uint8[] calldata assetTypes, address[] calldata comps, uint256[] calldata shares) external {
        _initData(assetTypes, comps, shares);
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
    LinkToken link;
    Token token0;
    Token token1;
    FeeVault feeVault;

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

        feeVault = FeeVault(
            address(new ERC1967Proxy(address(new FeeVault()), abi.encodeCall(FeeVault.initialize, (address(store)))))
        );

        sca = StagingCustodyAccount(payable(address(new ERC1967Proxy(address(new StagingCustodyAccount()), ""))));

        factory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));

        oracle = TestFunctionsOracle(payable(address(new ERC1967Proxy(address(new TestFunctionsOracle()), ""))));

        address[] memory comps = new address[](2);
        uint256[] memory shares = new uint256[](2);
        uint8[] memory types = new uint8[](2);
        comps[0] = address(bond);
        shares[0] = 80e18;
        types[0] = 0;
        comps[1] = address(idxc5);
        shares[1] = 20e18;
        types[1] = 1;
        oracle.seed(types, comps, shares);

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
            address(feeVault),
            address(1)
        );
        store.setFeeReceiver(feeRec);

        sca.initialize(address(store));
        vault.setOperator(address(sca), true);
        sca.transferOwnership(address(factory));
        factory.initialize(address(store), address(feeVault));

        idx.setMinter(owner, true);

        deal(alice, 10 ether);

        usdc.mint(alice, 1_000_000 * ONE_USDC);
        usdc.mint(bob, 1_000_000 * ONE_USDC);
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(factory), type(uint256).max);
    }

    // function testIncreaseRoundIdNonOwnerAddr() public {
    //     vm.startPrank(alice);
    //     vm.expectRevert("Caller is not the owner or operator");
    //     factoryStorage.increaseCurrentRoundId();
    // }

    // function testCancelIssuanceWithNonRequesterAddress() public {
    //     uint256 inputAmount = 10e18;
    //     deal(address(usdc), alice, 20e18);
    //     vm.startPrank(alice);
    //     IERC20(usdc).approve(address(factory), inputAmount + 1e16);
    //     factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), inputAmount);
    //     vm.stopPrank();

    //     vm.startPrank(bob);
    //     vm.expectRevert("Only requester can cancel");
    //     factory.cancelIssuance(1);
    //     vm.stopPrank();
    // }

    function testIssuanceHappyPath() public {
        uint256 inAmt = 10_000 * ONE_USDC;
        uint256 fee = (inAmt * 10) / 10000;

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(store.issuanceRoundId(), 1, alice, address(usdc), inAmt, fee, block.timestamp);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), inAmt);

        assertEq(nonce, 1);
        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), inAmt);
        assertEq(usdc.balanceOf(address(feeVault)), fee);
    }

    function test_increaseCurrentRoundId_FailWhenSenderIsNotOwnerOrOperator() public {
        vm.startPrank(alice);
        vm.expectRevert("Caller is not a factory contract");
        store.increaseIssuanceRoundId();
        vm.stopPrank();
    }

    function test_increaseCurrentRoundId_SuccessfulIncreaseCurrentRoundId() public {
        vm.prank(address(factory));
        store.increaseIssuanceRoundId();
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
        vm.expectRevert("Caller is not a factory contract");
        store.increaseIssuanceRoundId();
    }

    function testIssuance_HappyPath() public {
        uint256 amount = 10_000 * ONE_USDC;
        uint256 fee = (amount * 10) / 10000;

        console.log("Nex Bot balance After: ", address(nexBot).balance);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit IndexFactory.RequestIssuance(
            store.issuanceRoundId(), 1, alice, address(usdc), amount, fee, block.timestamp
        );
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amount);

        console.log("Nex Bot balance After: ", address(nexBot).balance);

        assertEq(factory.issuanceNonce(), 1);
        assertEq(usdc.balanceOf(address(sca)), amount);
        assertEq(usdc.balanceOf(address(feeVault)), fee);
        assertEq(store.issuanceInputAmount(1), amount);
    }

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

        deal(bob, 1 ether);

        vm.prank(alice);
        uint256 n1 = factory.redemption{value: 10}(aliceIdx);

        vm.prank(bob);
        uint256 n2 = factory.redemption{value: 10}(bobIdx);

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

    function testIssuance_updatesStorageAndRoundData() public {
        uint256 amt = 25_000 * ONE_USDC;
        uint256 fee = (amt * 10) / 10000;

        vm.startPrank(alice);
        uint256 n =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        assertEq(n, 1);
        assertEq(factory.issuanceNonce(), 1);

        assertEq(usdc.balanceOf(address(sca)), amt);
        assertEq(usdc.balanceOf(address(feeVault)), fee);

        assertEq(store.totalIssuanceByRound(1), amt);
        assertEq(store.issuanceAmountByRoundUser(1, alice), amt);
        assertEq(store.issuanceInputAmount(n), amt);
        assertEq(store.issuanceRequesterByNonce(n), alice);
        assertEq(store.issuanceRoundActive(1), true);
    }

    function testIssuance_feeChargedExactly() public {
        uint256 amt = 42_000 * ONE_USDC;
        uint256 fee = amt * store.feeRate() / 10_000;

        uint256 before = usdc.balanceOf(address(feeVault));
        vm.startPrank(alice);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        uint256 afterBal = usdc.balanceOf(address(feeVault));

        assertEq(afterBal - before, fee, "fee mismatch");
    }

    function testFullIssuanceFlow_Single() public {
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(sca), true);
        // oracle.setOperator(address(nexBot), true);
        vm.stopPrank();

        vm.startPrank(idx.owner());
        idx.setMinter(address(sca), true);
        vm.stopPrank();

        uint256 inAmt = 100_000 * ONE_USDC;

        console.log("Nex bot balance before issuance: ", address(nexBot).balance);

        vm.startPrank(alice);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), inAmt);
        assertEq(usdc.balanceOf(address(sca)), inAmt);
        vm.stopPrank();

        console.log("Nex bot balance after issuance: ", address(nexBot).balance);

        vm.startPrank(nexBot);
        sca.requestIssuance{value: 10}(1, new address[](0), new uint24[](0));
        vm.stopPrank();

        console.log("Nex bot balance after request issuance: ", address(nexBot).balance);

        uint256 toBot = inAmt * 80 / 100;
        assertEq(usdc.balanceOf(nexBot), toBot);

        uint256 bernQty = 50_000 ether;
        bond.mint(address(sca), bernQty);

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.startPrank(nexBot);
        sca.completeIssuance(1, bondPrice, c5Price);
        vm.stopPrank();

        uint256 usdcFee = FeeCalculation.calculateFee(inAmt, store.feeRate());

        // assertEq(idx.balanceOf(alice), expectedMint);
        assertEq(bond.balanceOf(address(vault)), bernQty);
        assertEq(idxc5.balanceOf(address(vault)), inAmt / 5 - usdcFee);

        assertTrue(store.issuanceIsCompleted(1));
    }

    function testFullIssuanceFlow_ThreeUsers() public {
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(sca), true);
        vm.stopPrank();

        vm.startPrank(idx.owner());
        idx.setMinter(address(sca), true);
        vm.stopPrank();

        address carol = vm.addr(9);
        deal(bob, 1 ether);
        deal(carol, 1 ether);
        usdc.mint(carol, 1_000_000 * ONE_USDC);
        vm.startPrank(carol);
        usdc.approve(address(factory), type(uint256).max);
        vm.stopPrank();

        uint256 aAmt = 60_000 * ONE_USDC;
        uint256 bAmt = 30_000 * ONE_USDC;
        uint256 cAmt = 10_000 * ONE_USDC;
        uint256 totalIn = aAmt + bAmt + cAmt;

        console.log("Nex bot balance before issuance: ", address(nexBot).balance);

        vm.startPrank(alice);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), aAmt);
        vm.stopPrank();

        vm.startPrank(bob);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), bAmt);
        vm.stopPrank();

        vm.startPrank(carol);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), cAmt);
        vm.stopPrank();

        console.log("Nex bot balance after issuance: ", address(nexBot).balance);

        vm.startPrank(nexBot);
        sca.requestIssuance{value: 10}(1, new address[](0), new uint24[](0));
        vm.stopPrank();

        console.log("Nex bot balance after requestIssuance: ", address(nexBot).balance);

        bond.mint(address(sca), 77_000 ether);
        // idxc5.mint(address(sca), 77_000 ether);

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;
        vm.startPrank(nexBot);
        sca.completeIssuance(1, bondPrice, c5Price);
        vm.stopPrank();

        assertEq(idxc5.balanceOf(address(vault)), totalIn / 5);
        assertTrue(store.issuanceIsCompleted(1));
    }

    function testFullIssuanceFlow_FirstRound_Price100() public {
        vm.startPrank(oracle.owner());
        oracle.setOperator(address(sca), true);
        vm.stopPrank();

        vm.prank(idx.owner());
        idx.setMinter(address(sca), true);

        address carol = vm.addr(9);
        deal(bob, 1 ether);
        deal(carol, 1 ether);

        usdc.mint(carol, 1_000_000 * ONE_USDC);

        vm.startPrank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(factory), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carol);
        usdc.approve(address(factory), type(uint256).max);
        vm.stopPrank();

        uint256 aAmt = 60_000 * ONE_USDC;
        uint256 bAmt = 30_000 * ONE_USDC;
        uint256 cAmt = 10_000 * ONE_USDC;
        // uint256 totalUSDCin = aAmt + bAmt + cAmt;

        vm.startPrank(alice);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), aAmt);
        vm.stopPrank();

        vm.startPrank(bob);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), bAmt);
        vm.stopPrank();

        vm.startPrank(carol);
        factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), cAmt);
        vm.stopPrank();

        vm.prank(nexBot);
        sca.requestIssuance{value: 10}(1, new address[](0), new uint24[](0));

        uint256 bondQty = 77_000 ether;

        bond.mint(address(sca), bondQty);

        uint256 bondPrice = 2e18;
        uint256 c5Price = 1e18;

        vm.prank(nexBot);
        sca.completeIssuance(1, bondPrice, c5Price);

        uint256 c5Bal = idxc5.balanceOf(address(vault));
        uint256 newValue = (bondQty * bondPrice) / 1e18 + (c5Bal * c5Price) / 1e18;

        uint256 expectedMint = newValue / 100;

        assertEq(idx.totalSupply(), expectedMint, "IDX minted mismatch");
        assertEq(
            idx.balanceOf(alice) + idx.balanceOf(bob) + idx.balanceOf(carol), expectedMint, "distribution mismatch"
        );
        assertTrue(store.issuanceIsCompleted(1));
    }

    function test_initialize_revertsOnZeroIndexFactoryStorage() public {
        address zero = address(0);
        address someFeeVault = address(0x1234);
        IndexFactory freshFactory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));
        vm.expectRevert(bytes("Invalid Address"));
        freshFactory.initialize(zero, someFeeVault);
    }

    function test_initialize_revertsOnZeroFeeVault() public {
        IndexFactory freshFactory = IndexFactory(address(new ERC1967Proxy(address(new IndexFactory()), "")));
        vm.expectRevert(bytes("Invalid FeeVault"));
        freshFactory.initialize(address(store), address(0));
    }

    function test_setIssuanceFeeByNonce_FailsWhenSenderIsNotFactoryNexBotOrSCA() public {
        uint256 nonce = 123;
        uint256 fee = 4567;
        address notAllowed = address(0xBEEF);
        vm.prank(notAllowed);
        vm.expectRevert("Caller is not a factory contract");
        store.setIssuanceFeeByNonce(nonce, fee);
    }

    function test_unpause_requiresOwnerOrOperator() public {
        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator");
        factory.unpause();
        vm.stopPrank();
    }

    function test_unpause_ownerCanUnpause() public {
        vm.prank(address(this));
        factory.pause();
        assertTrue(factory.paused());
        vm.prank(address(this));
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_redemption_revertsOnWrongEthFee() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.startPrank(alice);
        vm.expectRevert(WrongETHAmount.selector);
        factory.redemption{value: 5}(idxAmount);
        vm.stopPrank();
    }

    function test_issuanceIndexTokens_revertsOnZeroAmount() public {
        address tokenIn = address(store.usdc());
        address[] memory tokenInPath = new address[](0);
        uint24[] memory tokenInFees = new uint24[](0);
        uint256 inputAmount = 0;

        vm.expectRevert(ZeroAmount.selector);
        factory.issuanceIndexTokens{value: 0}(tokenIn, tokenInPath, tokenInFees, inputAmount);
    }

    function test_issuanceIndexTokens_revertsOnWrongETHAmount() public {
        address tokenIn = address(store.usdc());
        address[] memory tokenInPath = new address[](0);
        uint24[] memory tokenInFees = new uint24[](0);
        uint256 inputAmount = 1000 * ONE_USDC;
        uint256 correctEthFee = 10;
        uint256 wrongEthFee = 5;

        deal(address(usdc), alice, inputAmount);
        vm.prank(alice);
        usdc.approve(address(factory), inputAmount + 1e16);

        vm.startPrank(alice);
        vm.expectRevert(WrongETHAmount.selector);
        factory.issuanceIndexTokens{value: wrongEthFee}(tokenIn, tokenInPath, tokenInFees, inputAmount);
        vm.stopPrank();
    }

    function test_cancelIssuance_branch_issuanceRequestCancelled_true1() public {
        uint256 amt = 10_000 * ONE_USDC;
        vm.startPrank(alice);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setIssuanceRequestCancelled(nonce, true);
        assertTrue(store.issuanceRequestCancelled(nonce));

        vm.startPrank(alice);
        vm.expectRevert(OrderAlreadyCancelled.selector);
        factory.cancelIssuance(nonce);
        vm.stopPrank();
    }

    function test_cancelIssuance_branch_onlyRequesterCanCancel_opix_target_branch_173_True() public {
        uint256 amt = 10_000 * ONE_USDC;
        vm.startPrank(alice);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("Only requester can cancel");
        factory.cancelIssuance(nonce);
        vm.stopPrank();
    }

    function test_cancelIssuance_branch_onlyRequesterCanCancel_opix_target_branch_173_False() public {
        uint256 amt = 10_000 * ONE_USDC;
        vm.startPrank(alice);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        vm.startPrank(alice);

        factory.cancelIssuance(nonce);
        vm.stopPrank();

        assertTrue(store.issuanceIsCompleted(nonce));
        assertTrue(store.issuanceRequestCancelled(nonce));
    }

    function test_cancelIssuance_branch_amountIsZero_opix_target_branch_177_True() public {
        uint256 nonce = 99;
        vm.prank(address(factory));
        store.setIssuanceRequesterByNonce(nonce, alice);
        vm.prank(address(factory));
        store.setIssuanceRoundToNonce(nonce, 1);
        vm.prank(address(factory));
        store.setIssuanceRoundActive(1, true);
        vm.startPrank(alice);
        vm.expectRevert(bytes("nothing to refund"));
        factory.cancelIssuance(nonce);
        vm.stopPrank();
    }

    function test_cancelIssuance_branch_issuanceRoundActive_false_opix_target_branch_183_False() public {
        uint256 amt = 10_000 * ONE_USDC;
        vm.startPrank(alice);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        vm.prank(address(factory));
        store.setIssuanceRoundActive(1, false);
        assertFalse(store.issuanceRoundActive(1));

        vm.startPrank(alice);
        vm.expectRevert(bytes("round not active"));
        factory.cancelIssuance(nonce);
        vm.stopPrank();
    }

    function test_cancelIssuance_branch_balanceOfSCA_lt_amount_opix_target_branch_185_True() public {
        uint256 amt = 10_000 * ONE_USDC;
        vm.startPrank(alice);
        uint256 nonce =
            factory.issuanceIndexTokens{value: 10}(address(store.usdc()), new address[](0), new uint24[](0), amt);
        vm.stopPrank();

        address scaAddr = address(sca);
        address dummy = address(0xdead);
        vm.prank(scaAddr);
        usdc.transfer(dummy, amt);
        assertEq(usdc.balanceOf(scaAddr), 0);

        vm.startPrank(alice);
        vm.expectRevert(bytes("USDC already deployed"));
        factory.cancelIssuance(nonce);
        vm.stopPrank();
    }

    function test_cancelRedemption_branch_redemptionRequestCancelled_true1() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.prank(alice);
        uint256 nonce = factory.redemption{value: 10}(idxAmount);

        vm.prank(address(factory));
        store.setRedemptionRequestCancelled(nonce, true);
        assertTrue(store.redemptionRequestCancelled(nonce));

        vm.startPrank(alice);
        vm.expectRevert(OrderAlreadyCancelled.selector);
        factory.cancelRedemption(nonce);
        vm.stopPrank();
    }

    function test_cancelRedemption_onlyRequesterCanCancel_branch_coverage_opix_target_branch_205_True() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.prank(alice);
        uint256 nonce = factory.redemption{value: 10}(idxAmount);

        vm.startPrank(bob);
        vm.expectRevert("Only requester can cancel");
        factory.cancelRedemption(nonce);
        vm.stopPrank();
    }

    function test_cancelRedemption_onlyRequesterCanCancel_branch_coverage_opix_target_branch_205_False() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.prank(alice);
        uint256 nonce = factory.redemption{value: 10}(idxAmount);

        vm.startPrank(alice);
        factory.cancelRedemption(nonce);
        vm.stopPrank();

        assertTrue(store.redemptionRequestCancelled(nonce));
        assertTrue(store.redemptionIsCompleted(nonce));
    }

    function test_cancelRedemption_branch_amountIsZero_opix_target_branch_208_True() public {
        uint256 nonce = 99;
        vm.prank(address(factory));
        store.setRedemptionRequesterByNonce(nonce, alice);
        vm.prank(address(factory));
        store.setRedemptionRoundToNonce(nonce, 1);
        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, true);
        idx.mint(address(sca), 100 ether);

        vm.startPrank(alice);
        vm.expectRevert(bytes("nothing to refund"));
        factory.cancelRedemption(nonce);
        vm.stopPrank();
    }

    function test_cancelRedemption_branch_redemptionRoundActive_false_opix_target_branch_211_False() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.prank(alice);
        uint256 nonce = factory.redemption{value: 10}(idxAmount);

        vm.prank(address(factory));
        store.setRedemptionRoundActive(1, false);
        assertFalse(store.redemptionRoundActive(1));

        vm.startPrank(alice);
        vm.expectRevert(bytes("round not active"));
        factory.cancelRedemption(nonce);
        vm.stopPrank();
    }

    function test_cancelRedemption_branch_balanceOfSCA_lt_amount_opix_target_branch_213_True() public {
        uint256 idxAmount = 100 ether;
        _mintAndApproveIdx(alice, idxAmount);

        vm.prank(alice);
        uint256 nonce = factory.redemption{value: 10}(idxAmount);

        address scaAddr = address(sca);
        address dummy = address(0xdead);
        vm.prank(scaAddr);
        idx.transfer(dummy, idxAmount);
        assertEq(idx.balanceOf(scaAddr), 0);

        vm.startPrank(alice);
        vm.expectRevert(bytes("IDX already deployed")); // opix-target-branch-213-True
        factory.cancelRedemption(nonce);
        vm.stopPrank();
    }

    function test_pause_branch_coverage_opix_target_branch_233_True() public {
        vm.startPrank(alice);
        vm.expectRevert("Caller is not the owner or operator"); // opix-target-branch-233-True
        factory.pause();
        vm.stopPrank();
    }
}
