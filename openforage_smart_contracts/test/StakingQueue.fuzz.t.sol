// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";

// ============================================================
// TC-17: Fuzz Tests (R-10, R-13, R-14, R-15, R-20, R-21,
//        R-22, R-23, R-25, R-26, R-28, R-35, R-36, R-38, R-41)
// 7 fuzz functions testing queue mechanics, capacity enforcement,
// and state consistency under randomized inputs.
// ============================================================
contract StakingQueue_TC17_Fuzz is StakingQueueTestBase {
    /// @dev Fuzz 1: joinQueue with any valid amount and tier.
    /// Verify totalQueuedRiskusd increases, nextQueueId increments,
    /// RISKUSD transferred from caller to queue.
    function testFuzz_joinQueue_anyValidAmount(uint256 amount, uint8 tierRaw) public {
        uint256 bounded = bound(amount, 1, 1e15);
        uint8 tier = uint8(bound(tierRaw, 0, 3));

        // Fund alice
        riskusd.mint(alice, bounded);
        vm.prank(alice);
        riskusd.approve(address(queue), bounded);

        uint256 queuedBefore = queue.totalQueuedRiskusd();
        uint256 nextIdBefore = queue.nextQueueId();
        uint256 balanceBefore = riskusd.balanceOf(alice);

        vm.prank(alice);
        queue.joinQueue(bounded, tier);

        // Assert: totalQueuedRiskusd increased by bounded
        assertEq(
            queue.totalQueuedRiskusd(), queuedBefore + bounded, "totalQueuedRiskusd must increase by deposit amount"
        );

        // Assert: nextQueueId incremented
        assertEq(queue.nextQueueId(), nextIdBefore + 1, "nextQueueId must increment by 1");

        // Assert: RISKUSD transferred from alice to queue
        assertEq(
            riskusd.balanceOf(alice), balanceBefore - bounded, "Alice's RISKUSD balance must decrease by deposit amount"
        );
        assertEq(riskusd.balanceOf(address(queue)), bounded, "Queue must hold deposited RISKUSD");
    }

    /// @dev Fuzz 2: processQueue preserves FIFO order.
    /// Queue multiple entries, process with fuzzed maxEntries,
    /// verify entries processed in queueId order.
    function testFuzz_processQueue_fifoPreserved(uint256 seed, uint256 maxEntries) public {
        uint256 numEntries = bound(seed, 2, 10);
        uint256 boundedMax = bound(maxEntries, 1, numEntries);

        // Queue numEntries entries for tier 0
        uint256[] memory queueIds = new uint256[](numEntries);
        for (uint256 i = 0; i < numEntries; i++) {
            address user = i % 2 == 0 ? alice : bob;
            queueIds[i] = _joinQueue(user, STANDARD_DEPOSIT, 0);
        }

        // Process boundedMax entries
        vm.prank(keeper);
        queue.processQueue(0, boundedMax);

        // Verify entries processed in order: first boundedMax entries should be processed
        for (uint256 i = 0; i < boundedMax; i++) {
            StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueIds[i]);
            assertTrue(entry.processed, "Entry must be processed in FIFO order");
        }

        // Remaining entries should NOT be processed
        for (uint256 i = boundedMax; i < numEntries; i++) {
            StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueIds[i]);
            assertFalse(entry.processed, "Entry beyond maxEntries must not be processed");
        }

        // Verify totalQueuedRiskusd decreased correctly
        uint256 expectedQueued = (numEntries - boundedMax) * STANDARD_DEPOSIT;
        assertEq(queue.totalQueuedRiskusd(), expectedQueued, "totalQueuedRiskusd must reflect remaining entries");
    }

    /// @dev Fuzz 3: cancelQueue always returns the correct refund amount.
    function testFuzz_cancelQueue_refundCorrect(uint256 amount) public {
        uint256 bounded = bound(amount, 1, 1e15);

        // Fund and join
        riskusd.mint(alice, bounded);
        vm.prank(alice);
        riskusd.approve(address(queue), bounded);
        vm.prank(alice);
        queue.joinQueue(bounded, 0);

        uint256 queueId = queue.nextQueueId() - 1;
        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        uint256 queuedBefore = queue.totalQueuedRiskusd();

        // Cancel
        vm.prank(alice);
        queue.cancelQueue(queueId);

        // Assert: RISKUSD returned to depositor
        assertEq(riskusd.balanceOf(alice), aliceBalBefore + bounded, "Alice must receive full refund");

        // Assert: totalQueuedRiskusd decreased
        assertEq(
            queue.totalQueuedRiskusd(), queuedBefore - bounded, "totalQueuedRiskusd must decrease by cancelled amount"
        );

        // Assert: entry marked cancelled
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.cancelled, "Entry must be marked cancelled");
    }

    /// @dev Fuzz 4: Capacity enforcement with varying capacity and staked amounts.
    /// availableCapacity == max(0, combinedCapacity - combinedStaked).
    /// processQueue halts when no capacity.
    function testFuzz_capacityEnforcement(
        uint256 capacity,
        uint256 staked0,
        uint256 staked1,
        uint256 staked2,
        uint256 staked3
    ) public {
        uint256 boundedCapacity = bound(capacity, 1, 100_000_000e6);
        uint256 boundedStaked0 = bound(staked0, 0, 25_000_000e6);
        uint256 boundedStaked1 = bound(staked1, 0, 25_000_000e6);
        uint256 boundedStaked2 = bound(staked2, 0, 25_000_000e6);
        uint256 boundedStaked3 = bound(staked3, 0, 25_000_000e6);

        // Set combined capacity via VaultRegistry
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, boundedCapacity);

        // Set mock totalAssets for each vault
        vault0.setMockTotalAssets(boundedStaked0);
        vault1.setMockTotalAssets(boundedStaked1);
        vault2.setMockTotalAssets(boundedStaked2);
        vault3.setMockTotalAssets(boundedStaked3);

        // Verify combinedStaked
        uint256 totalStaked = boundedStaked0 + boundedStaked1 + boundedStaked2 + boundedStaked3;
        assertEq(queue.combinedStaked(), totalStaked, "combinedStaked must equal sum of tier vault totalAssets");

        // Verify availableCapacity formula
        uint256 expectedAvailable = totalStaked >= boundedCapacity ? 0 : boundedCapacity - totalStaked;
        assertEq(queue.availableCapacity(), expectedAvailable, "availableCapacity must equal max(0, capacity - staked)");

        // If availableCapacity is 0, verify processQueue halts
        if (expectedAvailable == 0) {
            // Queue an entry so there is something to process
            uint256 depositAmount = 1e6;
            riskusd.mint(alice, depositAmount);
            vm.prank(alice);
            riskusd.approve(address(queue), depositAmount);
            vm.prank(alice);
            queue.joinQueue(depositAmount, 0);

            // processQueue must revert with NoCapacityAvailable when capacity is exhausted
            vm.prank(keeper);
            vm.expectRevert(StakingQueue.NoCapacityAvailable.selector);
            queue.processQueue(0, 1);
        }
    }

    /// @dev Fuzz 5: Mixed cancel and process operations maintain state consistency.
    function testFuzz_mixedCancelAndProcess(uint256 seed) public {
        uint256 numEntries = bound(seed, 3, 8);

        // Queue entries
        uint256[] memory queueIds = new uint256[](numEntries);
        uint256[] memory amounts = new uint256[](numEntries);
        for (uint256 i = 0; i < numEntries; i++) {
            amounts[i] = STANDARD_DEPOSIT;
            queueIds[i] = _joinQueue(alice, amounts[i], 0);
        }

        uint256 totalQueued = numEntries * STANDARD_DEPOSIT;
        assertEq(queue.totalQueuedRiskusd(), totalQueued, "Initial total must match");

        // Cancel every other entry (entries at odd indices)
        uint256 cancelledCount = 0;
        for (uint256 i = 1; i < numEntries; i += 2) {
            vm.prank(alice);
            queue.cancelQueue(queueIds[i]);
            cancelledCount++;
        }

        // Verify totalQueuedRiskusd after cancels
        uint256 expectedAfterCancel = totalQueued - (cancelledCount * STANDARD_DEPOSIT);
        assertEq(queue.totalQueuedRiskusd(), expectedAfterCancel, "totalQueuedRiskusd must reflect cancellations");

        // Process remaining entries
        uint256 remainingEntries = numEntries - cancelledCount;
        vm.prank(keeper);
        queue.processQueue(0, uint256(numEntries));

        // Verify: cancelled entries were skipped, non-cancelled were processed
        for (uint256 i = 0; i < numEntries; i++) {
            StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueIds[i]);
            if (i % 2 == 1) {
                assertTrue(entry.cancelled, "Odd entries must be cancelled");
                assertFalse(entry.processed, "Cancelled entries must not be processed");
            } else {
                assertTrue(entry.processed, "Even entries must be processed");
                assertFalse(entry.cancelled, "Processed entries must not be cancelled");
            }
        }

        // totalQueuedRiskusd must be 0 after all active entries processed
        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd must be 0 after processing all remaining");
    }

    /// @dev Fuzz 6: Max value operations do not cause overflow.
    /// If amount == 0: revert ZeroAmount. Otherwise: tests the full uint256 range.
    /// Large values that exceed ERC-20 balance cause revert (expected).
    /// Values within mintable range must succeed without overflow.
    function testFuzz_maxValueOperations(uint256 amount) public {
        if (amount == 0) {
            // Must revert with ZeroAmount
            vm.prank(alice);
            vm.expectRevert(StakingQueue.ZeroAmount.selector);
            queue.joinQueue(0, 0);
            return;
        }

        // Use the full uint256 range -- bound up to type(uint256).max
        uint256 bounded = bound(amount, 1, type(uint256).max);

        // Fund alice and deposit -- mint the full amount
        riskusd.mint(alice, bounded);
        vm.prank(alice);
        riskusd.approve(address(queue), bounded);

        uint256 queuedBefore = queue.totalQueuedRiskusd();

        vm.prank(alice);
        queue.joinQueue(bounded, 0);

        assertEq(
            queue.totalQueuedRiskusd(), queuedBefore + bounded, "Large deposit must not overflow totalQueuedRiskusd"
        );
    }

    /// @dev Fuzz 7: Dual lane processing -- priority entries processed before standard.
    function testFuzz_dualLaneProcessing(uint256 numPriority, uint256 numStandard, uint256 maxEntries) public {
        uint256 boundedPriority = bound(numPriority, 1, 5);
        uint256 boundedStandard = bound(numStandard, 1, 5);
        uint256 totalEntries = boundedPriority + boundedStandard;
        uint256 boundedMax = bound(maxEntries, 1, totalEntries);

        // Activate priority: price=1e6, multiplier=10
        _activatePriority(1e6, 10);

        // Create priority entries (alice: 100_000e18 FORAGE -> cap = 1_000_000e6)
        forage.setLockedBalance(alice, 100_000e18);
        uint256[] memory priorityIds = new uint256[](boundedPriority);
        for (uint256 i = 0; i < boundedPriority; i++) {
            priorityIds[i] = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        }

        // Create standard entries (bob has no locked FORAGE)
        forage.setLockedBalance(bob, 0);
        uint256[] memory standardIds = new uint256[](boundedStandard);
        for (uint256 i = 0; i < boundedStandard; i++) {
            standardIds[i] = _joinQueue(bob, STANDARD_DEPOSIT, 0);
        }

        // Process boundedMax entries
        vm.prank(keeper);
        queue.processQueue(0, boundedMax);

        // If boundedMax <= boundedPriority: only priority entries should be processed
        if (boundedMax <= boundedPriority) {
            // First boundedMax priority entries should be processed
            for (uint256 i = 0; i < boundedMax; i++) {
                StakingQueue.QueueEntry memory entry = queue.getQueueEntry(priorityIds[i]);
                assertTrue(entry.processed, "Priority entry must be processed first");
            }
            // No standard entries should be processed
            for (uint256 i = 0; i < boundedStandard; i++) {
                StakingQueue.QueueEntry memory entry = queue.getQueueEntry(standardIds[i]);
                assertFalse(entry.processed, "Standard entry must not be processed while priority remains");
            }
        } else {
            // All priority entries processed
            for (uint256 i = 0; i < boundedPriority; i++) {
                StakingQueue.QueueEntry memory entry = queue.getQueueEntry(priorityIds[i]);
                assertTrue(entry.processed, "All priority entries must be processed");
            }
            // Some standard entries processed
            uint256 standardProcessed = boundedMax - boundedPriority;
            for (uint256 i = 0; i < standardProcessed; i++) {
                StakingQueue.QueueEntry memory entry = queue.getQueueEntry(standardIds[i]);
                assertTrue(entry.processed, "Standard entries must be processed after priority drained");
            }
        }
    }
}
