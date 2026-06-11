// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-10: Pause/Unpause Tests (L3 steps 1-15)
// Requirements: R-45, R-46, R-50
// ============================================================
contract StakingQueue_TC10_Pause is StakingQueueTestBase {
    /// @dev L3 step 1: Owner can pause. Assert paused() == true. Paused(owner) event emitted.
    function test_TC10_ownerCanPause() public {
        vm.expectEmit(true, false, false, false);
        emit PausableUpgradeable.Paused(owner);

        vm.prank(owner);
        queue.pause();

        assertTrue(queue.paused(), "contract should be paused after owner pause");
    }

    /// @dev L3 step 2: Owner can unpause. Assert paused() == false. Unpaused(owner) event emitted.
    function test_TC10_ownerCanUnpause() public {
        vm.prank(owner);
        queue.pause();
        assertTrue(queue.paused(), "contract should be paused");

        vm.expectEmit(true, false, false, false);
        emit PausableUpgradeable.Unpaused(owner);

        vm.prank(owner);
        queue.unpause();

        assertFalse(queue.paused(), "contract should not be paused after owner unpause");
    }

    /// @dev L3 step 3: Governor can pause. ForageGovernor calls pause(). MUST succeed.
    function test_TC10_governorCanPause() public {
        _setGovernor();

        vm.prank(governor);
        queue.pause();

        assertTrue(queue.paused(), "contract should be paused after governor pause");
    }

    /// @dev L3 step 4: Governor can unpause. ForageGovernor calls unpause(). MUST succeed.
    function test_TC10_governorCanUnpause() public {
        _setGovernor();

        vm.prank(governor);
        queue.pause();
        assertTrue(queue.paused(), "contract should be paused");

        vm.prank(governor);
        queue.unpause();

        assertFalse(queue.paused(), "contract should not be paused after governor unpause");
    }

    /// @dev L3 step 5: Unauthorized pause. Random address calls pause() -- MUST revert.
    /// pause() has dual authority (owner OR governor). An unauthorized caller MUST revert.
    function test_TC10_unauthorizedPauseReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        queue.pause();
    }

    /// @dev L3 step 6: Unauthorized unpause. Random address calls unpause() -- MUST revert.
    /// unpause() has dual authority (owner OR governor). An unauthorized caller MUST revert.
    function test_TC10_unauthorizedUnpauseReverts() public {
        vm.prank(owner);
        queue.pause();

        vm.prank(attacker);
        vm.expectRevert();
        queue.unpause();
    }

    /// @dev L3 step 7: Pause blocks joinQueue. Paused state -- joinQueue() MUST revert EnforcedPause.
    function test_TC10_pauseBlocksJoinQueue() public {
        vm.prank(owner);
        queue.pause();

        _fundUser(alice, STANDARD_DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.joinQueue(STANDARD_DEPOSIT, 0);
    }

    /// @dev L3 step 8: Pause blocks processQueue. Paused state -- processQueue() MUST revert EnforcedPause.
    function test_TC10_pauseBlocksProcessQueue() public {
        // Queue an entry first while unpaused
        _joinQueue(alice, STANDARD_DEPOSIT, 0);

        vm.prank(owner);
        queue.pause();

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.processQueue(0, 1);
    }

    /// @dev L3 step 9: Pause blocks upgradeTier. Paused state -- upgradeTier() MUST revert EnforcedPause.
    function test_TC10_pauseBlocksUpgradeTier() public {
        vm.prank(owner);
        queue.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.upgradeTier(0, 1, 100e6);
    }

    /// @dev L3 step 10: Pause blocks processExpiredLockups. Paused state -- MUST revert EnforcedPause.
    function test_TC10_pauseBlocksProcessExpiredLockups() public {
        vm.prank(owner);
        queue.pause();

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.processExpiredLockups(depositors, 1);
    }

    /// @dev L3 step 11: Pause does NOT block cancelQueue. Exit path open.
    function test_TC10_pauseDoesNotBlockCancelQueue() public {
        // Queue an entry while unpaused
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        vm.prank(owner);
        queue.pause();

        // Cancel should succeed even while paused
        vm.prank(alice);
        queue.cancelQueue(queueId);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.cancelled, "entry should be cancelled even while paused");
    }

    /// @dev L3 step 12: Pause does NOT block owner config functions.
    ///      setForagePriceUsd, setPriorityMultiplier, setForageGovernor MUST succeed.
    function test_TC10_pauseDoesNotBlockConfigFunctions() public {
        vm.prank(owner);
        queue.pause();

        // Capacity is now read from VaultRegistry via combinedCapacity() view -- verify it's readable while paused
        queue.combinedCapacity();

        // setForagePriceUsd should propose/finalize while paused
        vm.startPrank(owner);
        queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();
        assertEq(queue.foragePriceUsd(), 1e6, "setForagePriceUsd should work while paused");

        // setPriorityMultiplier should succeed
        vm.prank(owner);
        queue.setPriorityMultiplier(10);
        assertEq(queue.priorityMultiplier(), 10, "setPriorityMultiplier should work while paused");

        // setForageGovernor should succeed (propose + finalize)
        vm.startPrank(owner);
        queue.setForageGovernor(governor);
        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForageGovernor();
        vm.stopPrank();
        assertEq(queue.forageGovernor(), governor, "setForageGovernor should work while paused");
    }

    /// @dev L3 step 13: Pause does NOT block view functions. All view functions callable while paused.
    function test_TC10_pauseDoesNotBlockViewFunctions() public {
        // Queue an entry while unpaused
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        vm.prank(owner);
        queue.pause();

        // All view functions should succeed while paused
        queue.riskusd();
        queue.forage();
        queue.forageGovernor();
        queue.tierVault(0);
        queue.combinedCapacity();
        queue.combinedStaked();
        queue.availableCapacity();
        queue.totalQueuedRiskusd();
        queue.foragePriceUsd();
        queue.priorityMultiplier();
        queue.tierPriorityQueueLength(0);
        queue.tierStandardQueueLength(0);
        queue.tierPriorityHead(0);
        queue.tierStandardHead(0);
        queue.getQueueEntry(queueId);
        queue.nextQueueId();
        queue.owner();
        queue.pendingOwner();
        queue.paused();

        assertTrue(true, "all view functions should be callable while paused");
    }

    /// @dev L3 step 14: Unpause restores functionality. After unpause, all blocked functions work again.
    function test_TC10_unpauseRestoresFunctionality() public {
        vm.prank(owner);
        queue.pause();

        vm.prank(owner);
        queue.unpause();

        // joinQueue should work again
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertEq(entry.depositor, alice, "joinQueue should work after unpause");

        // processQueue should work again
        queue.processQueue(0, 1);
        entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "processQueue should work after unpause");
    }

    /// @dev L3 step 15: Governor not set (address(0)). Only owner can pause/unpause.
    ///      Governor check with address(0) fails.
    function test_TC10_governorNotSetOnlyOwnerCanPause() public {
        // ForageGovernor is address(0) by default -- do NOT set it
        assertEq(queue.forageGovernor(), address(0), "governor should be address(0)");

        // address(0) cannot call pause (it is not a valid caller)
        // A random non-owner address should fail.
        // pause() has dual authority (owner OR governor). An unauthorized caller MUST revert.
        vm.prank(attacker);
        vm.expectRevert();
        queue.pause();

        // Owner can still pause
        vm.prank(owner);
        queue.pause();
        assertTrue(queue.paused(), "owner should be able to pause when governor is address(0)");

        // Owner can still unpause
        vm.prank(owner);
        queue.unpause();
        assertFalse(queue.paused(), "owner should be able to unpause when governor is address(0)");
    }
}
