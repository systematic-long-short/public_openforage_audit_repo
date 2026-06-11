// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-07: Refund / Queue Cancellation Tests (L3 steps 1-11)
// ============================================================
contract StakingQueue_TC07_CancelQueue is StakingQueueTestBase {
    /// @dev L3 step 1: cancelQueue with invalid queueId 0 MUST revert InvalidQueueEntry.
    function test_TC07_cancelQueueInvalidIdZero() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidQueueEntry.selector);
        queue.cancelQueue(0);
    }

    /// @dev L3 step 2: cancelQueue with non-existent queueId MUST revert InvalidQueueEntry.
    function test_TC07_cancelQueueNonExistentId() public {
        // Create 3 entries
        _joinQueue(alice, STANDARD_DEPOSIT, 0);
        _joinQueue(bob, STANDARD_DEPOSIT, 0);
        _joinQueue(charlie, STANDARD_DEPOSIT, 0);

        // Try to cancel queueId 999 (does not exist)
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidQueueEntry.selector);
        queue.cancelQueue(999);
    }

    /// @dev L3 step 3: cancelQueue by non-depositor MUST revert NotQueueEntryDepositor.
    function test_TC07_cancelQueueNotDepositor() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        vm.prank(bob);
        vm.expectRevert(StakingQueue.NotQueueEntryDepositor.selector);
        queue.cancelQueue(queueId);
    }

    /// @dev L3 step 4: cancelQueue on already processed entry MUST revert QueueEntryAlreadyProcessed.
    function test_TC07_cancelQueueAlreadyProcessed() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Process the queue
        queue.processQueue(0, 10);

        // Verify entry was processed
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "entry should be processed");

        // Try to cancel processed entry
        vm.prank(alice);
        vm.expectRevert(StakingQueue.QueueEntryAlreadyProcessed.selector);
        queue.cancelQueue(queueId);
    }

    /// @dev L3 step 5: cancelQueue on already cancelled entry MUST revert QueueEntryAlreadyCancelled.
    function test_TC07_cancelQueueAlreadyCancelled() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Cancel once
        vm.prank(alice);
        queue.cancelQueue(queueId);

        // Try to cancel again
        vm.prank(alice);
        vm.expectRevert(StakingQueue.QueueEntryAlreadyCancelled.selector);
        queue.cancelQueue(queueId);
    }

    /// @dev L3 step 6: cancelQueue happy path.
    ///      RISKUSD returned, entry marked cancelled, totalQueuedRiskusd decremented, event emitted.
    function test_TC07_cancelQueueHappyPath() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        uint256 totalQueuedBefore = queue.totalQueuedRiskusd();

        vm.expectEmit(true, true, false, true);
        emit StakingQueue.QueueCancelled(queueId, alice, STANDARD_DEPOSIT);

        vm.prank(alice);
        queue.cancelQueue(queueId);

        // Verify RISKUSD returned to alice
        uint256 aliceBalAfter = riskusd.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, STANDARD_DEPOSIT, "alice should receive RISKUSD refund");

        // Verify entry marked cancelled
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.cancelled, "entry should be marked cancelled");

        // Verify totalQueuedRiskusd decreased
        assertEq(
            queue.totalQueuedRiskusd(),
            totalQueuedBefore - STANDARD_DEPOSIT,
            "totalQueuedRiskusd should decrease by deposit amount"
        );
    }

    /// @dev L3 step 7: cancelQueue while paused MUST succeed. Exit path remains open.
    function test_TC07_cancelQueueWhilePaused() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Pause the contract
        vm.prank(owner);
        queue.pause();

        // Cancel should succeed even while paused
        uint256 aliceBalBefore = riskusd.balanceOf(alice);

        vm.prank(alice);
        queue.cancelQueue(queueId);

        uint256 aliceBalAfter = riskusd.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, STANDARD_DEPOSIT, "alice should receive refund even while paused");

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.cancelled, "entry should be cancelled while paused");
    }

    /// @dev L3 step 8: Cancel does not affect other entries.
    ///      Alice and Bob queue. Alice cancels. Bob's entry unchanged and processable.
    function test_TC07_cancelDoesNotAffectOtherEntries() public {
        uint256 aliceId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 bobId = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        // Alice cancels
        vm.prank(alice);
        queue.cancelQueue(aliceId);

        // Verify Bob's entry is unchanged
        StakingQueue.QueueEntry memory bobEntry = queue.getQueueEntry(bobId);
        assertEq(bobEntry.depositor, bob, "bob entry depositor should be bob");
        assertEq(bobEntry.riskusdAmount, STANDARD_DEPOSIT, "bob entry amount should be unchanged");
        assertFalse(bobEntry.cancelled, "bob entry should NOT be cancelled");
        assertFalse(bobEntry.processed, "bob entry should NOT be processed");

        // Bob's entry can still be processed
        queue.processQueue(0, 10);

        StakingQueue.QueueEntry memory bobAfter = queue.getQueueEntry(bobId);
        assertTrue(bobAfter.processed, "bob entry should be processed after processQueue");
    }

    /// @dev L3 step 9: Cancel middle entry in queue.
    ///      Alice, Bob, Charlie queue in order. Bob cancels.
    ///      processQueue processes Alice, skips Bob (cancelled), processes Charlie.
    function test_TC07_cancelMiddleEntry() public {
        uint256 aliceId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 bobId = _joinQueue(bob, STANDARD_DEPOSIT, 0);
        uint256 charlieId = _joinQueue(charlie, STANDARD_DEPOSIT, 0);

        // Bob cancels
        vm.prank(bob);
        queue.cancelQueue(bobId);

        // Process all
        queue.processQueue(0, 10);

        // Alice processed
        StakingQueue.QueueEntry memory aliceEntry = queue.getQueueEntry(aliceId);
        assertTrue(aliceEntry.processed, "alice entry should be processed");

        // Bob cancelled (not processed)
        StakingQueue.QueueEntry memory bobEntry = queue.getQueueEntry(bobId);
        assertTrue(bobEntry.cancelled, "bob entry should be cancelled");
        assertFalse(bobEntry.processed, "bob entry should NOT be processed");

        // Charlie processed
        StakingQueue.QueueEntry memory charlieEntry = queue.getQueueEntry(charlieId);
        assertTrue(charlieEntry.processed, "charlie entry should be processed");
    }

    /// @dev L3 step 10: Multiple cancellations.
    ///      Queue 5 entries. Cancel entries 2 and 4. Verify totalQueuedRiskusd decremented
    ///      correctly. Entries 1, 3, 5 are processable.
    function test_TC07_multipleCancellations() public {
        // Queue 5 entries from different users
        uint256 id1 = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 id2 = _joinQueue(bob, STANDARD_DEPOSIT, 0);
        uint256 id3 = _joinQueue(charlie, STANDARD_DEPOSIT, 0);
        uint256 id4 = _joinQueue(dave, STANDARD_DEPOSIT, 0);
        uint256 id5 = _joinQueue(keeper, STANDARD_DEPOSIT, 0);

        uint256 totalQueuedAfterAll = queue.totalQueuedRiskusd();
        assertEq(totalQueuedAfterAll, STANDARD_DEPOSIT * 5, "totalQueuedRiskusd should be 5x deposit");

        // Cancel entries 2 and 4
        vm.prank(bob);
        queue.cancelQueue(id2);

        assertEq(
            queue.totalQueuedRiskusd(),
            STANDARD_DEPOSIT * 4,
            "totalQueuedRiskusd should decrease by 1 after first cancel"
        );

        vm.prank(dave);
        queue.cancelQueue(id4);

        assertEq(
            queue.totalQueuedRiskusd(),
            STANDARD_DEPOSIT * 3,
            "totalQueuedRiskusd should decrease by 2 after second cancel"
        );

        // Process remaining entries
        queue.processQueue(0, 10);

        // Verify entries 1, 3, 5 are processed
        assertTrue(queue.getQueueEntry(id1).processed, "entry 1 should be processed");
        assertTrue(queue.getQueueEntry(id3).processed, "entry 3 should be processed");
        assertTrue(queue.getQueueEntry(id5).processed, "entry 5 should be processed");

        // Verify entries 2, 4 remain cancelled (not processed)
        assertTrue(queue.getQueueEntry(id2).cancelled, "entry 2 should be cancelled");
        assertFalse(queue.getQueueEntry(id2).processed, "entry 2 should NOT be processed");
        assertTrue(queue.getQueueEntry(id4).cancelled, "entry 4 should be cancelled");
        assertFalse(queue.getQueueEntry(id4).processed, "entry 4 should NOT be processed");
    }

    /// @dev L3 step 11: Cancel then re-queue. Alice cancels entry and joins again.
    ///      Gets new entry with new queueId. Old entry remains cancelled.
    function test_TC07_cancelThenReQueue() public {
        uint256 oldId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Cancel the old entry
        vm.prank(alice);
        queue.cancelQueue(oldId);

        // Re-queue
        uint256 newId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Old entry remains cancelled
        StakingQueue.QueueEntry memory oldEntry = queue.getQueueEntry(oldId);
        assertTrue(oldEntry.cancelled, "old entry should remain cancelled");

        // New entry is active
        StakingQueue.QueueEntry memory newEntry = queue.getQueueEntry(newId);
        assertEq(newEntry.depositor, alice, "new entry depositor should be alice");
        assertFalse(newEntry.cancelled, "new entry should NOT be cancelled");
        assertFalse(newEntry.processed, "new entry should NOT be processed");

        // New ID should be different from old
        assertTrue(newId > oldId, "new queueId should be greater than old queueId");
    }
}
