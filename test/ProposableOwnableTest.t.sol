// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import "../src/proposable/ProposableOwnable.sol";

contract ProposableOwnableMock is ProposableOwnable {
    constructor() Ownable(msg.sender) {
        _transferOwnership(msg.sender);
    }
}

contract ProposableOwnableTest is Test {
    ProposableOwnableMock proposableOwnable;
    address owner;
    address proposedOwner;

    function setUp() public {
        owner = address(this);
        proposedOwner = address(0x1234);
        proposableOwnable = new ProposableOwnableMock();
    }

    function testInitialOwner() public view {
        assertEq(proposableOwnable.owner(), owner);
    }

    function testProposeOwner() public {
        proposableOwnable.proposeOwner(proposedOwner);

        assertEq(proposableOwnable.proposedOwner(), proposedOwner);
    }

    function testProposeOwnerRevertsIfZeroAddress() public {
        vm.expectRevert("ProposableOwnable: new owner is the zero address");
        proposableOwnable.proposeOwner(address(0));
    }

    function testTransferOwnershipRevertsIfNotProposedOwner() public {
        proposableOwnable.proposeOwner(proposedOwner);

        vm.expectRevert("ProposableOwnable: this call must be made by the new owner");
        proposableOwnable.transferOwnership(proposedOwner);
    }

    function testTransferOwnershipRevertsIfZeroAddress() public {
        vm.expectRevert("ProposableOwnable: new owner is the zero address");
        proposableOwnable.transferOwnership(address(0));
    }

    function testTransferOwnershipRevertsIfProposedMismatch() public {
        proposableOwnable.proposeOwner(proposedOwner);

        address anotherAddress = address(0x5678);
        vm.prank(proposedOwner);
        vm.expectRevert("ProposableOwnable: new owner is not proposed owner");
        proposableOwnable.transferOwnership(anotherAddress);
    }
}
