// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-05: Dual Lane Tests — Proportional Cap Model
// ============================================================
contract StakingQueue_TC05_DualLane is StakingQueueTestBase {
    // Price: 1 RISKUSD per FORAGE (6-decimal precision)
    uint256 constant PRICE = 1e6;
    // Multiplier: 10x
    uint256 constant MULT = 10;

    /// @dev Step 1: Default priority inactive (price=0, multiplier=0).
    ///      All entries go to standard lane regardless of FORAGE locked balance.
    function test_TC05_defaultPriorityInactive() public {
        forage.setLockedBalance(alice, 100_000e18);

        uint256 queueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.priority, "entry should be in standard lane when price and multiplier are 0");
        assertEq(queue.tierStandardQueueLength(0), 1, "standard lane should have 1 entry");
        assertEq(queue.tierPriorityQueueLength(0), 0, "priority lane should have 0 entries");
    }

    /// @dev Step 2: Activate priority lane. User within cap goes to priority.
    ///      User with insufficient cap goes to standard. Existing entries stay.
    function test_TC05_activatePriority() public {
        // First join in standard lane (priority inactive)
        uint256 stdId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Activate priority: price=1e6, mult=10
        _activatePriority(PRICE, MULT);

        // bob: 2000e18 FORAGE (unlocked) -> forageToLock = 100e18, fits.
        forage.mint(bob, 2000e18);
        // charlie: 5e18 FORAGE -> forageToLock = 100e18, exceeds 5e18 unlocked.
        forage.mint(charlie, 5e18);

        uint256 prioId = _joinQueue(bob, STANDARD_DEPOSIT, 0);
        uint256 stdId2 = _joinQueue(charlie, STANDARD_DEPOSIT, 0);

        StakingQueue.QueueEntry memory aliceEntry = queue.getQueueEntry(stdId);
        assertFalse(aliceEntry.priority, "alice original entry should remain in standard lane");

        StakingQueue.QueueEntry memory bobEntry = queue.getQueueEntry(prioId);
        assertTrue(bobEntry.priority, "bob should be in priority lane (within cap)");

        StakingQueue.QueueEntry memory charlieEntry = queue.getQueueEntry(stdId2);
        assertFalse(charlieEntry.priority, "charlie should be in standard lane (exceeds cap)");
    }

    /// @dev Step 3: Deactivate priority. Set price and multiplier back to 0.
    ///      All new entries go to standard lane again.
    function test_TC05_deactivatePriority() public {
        _activatePriority(PRICE, MULT);

        // alice: 5000e18 FORAGE (unlocked) -> forageToLock = 100e18, fits.
        forage.mint(alice, 5000e18);

        uint256 prioId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory prioEntry = queue.getQueueEntry(prioId);
        assertTrue(prioEntry.priority, "alice should be in priority lane when priority active");

        // Deactivate
        _setForagePriceUsd(0);
        _setPriorityMultiplier(0);

        uint256 stdId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        StakingQueue.QueueEntry memory stdEntry = queue.getQueueEntry(stdId);
        assertFalse(stdEntry.priority, "alice new entry should be in standard lane after deactivation");
    }

    /// @dev Step 4: Priority lane empty, standard lane has entries.
    ///      processQueue processes standard lane entries immediately.
    function test_TC05_priorityEmptyStandardHasEntries() public {
        _activatePriority(PRICE, MULT);

        // All users have no FORAGE -> cap = 0 -> standard lane
        uint256 id1 = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 id2 = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        assertEq(queue.tierPriorityQueueLength(0), 0, "priority lane should be empty");
        assertGt(queue.tierStandardQueueLength(0), 0, "standard lane should have entries");

        uint256 queuedBefore = queue.totalQueuedRiskusd();
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(id1).processed, "alice entry should be processed");
        assertTrue(queue.getQueueEntry(id2).processed, "bob entry should be processed");
        assertEq(
            queue.totalQueuedRiskusd(),
            queuedBefore - 2 * STANDARD_DEPOSIT,
            "totalQueuedRiskusd should decrease by both deposits"
        );
    }

    /// @dev Step 5: Standard lane empty, priority lane has entries.
    function test_TC05_standardEmptyPriorityHasEntries() public {
        _activatePriority(PRICE, MULT);

        // All users have enough FORAGE (unlocked) for lock
        forage.mint(alice, 5000e18);
        forage.mint(bob, 5000e18);

        uint256 id1 = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 id2 = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        assertGt(queue.tierPriorityQueueLength(0), 0, "priority lane should have entries");
        assertEq(queue.tierStandardQueueLength(0), 0, "standard lane should be empty");

        uint256 queuedBefore = queue.totalQueuedRiskusd();
        queue.processQueue(0, 10);

        assertTrue(queue.getQueueEntry(id1).processed, "alice priority entry should be processed");
        assertTrue(queue.getQueueEntry(id2).processed, "bob priority entry should be processed");
        assertEq(
            queue.totalQueuedRiskusd(),
            queuedBefore - 2 * STANDARD_DEPOSIT,
            "totalQueuedRiskusd should decrease by both deposits"
        );
    }

    /// @dev Step 6: Both lanes have entries. Priority drains first, then standard.
    function test_TC05_bothLanesPriorityDrainsFirst() public {
        _activatePriority(PRICE, MULT);

        forage.mint(alice, 5000e18); // enough FORAGE for lock
        uint256 prioId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // bob has no FORAGE -> standard lane
        uint256 stdId = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        assertTrue(queue.getQueueEntry(prioId).priority, "alice should be in priority lane");
        assertFalse(queue.getQueueEntry(stdId).priority, "bob should be in standard lane");

        // Process 1 entry -- should process priority first
        queue.processQueue(0, 1);

        assertTrue(queue.getQueueEntry(prioId).processed, "priority entry (alice) should be processed first");
        assertFalse(queue.getQueueEntry(stdId).processed, "standard entry (bob) should NOT be processed yet");

        // Second call processes standard
        queue.processQueue(0, 1);
        assertTrue(queue.getQueueEntry(stdId).processed, "standard entry (bob) should be processed on second call");
    }

    /// @dev Step 7: Lane switching mid-queue. User locks FORAGE after first entry.
    function test_TC05_laneSwitchingMidQueue() public {
        _activatePriority(PRICE, MULT);

        // alice has no FORAGE -> standard lane
        uint256 stdId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        assertFalse(queue.getQueueEntry(stdId).priority, "first entry should be standard (no FORAGE)");

        // alice gets FORAGE so lock() can succeed
        forage.mint(alice, 5000e18);

        uint256 prioId = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        assertTrue(queue.getQueueEntry(prioId).priority, "second entry should be priority (FORAGE locked)");

        // Original entry remains standard
        assertFalse(queue.getQueueEntry(stdId).priority, "original entry should remain in standard lane");
    }
}
