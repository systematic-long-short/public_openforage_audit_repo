// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/StakingQueue.sol";
import "../../../src/VaultRegistry.sol";
import "../../../src/atRISKUSD.sol";

// External nondeterministic boundary: tier yield source fixture.
import "../../mocks/MockYieldSourceForLossPending.sol";

contract Octane20260625QueueRedTest is Test {
    struct QueueFixture {
        address owner;
        address alice;
        address bob;
        address carol;
        address keeper;
        RISKUSD riskusd;
        ForageToken forage;
        MockYieldSourceForLossPending yieldSource;
        atRISKUSD vault0;
        atRISKUSD vault1;
        atRISKUSD vault2;
        atRISKUSD vault3;
        VaultRegistry registry;
        StakingQueue queue;
        uint256 vaultId;
    }

    QueueFixture internal queueFixture;

    function test_V1_liveUnreachableStandardHeadMustNotBlockLaterReachableEntry() public {
        // PHASE5_REPRO_BINDING: V-1
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        _fundRiskusd(f.alice, amount);
        uint256 poisonId = f.queue.nextQueueId();

        vm.prank(f.alice);
        (bool accepted,) = address(f.queue)
            .call(
                abi.encodeCall(
                    StakingQueue.joinQueueWithBounds, (amount, uint8(0), type(uint256).max, block.timestamp + 365 days)
                )
            );

        if (!accepted) {
            assertEq(f.queue.tierStandardQueueLength(0), 0, "rejected poison entry must not enter standard lane");
            return;
        }

        assertEq(f.queue.getQueueEntry(poisonId).depositor, f.alice, "setup: poison entry accepted");

        uint256 laterId = _joinStandard(f.bob, amount, 1, block.timestamp + 7 days);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertTrue(
            f.queue.getQueueEntry(laterId).processed,
            "live unprocessable standard head must not block a later reachable standard entry"
        );
    }

    function test_V1_oversizedStandardHeadCapacityPinMustNotBlockLaterProcessableEntry() public {
        // PHASE15_REJECT_REPRO_BINDING: V-1 oversized capacity pin
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();
        _setRegisteredCapacityCap(1_000e6);

        uint256 headId = _joinStandard(f.alice, 1_500e6, 1, block.timestamp + 30 days);
        uint256 laterId = _joinStandard(f.bob, 500e6, 1, block.timestamp + 30 days);

        assertEq(f.queue.tierStandardHead(0), 0, "setup: oversized head starts at standard head");
        assertEq(f.queue.totalQueuedRiskusd(), 2_000e6, "setup: both entries remain queued before processing");

        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        StakingQueue.QueueEntry memory head = f.queue.getQueueEntry(headId);
        assertEq(head.riskusdAmount, 1_500e6, "oversized head amount");
        assertEq(head.depositor, f.alice, "oversized head depositor");
        assertFalse(head.processed, "oversized standard head remains unprocessed");
        assertFalse(head.cancelled, "oversized standard head remains live");
        assertTrue(f.queue.getQueueEntry(laterId).processed, "later processable entry should settle within scan budget");
        assertEq(f.queue.tierStandardHead(0), 0, "standard head must not advance past live oversized entry");
        assertEq(f.queue.totalQueuedRiskusd(), 1_500e6, "queued accounting keeps only the live oversized head");
        assertEq(f.vault0.totalAssets(), 500e6, "only later entry deposits into tier vault");
        assertEq(f.queue.combinedStaked(), 500e6, "combined capacity usage stays below cap");
        assertEq(f.queue.availableCapacity(), 500e6, "combined capacity is not exceeded");
        assertEq(f.queue.tierDepositAvailableCapacity(0), 500e6, "tier capacity is not exceeded");

        vm.prank(f.alice);
        (bool cancelOk,) = address(f.queue).call(abi.encodeCall(StakingQueue.cancelQueue, (headId)));
        assertTrue(cancelOk, "live oversized head remains cancellable");
    }

    function test_RV11_expiredStandardEntryMustNotBeResurrectedToRewindHead() public {
        // PHASE5_REPRO_BINDING: R-V-1-1
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 expiredId = _joinStandard(f.alice, amount, 1, block.timestamp + 1);
        uint256 bobId = _joinStandard(f.bob, amount, 1, block.timestamp + 30 days);

        vm.warp(block.timestamp + 2);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertFalse(f.queue.getQueueEntry(expiredId).processed, "setup: first entry expired without processing");
        assertTrue(f.queue.getQueueEntry(bobId).processed, "setup: head advanced and processed later valid entry");
        assertEq(f.queue.tierStandardHead(0), 2, "setup: standard head advanced past expired and processed entries");

        uint256 carolId = _joinStandard(f.carol, amount, 1, block.timestamp + 30 days);

        vm.prank(f.alice);
        (bool revived,) = address(f.queue)
            .call(
                abi.encodeCall(
                    StakingQueue.setQueueEntryBounds, (expiredId, type(uint256).max, block.timestamp + 30 days)
                )
            );

        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertTrue(
            f.queue.getQueueEntry(carolId).processed,
            revived
                ? "expired standard entry must not be resurrected to rewind head and block later entries"
                : "valid later entry should process when expired entry cannot revive"
        );
    }

    function test_RV12_legacyZeroBoundsEntryBlocksStandardLaneUntilCancelled() public {
        // PHASE15_REPRO_BINDING: R-V-1-2
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 legacyId = _joinStandard(f.alice, amount, 1, block.timestamp + 30 days);
        uint256 laterId = _joinStandard(f.bob, amount, 1, block.timestamp + 30 days);

        _writeQueueEntryBounds(legacyId, 0, 0);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertFalse(
            f.queue.getQueueEntry(legacyId).processed,
            "legacy zero-bound entry remains live because deadline zero is not expired"
        );
        assertFalse(
            f.queue.getQueueEntry(laterId).processed,
            "standard processor breaks on live zero-bound legacy head and does not reach later entries"
        );
        assertEq(f.queue.tierStandardHead(0), 0, "head remains pinned at the legacy entry");

        vm.prank(f.alice);
        f.queue.cancelQueue(legacyId);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertTrue(f.queue.getQueueEntry(laterId).processed, "manual cancellation clears the legacy head pin");
    }

    function test_RV12_ownerBackfillsLegacyZeroBoundsThenLaterEntryProcesses() public {
        // CI-0067_POLICY_A_POSTFIX: R-V-1-2
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 legacyId = _joinStandard(f.alice, amount, 1, block.timestamp + 30 days);
        uint256 laterId = _joinStandard(f.bob, amount, 1, block.timestamp + 30 days);
        _writeQueueEntryBounds(legacyId, 0, 0);

        vm.prank(f.owner);
        f.queue.adminBackfillQueueEntryBounds(legacyId, 1, block.timestamp + 7 days);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 2);

        assertTrue(f.queue.getQueueEntry(legacyId).processed, "backfilled legacy entry processes normally");
        assertTrue(f.queue.getQueueEntry(laterId).processed, "backfill prevents legacy zero-bound head pin");
    }

    function test_V5_expiredLockupProcessingRequiresDepositorOwnerOrApprovedProcessor() public {
        // CI-0067_POLICY_A_POSTFIX: V-5
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 autoRenewId = _joinTier(f.alice, amount, 1, 1, block.timestamp + 30 days);
        vm.prank(f.keeper);
        f.queue.processQueue(1, 1);
        assertTrue(f.queue.getQueueEntry(autoRenewId).processed, "setup: tier 1 auto-renew deposit processed");
        uint256 aliceTier1Shares = f.vault1.balanceOf(f.alice);
        uint256 initialExpiry = f.vault1.lockExpiry(f.alice);

        vm.warp(initialExpiry + 1);
        address[] memory depositors = new address[](1);
        depositors[0] = f.alice;
        vm.prank(f.bob);
        vm.expectRevert(abi.encodeWithSelector(StakingQueue.UnauthorizedLockupProcessor.selector, f.bob));
        f.queue.processExpiredLockups(depositors, 1);

        vm.prank(f.alice);
        f.queue.processExpiredLockups(depositors, 1);

        assertGt(
            f.vault1.lockExpiry(f.alice), initialExpiry, "depositor can renew their own expired auto-renewing lockup"
        );
        assertEq(f.vault1.balanceOf(f.alice), aliceTier1Shares, "renewal path keeps depositor in the locked tier");

        uint256 revertId = _joinTier(f.carol, amount, 1, 1, block.timestamp + 30 days);
        vm.prank(f.keeper);
        f.queue.processQueue(1, 1);
        assertTrue(f.queue.getQueueEntry(revertId).processed, "setup: tier 1 reversion deposit processed");
        uint256 carolExpiry = f.vault1.lockExpiry(f.carol);
        vm.prank(f.carol);
        f.vault1.setAutoRenew(false);

        vm.warp(carolExpiry + 1);
        depositors[0] = f.carol;
        vm.prank(f.alice);
        vm.expectRevert(abi.encodeWithSelector(StakingQueue.UnauthorizedLockupProcessor.selector, f.alice));
        f.queue.processExpiredLockups(depositors, 1);

        vm.prank(f.owner);
        f.queue.setExpiredLockupProcessor(f.keeper, true);
        vm.prank(f.keeper);
        f.queue.processExpiredLockups(depositors, 1);

        assertEq(f.vault1.balanceOf(f.carol), 0, "approved processing redeemed expired non-renewing tier 1 shares");
        assertGt(f.vault0.balanceOf(f.carol), 0, "approved processing deposited the assets into tier 0");
    }

    function test_V5_unapprovedThirdPartyCannotProcessButApprovedKeeperCan() public {
        // CI-0067_POLICY_A_POSTFIX: V-5
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 queueId = _joinTier(f.alice, amount, 1, 1, block.timestamp + 30 days);
        vm.prank(f.keeper);
        f.queue.processQueue(1, 1);
        uint256 initialExpiry = f.vault1.lockExpiry(f.alice);
        vm.warp(initialExpiry + 1);

        address[] memory depositors = new address[](1);
        depositors[0] = f.alice;
        queueId;

        vm.prank(f.bob);
        vm.expectRevert(abi.encodeWithSelector(StakingQueue.UnauthorizedLockupProcessor.selector, f.bob));
        f.queue.processExpiredLockups(depositors, 1);
        assertEq(f.vault1.lockExpiry(f.alice), initialExpiry, "unapproved caller cannot renew another user");

        vm.prank(f.owner);
        f.queue.setExpiredLockupProcessor(f.keeper, true);
        vm.prank(f.keeper);
        f.queue.processExpiredLockups(depositors, 1);
        assertGt(f.vault1.lockExpiry(f.alice), initialExpiry, "approved keeper can process expired lockup");
    }

    function test_V6_upgradeTierDivergentTierRatesPreserveCombinedAssets() public {
        // CI-0067_POLICY_A_POSTFIX: V-6
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 queueId = _joinStandard(f.alice, amount, 1, block.timestamp + 30 days);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);
        assertTrue(f.queue.getQueueEntry(queueId).processed, "setup: tier 0 deposit processed");

        _accrueYieldToTier0(200e6);
        uint256 combinedAssetsBefore =
            f.vault0.totalAssets() + f.vault1.totalAssets() + f.vault2.totalAssets() + f.vault3.totalAssets();
        uint256 sourceShares = f.vault0.balanceOf(f.alice);

        vm.prank(f.alice);
        f.queue.upgradeTier(0, 1, sourceShares / 2);

        uint256 combinedAssetsAfter =
            f.vault0.totalAssets() + f.vault1.totalAssets() + f.vault2.totalAssets() + f.vault3.totalAssets();
        assertGe(combinedAssetsAfter, combinedAssetsBefore, "divergent-rate upgrade preserves combined assets");
        assertLt(f.vault0.balanceOf(f.alice), sourceShares, "source tier shares are burned");
        assertGt(f.vault1.balanceOf(f.alice), 0, "destination tier shares are minted");
    }

    function test_V6_divergentTierRateUpgradeSucceedsWithAssetPreservation() public {
        // CI-0067_POLICY_A_POSTFIX: V-6
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 queueId = _joinStandard(f.alice, amount, 1, block.timestamp + 30 days);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);
        assertTrue(f.queue.getQueueEntry(queueId).processed, "setup: tier 0 deposit processed");

        _accrueYieldToTier0(200e6);
        uint256 combinedAssetsBefore =
            f.vault0.totalAssets() + f.vault1.totalAssets() + f.vault2.totalAssets() + f.vault3.totalAssets();
        uint256 sourceShares = f.vault0.balanceOf(f.alice);

        vm.prank(f.alice);
        f.queue.upgradeTier(0, 1, sourceShares / 2);

        uint256 combinedAssetsAfter =
            f.vault0.totalAssets() + f.vault1.totalAssets() + f.vault2.totalAssets() + f.vault3.totalAssets();
        assertGe(combinedAssetsAfter, combinedAssetsBefore, "upgrade preserves combined assets");
        assertLt(f.vault0.balanceOf(f.alice), sourceShares, "source shares are burned");
        assertGt(f.vault1.balanceOf(f.alice), 0, "destination shares are minted");
    }

    function test_V10_compactionDropsExpiredEntryButUserCanStillCancelAndRequeue() public {
        // PHASE15_REPRO_BINDING: V-10
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 expiredId = _joinStandard(f.alice, amount, 1, block.timestamp + 1);
        uint256 bobId = _joinStandard(f.bob, amount, 1, block.timestamp + 30 days);

        vm.warp(block.timestamp + 2);
        f.queue.compactQueue(0, false);

        assertEq(f.queue.tierStandardQueueLength(0), 1, "expired entry is removed from the standard lane");
        assertEq(f.queue.getQueueEntry(expiredId).depositor, f.alice, "entry record remains addressable");
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);
        assertTrue(f.queue.getQueueEntry(bobId).processed, "later entry keeps the compacted lane position");

        uint256 aliceBalanceBefore = f.riskusd.balanceOf(f.alice);
        vm.prank(f.alice);
        f.queue.cancelQueue(expiredId);
        assertEq(f.riskusd.balanceOf(f.alice), aliceBalanceBefore + amount, "expired removed entry is still refundable");
    }

    function _deployQueueFixture() internal {
        QueueFixture storage f = queueFixture;
        f.owner = makeAddr("octane25.queue.owner");
        f.alice = makeAddr("octane25.queue.alice");
        f.bob = makeAddr("octane25.queue.bob");
        f.carol = makeAddr("octane25.queue.carol");
        f.keeper = makeAddr("octane25.queue.keeper");

        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(f.owner, f.owner, f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();

        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        _setTierWithdrawalCaps(f);

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.registry = _deployVaultRegistry(f.owner);
        f.queue = _deployStakingQueue(address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner);
        f.vaultId = _registerVault(f.registry, f.owner, "Octane 20260625 Queue", "O25Q", tierVaults, address(f.queue));

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));
    }

    function _joinStandard(address user, uint256 amount, uint256 minShares, uint256 deadline)
        internal
        returns (uint256 queueId)
    {
        return _joinTier(user, amount, 0, minShares, deadline);
    }

    function _joinTier(address user, uint256 amount, uint8 tier, uint256 minShares, uint256 deadline)
        internal
        returns (uint256 queueId)
    {
        QueueFixture storage f = queueFixture;
        _fundRiskusd(user, amount);
        queueId = f.queue.nextQueueId();
        vm.prank(user);
        f.queue.joinQueueWithBounds(amount, tier, minShares, deadline);
    }

    function _fundRiskusd(address user, uint256 amount) internal {
        QueueFixture storage f = queueFixture;
        f.riskusd.mint(user, amount);
        vm.prank(user);
        f.riskusd.approve(address(f.queue), amount);
    }

    function _accrueYieldToTier0(uint256 amount) internal {
        QueueFixture storage f = queueFixture;
        f.riskusd.mint(address(f.yieldSource), amount);
        vm.prank(address(f.yieldSource));
        f.riskusd.approve(address(f.vault0), amount);
        vm.prank(address(f.yieldSource));
        f.vault0.accrueYield(amount);
    }

    function _writeQueueEntryBounds(uint256 queueId, uint256 minimumShares, uint256 deadline) internal {
        bytes32 baseSlot = keccak256(abi.encode(queueId, uint256(12)));
        vm.store(address(queueFixture.queue), bytes32(uint256(baseSlot) + 5), bytes32(minimumShares));
        vm.store(address(queueFixture.queue), bytes32(uint256(baseSlot) + 6), bytes32(deadline));
    }

    function _setRegisteredCapacityCap(uint256 capacityCap) internal {
        QueueFixture storage f = queueFixture;
        vm.prank(f.owner);
        f.registry.setCapacityCap(f.vaultId, capacityCap);
        vm.warp(block.timestamp + f.registry.FINALIZE_DELAY() + 1);
        vm.prank(f.owner);
        f.registry.finalizeCapacityCap(f.vaultId);
    }

    function _deployForageToken(address teamVesting, address forageTreasury, address owner)
        internal
        returns (ForageToken)
    {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRISKUSD(address owner) internal returns (RISKUSD) {
        RISKUSD implementation = new RISKUSD();
        bytes memory initData = abi.encodeCall(RISKUSD.initialize, (owner));
        return RISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployMintableRiskUSD(address owner) internal returns (RISKUSD riskusd) {
        riskusd = _deployRISKUSD(owner);
        vm.prank(owner);
        riskusd.setMinter(address(this));
        vm.warp(block.timestamp + riskusd.FINALIZE_DELAY() + 1);
        riskusd.acceptMinter();
    }

    function _deployAtRiskVault(address riskusd, address yieldSource, address stakingQueue, address owner)
        internal
        returns (atRISKUSD)
    {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData =
            abi.encodeCall(atRISKUSD.initialize, (riskusd, yieldSource, stakingQueue, 0, 0, 0, "0D", owner));
        return atRISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployVaultRegistry(address owner) internal returns (VaultRegistry) {
        VaultRegistry implementation = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        return VaultRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployStakingQueue(
        address riskusd,
        address forage,
        address[4] memory tierVaults,
        address vaultRegistry,
        address owner
    ) internal returns (StakingQueue) {
        StakingQueue implementation = new StakingQueue();
        bytes memory initData =
            abi.encodeCall(StakingQueue.initialize, (riskusd, forage, tierVaults, vaultRegistry, owner));
        return StakingQueue(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _registerVault(
        VaultRegistry registry,
        address owner,
        string memory name,
        string memory abbreviation,
        address[4] memory tierVaults,
        address stakingQueue
    ) internal returns (uint256) {
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(360 days)];
        uint16[4] memory yieldBps = [uint16(5_000), uint16(5_500), uint16(6_000), uint16(6_500)];
        uint16[4] memory fundingBps = [uint16(2_000), uint16(2_000), uint16(1_500), uint16(1_500)];
        vm.prank(owner);
        return
            registry.addVault(name, abbreviation, tierVaults, stakingQueue, 10_000_000e6, lockups, yieldBps, fundingBps);
    }

    function _wireTierVaultToQueue(atRISKUSD vault, address owner, address queue) internal {
        vm.prank(owner);
        vault.setStakingQueue(queue);
        vm.warp(block.timestamp + vault.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        vault.finalizeStakingQueue();
    }

    function _setTierWithdrawalCaps(QueueFixture storage f) internal {
        vm.startPrank(f.owner);
        f.vault0.setWeeklyWithdrawalCapBps(10_000);
        f.vault1.setWeeklyWithdrawalCapBps(10_000);
        f.vault2.setWeeklyWithdrawalCapBps(10_000);
        f.vault3.setWeeklyWithdrawalCapBps(10_000);
        vm.stopPrank();
    }
}
