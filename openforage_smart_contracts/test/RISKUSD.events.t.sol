// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-13: Event Emission Tests
// ============================================================
contract RISKUSD_TC13_Events is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
        _setupGovernor();
    }

    /// @dev R-10, R-31: Mint emits Transfer(address(0), to, amount)
    function test_TC13_mintTransferEvent() public {
        vm.prank(minterAddr);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, 500e6);
        token.mint(alice, 500e6);
    }

    /// @dev R-16, R-31: Burn emits Transfer(from, address(0), amount)
    function test_TC13_burnTransferEvent() public {
        _mintTokens(alice, 1000e6);

        vm.prank(minterAddr);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), 400e6);
        token.burn(alice, 400e6);
    }

    /// @dev R-31, R-32: Transfer emits Transfer(from, to, amount)
    function test_TC13_transferTransferEvent() public {
        _mintTokens(alice, 1000e6);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, bob, 300e6);
        token.transfer(bob, 300e6);
    }

    /// @dev R-31, R-32: TransferFrom emits Transfer(from, to, amount)
    function test_TC13_transferFromTransferEvent() public {
        _mintTokens(alice, 1000e6);

        vm.prank(alice);
        token.approve(bob, 500e6);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, charlie, 200e6);
        token.transferFrom(alice, charlie, 200e6);
    }

    /// @dev R-31, R-32: Approve emits Approval(owner, spender, amount)
    function test_TC13_approvalEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(alice, bob, 500e6);
        token.approve(bob, 500e6);
    }

    /// @dev R-19, R-31: setMinter emits MinterProposed; finalizeMinter emits MinterUpdated
    function test_TC13_minterUpdatedEvent() public {
        address newMinter = makeAddr("newMinter");

        // setMinter now emits MinterProposed (delegated to proposeMinter)
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.MinterProposed(minterAddr, newMinter);
        token.setMinter(newMinter);

        vm.warp(block.timestamp + 2 days + 1);

        // finalizeMinter emits MinterUpdated
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.MinterUpdated(minterAddr, newMinter);
        token.finalizeMinter();
    }

    /// @dev R-23, R-31: setForageGovernor emits ForageGovernorProposed; finalize emits ForageGovernorSet
    function test_TC13_forageGovernorSetEvent() public {
        address newGovernor = makeAddr("newGovernor");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.ForageGovernorProposed(governorAddr, newGovernor);
        token.setForageGovernor(newGovernor);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, false, true);
        emit RISKUSD.ForageGovernorSet(governorAddr, newGovernor);
        token.finalizeForageGovernor();
        vm.stopPrank();
    }

    /// @dev R-31: pause() emits Paused, unpause() emits Unpaused
    function test_TC13_pausedUnpausedEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PausableUpgradeable.Paused(owner);
        token.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PausableUpgradeable.Unpaused(owner);
        token.unpause();
    }

    /// @dev R-31: Ownership transfer emits OwnershipTransferStarted and OwnershipTransferred
    function test_TC13_ownershipTransferEvents() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);
        token.acceptOwnership();
    }
}
