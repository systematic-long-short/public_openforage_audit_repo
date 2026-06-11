// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-02: Direct Deposit / Queue Entry Tests
//        (R-10, R-11, R-12, R-13, R-14, R-15, R-39, R-41,
//         R-46, R-49, R-50)
// ============================================================
contract StakingQueue_TC02_JoinQueue is StakingQueueTestBase {
    // ----- Step 1: Zero amount reverts ZeroAmount -----
    function test_TC02_joinQueueZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.joinQueue(0, 0);
    }

    // ----- Step 2: Invalid tier (4) reverts InvalidTier -----
    function test_TC02_joinQueueInvalidTier4Reverts() public {
        _fundUser(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.joinQueue(1000e6, 4);
    }

    // ----- Step 3: Invalid tier (255) reverts InvalidTier -----
    function test_TC02_joinQueueInvalidTier255Reverts() public {
        _fundUser(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.joinQueue(1000e6, 255);
    }

    // ----- Step 4: Paused reverts EnforcedPause -----
    function test_TC02_joinQueuePausedReverts() public {
        // Set up governor and pause
        _setGovernor();
        vm.prank(owner);
        queue.pause();

        _fundUser(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        queue.joinQueue(1000e6, 0);
    }

    // ----- Step 5: Insufficient allowance reverts -----
    function test_TC02_joinQueueInsufficientAllowanceReverts() public {
        // Mint but do NOT approve
        riskusd.mint(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(queue), 0, 1000e6)
        );
        queue.joinQueue(1000e6, 0);
    }

    // ----- Step 6: Insufficient balance reverts -----
    function test_TC02_joinQueueInsufficientBalanceReverts() public {
        // Approve without balance
        vm.prank(alice);
        riskusd.approve(address(queue), 1000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1000e6));
        queue.joinQueue(1000e6, 0);
    }

    // ----- Step 7: Happy path standard lane tier 0 -----
    function test_TC02_joinQueueHappyPathStandardTier0() public {
        uint256 amount = 1000e6;
        _fundUser(alice, amount);

        uint256 nextId = queue.nextQueueId();

        vm.expectEmit(true, true, true, true);
        emit StakingQueue.QueueJoined(nextId, alice, amount, 0, false);

        vm.prank(alice);
        queue.joinQueue(amount, 0);

        // Verify entry
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertEq(entry.depositor, alice, "depositor should be alice");
        assertEq(entry.riskusdAmount, amount, "riskusdAmount mismatch");
        assertEq(entry.tier, 0, "tier should be 0");
        assertEq(entry.entryTimestamp, block.timestamp, "entryTimestamp should be block.timestamp");
        assertFalse(entry.processed, "should not be processed");
        assertFalse(entry.cancelled, "should not be cancelled");
        assertFalse(entry.priority, "should not be priority (threshold==0)");

        // Verify queue state
        assertEq(queue.nextQueueId(), nextId + 1, "nextQueueId should increment");
        assertEq(queue.tierStandardQueueLength(0), 1, "tierStandardQueueLength(0) should be 1");
        assertEq(queue.tierPriorityQueueLength(0), 0, "tierPriorityQueueLength(0) should be 0");
        assertEq(queue.totalQueuedRiskusd(), amount, "totalQueuedRiskusd mismatch");

        // Verify RISKUSD transferred
        assertEq(riskusd.balanceOf(alice), 0, "alice balance should be 0 after joinQueue");
        assertEq(riskusd.balanceOf(address(queue)), amount, "queue should hold the RISKUSD");
    }

    // ----- Step 8: Happy path standard lane tier 3 -----
    function test_TC02_joinQueueHappyPathStandardTier3() public {
        uint256 amount = 5000e6;
        _fundUser(alice, amount);

        uint256 nextId = queue.nextQueueId();

        vm.expectEmit(true, true, true, true);
        emit StakingQueue.QueueJoined(nextId, alice, amount, 3, false);

        vm.prank(alice);
        queue.joinQueue(amount, 3);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertEq(entry.tier, 3, "tier should be 3");
        assertEq(entry.riskusdAmount, amount, "riskusdAmount mismatch");
        assertFalse(entry.priority, "should not be priority (threshold==0)");
        assertEq(queue.tierStandardQueueLength(3), 1, "tierStandardQueueLength(3) should be 1");
    }

    // ----- Step 9: Multiple entries same tier -----
    function test_TC02_joinQueueMultipleEntriesSameTier() public {
        uint256 aliceAmount = 1000e6;
        uint256 bobAmount = 2000e6;

        _joinQueue(alice, aliceAmount, 0);
        _joinQueue(bob, bobAmount, 0);

        assertEq(queue.nextQueueId(), 3, "nextQueueId should be 3 after two joins");
        assertEq(queue.tierStandardQueueLength(0), 2, "tierStandardQueueLength(0) should be 2");
        assertEq(queue.totalQueuedRiskusd(), aliceAmount + bobAmount, "totalQueuedRiskusd mismatch");
    }

    // ----- Step 10: Multiple entries different tiers -----
    function test_TC02_joinQueueMultipleEntriesDifferentTiers() public {
        _joinQueue(alice, 1000e6, 0);
        _joinQueue(bob, 2000e6, 2);

        assertEq(queue.tierStandardQueueLength(0), 1, "tier 0 standard length should be 1");
        assertEq(queue.tierStandardQueueLength(2), 1, "tier 2 standard length should be 1");
        assertEq(queue.tierStandardQueueLength(1), 0, "tier 1 standard length should be 0");
        assertEq(queue.tierStandardQueueLength(3), 0, "tier 3 standard length should be 0");
    }

    // ----- Step 11: Priority lane routing with proportional cap active -----
    function test_TC02_joinQueuePriorityLaneRouting() public {
        // Activate priority: price=1e6, mult=10
        _activatePriority(1e6, 10);
        // alice: 2000e18 FORAGE (unlocked) -> forageToLock = 100e18 fits.
        forage.mint(alice, 2000e18);

        uint256 amount = 1000e6;
        _fundUser(alice, amount);
        uint256 nextId = queue.nextQueueId();

        vm.expectEmit(true, true, true, true);
        emit StakingQueue.QueueJoined(nextId, alice, amount, 1, true);

        vm.prank(alice);
        queue.joinQueue(amount, 1);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertTrue(entry.priority, "should be priority lane");
        assertEq(queue.tierPriorityQueueLength(1), 1, "tierPriorityQueueLength(1) should be 1");
        assertEq(queue.tierStandardQueueLength(1), 0, "tierStandardQueueLength(1) should be 0");
    }

    // ----- Step 12: Standard lane when cap insufficient -----
    function test_TC02_joinQueueStandardLaneBelowCap() public {
        _activatePriority(1e6, 10);
        // bob: 5e18 FORAGE -> forageToLock = 100e18 exceeds 5e18 unlocked.
        forage.mint(bob, 5e18);

        _fundUser(bob, 1000e6);
        uint256 nextId = queue.nextQueueId();

        vm.prank(bob);
        queue.joinQueue(1000e6, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertFalse(entry.priority, "should be standard lane (cap insufficient)");
        assertEq(queue.tierStandardQueueLength(0), 1, "tierStandardQueueLength(0) should be 1");
        assertEq(queue.tierPriorityQueueLength(0), 0, "tierPriorityQueueLength(0) should be 0");
    }

    // ----- Step 13: Standard lane at boundary (cap just below amount) -----
    function test_TC02_joinQueueStandardLaneAtBoundaryBelow() public {
        _activatePriority(1e6, 10);
        // charlie: 99e18 FORAGE -> forageToLock = 100e18 exceeds 99e18 unlocked.
        forage.mint(charlie, 99e18);

        _fundUser(charlie, 1000e6);
        uint256 nextId = queue.nextQueueId();

        vm.prank(charlie);
        queue.joinQueue(1000e6, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertFalse(entry.priority, "should be standard lane (cap 990e6 < deposit 1000e6)");
    }

    // ----- Step 14: Priority lane when exactly at cap -----
    function test_TC02_joinQueuePriorityLaneExactlyAtCap() public {
        _activatePriority(1e6, 10);
        // dave: 100e18 FORAGE -> forageToLock = 100e18, exactly matches available.
        forage.mint(dave, 100e18);

        _fundUser(dave, 1000e6);
        uint256 nextId = queue.nextQueueId();

        vm.prank(dave);
        queue.joinQueue(1000e6, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(nextId);
        assertTrue(entry.priority, "exactly at cap should be priority lane (<=)");
    }

    // ----- Step 15: Queue ID monotonicity -----
    function test_TC02_joinQueueIdMonotonicity() public {
        uint256 firstId = queue.nextQueueId();

        for (uint256 i = 0; i < 5; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            _joinQueue(user, 1000e6, 0);
        }

        // IDs should be firstId, firstId+1, ..., firstId+4
        for (uint256 i = 0; i < 5; i++) {
            StakingQueue.QueueEntry memory entry = queue.getQueueEntry(firstId + i);
            assertTrue(entry.depositor != address(0), "entry should exist");
            assertEq(entry.riskusdAmount, 1000e6, "each entry should have 1000e6");
        }
        assertEq(queue.nextQueueId(), firstId + 5, "nextQueueId should be firstId + 5");
    }

    // ----- Step 16: Entry timestamp -----
    function test_TC02_joinQueueEntryTimestamp() public {
        uint256 ts1 = 1000;
        uint256 ts2 = 2000;

        vm.warp(ts1);
        uint256 id1 = _joinQueue(alice, 1000e6, 0);

        vm.warp(ts2);
        uint256 id2 = _joinQueue(bob, 1000e6, 0);

        StakingQueue.QueueEntry memory entry1 = queue.getQueueEntry(id1);
        StakingQueue.QueueEntry memory entry2 = queue.getQueueEntry(id2);

        assertEq(entry1.entryTimestamp, ts1, "entry1 timestamp should be ts1");
        assertEq(entry2.entryTimestamp, ts2, "entry2 timestamp should be ts2");
    }
}
