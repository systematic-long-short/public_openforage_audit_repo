// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";

// ============================================================
// TC-03: Queue Entry with Capacity Available
//        (R-10, R-13, R-25, R-35, R-36)
// ============================================================
contract StakingQueue_TC03_CapacityPath is StakingQueueTestBase {
    // ----- Step 1: Queue then immediate process -----
    /// @dev Alice joins queue for tier 0 with 1000e6. Capacity available (10M default, 0 staked).
    ///      Keeper calls processQueue(0, 10). Entry processed and deposited into tier vault.
    function test_TC03_queueThenImmediateProcess() public {
        uint256 amount = 1000e6;
        uint256 queueId = _joinQueue(alice, amount, 0);

        // Keeper processes the queue
        vm.prank(keeper);
        queue.processQueue(0, 10);

        // Verify entry is processed
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "entry should be marked processed");

        // Verify vault received the deposit
        assertEq(vault0.depositCallCount(), 1, "vault0 should have 1 deposit call");
        (uint256 depositedAmount, address depositedFor) = vault0.depositCalls(0);
        assertEq(depositedAmount, amount, "deposited amount mismatch");
        assertEq(depositedFor, alice, "deposited for wrong address");

        // Verify totalQueuedRiskusd decreased
        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd should be 0 after processing");
    }

    // ----- Step 2: Queue entries when near capacity -----
    /// @dev Mock combined staked at 9_999_000e6. Alice joins with 1000e6 (within remaining 1M capacity).
    ///      processQueue MUST succeed.
    function test_TC03_queueNearCapacity() public {
        // Set mock total assets to bring combined staked near capacity
        // 10M capacity, staked = 9_999_000e6 across all vaults, 1M remaining
        vault0.setMockTotalAssets(9_999_000e6);

        uint256 amount = 1000e6;
        uint256 queueId = _joinQueue(alice, amount, 0);

        // Should succeed -- 1000e6 fits within remaining 1_001_000e6 capacity
        // (capacity check: amount <= availableCapacity)
        vm.prank(keeper);
        queue.processQueue(0, 10);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "entry should be processed when near capacity");
    }

    // ----- Step 3: At capacity -- processQueue reverts NoCapacityAvailable -----
    /// @dev Mock combined staked at 10_000_000e6 (full). Alice joins queue (entry is queued, not rejected).
    ///      processQueue MUST revert with NoCapacityAvailable.
    function test_TC03_atCapacityRevertsNoCapacityAvailable() public {
        // Fill capacity across vaults
        vault0.setMockTotalAssets(2_500_000e6);
        vault1.setMockTotalAssets(2_500_000e6);
        vault2.setMockTotalAssets(2_500_000e6);
        vault3.setMockTotalAssets(2_500_000e6);

        // Alice can still join the queue (joinQueue does not check capacity)
        _joinQueue(alice, 1000e6, 0);

        // But processQueue should revert when no capacity available
        vm.prank(keeper);
        vm.expectRevert(StakingQueue.NoCapacityAvailable.selector);
        queue.processQueue(0, 10);
    }

    // ----- Step 4: Just over capacity -- no partial fill -----
    /// @dev Entry amount is 1001e6 but only 1000e6 capacity available.
    ///      processQueue -- entry MUST NOT be processed (no partial fill). Processing stops.
    function test_TC03_justOverCapacityNoPartialFill() public {
        // Set staked to leave exactly 1000e6 capacity
        vault0.setMockTotalAssets(9_999_000e6);

        // Queue an entry that exceeds remaining capacity
        uint256 queueId = _joinQueue(alice, 1001e6, 0);

        // processQueue should not process the entry (no partial fill)
        // The entry is too large for remaining capacity, so processing stops
        vm.prank(keeper);
        // Depending on implementation: may revert with NoCapacityAvailable or silently skip
        // Either way, the entry should NOT be partially processed
        queue.processQueue(0, 10);

        // If we get here (no revert), verify entry is NOT processed
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.processed, "entry should NOT be processed (no partial fill)");
    }
}
