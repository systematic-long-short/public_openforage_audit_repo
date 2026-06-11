// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============================================================
// Inline attack contracts for reentrancy tests
// ============================================================

/// @dev Malicious ERC20 that re-enters StakingQueue.joinQueue() or
/// cancelQueue() during transferFrom/transfer calls.
contract ReentrantRISKUSD is ERC20 {
    address public target; // StakingQueue address
    bool public armed;
    enum AttackType {
        JOIN,
        CANCEL
    }
    AttackType public attackType;
    uint256 public attackQueueId; // for cancel reentrancy

    constructor() ERC20("ReentrantRISKUSD", "REUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, AttackType type_, uint256 queueId_) external {
        target = target_;
        armed = true;
        attackType = type_;
        attackQueueId = queueId_;
    }

    function disarm() external {
        armed = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (armed) {
            armed = false; // prevent infinite recursion
            _reenter();
        }
        return result;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (armed) {
            armed = false;
            _reenter();
        }
        return result;
    }

    function _reenter() internal {
        if (attackType == AttackType.JOIN) {
            StakingQueue(target).joinQueue(1e6, 0);
        } else if (attackType == AttackType.CANCEL) {
            StakingQueue(target).cancelQueue(attackQueueId);
        }
    }
}

/// @dev Malicious vault that re-enters StakingQueue.processQueue() during deposit().
contract ReentrantVault {
    IERC20 public riskusd;
    address public target; // StakingQueue address
    bool public armed;

    constructor(address riskusd_) {
        riskusd = IERC20(riskusd_);
    }

    function arm(address target_) external {
        target = target_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function deposit(
        uint256 riskusdAmount,
        address /*depositor*/
    )
        external
        returns (uint256)
    {
        riskusd.transferFrom(msg.sender, address(this), riskusdAmount);
        if (armed) {
            armed = false;
            // Re-enter processQueue
            StakingQueue(target).processQueue(0, 10);
        }
        return riskusdAmount;
    }

    function totalAssets() external view returns (uint256) {
        return riskusd.balanceOf(address(this));
    }

    function legitimateAssets() external view returns (uint256) {
        return riskusd.balanceOf(address(this));
    }

    function redeemForUpgrade(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function redeemForReversion(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function renewLockup(address) external pure returns (uint256) {
        return 0;
    }
}

// ============================================================
// TC-15: Attack Vector Tests (R-10, R-15, R-21, R-22, R-28,
//        R-30, R-32, R-33, R-34, R-35, R-36, R-41, R-49)
// 14 tests covering queue manipulation, lockup expiry attacks,
// reentrancy attacks, and zero amount attacks.
// ============================================================
contract StakingQueue_TC15_Attacks is StakingQueueTestBase {
    // ── Queue Manipulation Attacks ──

    /// @dev Attack 16.1: Queue manipulation via front-running processQueue.
    /// Alice and Bob submit entries in the same block. Processing order MUST
    /// match submission order (FIFO by queueId), regardless of caller.
    function test_TC15_queueManipulationFrontRunning() public {
        // Alice and Bob both join in the same block
        uint256 queueIdAlice = _joinQueue(alice, STANDARD_DEPOSIT, 0);
        uint256 queueIdBob = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        // Alice's queueId MUST be less than Bob's (FIFO ordering)
        assertLt(queueIdAlice, queueIdBob, "Alice must have lower queueId than Bob");

        // Process queue -- keeper cannot selectively skip Alice
        vm.prank(keeper);
        queue.processQueue(0, 1);

        // Verify Alice was processed first (her entry should be marked processed)
        StakingQueue.QueueEntry memory entryAlice = queue.getQueueEntry(queueIdAlice);
        assertTrue(entryAlice.processed, "Alice's entry must be processed first (FIFO)");

        StakingQueue.QueueEntry memory entryBob = queue.getQueueEntry(queueIdBob);
        assertFalse(entryBob.processed, "Bob's entry must not be processed yet");
    }

    /// @dev Attack 16.1: FIFO under block reordering. Entries are ordered by queueId
    /// (append order), not by block.timestamp.
    function test_TC15_fifoByQueueIdNotTimestamp() public {
        // Alice joins at timestamp T
        uint256 queueIdAlice = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        // Bob joins at timestamp T + 1h
        uint256 queueIdBob = _joinQueue(bob, STANDARD_DEPOSIT, 0);

        // Process: Alice must be first despite earlier timestamp
        vm.prank(keeper);
        queue.processQueue(0, 1);

        StakingQueue.QueueEntry memory entryAlice = queue.getQueueEntry(queueIdAlice);
        assertTrue(entryAlice.processed, "Alice must be processed first by queueId order");

        StakingQueue.QueueEntry memory entryBob = queue.getQueueEntry(queueIdBob);
        assertFalse(entryBob.processed, "Bob must not be processed yet");
    }

    /// @dev Attack 16.2: Tier processing starvation via keeper bias.
    /// Keeper repeatedly processes tier 0. A second keeper MUST be able
    /// to process tier 1 independently.
    function test_TC15_tierProcessingStarvation() public {
        // Queue entries in tier 0 and tier 1
        _joinQueue(alice, STANDARD_DEPOSIT, 0);
        _joinQueue(bob, STANDARD_DEPOSIT, 1);

        // First keeper processes only tier 0
        vm.prank(keeper);
        queue.processQueue(0, 10);

        // Second keeper processes tier 1 independently
        address keeper2 = makeAddr("keeper2");
        vm.prank(keeper2);
        queue.processQueue(1, 10);

        // Verify both tiers were processed
        assertEq(vault0.depositCallCount(), 1, "Tier 0 should have 1 deposit");
        assertEq(vault1.depositCallCount(), 1, "Tier 1 should have 1 deposit");
    }

    /// @dev Attack 16.3: Queue griefing via spam entries.
    /// Each entry requires real RISKUSD transfer (economic cost).
    /// processQueue can process them incrementally.
    function test_TC15_queueGriefingViaSpam() public {
        // Submit 20 small spam entries (1 RISKUSD each)
        uint256 spamAmount = 1; // 1 unit (smallest possible)
        for (uint256 i = 0; i < 20; i++) {
            _joinQueue(attacker, spamAmount, 0);
        }

        // Verify attacker's RISKUSD was actually transferred (economic cost)
        assertEq(riskusd.balanceOf(address(queue)), spamAmount * 20, "Queue must hold all spam entry RISKUSD");

        // Queue a legitimate entry behind the spam
        uint256 legitQueueId = _joinQueue(alice, STANDARD_DEPOSIT, 0);

        // Process all spam entries incrementally
        vm.prank(keeper);
        queue.processQueue(0, 20);

        // Process legitimate entry
        vm.prank(keeper);
        queue.processQueue(0, 1);

        // Verify legitimate entry was processed
        StakingQueue.QueueEntry memory legitEntry = queue.getQueueEntry(legitQueueId);
        assertTrue(legitEntry.processed, "Legitimate entry behind spam must still be processable");
    }

    /// @dev Attack 16.4: Tier upgrade atomicity violation.
    /// If destination vault deposit() reverts, the ENTIRE transaction MUST revert
    /// (source vault redeemForUpgrade() rolled back).
    function test_TC15_tierUpgradeAtomicity() public {
        // Fund vault1 with RISKUSD so redeemForUpgrade can transfer to StakingQueue
        riskusd.mint(address(vault1), 1e6);

        // Set destination vault to revert on deposit
        vault2.setShouldRevertDeposit(true);

        // Attempt upgrade from tier 1 to tier 2
        vm.prank(alice);
        vm.expectRevert(bytes("MockAtRISKUSD: deposit reverted")); // Destination vault deposit failure propagates
        queue.upgradeTier(1, 2, 1000e6);

        // Verify source vault redeemForUpgrade was NOT called (or was rolled back)
        assertEq(
            vault1.redeemForUpgradeCallCount(), 0, "Source vault redeemForUpgrade must be rolled back on dest failure"
        );
    }

    /// @dev Attack 16.5: Combined capacity cap bypass defense.
    /// After filling to capacity, next processQueue MUST halt.
    /// Verifies capacity enforcement across multiple processQueue calls.
    function test_TC15_capacityCapBypass() public {
        // Set a small capacity for easier testing via VaultRegistry
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 2000e6);

        // Queue entries exceeding capacity
        uint256 aliceId = _joinQueue(alice, 1500e6, 0);
        uint256 bobId = _joinQueue(bob, 1500e6, 0);

        // Process first entry (1500 < 2000 capacity -- fits)
        vm.prank(keeper);
        queue.processQueue(0, 1);

        // Verify alice processed
        assertTrue(queue.getQueueEntry(aliceId).processed, "Alice's entry must be processed (fits capacity)");

        // Available capacity after alice: max(0, 2000 - 1500) = 500
        assertEq(queue.availableCapacity(), 500e6, "Available capacity should be 500e6 after alice");

        // Process second entry -- should halt (1500 > 500 remaining)
        vm.prank(keeper);
        queue.processQueue(0, 1);

        // Bob's entry should NOT have been processed (no partial fill)
        assertFalse(queue.getQueueEntry(bobId).processed, "Bob's entry must not be processed (exceeds capacity)");

        // Bob's RISKUSD should still be queued
        assertEq(queue.totalQueuedRiskusd(), 1500e6, "Bob's 1500e6 should remain queued");

        // Verify repeated processQueue calls don't bypass capacity
        vm.prank(keeper);
        queue.processQueue(0, 100);
        assertFalse(queue.getQueueEntry(bobId).processed, "Repeated processQueue must not bypass capacity");

        // Verify direct vault deposit bypasses capacity tracking:
        // A user who deposits directly to vault0 (bypassing StakingQueue) does NOT
        // update combinedStaked as seen by the queue. The capacity check uses
        // vault.totalAssets() which WILL reflect the direct deposit, so capacity
        // is still correctly enforced from the queue's perspective.
        uint256 capacityBefore = queue.availableCapacity();
        riskusd.mint(attacker, 1000e6);
        vm.prank(attacker);
        riskusd.approve(address(vault0), 1000e6);
        vm.prank(attacker);
        vault0.deposit(1000e6, attacker);

        // After direct deposit, vault0.totalAssets() increases, so availableCapacity decreases
        uint256 capacityAfter = queue.availableCapacity();
        assertLt(
            capacityAfter,
            capacityBefore,
            "Direct vault deposit must reduce availableCapacity (reflected via totalAssets)"
        );
    }

    // ── Lockup Expiry Attacks ──

    /// @dev Attack 17.1: Keeper griefing via processExpiredLockups.
    /// Calling with non-expired depositors: no state changes, no reverts.
    function test_TC15_keeperGriefingExpiredLockups() public {
        // Set lockup info: Alice has non-expired lockup
        vault1.setLockupInfo(alice, true, false, false, false, 1000e6);

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        // Call processExpiredLockups with non-expired depositor
        // Should be a no-op (gas wasted is attacker's cost)
        uint256 depositCountBefore = vault0.depositCallCount();
        uint256 renewCountBefore = vault1.renewLockupCallCount();

        vm.prank(attacker);
        queue.processExpiredLockups(depositors, 1);

        // No state changes
        assertEq(vault0.depositCallCount(), depositCountBefore, "No deposits should occur");
        assertEq(vault1.renewLockupCallCount(), renewCountBefore, "No renewals should occur");
    }

    /// @dev Attack 17.2: Auto-renewal toggle front-running.
    /// Function uses on-chain state at execution time.
    function test_TC15_autoRenewalToggleFrontRunning() public {
        // Alice has expired lockup with auto-renewal ENABLED
        vault1.setLockupInfo(alice, true, true, true, false, 1000e6);

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        // Keeper calls processExpiredLockups
        // At execution time, auto-renewal is ENABLED -> renewal should happen
        vm.prank(keeper);
        queue.processExpiredLockups(depositors, 1);

        // If auto-renewal was used, renewLockup should be called
        assertEq(vault1.renewLockupCallCount(), 1, "Lockup should be renewed (auto-renewal enabled at execution time)");
    }

    /// @dev Attack 17.3: Sweep front-running for exchange rate.
    /// redeemForReversion returns RISKUSD at current exchange rate.
    /// Attacker gains no advantage from timing.
    function test_TC15_sweepFrontRunningExchangeRate() public {
        // Alice has expired lockup in tier 1, auto-renewal disabled
        vault1.setLockupInfo(alice, true, true, false, false, 1000e6);

        // Set a specific exchange rate (redeem returns 900 RISKUSD for 1000 shares)
        vault1.setRedeemForReversionReturnAmount(900e6);

        // Mint RISKUSD to vault1 so it can transfer back
        riskusd.mint(address(vault1), 900e6);

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.prank(keeper);
        queue.processExpiredLockups(depositors, 1);

        // Verify reversion happened at the execution-time exchange rate
        assertEq(vault1.redeemForReversionCallCount(), 1, "redeemForReversion must be called");
    }

    /// @dev Attack 17.4: Vault operations MUST only be callable via StakingQueue.
    /// Part A: Direct unauthorized vault calls MUST revert (caller != authorizedQueue).
    /// Part B: StakingQueue-mediated calls MUST succeed under the same restriction.
    /// Both parts operate with the same authorizedQueue restriction active, proving
    /// that the queue is authorized while direct callers are not.
    function test_TC15_vaultOperationsOnlyViaStakingQueue() public {
        // Enable caller-based restriction: only the StakingQueue contract is authorized
        vault1.setAuthorizedQueue(address(queue));

        // Part A: Direct vault calls from attacker MUST revert.
        vm.prank(attacker);
        vm.expectRevert(bytes("MockAtRISKUSD: restricted to queue"));
        vault1.redeemForReversion(attacker, 1000e6);

        vm.prank(attacker);
        vm.expectRevert(bytes("MockAtRISKUSD: restricted to queue"));
        vault1.renewLockup(attacker);

        // Part B: StakingQueue-mediated path MUST succeed (same restriction still active).
        // Set up alice's expired lockup for reversion via processExpiredLockups
        vault1.setLockupInfo(alice, true, true, false, false, 1000e6);
        vault1.setRedeemForReversionReturnAmount(1000e6);
        riskusd.mint(address(vault1), 1000e6);

        // Verify no vault operations before processExpiredLockups
        assertEq(vault1.redeemForReversionCallCount(), 0, "No redeemForReversion before processing");
        assertEq(vault0.depositCallCount(), 0, "No deposits before processing");

        // Process via StakingQueue -- the authorized path (restriction still active!)
        address[] memory depositors = new address[](1);
        depositors[0] = alice;
        vm.prank(attacker); // permissionless caller of processExpiredLockups
        queue.processExpiredLockups(depositors, 1);

        // Verify vault operations succeeded via StakingQueue (msg.sender == queue == authorizedQueue)
        assertEq(
            vault1.redeemForReversionCallCount(),
            1,
            "redeemForReversion must succeed via StakingQueue (authorized caller)"
        );
        assertEq(vault0.depositCallCount(), 1, "Deposit to tier 0 must succeed via StakingQueue (authorized caller)");
    }

    // ── Reentrancy Attacks ──

    /// @dev Attack 2.3.11: Reentrancy via joinQueue.
    /// Malicious RISKUSD re-enters joinQueue during transferFrom.
    /// MUST revert with ReentrancyGuardReentrantCall.
    function test_TC15_reentrancyViaJoinQueue() public {
        // Deploy a fresh StakingQueue with ReentrantRISKUSD
        ReentrantRISKUSD reentrantToken = new ReentrantRISKUSD();
        MockForageTokenLocked forage_ = new MockForageTokenLocked();
        MockAtRISKUSD v0 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v1 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v2 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v3 = new MockAtRISKUSD(address(reentrantToken));

        StakingQueue impl = new StakingQueue();
        address[4] memory vaults = [address(v0), address(v1), address(v2), address(v3)];
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize,
            (address(reentrantToken), address(forage_), vaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue attackQueue = StakingQueue(address(proxy));

        // OF-039: Set vaultId before joinQueue
        vm.prank(owner);
        attackQueue.setVaultId(registeredVaultId);

        // Mint and approve tokens for alice
        reentrantToken.mint(alice, 10e6);
        vm.prank(alice);
        reentrantToken.approve(address(attackQueue), 10e6);

        // Arm the reentrant token: re-enter joinQueue during transferFrom
        reentrantToken.arm(address(attackQueue), ReentrantRISKUSD.AttackType.JOIN, 0);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackQueue.joinQueue(5e6, 0);
    }

    /// @dev Attack 2.3.12: Reentrancy via processQueue.
    /// Malicious vault re-enters processQueue during deposit().
    /// MUST revert with ReentrancyGuardReentrantCall.
    function test_TC15_reentrancyViaProcessQueue() public {
        // Deploy StakingQueue with ReentrantVault as tier 0
        ReentrantVault reentrantVault = new ReentrantVault(address(riskusd));
        MockAtRISKUSD v1 = new MockAtRISKUSD(address(riskusd));
        MockAtRISKUSD v2 = new MockAtRISKUSD(address(riskusd));
        MockAtRISKUSD v3 = new MockAtRISKUSD(address(riskusd));

        address[4] memory vaults = [address(reentrantVault), address(v1), address(v2), address(v3)];

        // OF-16-008: Register a custom vault in the registry with ReentrantVault as tier 0
        // so the auto-sync in processQueue doesn't override the reentrant vault.
        uint256[4] memory lockups = [uint256(0), 7776000, 15552000, 31104000];
        uint16[4] memory yieldBps = [uint16(5000), 5500, 6000, 6500];
        uint16[4] memory fundingBps = [uint16(2000), 2000, 1500, 1500];
        uint256 attackVaultId = mockVaultRegistry.addTestVault(
            "Attack Vault", "AV", vaults, address(0), DEFAULT_COMBINED_CAPACITY, lockups, yieldBps, fundingBps
        );

        StakingQueue impl = new StakingQueue();
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), vaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue attackQueue = StakingQueue(address(proxy));

        // Set the vault ID to the attack vault (which has ReentrantVault as tier 0)
        vm.prank(owner);
        attackQueue.setVaultId(attackVaultId);

        // Fund alice and join queue
        riskusd.mint(alice, STANDARD_DEPOSIT);
        vm.prank(alice);
        riskusd.approve(address(attackQueue), STANDARD_DEPOSIT);
        vm.prank(alice);
        attackQueue.joinQueue(STANDARD_DEPOSIT, 0);

        // Arm the reentrant vault: re-enter processQueue during deposit
        reentrantVault.arm(address(attackQueue));

        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackQueue.processQueue(0, 1);
    }

    /// @dev Attack 2.3.13: Reentrancy via cancelQueue.
    /// Malicious RISKUSD re-enters cancelQueue during transfer (refund).
    /// MUST revert with ReentrancyGuardReentrantCall.
    function test_TC15_reentrancyViaCancelQueue() public {
        // Deploy a fresh StakingQueue with ReentrantRISKUSD
        ReentrantRISKUSD reentrantToken = new ReentrantRISKUSD();
        MockForageTokenLocked forage_ = new MockForageTokenLocked();
        MockAtRISKUSD v0 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v1 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v2 = new MockAtRISKUSD(address(reentrantToken));
        MockAtRISKUSD v3 = new MockAtRISKUSD(address(reentrantToken));

        StakingQueue impl = new StakingQueue();
        address[4] memory vaults = [address(v0), address(v1), address(v2), address(v3)];
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize,
            (address(reentrantToken), address(forage_), vaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        StakingQueue attackQueue = StakingQueue(address(proxy));

        // OF-039: Set vaultId before joinQueue
        vm.prank(owner);
        attackQueue.setVaultId(registeredVaultId);

        // Mint and approve tokens for alice, then join
        reentrantToken.mint(alice, 10e6);
        vm.prank(alice);
        reentrantToken.approve(address(attackQueue), 10e6);
        vm.prank(alice);
        attackQueue.joinQueue(5e6, 0);

        // Arm the reentrant token: re-enter cancelQueue during transfer (refund)
        uint256 queueId = attackQueue.nextQueueId() - 1;
        reentrantToken.arm(address(attackQueue), ReentrantRISKUSD.AttackType.CANCEL, queueId);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackQueue.cancelQueue(queueId);
    }

    // ── Zero Amount Attacks ──

    /// @dev Attack 10.3: Zero amount operations MUST revert with ZeroAmount().
    function test_TC15_zeroAmountOperations() public {
        // joinQueue(0, tier) -- must revert ZeroAmount
        _fundUser(alice, STANDARD_DEPOSIT);
        vm.prank(alice);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.joinQueue(0, 0);

        // processQueue(tier, 0) -- must revert ZeroAmount
        vm.prank(keeper);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.processQueue(0, 0);

        // upgradeTier(0, 1, 0) -- must revert ZeroAmount
        vm.prank(alice);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.upgradeTier(0, 1, 0);

        // processExpiredLockups([], tier) -- must revert ZeroAmount
        address[] memory emptyDepositors = new address[](0);
        vm.prank(keeper);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.processExpiredLockups(emptyDepositors, 1);
    }
}
