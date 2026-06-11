// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageTokenTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "./helpers/ForageTokenV2.sol";
import "./helpers/ForageTokenV3.sol";
import "./helpers/ForageTokenV4.sol";

// ============================================================
// TC-09: Voting Power Snapshot Tests
// ============================================================
contract ForageToken_TC09_Snapshots is ForageTokenTestBase {
    function setUp() public override {
        super.setUp();
        _fundAlice(1000e18);
        _fundBob(500e18);
    }

    function test_TC09_clockReturnsTimestamp() public view {
        assertEq(token.clock(), uint48(block.timestamp));
    }

    function test_TC09_clockMode() public view {
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }

    function test_TC09_historicalVotes() public {
        vm.prank(alice);
        token.delegate(alice);
        uint256 delegationTime = block.timestamp;

        vm.warp(block.timestamp + 10);

        assertEq(token.getPastVotes(alice, delegationTime), 1000e18);
        if (delegationTime > 0) {
            assertEq(token.getPastVotes(alice, delegationTime - 1), 0);
        }
    }

    function test_TC09_delegationChangeSnapshot() public {
        vm.prank(alice);
        token.delegate(bob);
        uint256 timeN = block.timestamp;

        vm.warp(block.timestamp + 5);
        uint256 timeN5 = block.timestamp;

        vm.prank(alice);
        token.delegate(charlie);

        vm.warp(block.timestamp + 5);

        // Bob had votes between N and N+5
        assertEq(token.getPastVotes(bob, timeN + 2), 1000e18);
        // Bob lost votes after re-delegation
        assertEq(token.getPastVotes(bob, timeN5 + 2), 0);
        // Charlie gained votes
        assertEq(token.getPastVotes(charlie, timeN5 + 2), 1000e18);
    }

    function test_TC09_transferSnapshot() public {
        vm.prank(alice);
        token.delegate(alice);

        vm.prank(bob);
        token.delegate(bob);

        vm.warp(block.timestamp + 1);
        uint256 preTransferTime = block.timestamp;

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        token.transfer(bob, 300e18);
        uint256 postTransferTime = block.timestamp;

        vm.warp(block.timestamp + 5);

        assertEq(token.getPastVotes(alice, preTransferTime), 1000e18);
        assertEq(token.getPastVotes(alice, postTransferTime), 700e18);
        assertEq(token.getPastVotes(bob, postTransferTime), 800e18); // 500 + 300
    }

    function test_TC09_pastTotalSupplyAfterBurn() public {
        _setupBurner();

        vm.warp(block.timestamp + 1);
        uint256 preBurnTime = block.timestamp;

        vm.warp(block.timestamp + 1);
        vm.prank(authorizedBurner);
        token.burn(alice, 100e18);
        uint256 postBurnTime = block.timestamp;

        vm.warp(block.timestamp + 5);

        assertEq(token.getPastTotalSupply(preBurnTime), TOTAL_SUPPLY);
        assertEq(token.getPastTotalSupply(postBurnTime), TOTAL_SUPPLY - 100e18);
    }

    function test_TC09_futureBlockReverts() public {
        // VotesUpgradeable reverts with ERC5805FutureLookup for future timepoints
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC5805FutureLookup(uint256,uint48)")), block.timestamp + 1, uint48(block.timestamp)
            )
        );
        token.getPastVotes(alice, block.timestamp + 1);
    }

    function test_TC09_lockedTokensRetainVotingPower() public {
        _setupLocker();

        vm.prank(alice);
        token.delegate(alice);

        vm.warp(block.timestamp + 1);
        _lockTokens(alice, 500e18);
        uint256 lockTime = block.timestamp;

        vm.warp(block.timestamp + 5);

        assertEq(token.getPastVotes(alice, lockTime), 1000e18, "Locked tokens retain voting power");
    }

    function test_TC09_checkpointPayload() public {
        // Delegation creates first checkpoint
        vm.prank(alice);
        token.delegate(alice);
        uint256 numCp1 = token.numCheckpoints(alice);
        assertEq(numCp1, 1, "Should have exactly 1 checkpoint after delegation");

        // Verify first checkpoint has correct timestamp and voting power
        Checkpoints.Checkpoint208 memory cp0 = token.checkpoints(alice, 0);
        assertEq(cp0._key, uint48(block.timestamp), "Checkpoint 0 timestamp");
        assertEq(uint256(cp0._value), 1000e18, "Checkpoint 0 voting power");

        // Balance change (transfer out) at a new timestamp creates a new checkpoint
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        token.transfer(bob, 200e18);
        uint256 numCp2 = token.numCheckpoints(alice);
        assertEq(numCp2, 2, "Should have 2 checkpoints after transfer");

        Checkpoints.Checkpoint208 memory cp1 = token.checkpoints(alice, 1);
        assertEq(cp1._key, uint48(block.timestamp), "Checkpoint 1 timestamp");
        assertEq(uint256(cp1._value), 800e18, "Checkpoint 1 voting power after transfer");

        // Re-delegation to another creates another checkpoint
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        token.delegate(bob);
        uint256 numCp3 = token.numCheckpoints(alice);
        assertEq(numCp3, 3, "Should have 3 checkpoints after re-delegation");

        Checkpoints.Checkpoint208 memory cp2 = token.checkpoints(alice, 2);
        assertEq(uint256(cp2._value), 0, "Checkpoint 2: alice votes 0 after delegating away");
    }

    function test_TC09_noVotingPowerWithoutDelegation() public view {
        assertEq(token.getVotes(alice), 0, "No votes without delegation");
    }

    function test_TC09_getPastVotesWithoutDelegation() public {
        vm.warp(block.timestamp + 5);
        assertEq(token.getPastVotes(alice, block.timestamp - 1), 0, "No past votes without delegation");
    }

    function test_TC09_burnAffectsVotingSnapshot() public {
        _setupBurner();

        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 1000e18);

        vm.warp(block.timestamp + 1);
        uint256 preBurnTime = block.timestamp;

        vm.warp(block.timestamp + 1);
        vm.prank(authorizedBurner);
        token.burn(alice, 200e18);

        vm.warp(block.timestamp + 5);

        assertEq(token.getVotes(alice), 800e18);
        assertEq(token.getPastVotes(alice, preBurnTime), 1000e18);
    }
}

// ============================================================
// TC-10: Ownership Transfer Tests
// ============================================================
contract ForageToken_TC10_Ownership is ForageTokenTestBase {
    function test_TC10_proposeOwnershipWithEvent() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);
        token.transferOwnership(newOwner);

        assertEq(token.pendingOwner(), newOwner);
        assertEq(token.owner(), owner, "Owner not yet changed");
    }

    function test_TC10_acceptOwnershipWithEvent() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);
        token.acceptOwnership();

        assertEq(token.owner(), newOwner);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_TC10_nonOwnerProposeReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.transferOwnership(attacker);
    }

    function test_TC10_nonPendingOwnerAcceptReverts() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.acceptOwnership();
    }

    function test_TC10_overwritePendingOwner() public {
        address newOwner1 = makeAddr("newOwner1");
        address newOwner2 = makeAddr("newOwner2");

        vm.prank(owner);
        token.transferOwnership(newOwner1);

        vm.prank(owner);
        token.transferOwnership(newOwner2);

        assertEq(token.pendingOwner(), newOwner2);

        // Old pending owner cannot accept
        vm.prank(newOwner1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner1));
        token.acceptOwnership();
    }

    function test_TC10_renounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(ForageToken.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();

        assertEq(token.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    function test_TC10_afterRenounceContractImmutable() public {
        // renounceOwnership is disabled (OF-020), so this test verifies the revert
        vm.prank(owner);
        vm.expectRevert(ForageToken.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();

        // Owner is still set, so upgrades remain possible (ownership not renounced)
        assertEq(token.owner(), owner, "owner should remain unchanged after disabled renounce");
    }
}

// ============================================================
// TC-11: UUPS Upgrade Tests
// ============================================================
contract ForageToken_TC11_Upgrades is ForageTokenTestBase {
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _getImplAddress() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(token), ERC1967_IMPL_SLOT))));
    }

    function test_TC11_proxiableUUID() public view {
        // proxiableUUID is marked notDelegated in OZ UUPS — must call on implementation
        assertEq(implementation.proxiableUUID(), ERC1967_IMPL_SLOT);
    }

    function test_TC11_upgradeToV2() public {
        address implBefore = _getImplAddress();

        ForageTokenV2 v2Impl = new ForageTokenV2();

        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");

        // Implementation address changed
        address implAfter = _getImplAddress();
        assertTrue(implAfter != implBefore, "Implementation address must change after upgrade");
        assertEq(implAfter, address(v2Impl));

        // Cast to V2 to access new function
        ForageTokenV2 tokenV2 = ForageTokenV2(address(token));
        assertEq(tokenV2.version(), 2);

        // V1 state preserved
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(teamVesting), TEAM_ALLOCATION);
        assertEq(token.balanceOf(forageTreasury), FORAGE_TREASURY_ALLOCATION);
        assertEq(token.owner(), owner);
    }

    function test_TC11_nonOwnerUpgradeReverts() public {
        ForageTokenV2 v2Impl = new ForageTokenV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        token.upgradeToAndCall(address(v2Impl), "");
    }

    function test_TC11_multiGenerationUpgrade() public {
        // v1 -> v2
        ForageTokenV2 v2Impl = new ForageTokenV2();
        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");
        ForageTokenV2 tokenV2 = ForageTokenV2(address(token));
        assertEq(tokenV2.version(), 2);

        // v2 -> v3
        ForageTokenV3 v3Impl = new ForageTokenV3();
        vm.prank(owner);
        token.upgradeToAndCall(address(v3Impl), "");
        ForageTokenV3 tokenV3 = ForageTokenV3(address(token));
        assertEq(tokenV3.version(), 3);

        // v3 -> v4
        ForageTokenV4 v4Impl = new ForageTokenV4();
        vm.prank(owner);
        token.upgradeToAndCall(address(v4Impl), "");
        ForageTokenV4 tokenV4 = ForageTokenV4(address(token));
        assertEq(tokenV4.version(), 4);

        // All state preserved
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.owner(), owner);

        // V4 can still be upgraded (not bricked)
        ForageTokenV4 v4Impl2 = new ForageTokenV4();
        vm.prank(owner);
        token.upgradeToAndCall(address(v4Impl2), "");
    }

    function test_TC11_implementationV2CannotBeInitialized() public {
        ForageTokenV2 v2Impl = new ForageTokenV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2Impl.initialize(teamVesting, forageTreasury, owner);
    }

    function test_TC11_implementationV3CannotBeInitialized() public {
        ForageTokenV3 v3Impl = new ForageTokenV3();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v3Impl.initialize(teamVesting, forageTreasury, owner);
    }

    function test_TC11_storagePreservedAcrossUpgrade() public {
        _fundAlice(1000e18);
        _setupLocker();
        _setupBurner();

        // Lock some tokens
        _lockTokens(alice, 500e18);

        // Burn some tokens
        vm.prank(authorizedBurner);
        token.burn(alice, 100e18);

        // Delegate
        vm.prank(alice);
        token.delegate(charlie);

        uint256 aliceBalance = token.balanceOf(alice);
        uint256 aliceLocked = token.lockedBalance(alice);
        uint256 charlieVotes = token.getVotes(charlie);
        uint256 supply = token.totalSupply();

        // Upgrade to v2
        ForageTokenV2 v2Impl = new ForageTokenV2();
        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), "");

        // All state preserved — including locks, burns, delegations, AND roles
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.lockedBalance(alice), aliceLocked);
        assertEq(token.delegates(alice), charlie);
        assertEq(token.getVotes(charlie), charlieVotes);
        assertEq(token.totalSupply(), supply);

        // Burner role still works after upgrade
        vm.prank(authorizedBurner);
        token.burn(alice, 10e18);
        assertEq(token.balanceOf(alice), aliceBalance - 10e18);

        // Locker role still works after upgrade
        vm.prank(authorizedLocker);
        token.unlock(alice, 10e18);
        assertEq(token.lockedBalance(alice), aliceLocked - 10e18);
    }

    function test_TC11_upgradeWithInitData() public {
        ForageTokenV2 v2Impl = new ForageTokenV2();

        // Upgrade and set v2 new var in one call
        bytes memory initData = abi.encodeCall(ForageTokenV2.setV2NewVar, (42));
        vm.prank(owner);
        token.upgradeToAndCall(address(v2Impl), initData);

        ForageTokenV2 tokenV2 = ForageTokenV2(address(token));
        assertEq(tokenV2.getV2NewVar(), 42);
        assertEq(tokenV2.version(), 2);
    }
}
