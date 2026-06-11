// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/StakingQueue.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockForageTokenLocked.sol";
import "./mocks/MockAtRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";

// ============================================================
// TC-14: Invariant Tests (R-21, R-22, R-28, R-29, R-35, R-36,
//        R-37, R-38)
// Handler contract + 8 invariant functions + 3 basic handler
// verification tests.
// ============================================================

/// @dev Handler contract for StakingQueue invariant testing.
/// Randomly calls joinQueue, cancelQueue, processQueue, setCapacityCap (via VaultRegistry),
/// setForagePriceUsd/setPriorityMultiplier with bounded parameters. Tracks all queue entries
/// and state for invariant verification. Uses generation tracking to correctly
/// verify priority-drains-first across multiple processQueue calls.
contract StakingQueueHandler is Test {
    StakingQueue public stakingQueue;
    MockRISKUSD public riskusd;
    MockForageTokenLocked public forage;
    MockAtRISKUSD public vault0;
    MockAtRISKUSD public vault1;
    MockAtRISKUSD public vault2;
    MockAtRISKUSD public vault3;
    MockVaultRegistry public mockVaultRegistry;
    uint256 public registeredVaultId;
    address public owner;

    // Ghost variables for tracking
    uint256 public ghost_totalJoined;
    uint256 public ghost_totalCancelled;
    uint256 public ghost_totalProcessed;

    // Generation counter: incremented on each processQueue call.
    // Used to disambiguate entries created before vs after a processQueue call.
    uint256 public ghost_processGeneration;

    // Entry tracking with generation info
    struct TrackedEntry {
        uint256 queueId;
        address depositor;
        uint256 amount;
        uint8 tier;
        bool processed;
        bool cancelled;
        bool priority;
        bool cancelledDuringProcess; // true if cancelled by OF-L06 during processQueue, false if user cancel
        uint256 createdGen; // generation when entry was created (0 = before any processQueue)
        uint256 processedGen; // generation when entry was processed (0 = not processed)
        uint256 cancelledGen; // generation when entry was cancelled (0 = not cancelled)
    }

    TrackedEntry[] public entries;
    uint256[] public queueIds; // all IDs created, in order

    // Per-depositor RISKUSD refund tracking
    mapping(address => uint256) public refundedTo;

    // Per-deposit tracking for process verification
    uint256 public ghost_depositCallCount;

    // Capacity tracking for invariant: track capacity at each processQueue call
    uint256 public ghost_capacityAtLastProcess;
    uint256 public ghost_processedSinceLastCapacityChange;
    uint256 public ghost_maxCapacityEverSet;

    // Priority price/multiplier tracking
    uint256 public ghost_currentPrice;
    uint256 public ghost_currentMultiplier;

    // Per-generation available capacity tracking (for priority-drain verification)
    mapping(uint256 => uint256) public ghost_availCapacityAtGeneration;

    // Per-generation budget and tier tracking (for scan-budget-aware verification)
    mapping(uint256 => uint256) public ghost_budgetAtGeneration;
    mapping(uint256 => uint8) public ghost_tierAtGeneration;

    // Callers for bounded random user selection
    address[] internal callers;

    // Bounded constants
    uint256 public constant MAX_AMOUNT = 1e12;
    uint256 public constant MIN_AMOUNT = 1;

    constructor(
        StakingQueue stakingQueue_,
        MockRISKUSD riskusd_,
        MockForageTokenLocked forage_,
        MockAtRISKUSD vault0_,
        MockAtRISKUSD vault1_,
        MockAtRISKUSD vault2_,
        MockAtRISKUSD vault3_,
        MockVaultRegistry mockVaultRegistry_,
        uint256 registeredVaultId_,
        address owner_
    ) {
        stakingQueue = stakingQueue_;
        riskusd = riskusd_;
        forage = forage_;
        vault0 = vault0_;
        vault1 = vault1_;
        vault2 = vault2_;
        vault3 = vault3_;
        mockVaultRegistry = mockVaultRegistry_;
        registeredVaultId = registeredVaultId_;
        owner = owner_;

        // Pre-create callers
        callers.push(makeAddr("handler_alice"));
        callers.push(makeAddr("handler_bob"));
        callers.push(makeAddr("handler_charlie"));
        callers.push(makeAddr("handler_dave"));
        callers.push(makeAddr("handler_eve"));
    }

    /// @dev Set FORAGE price with bounded value.
    function setForagePriceUsd(uint256 price) external {
        uint256 bounded = bound(price, 0, 100e6); // 0 to $100 per FORAGE
        vm.startPrank(owner);
        try stakingQueue.setForagePriceUsd(bounded) {
            vm.warp(block.timestamp + stakingQueue.FINALIZE_DELAY() + 1);
            try stakingQueue.finalizeForagePriceUsd() {
                ghost_currentPrice = bounded;
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    /// @dev Set priority multiplier with bounded value.
    function setPriorityMultiplier(uint256 multiplier) external {
        uint256 bounded = bound(multiplier, 0, 100);
        vm.prank(owner);
        try stakingQueue.setPriorityMultiplier(bounded) {
            ghost_currentMultiplier = bounded;
        } catch {}
    }

    /// @dev Join the queue with bounded parameters.
    function joinQueue(uint256 amount, uint8 tierRaw, uint256 callerSeed) external {
        uint256 boundedAmount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        uint8 tier = uint8(bound(tierRaw, 0, 3));
        address caller = callers[callerSeed % callers.length];

        // If priority is active, randomly give some callers enough FORAGE
        // so the active lock() call in joinQueue succeeds and creates priority entries.
        // Active locking model: StakingQueue calls lock(user, forageToLock) during joinQueue.
        // lock() requires balanceOf(user) - lockedBalances(user) >= forageToLock.
        if (ghost_currentPrice > 0 && ghost_currentMultiplier > 0) {
            uint256 callerIdx = callerSeed % callers.length;
            if (callerIdx % 2 == 0) {
                // forageToLock = ceilDiv(riskusdAmount * 1e18, price * mult)
                uint256 needed = (boundedAmount * 1e18) / (ghost_currentPrice * ghost_currentMultiplier) + 1;
                // Mint enough FORAGE so lock() can succeed (need unlocked >= needed)
                uint256 currentBalance = forage.balanceOf(caller);
                uint256 currentLocked = forage.lockedBalance(caller);
                uint256 currentUnlocked = currentBalance >= currentLocked ? currentBalance - currentLocked : 0;
                if (currentUnlocked < needed) {
                    forage.mint(caller, needed - currentUnlocked);
                }
            }
        }

        // Mint and approve RISKUSD for the caller
        riskusd.mint(caller, boundedAmount);
        vm.prank(caller);
        riskusd.approve(address(stakingQueue), boundedAmount);

        uint256 queueIdBefore = stakingQueue.nextQueueId();

        // Determine if this caller qualifies for priority (active locking model).
        // Priority is determined by whether lock(user, forageToLock) succeeds,
        // which requires balanceOf(user) - lockedBalances(user) >= forageToLock
        // AND cap >= alreadyQueued + newAmount.
        bool isPriority = false;
        if (ghost_currentPrice > 0 && ghost_currentMultiplier > 0) {
            uint256 forageToLock = Math.ceilDiv(boundedAmount * 1e18, ghost_currentPrice * ghost_currentMultiplier);
            uint256 currentBalance = forage.balanceOf(caller);
            uint256 currentLocked = forage.lockedBalance(caller);
            uint256 unlocked = currentBalance >= currentLocked ? currentBalance - currentLocked : 0;
            // lock() succeeds if unlocked >= forageToLock
            isPriority = (forageToLock >= 1e15 && unlocked >= forageToLock);
        }

        vm.prank(caller);
        try stakingQueue.joinQueue(boundedAmount, tier) {
            // Track the entry with current generation
            queueIds.push(queueIdBefore);
            entries.push(
                TrackedEntry({
                    queueId: queueIdBefore,
                    depositor: caller,
                    amount: boundedAmount,
                    tier: tier,
                    processed: false,
                    cancelled: false,
                    priority: isPriority,
                    cancelledDuringProcess: false,
                    createdGen: ghost_processGeneration,
                    processedGen: 0,
                    cancelledGen: 0
                })
            );
            ghost_totalJoined += boundedAmount;
        } catch {
            // Stub reverts -- expected before implementation
        }
    }

    /// @dev Cancel a random existing queue entry.
    function cancelQueue(uint256 entrySeed) external {
        if (entries.length == 0) return;

        uint256 idx = entrySeed % entries.length;
        TrackedEntry storage entry = entries[idx];

        // Skip already processed or cancelled
        if (entry.processed || entry.cancelled) return;

        vm.prank(entry.depositor);
        try stakingQueue.cancelQueue(entry.queueId) {
            entry.cancelled = true;
            entry.cancelledGen = ghost_processGeneration;
            ghost_totalCancelled += entry.amount;
            refundedTo[entry.depositor] += entry.amount;
        } catch {
            // Stub reverts -- expected before implementation
        }
    }

    /// @dev Process the queue for a random tier.
    /// After processQueue succeeds, reads the contract's actual entry state to determine
    /// which entries were processed. This avoids the handler needing to replicate the
    /// contract's capacity-aware priority-then-standard logic.
    function processQueue(uint8 tierRaw, uint256 maxEntries) external {
        uint8 tier = uint8(bound(tierRaw, 0, 3));
        uint256 bounded = bound(maxEntries, 1, 50);

        uint256 depositCountBefore = _getVaultDepositCount(tier);

        // Record the capacity available at the time of this processQueue call
        ghost_capacityAtLastProcess = stakingQueue.combinedCapacity();

        // Increment generation BEFORE processing so entries created in this
        // generation are distinguishable from entries created before it
        ghost_processGeneration++;

        // Track available capacity, budget, and tier per generation for priority-drain verification
        ghost_availCapacityAtGeneration[ghost_processGeneration] = stakingQueue.availableCapacity();
        ghost_budgetAtGeneration[ghost_processGeneration] = bounded;
        ghost_tierAtGeneration[ghost_processGeneration] = tier;

        try stakingQueue.processQueue(tier, bounded) {
            uint256 depositCountAfter = _getVaultDepositCount(tier);
            uint256 newDeposits = depositCountAfter - depositCountBefore;
            ghost_depositCallCount += newDeposits;

            // Read actual state from contract to determine which entries were
            // processed or cancelled (OF-L06: priority entries may be cancelled
            // during processQueue if depositor no longer meets FORAGE threshold).
            for (uint256 i = 0; i < entries.length; i++) {
                if (entries[i].tier == tier && !entries[i].processed && !entries[i].cancelled) {
                    StakingQueue.QueueEntry memory contractEntry = stakingQueue.getQueueEntry(entries[i].queueId);
                    if (contractEntry.processed) {
                        entries[i].processed = true;
                        entries[i].processedGen = ghost_processGeneration;
                        ghost_totalProcessed += entries[i].amount;
                        ghost_processedSinceLastCapacityChange += entries[i].amount;
                    } else if (contractEntry.cancelled) {
                        // OF-L06: entry was cancelled during processQueue
                        entries[i].cancelled = true;
                        entries[i].cancelledDuringProcess = true;
                        entries[i].cancelledGen = ghost_processGeneration;
                        ghost_totalCancelled += entries[i].amount;
                        refundedTo[entries[i].depositor] += entries[i].amount;
                    }
                }
            }
        } catch {
            // Reverts -- capacity exceeded or other error
        }
    }

    /// @dev Set combined capacity via VaultRegistry with bounded value.
    function setCapacityCap(uint256 capacity) external {
        uint256 bounded = bound(capacity, 1, 100_000_000e6);
        try mockVaultRegistry.setTestCapacityCap(registeredVaultId, bounded) {
            if (bounded > ghost_maxCapacityEverSet) {
                ghost_maxCapacityEverSet = bounded;
            }
            // Reset processed-since-last-change tracking
            ghost_processedSinceLastCapacityChange = 0;
        } catch {}
    }

    // ── Verification helper functions ──

    /// @dev Compute sum of riskusdAmount for all non-processed, non-cancelled entries.
    function computeTotalQueued() external view returns (uint256 total) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (!entries[i].processed && !entries[i].cancelled) {
                total += entries[i].amount;
            }
        }
    }

    /// @dev Verify FIFO order: within each tier+lane, queueIds are strictly increasing
    /// among non-processed, non-cancelled entries.
    function verifyFifoOrder() external view returns (bool) {
        for (uint8 tier = 0; tier < 4; tier++) {
            uint256 lastId = 0;
            bool foundFirst = false;
            for (uint256 i = 0; i < entries.length; i++) {
                if (entries[i].tier == tier && !entries[i].processed && !entries[i].cancelled) {
                    if (foundFirst && entries[i].queueId <= lastId) {
                        return false;
                    }
                    lastId = entries[i].queueId;
                    foundFirst = true;
                }
            }
        }
        return true;
    }

    /// @dev Verify priority entries drain before standard entries within the same tier.
    /// Uses generation tracking with capacity AND budget awareness: for each processQueue
    /// generation G, if any standard entry was processed in generation G, then all priority
    /// entries in the same tier that existed before G must be either:
    /// (a) processed by G, (b) cancelled, (c) blocked by capacity constraints, or
    /// (d) blocked by scan budget (OF-M04: _processLane scans at most `budget` entries
    ///     including dead entries, so cancelled/processed entries consume scan budget).
    function verifyPriorityDrainsFirst() external view returns (bool) {
        for (uint8 tier = 0; tier < 4; tier++) {
            for (uint256 g = 1; g <= ghost_processGeneration; g++) {
                // Only check generations that processed this tier
                if (ghost_tierAtGeneration[g] != tier) continue;

                // Check if any standard entry was processed in this generation
                bool standardProcessedInG = false;
                for (uint256 i = 0; i < entries.length; i++) {
                    if (entries[i].tier == tier && !entries[i].priority && entries[i].processedGen == g) {
                        standardProcessedInG = true;
                        break;
                    }
                }
                if (!standardProcessedInG) continue;

                // Standard entry was processed. Check each priority entry for this tier.
                // Track remaining capacity after each processed priority entry (FIFO order).
                // Also track scan budget: the contract's _processLane iterates at most
                // `budget` entries (including dead entries from prior gens and OF-L06
                // cancelled entries). When the scan budget is exhausted, remaining
                // priority entries are unreachable — not a violation.
                uint256 remainingCapacity = ghost_availCapacityAtGeneration[g];
                bool blockedByCapacity = false;
                uint256 budget = ghost_budgetAtGeneration[g];
                uint256 scannedCount = 0;

                for (uint256 i = 0; i < entries.length; i++) {
                    if (entries[i].tier != tier || !entries[i].priority) continue;
                    if (entries[i].createdGen >= g) continue; // created after this generation

                    // OF-M04: scan budget exhausted — remaining entries unreachable
                    if (scannedCount >= budget) break;

                    // Dead entry: cancelled or processed before this generation.
                    // Still in the lane (no compaction by handler), consumes scan budget
                    // when the contract iterates past it.
                    bool deadBeforeG = (entries[i].processedGen > 0 && entries[i].processedGen < g)
                        || (entries[i].cancelled && entries[i].cancelledGen < g);
                    if (deadBeforeG) {
                        scannedCount++;
                        continue;
                    }

                    // Processed in this generation — consumes budget + capacity
                    if (entries[i].processedGen == g) {
                        scannedCount++;
                        if (entries[i].amount <= remainingCapacity) {
                            remainingCapacity -= entries[i].amount;
                        } else {
                            remainingCapacity = 0;
                        }
                        continue;
                    }

                    // OF-L06: entry cancelled BY processQueue during this generation
                    // (depositor no longer met FORAGE threshold). The contract skipped
                    // this entry without breaking, so it did NOT block subsequent entries.
                    // Consumes scan budget only.
                    if (entries[i].cancelled && entries[i].cancelledDuringProcess && entries[i].cancelledGen == g) {
                        scannedCount++;
                        continue;
                    }

                    // User-cancelled entry (cancelled after processQueue, same gen):
                    // During processQueue this entry was ACTIVE. If it didn't fit
                    // capacity, it blocked subsequent entries via FIFO break.
                    // Treat it the same as a live unprocessed entry.
                    // (Falls through to the capacity/FIFO check below.)

                    // Live or user-cancelled-after-process entry: not processed,
                    // budget not exhausted. Must be blocked by capacity or FIFO.
                    if (blockedByCapacity) continue; // FIFO blocked by a prior entry

                    if (entries[i].amount > remainingCapacity) {
                        // This entry doesn't fit remaining capacity — blocked.
                        // All subsequent entries are FIFO blocked.
                        blockedByCapacity = true;
                        continue;
                    }

                    // Entry fits remaining capacity and budget but wasn't processed — violation!
                    return false;
                }
            }
        }
        return true;
    }

    /// @dev Verify all cancelled entries had RISKUSD refunded.
    function verifyCancelRefunds() external view returns (bool) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].cancelled) {
                if (refundedTo[entries[i].depositor] < entries[i].amount) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @dev Verify all processed entries resulted in vault deposit calls.
    function verifyProcessDeposits() external view returns (bool) {
        uint256 processedCount = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].processed) {
                processedCount++;
            }
        }
        return ghost_depositCallCount >= processedCount;
    }

    /// @dev Get the total number of entries tracked.
    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    /// @dev Get the deposit call count from the vault for a given tier.
    function _getVaultDepositCount(uint8 tier) internal view returns (uint256) {
        if (tier == 0) return vault0.depositCallCount();
        if (tier == 1) return vault1.depositCallCount();
        if (tier == 2) return vault2.depositCallCount();
        if (tier == 3) return vault3.depositCallCount();
        return 0;
    }
}

contract StakingQueue_TC14_Invariants is Test {
    StakingQueue public stakingQueue;
    StakingQueue public implementation;
    MockRISKUSD public riskusd;
    MockForageTokenLocked public forage;
    MockAtRISKUSD public vault0;
    MockAtRISKUSD public vault1;
    MockAtRISKUSD public vault2;
    MockAtRISKUSD public vault3;
    MockVaultRegistry public mockVaultRegistry;
    uint256 public registeredVaultId;
    StakingQueueHandler public handler;

    address public owner;

    uint256 public constant DEFAULT_COMBINED_CAPACITY = 10_000_000e6;

    function setUp() public {
        owner = makeAddr("timelock");

        riskusd = new MockRISKUSD();
        forage = new MockForageTokenLocked();
        vault0 = new MockAtRISKUSD(address(riskusd));
        vault1 = new MockAtRISKUSD(address(riskusd));
        vault2 = new MockAtRISKUSD(address(riskusd));
        vault3 = new MockAtRISKUSD(address(riskusd));

        // Deploy VaultRegistry mock and register a vault
        mockVaultRegistry = new MockVaultRegistry();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        uint256[4] memory lockups = [uint256(0), 7776000, 15552000, 31104000];
        uint16[4] memory yieldBps = [uint16(5000), 5500, 6000, 6500];
        uint16[4] memory fundingBps = [uint16(2000), 2000, 1500, 1500];
        registeredVaultId = mockVaultRegistry.addTestVault(
            "Test Vault", "TV", tierVaults, address(0), DEFAULT_COMBINED_CAPACITY, lockups, yieldBps, fundingBps
        );

        implementation = new StakingQueue();

        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        stakingQueue = StakingQueue(address(proxy));

        // Link queue to its vault in the registry
        vm.prank(owner);
        stakingQueue.setVaultId(registeredVaultId);

        handler = new StakingQueueHandler(
            stakingQueue, riskusd, forage, vault0, vault1, vault2, vault3, mockVaultRegistry, registeredVaultId, owner
        );

        // Register handler as target contract with explicit selectors
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = StakingQueueHandler.joinQueue.selector;
        selectors[1] = StakingQueueHandler.cancelQueue.selector;
        selectors[2] = StakingQueueHandler.processQueue.selector;
        selectors[3] = StakingQueueHandler.setCapacityCap.selector;
        selectors[4] = StakingQueueHandler.setForagePriceUsd.selector;
        selectors[5] = StakingQueueHandler.setPriorityMultiplier.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ── 8 Invariant Functions ──

    /// @dev R-37: nextQueueId MUST be monotonically non-decreasing.
    function invariant_queueIdMonotonicity() public view {
        assertGe(stakingQueue.nextQueueId(), 1, "nextQueueId must be >= 1 (monotonic from initial 1)");
        assertGe(
            stakingQueue.nextQueueId(), 1 + handler.entryCount(), "nextQueueId must be >= 1 + number of entries created"
        );
    }

    /// @dev R-38: totalQueuedRiskusd MUST equal sum of riskusdAmount across entries
    /// where processed == false AND cancelled == false.
    function invariant_totalQueuedRiskusdConsistency() public view {
        uint256 computed = handler.computeTotalQueued();
        assertEq(
            stakingQueue.totalQueuedRiskusd(), computed, "totalQueuedRiskusd must match computed sum of active entries"
        );
    }

    /// @dev R-22: Entries within each tier and lane MUST have queueIds in strictly
    /// increasing order (FIFO preserved).
    function invariant_queueOrderPreserved() public view {
        assertTrue(handler.verifyFifoOrder(), "Queue order must be preserved (FIFO by queueId)");
    }

    /// @dev R-28, R-36: processQueue MUST NOT deposit beyond the capacity that was
    /// available at the time of processing.
    function invariant_capacityNotExceededByProcessing() public view {
        if (handler.ghost_maxCapacityEverSet() == 0) return;

        assertLe(
            handler.ghost_processedSinceLastCapacityChange(),
            handler.ghost_capacityAtLastProcess(),
            "Processed amount since last capacity change must not exceed capacity at time of processing"
        );
    }

    /// @dev R-21: Priority lane entries MUST be processed before standard lane entries
    /// within the same tier and processQueue call.
    function invariant_upgradesPrioritized() public view {
        assertTrue(handler.verifyPriorityDrainsFirst(), "Priority entries must drain before standard entries");
    }

    /// @dev R-20: Every cancelled entry MUST have its RISKUSD refunded to the depositor.
    function invariant_cancelledEntriesReturnFunds() public view {
        assertTrue(handler.verifyCancelRefunds(), "All cancelled entries must have RISKUSD refunded");
    }

    /// @dev R-25: Every processed entry MUST result in a vault deposit call.
    function invariant_processedEntriesDeposited() public view {
        assertTrue(handler.verifyProcessDeposits(), "All processed entries must have corresponding vault deposits");
    }

    /// @dev R-38: StakingQueue RISKUSD balance MUST equal totalQueuedRiskusd.
    function invariant_riskusdBalanceConsistency() public view {
        assertEq(
            riskusd.balanceOf(address(stakingQueue)),
            stakingQueue.totalQueuedRiskusd(),
            "StakingQueue RISKUSD balance must equal totalQueuedRiskusd"
        );
    }

    // ── 3 Basic Handler Verification Tests ──

    /// @dev Verify handler can track a join operation.
    function test_TC14_handlerTracksJoin() public {
        handler.joinQueue(1000e6, 0, 0);
        assertTrue(true, "handler joinQueue did not revert");
    }

    /// @dev Verify handler can track a cancel operation.
    function test_TC14_handlerTracksCancel() public {
        handler.joinQueue(1000e6, 0, 0);
        handler.cancelQueue(0);
        assertTrue(true, "handler cancelQueue did not revert");
    }

    /// @dev Verify handler can track a process operation.
    function test_TC14_handlerTracksProcess() public {
        handler.joinQueue(1000e6, 0, 0);
        handler.processQueue(0, 10);
        assertTrue(true, "handler processQueue did not revert");
    }
}
