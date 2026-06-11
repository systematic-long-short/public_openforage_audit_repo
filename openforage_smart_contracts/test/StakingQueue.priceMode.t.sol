// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "./mocks/MockForagePriceOracle.sol";

contract StakingQueue_R32_PriceMode is StakingQueueTestBase {
    MockForagePriceOracle internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = new MockForagePriceOracle(8);
    }

    function _setOracleMode(uint256 maxStaleness) internal {
        vm.startPrank(owner);
        queue.setForagePriceOracle(address(oracle), maxStaleness);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceOracle();
        queue.setForagePriceMode(StakingQueue.PriceMode.ORACLE);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceMode();
        queue.setPriorityMultiplier(10);
        vm.stopPrank();
    }

    function test_R32_defaultsToFixedPriceLaunchMode() public view {
        assertEq(uint8(queue.foragePriceMode()), uint8(StakingQueue.PriceMode.FIXED_PRICE), "default mode");
        assertEq(queue.foragePriceUsd(), 0, "fixed price starts disabled");
        assertEq(queue.effectiveForagePriceUsd(), 0, "effective fixed price starts disabled");
        assertEq(queue.foragePriceOracle(), address(0), "oracle unset");
        assertEq(queue.oraclePriceMaxStaleness(), 0, "oracle staleness unset");
    }

    function test_R32_oracleModeUsesFreshNormalizedPrice() public {
        _setOracleMode(1 hours);
        oracle.setRoundData(2e8, block.timestamp); // 8-decimal $2.00 -> 2e6 fixed-price units

        assertEq(queue.effectiveForagePriceUsd(), 2e6, "oracle price should normalize to 6 decimals");

        forage.mint(alice, 50e18);
        uint256 queueId = _joinQueue(alice, 1_000e6, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertTrue(entry.priority, "fresh oracle price should allow priority lane");
        assertEq(queue.forageLockedPerEntry(queueId), 50e18, "1,000 RISKUSD at $2 x 10 locks 50 FORAGE");
    }

    function test_R32_oracleModeRejectsStalePrice() public {
        _setOracleMode(1 hours);
        oracle.setRoundData(1e8, block.timestamp);

        forage.mint(alice, 1_000e18);
        _fundUser(alice, STANDARD_DEPOSIT);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectRevert(StakingQueue.StaleFORAGEPrice.selector);
        queue.effectiveForagePriceUsd();

        uint256 queueId = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(STANDARD_DEPOSIT, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.priority, "stale oracle price should fall back to standard lane");
        assertEq(queue.tierStandardQueueLength(0), 1, "standard entry recorded");
    }

    function test_R32_oracleModeRejectsInvalidAnswer() public {
        _setOracleMode(1 hours);
        oracle.setRoundData(0, block.timestamp);

        _fundUser(alice, STANDARD_DEPOSIT);
        vm.expectRevert(StakingQueue.InvalidOraclePrice.selector);
        queue.effectiveForagePriceUsd();

        uint256 queueId = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(STANDARD_DEPOSIT, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.priority, "invalid oracle price should fall back to standard lane");
        assertEq(queue.tierStandardQueueLength(0), 1, "standard entry recorded");
    }

    function test_R32_fixedModePreservesSevenDayStaleness() public {
        _activatePriority(1e6, 10);
        forage.mint(alice, 1_000e18);
        _fundUser(alice, STANDARD_DEPOSIT);

        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(StakingQueue.StaleFORAGEPrice.selector);
        queue.effectiveForagePriceUsd();

        uint256 queueId = queue.nextQueueId();
        vm.prank(alice);
        queue.joinQueue(STANDARD_DEPOSIT, 0);

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.priority, "stale fixed price should fall back to standard lane");
        assertEq(queue.tierStandardQueueLength(0), 1, "standard entry recorded");
    }

    function test_R32_cannotEnterOracleModeBeforeOracleConfigured() public {
        vm.prank(owner);
        vm.expectRevert(StakingQueue.OracleNotConfigured.selector);
        queue.setForagePriceMode(StakingQueue.PriceMode.ORACLE);
    }

    function test_R32_fixedPriceSetterRequiresFinalizeDelay() public {
        vm.prank(owner);
        queue.setForagePriceUsd(1e6);

        assertEq(queue.foragePriceUsd(), 0, "proposal should not update active price");

        vm.prank(owner);
        vm.expectRevert(StakingQueue.FinalizeDelayNotElapsed.selector);
        queue.finalizeForagePriceUsd();

        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        queue.finalizeForagePriceUsd();
        assertEq(queue.foragePriceUsd(), 1e6, "active after finalize");
    }
}
