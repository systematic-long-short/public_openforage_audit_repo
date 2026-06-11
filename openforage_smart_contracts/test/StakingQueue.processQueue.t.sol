// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-04: Queue Processing Tests
//        (R-21, R-22, R-23, R-24, R-25, R-26, R-27, R-28,
//         R-39, R-41, R-46, R-49, R-50)
// ============================================================
contract StakingQueue_TC04_ProcessQueue is StakingQueueTestBase {
    // ----- Step 1: Zero maxEntries reverts ZeroAmount -----
    function test_TC04_processQueueZeroMaxEntriesReverts() public {
        vm.prank(keeper);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.processQueue(0, 0);
    }

    // ----- Step 2: Invalid tier reverts InvalidTier -----
    function test_TC04_processQueueInvalidTierReverts() public {
        vm.prank(keeper);
        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.processQueue(4, 10);
    }

    // ----- Step 3: Paused reverts EnforcedPause -----
    function test_TC04_processQueuePausedReverts() public {
        _setGovernor();
        vm.prank(owner);
        queue.pause();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.processQueue(0, 10);
    }

    // ----- Step 4: No capacity reverts NoCapacityAvailable -----
    function test_TC04_processQueueNoCapacityReverts() public {
        // Fill capacity
        vault0.setMockTotalAssets(2_500_000e6);
        vault1.setMockTotalAssets(2_500_000e6);
        vault2.setMockTotalAssets(2_500_000e6);
        vault3.setMockTotalAssets(2_500_000e6);

        // Queue an entry
        _joinQueue(alice, 1000e6, 0);

        vm.prank(keeper);
        vm.expectRevert(StakingQueue.NoCapacityAvailable.selector);
        queue.processQueue(0, 10);
    }

    // ----- Step 5: Empty queue -- no-op, no events -----
    function test_TC04_processQueueEmptyQueueNoOp() public {
        // No entries queued. Should succeed silently.
        vm.prank(keeper);
        vm.recordLogs();
        queue.processQueue(0, 10);

        // Verify no QueueProcessed events emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 processedSig = keccak256("QueueProcessed(uint256,address,uint256,uint8)");
        uint256 processedCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == processedSig) {
                processedCount++;
            }
        }
        assertEq(processedCount, 0, "no QueueProcessed events should be emitted for empty queue");
    }

    // ----- Step 6: Standard lane FIFO single entry -----
    function test_TC04_processQueueStandardFifoSingle() public {
        uint256 amount = 1000e6;
        uint256 queueId = _joinQueue(alice, amount, 0);

        vm.expectEmit(true, true, true, true);
        emit StakingQueue.QueueProcessed(queueId, alice, amount, 0);

        vm.prank(keeper);
        queue.processQueue(0, 10);

        // Verify entry marked processed
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "entry should be marked processed");

        // Verify vault deposit called
        assertEq(vault0.depositCallCount(), 1, "should have 1 deposit call");
        (uint256 deposited, address depositor) = vault0.depositCalls(0);
        assertEq(deposited, amount, "deposit amount mismatch");
        assertEq(depositor, alice, "deposit depositor mismatch");

        // Verify totalQueuedRiskusd decreased
        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd should be 0");

        // Verify head advanced
        assertGt(queue.tierStandardHead(0), 0, "tierStandardHead(0) should advance");
    }

    // ----- Step 7: Standard lane FIFO multiple entries -----
    function test_TC04_processQueueStandardFifoMultiple() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 2000e6, 0);
        uint256 id3 = _joinQueue(charlie, 3000e6, 0);

        vm.prank(keeper);
        queue.processQueue(0, 10);

        // All three should be processed
        assertTrue(queue.getQueueEntry(id1).processed, "alice entry should be processed");
        assertTrue(queue.getQueueEntry(id2).processed, "bob entry should be processed");
        assertTrue(queue.getQueueEntry(id3).processed, "charlie entry should be processed");

        // Verify FIFO order via vault deposit calls
        assertEq(vault0.depositCallCount(), 3, "should have 3 deposit calls");

        // First deposit: alice (1000e6)
        (uint256 amt0, address dep0) = vault0.depositCalls(0);
        assertEq(dep0, alice, "first deposit should be for alice");
        assertEq(amt0, 1000e6, "first deposit amount mismatch");

        // Second deposit: bob (2000e6)
        (uint256 amt1, address dep1) = vault0.depositCalls(1);
        assertEq(dep1, bob, "second deposit should be for bob");
        assertEq(amt1, 2000e6, "second deposit amount mismatch");

        // Third deposit: charlie (3000e6)
        (uint256 amt2, address dep2) = vault0.depositCalls(2);
        assertEq(dep2, charlie, "third deposit should be for charlie");
        assertEq(amt2, 3000e6, "third deposit amount mismatch");
    }

    // ----- Step 8: maxEntries limit -----
    function test_TC04_processQueueMaxEntriesLimit() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 1000e6, 0);
        uint256 id3 = _joinQueue(charlie, 1000e6, 0);

        // Process only 2 of 3
        vm.prank(keeper);
        queue.processQueue(0, 2);

        assertTrue(queue.getQueueEntry(id1).processed, "first entry should be processed");
        assertTrue(queue.getQueueEntry(id2).processed, "second entry should be processed");
        assertFalse(queue.getQueueEntry(id3).processed, "third entry should NOT be processed");
        assertEq(queue.totalQueuedRiskusd(), 1000e6, "totalQueuedRiskusd should be 1000e6 (1 remaining)");
    }

    // ----- Step 9: Priority lane drains first -----
    function test_TC04_processQueuePriorityDrainsFirst() public {
        // Set up priority lane
        _activatePriority(1e6, 10);
        forage.setLockedBalance(alice, 2000e18);
        forage.setLockedBalance(bob, 0);

        uint256 tier = 1;
        uint256 priorityId = _joinQueue(alice, 1000e6, uint8(tier));
        uint256 standardId = _joinQueue(bob, 2000e6, uint8(tier));

        vm.prank(keeper);
        queue.processQueue(uint8(tier), 10);

        // Both should be processed, but priority (alice) first
        assertTrue(queue.getQueueEntry(priorityId).processed, "priority entry should be processed");
        assertTrue(queue.getQueueEntry(standardId).processed, "standard entry should be processed");

        // Verify order: alice deposit first, bob second
        assertGe(vault1.depositCallCount(), 2, "should have at least 2 deposit calls on vault1");
        (, address first) = vault1.depositCalls(0);
        (, address second) = vault1.depositCalls(1);
        assertEq(first, alice, "priority entry (alice) should be processed first");
        assertEq(second, bob, "standard entry (bob) should be processed second");
    }

    // ----- Step 10: Priority lane only -----
    function test_TC04_processQueuePriorityOnly() public {
        _activatePriority(1e6, 10);

        // Create 3 priority entries + 2 standard entries
        address user1 = makeAddr("p1");
        address user2 = makeAddr("p2");
        address user3 = makeAddr("p3");
        address user4 = makeAddr("s1");
        address user5 = makeAddr("s2");

        forage.setLockedBalance(user1, 2000e18);
        forage.setLockedBalance(user2, 2000e18);
        forage.setLockedBalance(user3, 2000e18);
        forage.setLockedBalance(user4, 0);
        forage.setLockedBalance(user5, 0);

        uint8 tier = 0;
        uint256 pid1 = _joinQueue(user1, 1000e6, tier);
        uint256 pid2 = _joinQueue(user2, 1000e6, tier);
        uint256 pid3 = _joinQueue(user3, 1000e6, tier);
        uint256 sid1 = _joinQueue(user4, 1000e6, tier);
        uint256 sid2 = _joinQueue(user5, 1000e6, tier);

        // Process only 3 -- should process all 3 priority, 0 standard
        vm.prank(keeper);
        queue.processQueue(tier, 3);

        assertTrue(queue.getQueueEntry(pid1).processed, "priority 1 should be processed");
        assertTrue(queue.getQueueEntry(pid2).processed, "priority 2 should be processed");
        assertTrue(queue.getQueueEntry(pid3).processed, "priority 3 should be processed");
        assertFalse(queue.getQueueEntry(sid1).processed, "standard 1 should NOT be processed");
        assertFalse(queue.getQueueEntry(sid2).processed, "standard 2 should NOT be processed");
    }

    // ----- Step 11: Priority lane exhausted then standard -----
    function test_TC04_processQueuePriorityExhaustedThenStandard() public {
        _activatePriority(1e6, 10);

        address user1 = makeAddr("p1");
        address user2 = makeAddr("p2");
        address user3 = makeAddr("s1");
        address user4 = makeAddr("s2");
        address user5 = makeAddr("s3");

        forage.setLockedBalance(user1, 2000e18);
        forage.setLockedBalance(user2, 2000e18);
        forage.setLockedBalance(user3, 0);
        forage.setLockedBalance(user4, 0);
        forage.setLockedBalance(user5, 0);

        uint8 tier = 0;
        uint256 pid1 = _joinQueue(user1, 1000e6, tier);
        uint256 pid2 = _joinQueue(user2, 1000e6, tier);
        uint256 sid1 = _joinQueue(user3, 1000e6, tier);
        uint256 sid2 = _joinQueue(user4, 1000e6, tier);
        uint256 sid3 = _joinQueue(user5, 1000e6, tier);

        // Process all 5 -- priority drains first (2), then standard (3)
        vm.prank(keeper);
        queue.processQueue(tier, 5);

        assertTrue(queue.getQueueEntry(pid1).processed, "priority 1 processed");
        assertTrue(queue.getQueueEntry(pid2).processed, "priority 2 processed");
        assertTrue(queue.getQueueEntry(sid1).processed, "standard 1 processed");
        assertTrue(queue.getQueueEntry(sid2).processed, "standard 2 processed");
        assertTrue(queue.getQueueEntry(sid3).processed, "standard 3 processed");

        // Verify priority was first (checking deposit order)
        assertGe(vault0.depositCallCount(), 5, "should have 5 deposit calls");
        (, address dep0) = vault0.depositCalls(0);
        (, address dep1) = vault0.depositCalls(1);
        assertEq(dep0, user1, "first deposit should be priority user1");
        assertEq(dep1, user2, "second deposit should be priority user2");
    }

    // ----- Step 12: Mixed cancelled entries in queue -----
    function test_TC04_processQueueSkipsCancelledEntries() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 2000e6, 0);

        // Alice cancels
        vm.prank(alice);
        queue.cancelQueue(id1);

        // Process queue -- should skip alice (cancelled), process bob
        vm.prank(keeper);
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(id1).cancelled, "alice entry should be cancelled");
        assertFalse(queue.getQueueEntry(id1).processed, "alice entry should NOT be processed");
        assertTrue(queue.getQueueEntry(id2).processed, "bob entry should be processed");
    }

    // ----- Step 13: Mixed processed entries -----
    function test_TC04_processQueueSkipsAlreadyProcessedEntries() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 2000e6, 0);
        uint256 id3 = _joinQueue(charlie, 3000e6, 0);

        // Process first entry only
        vm.prank(keeper);
        queue.processQueue(0, 1);

        assertTrue(queue.getQueueEntry(id1).processed, "first entry should be processed");
        assertFalse(queue.getQueueEntry(id2).processed, "second entry should NOT be processed yet");

        // Process remaining -- should skip already-processed entry
        vm.prank(keeper);
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(id2).processed, "second entry should now be processed");
        assertTrue(queue.getQueueEntry(id3).processed, "third entry should now be processed");
    }

    // ----- Step 14: No partial fill -----
    function test_TC04_processQueueNoPartialFill() public {
        // Set capacity to allow first entry but not second
        // Default capacity 10M; set staked to leave only 1000e6 remaining
        vault0.setMockTotalAssets(9_999_000e6);

        uint256 id1 = _joinQueue(alice, 800e6, 0);
        uint256 id2 = _joinQueue(bob, 600e6, 0);

        // Process: 800e6 fits in remaining ~1000e6 capacity.
        // After processing 800e6, only ~200e6 remaining.
        // 600e6 > 200e6 -- should NOT partially fill.
        vm.prank(keeper);
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(id1).processed, "800e6 entry should be processed");
        assertFalse(queue.getQueueEntry(id2).processed, "600e6 entry should NOT be processed (no partial fill)");
    }

    // ----- Step 15: Exact capacity match -----
    function test_TC04_processQueueExactCapacityMatch() public {
        // Leave exactly 1000e6 capacity
        vault0.setMockTotalAssets(9_999_000e6);

        uint256 queueId = _joinQueue(alice, 1000e6, 0);

        vm.prank(keeper);
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(queueId).processed, "exact capacity match should process");
    }

    // ----- Step 16: Capacity decreases between calls -----
    function test_TC04_processQueueCapacityDecreasesBetweenCalls() public {
        // Start with plenty of capacity
        uint256 id1 = _joinQueue(alice, 5_000_000e6, 0);
        uint256 id2 = _joinQueue(bob, 5_000_000e6, 0);

        // Process first entry -- consumes 5M of 10M capacity
        vm.prank(keeper);
        queue.processQueue(0, 1);

        assertTrue(queue.getQueueEntry(id1).processed, "first entry should be processed");
        // vault0 now has 5M in totalAssets (mock increments in deposit)

        // Process second entry -- 5M remaining capacity, 5M entry -- should work
        vm.prank(keeper);
        queue.processQueue(0, 1);

        assertTrue(queue.getQueueEntry(id2).processed, "second entry should be processed (capacity sufficient)");
    }

    // ----- Step 17: Per-tier isolation -----
    function test_TC04_processQueuePerTierIsolation() public {
        uint256 tier0Id = _joinQueue(alice, 1000e6, 0);
        uint256 tier1Id = _joinQueue(bob, 2000e6, 1);

        // Process only tier 0
        vm.prank(keeper);
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(tier0Id).processed, "tier 0 entry should be processed");
        assertFalse(queue.getQueueEntry(tier1Id).processed, "tier 1 entry should NOT be processed");

        // Tier 1 queue state unchanged
        assertEq(queue.tierStandardQueueLength(1), 1, "tier 1 standard queue length should still be 1");
    }

    // ----- Step 18: Head advancement past cancelled entries -----
    // OF-M04: maxEntries now caps total scanned entries (dead + live) to prevent DoS.
    // Callers must account for dead entries in their maxEntries budget.
    function test_TC04_processQueueHeadAdvancementPastCancelled() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 1000e6, 0);
        uint256 id3 = _joinQueue(charlie, 1000e6, 0);
        uint256 id4 = _joinQueue(dave, 1000e6, 0);
        uint256 id5 = _joinQueue(keeper, 1000e6, 0);

        // Cancel entries 2 and 3
        vm.prank(bob);
        queue.cancelQueue(id2);
        vm.prank(charlie);
        queue.cancelQueue(id3);

        // Process with maxEntries=5 (3 live + 2 dead = 5 total scans needed)
        // OF-M04: scan budget counts all iterations, not just processed entries
        vm.prank(alice);
        queue.processQueue(0, 5);

        assertTrue(queue.getQueueEntry(id1).processed, "entry 1 should be processed");
        assertTrue(queue.getQueueEntry(id2).cancelled, "entry 2 should remain cancelled");
        assertFalse(queue.getQueueEntry(id2).processed, "entry 2 should not be processed");
        assertTrue(queue.getQueueEntry(id3).cancelled, "entry 3 should remain cancelled");
        assertFalse(queue.getQueueEntry(id3).processed, "entry 3 should not be processed");
        assertTrue(queue.getQueueEntry(id4).processed, "entry 4 should be processed");
        assertTrue(queue.getQueueEntry(id5).processed, "entry 5 should be processed");
    }

    // ----- Step 19: Permissionless caller -----
    function test_TC04_processQueuePermissionless() public {
        _joinQueue(alice, 1000e6, 0);

        // Any address can call processQueue -- use attacker
        vm.prank(attacker);
        queue.processQueue(0, 10);

        // Should succeed without reverting
        assertEq(queue.totalQueuedRiskusd(), 0, "entry should have been processed by random caller");
    }

    // ----- Step 20: Event per processed entry -----
    function test_TC04_processQueueEventPerEntry() public {
        uint256 id1 = _joinQueue(alice, 1000e6, 0);
        uint256 id2 = _joinQueue(bob, 2000e6, 0);
        uint256 id3 = _joinQueue(charlie, 3000e6, 0);

        vm.prank(keeper);
        vm.recordLogs();
        queue.processQueue(0, 10);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 processedSig = keccak256("QueueProcessed(uint256,address,uint256,uint8)");

        uint256 processedEventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == processedSig) {
                processedEventCount++;
            }
        }
        assertEq(processedEventCount, 3, "should emit exactly 3 QueueProcessed events");

        // Verify events have correct queueIds (indexed as topics[1]) AND all 4 parameters
        uint256 eventIdx = 0;
        uint256[3] memory expectedIds = [id1, id2, id3];
        address[3] memory expectedDepositors = [alice, bob, charlie];
        uint256[3] memory expectedAmounts = [uint256(1000e6), uint256(2000e6), uint256(3000e6)];
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == processedSig) {
                // topics[1] = indexed queueId
                assertEq(uint256(logs[i].topics[1]), expectedIds[eventIdx], "QueueProcessed event queueId mismatch");
                // topics[2] = indexed depositor
                assertEq(
                    address(uint160(uint256(logs[i].topics[2]))),
                    expectedDepositors[eventIdx],
                    "QueueProcessed event depositor mismatch"
                );
                // data = (riskusdProcessed, tier) — non-indexed parameters
                (uint256 riskusdProcessed, uint8 tier) = abi.decode(logs[i].data, (uint256, uint8));
                assertEq(riskusdProcessed, expectedAmounts[eventIdx], "QueueProcessed event riskusdProcessed mismatch");
                assertEq(tier, 0, "QueueProcessed event tier mismatch");
                eventIdx++;
            }
        }
    }
}
