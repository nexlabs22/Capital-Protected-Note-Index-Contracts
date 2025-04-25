// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import {IndexToken} from "../src/token/IndexToken.sol";
import {IndexFactoryStorage} from "../src/factory/IndexFactoryStorage.sol";
import {StagingCustodyAccount} from "../src/SCA/StagingCustodyAccount.sol";
import {FunctionsOracle} from "../src/factory/FunctionsOracle.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDC is ERC20("USD Coin", "USDC") {
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
    IndexToken idx;
    TestFunctionsOracle oracle;
    IndexFactoryStorage store;
    StagingCustodyAccount sca;

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();

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

        {
            IndexFactoryStorage impl = new IndexFactoryStorage();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(IndexFactoryStorage.initialize, (factory, address(oracle), vault, false, nexBot))
            );
            store = IndexFactoryStorage(address(proxy));
        }

        {
            StagingCustodyAccount impl = new StagingCustodyAccount();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    StagingCustodyAccount.initialize,
                    (
                        address(idx),
                        factory,
                        address(0xDEADBEEF),
                        address(usdc),
                        factory,
                        address(store),
                        nexBot,
                        address(oracle)
                    )
                )
            );
            sca = StagingCustodyAccount(address(proxy));
        }

        vm.prank(address(this));
        store.transferOwnership(address(sca));

        idx.setMinter(address(sca), true);

        vm.startPrank(factory);
        store.addIssuanceForCurrentRound(alice, 60_000 * ONE_USDC);
        store.addIssuanceForCurrentRound(bob, 40_000 * ONE_USDC);
        vm.stopPrank();

        usdc.mint(address(sca), 100_000 * ONE_USDC);
    }

    function testWithdrawForPurchase() public {
        uint256 pre = usdc.balanceOf(nexBot);

        vm.prank(nexBot);
        sca.withdrawForPurchase(1);

        assertEq(usdc.balanceOf(address(sca)), 0);
        assertEq(usdc.balanceOf(nexBot), pre + 100_000 * ONE_USDC);
    }

    function testDistributeAndSettle() public {
        vm.prank(nexBot);
        sca.distributeTokens(1_000 ether, 1);

        assertEq(idx.balanceOf(alice), 600 ether);
        assertEq(idx.balanceOf(bob), 400 ether);
        assertEq(store.currentRoundId(), 1);

        assertTrue(store.issuanceIsCompleted(1));
    }

    function testCannotIssueIfPriorUnsettled() public {
        vm.prank(factory);
        store.addIssuanceForCurrentRound(alice, 100);

        vm.prank(operator);
        vm.expectRevert("Round is not active");
        sca.issuanceAndWithdrawForPurchase(2, 1_000e6, new address[](0), new uint24[](0));
    }
}
