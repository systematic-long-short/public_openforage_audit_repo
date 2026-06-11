// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";

// ============================================================
// TC-09: Tier Routing and View Function Tests (L3 steps 1-13)
// Requirements: R-04, R-05, R-06, R-07, R-08, R-35, R-36, R-39, R-40
// ============================================================
contract StakingQueue_TC09_RoutingAndViews is StakingQueueTestBase {
    // ── Tier Routing ──

    /// @dev L3 step 1: Valid tiers (0-3). joinQueue with each valid tier.
    ///      Assert each entry stored with correct tier.
    function test_TC09_validTierRouting0Through3() public {
        for (uint8 t = 0; t < 4; t++) {
            uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, t);
            StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
            assertEq(entry.tier, t, "entry tier should match requested tier");
            assertEq(entry.depositor, alice, "entry depositor should be alice");
            assertEq(entry.riskusdAmount, STANDARD_DEPOSIT, "entry amount should match");
        }
    }

    /// @dev L3 step 2: Invalid tier boundary. joinQueue(amount, 4) MUST revert InvalidTier().
    function test_TC09_invalidTierBoundary4Reverts() public {
        _fundUser(alice, STANDARD_DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.joinQueue(STANDARD_DEPOSIT, 4);
    }

    /// @dev L3 step 3: processQueue tier isolation.
    ///      Entries in different tiers. Processing tier 0 does not affect tier 1 queue.
    function test_TC09_processQueueTierIsolation() public {
        // Queue entries in tier 0 and tier 1
        uint256 queueId0 = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 queueId1 = _joinQueue(bob, STANDARD_DEPOSIT, 1);

        // Process only tier 0
        queue.processQueue(0, 10);

        // Tier 0 entry should be processed
        StakingQueue.QueueEntry memory entry0 = queue.getQueueEntry(queueId0);
        assertTrue(entry0.processed, "tier 0 entry should be processed");

        // Tier 1 entry should NOT be processed
        StakingQueue.QueueEntry memory entry1 = queue.getQueueEntry(queueId1);
        assertFalse(entry1.processed, "tier 1 entry should NOT be processed when processing tier 0");
    }

    /// @dev L3 step 4: Tier vault mapping correctness.
    ///      Each processed entry deposits into correct _tierVaults[tier].
    function test_TC09_tierVaultMappingCorrectness() public {
        // Queue and process entries in each tier
        for (uint8 t = 0; t < 4; t++) {
            _joinQueue(alice, STANDARD_DEPOSIT, t);
            queue.processQueue(t, 1);
        }

        // Verify each vault received exactly one deposit
        assertEq(vault0.depositCallCount(), 1, "vault0 should have 1 deposit (tier 0)");
        assertEq(vault1.depositCallCount(), 1, "vault1 should have 1 deposit (tier 1)");
        assertEq(vault2.depositCallCount(), 1, "vault2 should have 1 deposit (tier 2)");
        assertEq(vault3.depositCallCount(), 1, "vault3 should have 1 deposit (tier 3)");
    }

    // ── View Functions ──

    /// @dev L3 step 5: After initialization. All view functions return defaults (verifies TC-01 overlap).
    function test_TC09_viewsAfterInit() public view {
        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd should be 0 after init");
        assertEq(queue.nextQueueId(), 1, "nextQueueId should be 1 after init");
        assertEq(queue.combinedCapacity(), DEFAULT_COMBINED_CAPACITY, "combinedCapacity should be 10M after init");
        assertEq(queue.foragePriceUsd(), 0, "foragePriceUsd should be 0 after init");
        assertEq(queue.priorityMultiplier(), 0, "priorityMultiplier should be 0 after init");
        assertEq(queue.forageGovernor(), address(0), "forageGovernor should be address(0) after init");
        for (uint8 t = 0; t < 4; t++) {
            assertEq(queue.tierStandardQueueLength(t), 0, "tierStandardQueueLength should be 0 after init");
            assertEq(queue.tierPriorityQueueLength(t), 0, "tierPriorityQueueLength should be 0 after init");
            assertEq(queue.tierStandardHead(t), 0, "tierStandardHead should be 0 after init");
            assertEq(queue.tierPriorityHead(t), 0, "tierPriorityHead should be 0 after init");
        }
    }

    /// @dev L3 step 6: After joinQueue. totalQueuedRiskusd, queue lengths, nextQueueId updated.
    function test_TC09_viewsAfterJoinQueue() public {
        uint256 amount1 = 1_000e6;
        uint256 amount2 = 2_000e6;

        _joinQueue(alice, amount1, 0);
        assertEq(queue.totalQueuedRiskusd(), amount1, "totalQueuedRiskusd should reflect first entry");
        assertEq(queue.tierStandardQueueLength(0), 1, "tier 0 standard queue length should be 1");
        assertEq(queue.nextQueueId(), 2, "nextQueueId should be 2 after one join");

        _joinQueue(bob, amount2, 1);
        assertEq(queue.totalQueuedRiskusd(), amount1 + amount2, "totalQueuedRiskusd should reflect both entries");
        assertEq(queue.tierStandardQueueLength(1), 1, "tier 1 standard queue length should be 1");
        assertEq(queue.nextQueueId(), 3, "nextQueueId should be 3 after two joins");
    }

    /// @dev L3 step 7: After processQueue. totalQueuedRiskusd decreased. Heads advanced.
    function test_TC09_viewsAfterProcessQueue() public {
        _joinQueue(alice, STANDARD_DEPOSIT, 0);
        _joinQueue(bob, STANDARD_DEPOSIT, 0);

        uint256 totalBefore = queue.totalQueuedRiskusd();
        assertEq(totalBefore, STANDARD_DEPOSIT * 2, "totalQueuedRiskusd should reflect both entries");

        // Process 1 entry
        queue.processQueue(0, 1);

        assertEq(queue.totalQueuedRiskusd(), STANDARD_DEPOSIT, "totalQueuedRiskusd should decrease by one entry amount");
        // Head should have advanced
        assertGt(queue.tierStandardHead(0), 0, "tierStandardHead should advance after processing");
    }

    /// @dev L3 step 8: After cancelQueue. totalQueuedRiskusd decreased.
    function test_TC09_viewsAfterCancelQueue() public {
        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        assertEq(queue.totalQueuedRiskusd(), STANDARD_DEPOSIT, "totalQueuedRiskusd should reflect entry");

        vm.prank(alice);
        queue.cancelQueue(queueId);

        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd should be 0 after cancel");
    }

    /// @dev L3 step 9-10: getQueueEntry returns correct struct for active, processed, cancelled, non-existent.
    function test_TC09_getQueueEntryActiveProcessedCancelledNonExistent() public {
        // Active entry
        uint256 activeId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory active = queue.getQueueEntry(activeId);
        assertEq(active.depositor, alice, "active entry depositor");
        assertEq(active.riskusdAmount, STANDARD_DEPOSIT, "active entry amount");
        assertEq(active.tier, 0, "active entry tier");
        assertFalse(active.processed, "active entry should not be processed");
        assertFalse(active.cancelled, "active entry should not be cancelled");

        // Processed entry
        uint256 processedId = _joinQueue(bob, STANDARD_DEPOSIT, 1);
        queue.processQueue(1, 1);
        StakingQueue.QueueEntry memory processed = queue.getQueueEntry(processedId);
        assertEq(processed.depositor, bob, "processed entry depositor");
        assertTrue(processed.processed, "processed entry should be marked processed");
        assertFalse(processed.cancelled, "processed entry should not be cancelled");

        // Cancelled entry
        uint256 cancelledId = _joinQueue(charlie, STANDARD_DEPOSIT, 2);
        vm.prank(charlie);
        queue.cancelQueue(cancelledId);
        StakingQueue.QueueEntry memory cancelled = queue.getQueueEntry(cancelledId);
        assertEq(cancelled.depositor, charlie, "cancelled entry depositor");
        assertFalse(cancelled.processed, "cancelled entry should not be processed");
        assertTrue(cancelled.cancelled, "cancelled entry should be marked cancelled");

        // Non-existent entry -- returns zeroed struct
        StakingQueue.QueueEntry memory nonExistent = queue.getQueueEntry(999);
        assertEq(nonExistent.depositor, address(0), "non-existent entry depositor should be address(0)");
        assertEq(nonExistent.riskusdAmount, 0, "non-existent entry amount should be 0");
    }

    /// @dev L3 step 11: combinedStaked equals sum of tier vault totalAssets() across all 4 vaults.
    function test_TC09_combinedStakedComputation() public {
        vault0.setMockTotalAssets(1_000_000e6);
        vault1.setMockTotalAssets(2_000_000e6);
        vault2.setMockTotalAssets(3_000_000e6);
        vault3.setMockTotalAssets(4_000_000e6);

        assertEq(queue.combinedStaked(), 10_000_000e6, "combinedStaked should be sum of all tier vault totalAssets");
    }

    /// @dev L3 step 12: availableCapacity equals max(0, combinedCapacity - combinedStaked).
    function test_TC09_availableCapacityComputation() public {
        // combinedCapacity = 10M (default), staked = 7M -> available = 3M
        vault0.setMockTotalAssets(1_000_000e6);
        vault1.setMockTotalAssets(2_000_000e6);
        vault2.setMockTotalAssets(2_000_000e6);
        vault3.setMockTotalAssets(2_000_000e6);

        assertEq(queue.availableCapacity(), 3_000_000e6, "availableCapacity should be 10M - 7M = 3M");

        // Over capacity: staked = 12M -> available = 0
        vault0.setMockTotalAssets(3_000_000e6);
        vault1.setMockTotalAssets(3_000_000e6);
        vault2.setMockTotalAssets(3_000_000e6);
        vault3.setMockTotalAssets(3_000_000e6);

        assertEq(queue.availableCapacity(), 0, "availableCapacity should be 0 when staked exceeds capacity");
    }

    /// @dev L3 step 13: owner(), pendingOwner(), paused() standard view function checks.
    function test_TC09_standardViewFunctions() public view {
        assertEq(queue.owner(), owner, "owner should match");
        assertEq(queue.pendingOwner(), address(0), "pendingOwner should be address(0) initially");
        assertFalse(queue.paused(), "paused should be false initially");
    }
}
