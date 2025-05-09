// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "forge-std/Test.sol";
import {IndexToken} from "../src/token/IndexToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./OlympixUnitTest.sol";

contract IndexTokenTest is OlympixUnitTest("IndexToken") {
    uint256 internal constant SCALAR = 1e20;

    IndexToken public indexToken;

    address feeReceiver = vm.addr(1);
    address newFeeReceiver = vm.addr(2);
    address minter = vm.addr(3);
    address newMinter = vm.addr(4);
    address methodologist = vm.addr(5);

    event FeeReceiverSet(address indexed feeReceiver);
    event FeeRateSet(uint256 indexed feeRatePerDayScaled);
    event MethodologistSet(address indexed methodologist);
    event MethodologySet(string methodology);
    event MinterSet(address indexed minter);
    event SupplyCeilingSet(uint256 supplyCeiling);
    event MintFeeToReceiver(address feeReceiver, uint256 timestamp, uint256 totalSupply, uint256 amount);
    event ToggledRestricted(address indexed account, bool isRestricted);

    error EnforcedPause();

    function setUp() public {
        IndexToken indexTokenImpl = new IndexToken();
        indexToken = IndexToken(
            address(
                new ERC1967Proxy(
                    address(indexTokenImpl),
                    abi.encodeCall(IndexToken.initialize, ("Magnificent 7", "MAG7", 1e18, feeReceiver, 1000000e18))
                )
            )
        );
        indexToken.setMinter(minter, true);
    }

    function testInitialized() public view {
        assertEq(indexToken.owner(), address(this));
        assertEq(indexToken.feeRatePerDayScaled(), 1e18);
        assertEq(indexToken.feeTimestamp(), block.timestamp);
        assertEq(indexToken.feeReceiver(), feeReceiver);
        assertEq(indexToken.methodology(), "");
        assertEq(indexToken.supplyCeiling(), 1000000e18);
        assertEq(indexToken.isMinter(minter), true);
    }

    function testMintOnlyMinter() public {
        vm.expectRevert("IndexToken: caller is not the minter");
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 0);
    }

    function testMintWhenNotPaused() public {
        indexToken.pause();
        vm.startPrank(minter);
        vm.expectRevert(EnforcedPause.selector);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 0);
        vm.stopPrank();

        indexToken.unpause();
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
    }

    function testMintExceedSupply() public {
        vm.startPrank(minter);
        vm.expectRevert("will exceed supply ceiling");
        indexToken.mint(address(this), 1000000e18 + 1);
        assertEq(indexToken.balanceOf(address(this)), 0);
        indexToken.mint(address(this), 1000000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000000e18);
    }

    function testMintToRestricted() public {
        indexToken.toggleRestriction(address(this));
        vm.startPrank(minter);
        vm.expectRevert("to is restricted");
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 0);
    }

    function testMintMsgRestricted() public {
        indexToken.toggleRestriction(minter);
        vm.startPrank(minter);
        vm.expectRevert("msg.sender is restricted");
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 0);
    }

    function testMint() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        assertEq(indexToken.totalSupply(), 1000e18);
    }

    function testBurnOnlyMinter() public {
        vm.expectRevert("IndexToken: caller is not the minter");
        indexToken.burn(address(this), 1000e18);
    }

    function testBurnWhenNotPaused() public {
        indexToken.pause();
        vm.startPrank(minter);
        vm.expectRevert(EnforcedPause.selector);
        indexToken.burn(address(this), 1000e18);
    }

    function testBurnFromIsRestricted() public {
        indexToken.toggleRestriction(address(this));
        vm.startPrank(minter);
        vm.expectRevert("from is restricted");
        indexToken.burn(address(this), 1000e18);
    }

    function testBurnMsgIsRestricted() public {
        indexToken.toggleRestriction(minter);
        vm.startPrank(minter);
        vm.expectRevert("msg.sender is restricted");
        indexToken.burn(address(this), 1000e18);
    }

    function testBurn() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        indexToken.burn(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 0);
    }

    function testMintForFeeReceiver() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        assertEq(indexToken.totalSupply(), 1000e18);

        uint256 newTime = block.timestamp + 1 days;
        vm.warp(newTime);

        uint256 feePerDay = indexToken.feeRatePerDayScaled();
        uint256 totalSupply = indexToken.totalSupply();
        uint256 expectedFeeAmount = ((feePerDay * totalSupply) / 1e20);
        vm.stopPrank();

        indexToken.mintToFeeReceiver();
        assertEq(indexToken.balanceOf(feeReceiver), expectedFeeAmount);
        assertEq(indexToken.totalSupply(), 1000e18 + expectedFeeAmount);
    }

    function testMintForFeeReceiverOneDay() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        assertEq(indexToken.totalSupply(), 1000e18);

        uint256 newTime = block.timestamp + 1 days;
        vm.warp(newTime);

        uint256 feePerDay = indexToken.feeRatePerDayScaled();
        uint256 totalSupply = indexToken.totalSupply();
        uint256 expectedFeeAmount = ((feePerDay * totalSupply) / 1e20);

        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 2000e18);
        assertEq(indexToken.balanceOf(feeReceiver), expectedFeeAmount);
        assertEq(indexToken.totalSupply(), 2000e18 + expectedFeeAmount);
    }

    function testMintForFeeReceiverTenDays() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        assertEq(indexToken.totalSupply(), 1000e18);
        uint256 newTime = block.timestamp + 10 days;
        vm.warp(newTime);
        uint256 _days = (block.timestamp - indexToken.feeTimestamp()) / 1 days;
        uint256 feePerDay = indexToken.feeRatePerDayScaled();
        uint256 totalSupply = indexToken.totalSupply();
        uint256 supply = totalSupply;

        uint256 compoundedFeeRate = SCALAR + (feePerDay * _days);
        supply = (supply * compoundedFeeRate) / SCALAR;

        uint256 expectedFeeAmount = supply - totalSupply;
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 2000e18);
        assertEq(indexToken.balanceOf(feeReceiver), expectedFeeAmount);
        assertEq(indexToken.totalSupply(), 2000e18 + expectedFeeAmount);
    }

    function testSetMethodologist() public {
        vm.expectEmit(true, true, true, true);
        emit MethodologistSet(methodologist);
        assertEq(indexToken.methodologist(), address(0));
        indexToken.setMethodologist(methodologist);
        assertEq(indexToken.methodologist(), methodologist);
    }

    function testSetMethodology() public {
        indexToken.setMethodologist(methodologist);
        assertEq(indexToken.methodologist(), methodologist);

        vm.expectRevert("IndexToken: caller is not the methodologist");
        indexToken.setMethodology("Test");

        vm.startPrank(methodologist);
        vm.expectEmit(true, true, true, true);
        emit MethodologySet("Test");

        assertEq(indexToken.methodology(), "");
        indexToken.setMethodology("Test");
        assertEq(indexToken.methodology(), "Test");
    }

    function testSetFeeRate() public {
        vm.expectEmit(true, true, true, true);
        emit FeeRateSet(2e18);

        assertEq(indexToken.feeRatePerDayScaled(), 1e18);
        indexToken.setFeeRate(2e18);
        assertEq(indexToken.feeRatePerDayScaled(), 2e18);
    }

    function testSetFeeReceiver() public {
        vm.expectEmit(true, true, true, true);
        emit FeeReceiverSet(newFeeReceiver);

        assertEq(indexToken.feeReceiver(), feeReceiver);
        indexToken.setFeeReceiver(newFeeReceiver);
        assertEq(indexToken.feeReceiver(), newFeeReceiver);
    }

    function testSetMinter() public {
        vm.expectEmit(true, true, true, true);
        emit MinterSet(newMinter);

        assertEq(indexToken.isMinter(minter), true);
        indexToken.setMinter(newMinter, true);
        assertEq(indexToken.isMinter(newMinter), true);
    }

    function testSetSupplyCeiling() public {
        vm.expectEmit(true, true, true, true);
        emit SupplyCeilingSet(2000000e18);

        assertEq(indexToken.supplyCeiling(), 1000000e18);
        indexToken.setSupplyCeiling(2000000e18);
        assertEq(indexToken.supplyCeiling(), 2000000e18);
    }

    function testToggleRestriction() public {
        vm.expectEmit(true, true, true, true);
        emit ToggledRestricted(minter, true);
        assertEq(indexToken.isRestricted(minter), false);

        indexToken.toggleRestriction(minter);
        assertEq(indexToken.isRestricted(minter), true);
        vm.expectEmit(true, true, true, true);
        emit ToggledRestricted(minter, false);

        indexToken.toggleRestriction(minter);
        assertEq(indexToken.isRestricted(minter), false);
    }

    function testTransferWhenNotPaused() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        vm.stopPrank();

        indexToken.pause();
        vm.expectRevert(EnforcedPause.selector);

        indexToken.transfer(minter, 100e18);
        indexToken.unpause();
        indexToken.transfer(minter, 100e18);

        assertEq(indexToken.balanceOf(address(this)), 900e18);
        assertEq(indexToken.balanceOf(minter), 100e18);
    }

    function testTransferWhenToIsRestricted() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        vm.stopPrank();

        indexToken.toggleRestriction(minter);
        vm.expectRevert("to is restricted");

        indexToken.transfer(minter, 100e18);
        indexToken.toggleRestriction(minter);
        indexToken.transfer(minter, 100e18);

        assertEq(indexToken.balanceOf(address(this)), 900e18);
        assertEq(indexToken.balanceOf(minter), 100e18);
    }

    function testTransferWhenMsgIsRestricted() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        assertEq(indexToken.balanceOf(minter), 1000e18);
        vm.stopPrank();

        indexToken.toggleRestriction(minter);

        vm.startPrank(minter);
        vm.expectRevert("msg.sender is restricted");
        indexToken.transfer(address(this), 100e18);
        vm.stopPrank();

        indexToken.toggleRestriction(minter);

        vm.startPrank(minter);
        indexToken.transfer(address(this), 100e18);
        assertEq(indexToken.balanceOf(address(this)), 100e18);
        assertEq(indexToken.balanceOf(minter), 900e18);
    }

    function testTransferFromWhenNotPaused() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        assertEq(indexToken.balanceOf(minter), 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        indexToken.pause();
        vm.expectRevert(EnforcedPause.selector);

        indexToken.transferFrom(minter, feeReceiver, 100e18);
        indexToken.unpause();
        indexToken.transferFrom(minter, feeReceiver, 100e18);

        assertEq(indexToken.balanceOf(feeReceiver), 100e18);
        assertEq(indexToken.balanceOf(minter), 900e18);
    }

    function testTransferFromWhenFromIsRestricted() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        assertEq(indexToken.balanceOf(minter), 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        indexToken.toggleRestriction(minter);
        vm.expectRevert("from is restricted");

        indexToken.transferFrom(minter, feeReceiver, 100e18);
        indexToken.toggleRestriction(minter);
        indexToken.transferFrom(minter, feeReceiver, 100e18);

        assertEq(indexToken.balanceOf(feeReceiver), 100e18);
        assertEq(indexToken.balanceOf(minter), 900e18);
    }

    function testTransferFromWhenToIsRestricted() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        assertEq(indexToken.balanceOf(minter), 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        indexToken.toggleRestriction(feeReceiver);
        vm.expectRevert("to is restricted");

        indexToken.transferFrom(minter, feeReceiver, 100e18);
        indexToken.toggleRestriction(feeReceiver);
        indexToken.transferFrom(minter, feeReceiver, 100e18);

        assertEq(indexToken.balanceOf(feeReceiver), 100e18);
        assertEq(indexToken.balanceOf(minter), 900e18);
    }

    function testTransferFromWhenMsgIsRestricted() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        assertEq(indexToken.balanceOf(minter), 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        indexToken.toggleRestriction(address(this));
        vm.expectRevert("msg.sender is restricted");

        indexToken.transferFrom(minter, feeReceiver, 100e18);
        indexToken.toggleRestriction(address(this));
        indexToken.transferFrom(minter, feeReceiver, 100e18);

        assertEq(indexToken.balanceOf(feeReceiver), 100e18);
        assertEq(indexToken.balanceOf(minter), 900e18);
    }

    function testInitialize_tokenNameEmpty_reverts() public {
        IndexToken indexTokenImpl = new IndexToken();
        vm.expectRevert(bytes("token name cannot be empty"));
        address proxy = address(
            new ERC1967Proxy(
                address(indexTokenImpl),
                abi.encodeCall(IndexToken.initialize, ("", "MAG7", 1e18, feeReceiver, 1000000e18))
            )
        );
    }

    function testInitialize_tokenSymbolEmpty_reverts() public {
        IndexToken indexTokenImpl = new IndexToken();
        vm.expectRevert(bytes("token symbol cannot be empty"));
        address proxy = address(
            new ERC1967Proxy(
                address(indexTokenImpl),
                abi.encodeCall(IndexToken.initialize, ("Magnificent 7", "", 1e18, feeReceiver, 1000000e18))
            )
        );
    }

    function testInitialize_feeRateZero_reverts() public {
        IndexToken indexTokenImpl = new IndexToken();
        vm.expectRevert(bytes("fee rate must be greater than 0"));
        address proxy = address(
            new ERC1967Proxy(
                address(indexTokenImpl),
                abi.encodeCall(IndexToken.initialize, ("Magnificent 7", "MAG7", 0, feeReceiver, 1000000e18))
            )
        );
    }

    function testInitialize_feeReceiverZeroAddress_reverts() public {
        IndexToken indexTokenImpl = new IndexToken();
        vm.expectRevert(bytes("fee receiver cannot be the zero address"));
        address proxy = address(
            new ERC1967Proxy(
                address(indexTokenImpl),
                abi.encodeCall(IndexToken.initialize, ("Magnificent 7", "MAG7", 1e18, address(0), 1000000e18))
            )
        );
    }

    function testInitialize_supplyCeilingZero_reverts() public {
        IndexToken indexTokenImpl = new IndexToken();
        vm.expectRevert(bytes("supply ceiling must be greater than 0"));
        address proxy = address(
            new ERC1967Proxy(
                address(indexTokenImpl),
                abi.encodeCall(IndexToken.initialize, ("Magnificent 7", "MAG7", 1e18, feeReceiver, 0))
            )
        );
    }

    function testMintToZeroAddress() public {
        address zero = address(0);
        vm.startPrank(minter);
        vm.expectRevert("mint to the zero address");
        indexToken.mint(zero, 1000e18);
        vm.stopPrank();
    }

    function testMintRevertsOnZeroAmount() public {
        vm.startPrank(minter);
        vm.expectRevert("mint amount must be greater than 0");
        indexToken.mint(address(this), 0);
        vm.stopPrank();
    }

    function testBurnFromZeroAddress() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        assertEq(indexToken.balanceOf(address(this)), 1000e18);
        vm.expectRevert("burn from the zero address");
        indexToken.burn(address(0), 100e18);
        vm.stopPrank();
    }

    function testMintToFeeReceiverExceedSupplyCeiling() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000000e18 - 1e18);
        assertEq(indexToken.totalSupply(), 1000000e18 - 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 feePerDay = indexToken.feeRatePerDayScaled();
        uint256 totalSupply = indexToken.totalSupply();
        uint256 expectedFeeAmount = (feePerDay * totalSupply) / 1e20;

        vm.expectRevert("will exceed supply ceiling");
        indexToken.mintToFeeReceiver();
    }

    function testSetMethodologistRevertsOnZeroAddress() public {
        vm.expectRevert();
        indexToken.setMethodologist(address(0));
    }

    function testSetMethodologyRevertsOnEmptyString() public {
        indexToken.setMethodologist(methodologist);
        assertEq(indexToken.methodologist(), methodologist);

        vm.startPrank(methodologist);
        vm.expectRevert("methodology cannot be empty");
        indexToken.setMethodology("");
        vm.stopPrank();
    }

    function testSetFeeReceiverRevertsOnZeroAddress() public {
        vm.expectRevert();
        indexToken.setFeeReceiver(address(0));
    }

    function testSetMinterRevertsOnZeroAddress() public {
        vm.expectRevert();
        indexToken.setMinter(address(0), true);
    }

    function testTransferToZeroAddress() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        vm.stopPrank();

        vm.expectRevert("transfer to the zero address");
        indexToken.transfer(address(0), 100e18);
    }

    function testTransferAmountExceedsBalance() public {
        vm.startPrank(minter);
        indexToken.mint(address(this), 1000e18);
        vm.stopPrank();

        vm.expectRevert("transfer amount exceeds balance");
        indexToken.transfer(feeReceiver, 2000e18);
    }

    function testTransferFromToZeroAddressReverts() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        vm.expectRevert("transfer to the zero address");
        indexToken.transferFrom(minter, address(0), 100e18);
    }

    function testTransferFromAmountExceedsBalance() public {
        vm.startPrank(minter);
        indexToken.mint(minter, 1000e18);
        indexToken.approve(address(this), 100e18);
        vm.stopPrank();

        vm.expectRevert("transfer amount exceeds balance");
        indexToken.transferFrom(minter, feeReceiver, 2000e18);
    }
}
