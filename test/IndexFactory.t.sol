// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IndexToken} from "../src/token/IndexToken.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {IndexFactory} from "../src/factory/IndexFactory.sol";

contract MockUSDC is ERC20("USD Coin", "USDC") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract DummyReceiver {}

contract DummyOracle {
    mapping(address => bool) public isOperator;
}

contract IndexFactoryTest is Test {
    address alice = vm.addr(1);
    address feeRecv = vm.addr(2);

    MockUSDC usdc;
    IndexToken idx;
    IndexFactoryStorage store;
    IndexFactory factory;
    DummyReceiver sca;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        sca = new DummyReceiver();

        {
            IndexToken impl = new IndexToken();
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(IndexToken.initialize, ("IndexToken", "IDX", 5e14, feeRecv, 10_000_000 ether))
            );
            idx = IndexToken(address(p));
        }

        address oracleAddr = address(new DummyOracle());

        IndexFactoryStorage storeImpl = new IndexFactoryStorage();
        ERC1967Proxy storeProxy = new ERC1967Proxy(address(storeImpl), bytes(""));
        store = IndexFactoryStorage(address(storeProxy));

        IndexFactory factoryImpl = new IndexFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), bytes(""));
        factory = IndexFactory(address(factoryProxy));

        store.initialize(address(factory), oracleAddr, address(0), false, address(0));
        vm.prank(address(this));
        store.setFeeReceiver(feeRecv);

        factory.initialize(address(idx), address(sca), oracleAddr, address(usdc), address(store));

        usdc.mint(alice, 1_000_000 * ONE_USDC);
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
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
        assertEq(usdc.balanceOf(feeRecv), fee);
    }

    function testIssuanceZeroRevert() public {
        vm.expectRevert("Invalid input amount");
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
        vm.expectRevert("Invalid amount");
        factory.redemption(0);
        vm.stopPrank();
    }
}
