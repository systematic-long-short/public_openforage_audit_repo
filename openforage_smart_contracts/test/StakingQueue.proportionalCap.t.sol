// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// Proportional Cap Tests — New test file for proportional priority model
// ============================================================
contract StakingQueue_ProportionalCap is StakingQueueTestBase {
    uint256 constant PRICE = 1e6; // 1 RISKUSD per FORAGE
    uint256 constant MULT = 10;

    function _activate() internal {
        _activatePriority(PRICE, MULT);
    }

    // ── Cap Formula Correctness ──

    /// @dev Known inputs -> expected cap.
    /// priorityCapFor reads lockedBalance view, so setLockedBalance is correct here.
    function test_capFormulaCorrectness() public {
        _activate();
        forage.setLockedBalance(alice, 1000e18);
        assertEq(queue.priorityCapFor(alice), 10_000e6, "cap should be 10_000e6");
    }

    /// @dev Zero FORAGE -> zero cap.
    function test_capFormulaZeroForage() public {
        _activate();
        forage.setLockedBalance(alice, 0);
        assertEq(queue.priorityCapFor(alice), 0, "cap should be 0 with no FORAGE");
    }

    /// @dev Both params 0 -> cap view returns 0.
    function test_capFormulaInactive() public {
        forage.setLockedBalance(alice, 100_000e18);
        assertEq(queue.priorityCapFor(alice), 0, "cap should be 0 when price and mult are 0");
    }

    // ── Multi-Entry Depositor ──

    /// @dev 1st entry locks part of FORAGE, 2nd locks rest, 3rd falls to standard (no unlocked left).
    function test_multiEntryDepositor() public {
        _activate();
        // 500e18 FORAGE (unlocked). Entry1 locks 200e18, entry2 locks 300e18, entry3 needs 0.1e18 but 0 unlocked.
        forage.mint(alice, 500e18);

        // 1st entry: 2_000e6 (within cap)
        _fundUserMax(alice);
        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(2_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "1st entry should be priority");
        assertEq(queue.priorityRiskusdQueued(alice), 2_000e6, "tracking should be 2_000e6");

        // 2nd entry: 3_000e6 (exactly fills remaining cap: 2000 + 3000 = 5000 = cap)
        uint256 id2 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(3_000e6, 0);
        assertTrue(queue.getQueueEntry(id2).priority, "2nd entry should be priority (fills cap exactly)");
        assertEq(queue.priorityRiskusdQueued(alice), 5_000e6, "tracking should be 5_000e6");

        // 3rd entry: 1e6 (exceeds cap by 1)
        uint256 id3 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1e6, 0);
        assertFalse(queue.getQueueEntry(id3).priority, "3rd entry should fall to standard (cap exceeded)");
        // Tracking unchanged (standard entry doesn't add)
        assertEq(queue.priorityRiskusdQueued(alice), 5_000e6, "tracking should remain 5_000e6");
    }

    // ── Cap Boundary ──

    /// @dev Amount exactly at cap -> priority; forageToLock = 100e18 with 100e18 available.
    function test_capBoundaryExact() public {
        _activate();
        // 100e18 FORAGE (unlocked) -> forageToLock = 100e18, exactly matches.
        forage.mint(alice, 100e18);
        _fundUserMax(alice);

        // Exactly at cap
        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "exact cap should be priority");
    }

    function test_capBoundaryOneOver() public {
        _activate();
        // 100e18 FORAGE (unlocked) -> forageToLock for 1001e6 = 100.1e18 > 100e18 unlocked.
        forage.mint(alice, 100e18);
        _fundUserMax(alice);

        // 1 wei over cap
        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1_000e6 + 1, 0);
        assertFalse(queue.getQueueEntry(id1).priority, "1 wei over cap should be standard");
    }

    // ── Price Change -> No Demotion (Active Lock Model) ──

    /// @dev Price drops between join and process. Under active locking, the entry
    /// was locked at join time, so it processes normally. No demotion.
    function test_priceChangeCausesDemotion() public {
        _activate();
        forage.mint(alice, 1000e18); // enough FORAGE to lock
        _fundUserMax(alice);

        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(8_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "should be priority at join time");

        // Drop price -- no effect under active lock model
        _setForagePriceUsd(0.5e6);

        queue.processQueue(0, 10);

        // Entry processes normally (not demoted)
        assertTrue(queue.getQueueEntry(id1).processed, "entry should be processed (active lock, no demotion)");
        assertEq(queue.priorityRiskusdQueued(alice), 0, "tracking should be 0 after processing");
    }

    // ── Multiplier Change -> No Demotion (Active Lock Model) ──

    function test_multiplierChangeCausesDemotion() public {
        _activate();
        forage.mint(alice, 1000e18); // enough FORAGE to lock
        _fundUserMax(alice);

        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(8_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "should be priority at join time");

        // Drop multiplier -- no effect under active lock model
        _setPriorityMultiplier(5);

        queue.processQueue(0, 10);
        assertTrue(queue.getQueueEntry(id1).processed, "entry should be processed (active lock, no demotion)");
    }

    // ── FORAGE Unlock After Join -> Processes Normally (Active Lock Model) ──

    function test_forageUnlockCausesDemotion() public {
        _activate();
        forage.mint(alice, 1000e18); // enough FORAGE to lock
        _fundUserMax(alice);

        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(5_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "should be priority at join time");

        // Externally zero locked balance -- doesn't affect active lock model processing
        forage.setLockedBalance(alice, 0);

        queue.processQueue(0, 10);
        // Under active lock model, unlock reverts (lockedBalance=0) but try/catch handles it
        assertTrue(queue.getQueueEntry(id1).processed, "entry should be processed (active lock, try/catch on unlock)");
        assertEq(queue.priorityRiskusdQueued(alice), 0, "tracking should be 0 after processing");
    }

    // ── Tracking: join increments, cancel decrements, process decrements, demotion decrements ──

    function test_trackingJoinIncrements() public {
        _activate();
        forage.mint(alice, 5000e18); // enough FORAGE for active lock
        _fundUserMax(alice);

        assertEq(queue.priorityRiskusdQueued(alice), 0, "should start at 0");

        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);
        assertEq(queue.priorityRiskusdQueued(alice), 1_000e6, "should be 1_000e6 after join");

        vm.prank(alice);
        queue.joinQueue(2_000e6, 0);
        assertEq(queue.priorityRiskusdQueued(alice), 3_000e6, "should be 3_000e6 after second join");
    }

    function test_trackingCancelDecrements() public {
        _activate();
        forage.mint(alice, 5000e18);
        _fundUserMax(alice);

        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);

        uint256 id2 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(2_000e6, 0);

        assertEq(queue.priorityRiskusdQueued(alice), 3_000e6, "should be 3_000e6");

        vm.prank(alice);
        queue.cancelQueue(id1);
        assertEq(queue.priorityRiskusdQueued(alice), 2_000e6, "should be 2_000e6 after cancel");
    }

    function test_trackingProcessDecrements() public {
        _activate();
        forage.mint(alice, 5000e18);
        _fundUserMax(alice);

        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);
        assertEq(queue.priorityRiskusdQueued(alice), 1_000e6, "should be 1_000e6");

        queue.processQueue(0, 10);
        assertEq(queue.priorityRiskusdQueued(alice), 0, "should be 0 after processing");
    }

    // ── Cancel frees up cap for re-join ──

    function test_cancelFreesCapForRejoin() public {
        _activate();
        // 200e18 FORAGE (unlocked). First entry locks 100e18 (for 1000e6).
        // Second entry needs 10e18 (for 100e6). Only 100e18 unlocked. Succeeds.
        // Cancel first -> unlocks 100e18. Re-join locks 100e18 again.
        forage.mint(alice, 200e18);
        _fundUserMax(alice);

        // First entry locks 100e18
        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "should be priority");

        // Second entry: forageToLock = ceilDiv(100e6 * 1e18, 1e7) = 10e18. 100e18 unlocked. Succeeds.
        uint256 id2 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(100e6, 0);
        assertTrue(queue.getQueueEntry(id2).priority, "should be priority (enough unlocked)");

        // Cancel first entry -> unlocks 100e18 FORAGE
        vm.prank(alice);
        queue.cancelQueue(id1);

        // Re-join -> should be priority (100e18 unlocked after cancel + 90e18 from entry2 still locked = 110 unlocked)
        uint256 id3 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(1_000e6, 0);
        assertTrue(queue.getQueueEntry(id3).priority, "should be priority after cancel freed FORAGE");
    }

    // ── Both params 0 -> all standard, no demotions ──

    function test_bothParamsZeroNoDenotions() public {
        // Priority inactive (default)
        forage.setLockedBalance(alice, 100_000e18);

        uint256 id1 = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        assertFalse(queue.getQueueEntry(id1).priority, "should be standard when inactive");

        // processQueue should process normally, no demotion logic triggered
        queue.processQueue(0, 10);
        assertTrue(queue.getQueueEntry(id1).processed, "should be processed normally");
    }

    // ── View functions ──

    function test_priorityCapForView() public {
        _activate();
        forage.setLockedBalance(alice, 2500e18);
        // cap = 2500e18 * 1e6 * 10 / 1e18 = 25_000e6
        assertEq(queue.priorityCapFor(alice), 25_000e6, "priorityCapFor should return correct value");
    }

    function test_priorityRiskusdQueuedView() public {
        _activate();
        forage.mint(alice, 5000e18);
        _fundUserMax(alice);

        assertEq(queue.priorityRiskusdQueued(alice), 0, "should be 0 initially");

        vm.prank(alice);
        queue.joinQueue(3_000e6, 0);
        assertEq(queue.priorityRiskusdQueued(alice), 3_000e6, "should reflect queued amount");
    }

    // ── adminCancelQueue decrements tracking ──

    function test_adminCancelDecrements() public {
        _activate();
        forage.mint(alice, 5000e18);
        _fundUserMax(alice);

        uint256 id1 = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(2_000e6, 0);
        assertTrue(queue.getQueueEntry(id1).priority, "should be priority");
        assertEq(queue.priorityRiskusdQueued(alice), 2_000e6, "tracking should be 2_000e6");

        // Admin cancel
        vm.prank(owner);
        queue.adminCancelQueue(id1, owner);

        assertEq(queue.priorityRiskusdQueued(alice), 0, "tracking should be 0 after admin cancel");
    }

    // ── Precision: rounding is floor (conservative) ──

    function test_precisionFloorRounding() public {
        // price = 1, mult = 3 -> cap = lockedBal * 1 * 3 / 1e18
        // With 1e18 + 1 FORAGE: (1e18 + 1) * 1 * 3 / 1e18 = 3 + 3/1e18 = 3 (floor)
        _setForagePriceUsd(1);
        _setPriorityMultiplier(3);
        forage.setLockedBalance(alice, 1e18 + 1);
        assertEq(queue.priorityCapFor(alice), 3, "should floor to 3");

        // With exactly 1e18 FORAGE: 1e18 * 1 * 3 / 1e18 = 3
        forage.setLockedBalance(alice, 1e18);
        assertEq(queue.priorityCapFor(alice), 3, "should be exactly 3");
    }

    // ── Large values: no overflow with max realistic inputs ──

    function test_largeValuesNoOverflow() public {
        // Max realistic: 1e26 FORAGE (100M tokens) * 1e8 price ($100) * 1e3 multiplier
        // = 1e26 * 1e8 * 1e3 / 1e18 = 1e19, well within uint256
        _setForagePriceUsd(1e8);
        _setPriorityMultiplier(1000);
        forage.setLockedBalance(alice, 1e26);
        assertEq(queue.priorityCapFor(alice), 1e19, "large values should not overflow");
    }

    // ── Reinitializer ──

    function test_reinitializerSetsMultiplier() public {
        // Deploy fresh proxy for reinitializer test
        StakingQueue impl2 = new StakingQueue();
        vm.prank(owner);
        queue.upgradeToAndCall(address(impl2), abi.encodeCall(StakingQueue.reinitialize, (10)));
        assertEq(queue.priorityMultiplier(), 10, "reinitializer should set multiplier");
    }

    function test_reinitializerCannotRunTwice() public {
        StakingQueue impl2 = new StakingQueue();
        vm.prank(owner);
        queue.upgradeToAndCall(address(impl2), abi.encodeCall(StakingQueue.reinitialize, (10)));

        // Second call to reinitialize(2) should revert
        StakingQueue impl3 = new StakingQueue();
        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        queue.upgradeToAndCall(address(impl3), abi.encodeCall(StakingQueue.reinitialize, (20)));
    }

    function test_reinitializerOnlyOwner() public {
        StakingQueue impl2 = new StakingQueue();
        // Non-owner cannot upgrade (which is what calls reinitialize)
        vm.prank(attacker);
        vm.expectRevert();
        queue.upgradeToAndCall(address(impl2), abi.encodeCall(StakingQueue.reinitialize, (10)));
    }
}
