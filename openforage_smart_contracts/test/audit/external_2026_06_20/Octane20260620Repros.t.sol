// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/StakingQueue.sol";
import "../../../src/VaultRegistry.sol";
import "../../../src/atRISKUSD.sol";
import "../../../src/hyperliquid/HLTradingBridge.sol";

// External boundaries only: USDC and the atRISKUSD yield source.
// OpenForage contracts under test are real src/ contracts.
import "../../mocks/MockUSDC.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

contract Octane20260620ReprosTest is Test {
    using stdStorage for StdStorage;

    string internal constant REPRO_FILE = "test/audit/external_2026_06_20/Octane20260620Repros.t.sol";
    string internal constant BINDING_MARKER = "PHASE5_REPRO_BINDING: ";

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

    struct GovernanceFixture {
        address owner;
        address guardian;
        address blockedSource;
        address cleanSource;
        address delegatee;
        ForageToken forage;
        Blocklist blocklist;
    }

    struct BridgeFixture {
        address owner;
        address keeper;
        address executor;
        address guardianModule;
        address reporter;
        address depositor;
        MockUSDC usdc;
        RISKUSD riskusd;
        RISKUSDVault vault;
        Blocklist blocklist;
        HLTradingBridge bridge;
    }

    QueueFixture internal queueFixture;
    GovernanceFixture internal governanceFixture;
    BridgeFixture internal bridgeFixture;

    function test_phase5ReproFileCarriesConcreteMarkersForAllJune20TruePositiveIds() public view {
        string memory repros = vm.readFile(REPRO_FILE);

        _assertBindingPresent(repros, "V-1");
        _assertBindingPresent(repros, "R-V-1-1");
        _assertBindingPresent(repros, "R-V-1-2");
        _assertBindingPresent(repros, "V-2");
        _assertBindingPresent(repros, "R-V-2-1");
        _assertBindingPresent(repros, "V-3");
        _assertBindingPresent(repros, "R-V-3-1");
        _assertBindingPresent(repros, "V-4");
        _assertBindingPresent(repros, "V-5");
    }

    function test_TQ1_livePreHeadEntrySurvivesCompactionAndRescue() public {
        // PHASE5_REPRO_BINDING: V-1
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 firstMinimumShares = f.vault0.previewDeposit(amount);
        uint256 firstId = _joinStandard(f.alice, amount, firstMinimumShares);

        _accrueYieldToTier0(amount);

        _joinStandard(f.bob, amount, 1);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertFalse(f.queue.getQueueEntry(firstId).processed, "setup: first entry is still live and unprocessed");

        vm.prank(f.keeper);
        f.queue.compactQueue(0, false);

        assertEq(
            f.queue.tierStandardQueueLength(0),
            2,
            "live standard entries must survive compaction instead of losing rescue/process paths"
        );

        vm.prank(f.alice);
        f.queue.setQueueEntryBounds(firstId, 1, block.timestamp + 7 days);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertTrue(f.queue.getQueueEntry(firstId).processed, "rescued pre-head entry should remain processable");
    }

    function test_TQ2_priorityLookaheadPreventsLaterStandardOvertaking() public {
        // PHASE5_REPRO_BINDING: R-V-1-1
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();
        _enablePriorityAdmission();

        uint256 amount = 1_000e6;
        uint256 unreachableMinimumShares = f.vault0.previewDeposit(amount);
        uint256 toxicPriorityId = _joinPriority(f.alice, amount, unreachableMinimumShares);
        assertTrue(f.queue.getQueueEntry(toxicPriorityId).priority, "setup: first entry is priority");

        _accrueYieldToTier0(amount);

        uint256 reachablePriorityId = _joinPriority(f.carol, amount, 1);
        assertTrue(f.queue.getQueueEntry(reachablePriorityId).priority, "setup: second entry is reachable priority");
        uint256 standardId = _joinStandard(f.bob, amount, 1);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertTrue(
            f.queue.getQueueEntry(reachablePriorityId).processed,
            "reachable priority entry must be served before later standard capacity"
        );
        assertFalse(
            f.queue.getQueueEntry(standardId).processed,
            "later standard entry must not overtake reachable priority solely because an earlier priority head is unreachable"
        );
    }

    function test_TQ3_dynamicReachabilityDoesNotLetLaterTolerantStandardFillFirst() public {
        // PHASE5_REPRO_BINDING: R-V-1-2
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 firstMinimumShares = f.vault0.previewDeposit(amount);
        uint256 firstId = _joinStandard(f.alice, amount, firstMinimumShares);

        _accrueYieldToTier0(amount);

        uint256 laterId = _joinStandard(f.bob, amount, 1);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertFalse(f.queue.getQueueEntry(firstId).processed, "setup: first entry remains available for rescue");
        assertFalse(
            f.queue.getQueueEntry(laterId).processed,
            "later tolerant standard entry must not fill before an earlier live FIFO entry"
        );
    }

    function test_TQ4_priorityAdmissionIgnoresManipulableJoinTimeReachability() public {
        // PHASE5_REPRO_BINDING: V-5
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();
        _enablePriorityAdmission();

        uint256 amount = 1_000e6;
        uint256 minimumSharesBeforeManipulation = f.vault0.previewDeposit(amount);
        _accrueYieldToTier0(amount);

        uint256 priorityId = _joinPriority(f.alice, amount, minimumSharesBeforeManipulation);

        assertTrue(
            f.queue.getQueueEntry(priorityId).priority,
            "valid priority admission must not be demoted by manipulable join-time reachability"
        );
    }

    function test_TB1_legacyBlockedSourceExcludedFromHistoricalVotes() public {
        // PHASE5_REPRO_BINDING: V-2
        GovernanceFixture storage f = governanceFixture;
        _deployGovernanceFixture();

        uint256 blockedVotes = 100e18;
        uint256 cleanVotes = 25e18;
        vm.prank(f.owner);
        f.forage.transfer(f.blockedSource, blockedVotes);
        vm.prank(f.owner);
        f.forage.transfer(f.cleanSource, cleanVotes);

        vm.prank(f.blockedSource);
        f.forage.delegate(f.delegatee);
        vm.prank(f.cleanSource);
        f.forage.delegate(f.delegatee);

        uint256 snapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        _writeLegacyBlockedUntil(f.blocklist, f.blockedSource, snapshot + 30 days);

        assertTrue(f.blocklist.isBlocked(f.blockedSource), "setup: legacy mapping says the source is blocked");
        assertFalse(
            f.blocklist.wasBlockedAt(f.blockedSource, snapshot),
            "setup: current implementation has no checkpoint fallback for legacy state"
        );
        assertEq(
            f.forage.getPastVotes(f.delegatee, snapshot),
            cleanVotes,
            "historical votes must exclude legacy-blocked delegate source voting power"
        );
    }

    function test_TB2_sameBlockBackfillSnapshotCannotCountLegacyBlockedSource() public {
        // PHASE5_REPRO_BINDING: R-V-2-1
        GovernanceFixture storage f = governanceFixture;
        _deployGovernanceFixture();

        uint256 blockedVotes = 100e18;
        uint256 cleanVotes = 25e18;
        vm.prank(f.owner);
        f.forage.transfer(f.blockedSource, blockedVotes);
        vm.prank(f.owner);
        f.forage.transfer(f.cleanSource, cleanVotes);

        vm.prank(f.blockedSource);
        f.forage.delegate(f.delegatee);
        vm.prank(f.cleanSource);
        f.forage.delegate(f.delegatee);

        uint256 proposerSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        _writeLegacyBlockedUntil(f.blocklist, f.blockedSource, proposerSnapshot + 30 days);

        address[] memory sources = new address[](2);
        sources[0] = f.blockedSource;
        sources[1] = f.cleanSource;
        vm.prank(f.owner);
        f.forage.syncDelegateSources(sources);

        assertEq(
            f.forage.getPastVotes(f.delegatee, proposerSnapshot),
            cleanVotes,
            "same-block proposer-threshold snapshot must not count a legacy-blocked source"
        );
    }

    function test_TB3_legacyBlockedSnapshotStillExcludedAfterLaterBlocklistCheckpoint() public {
        GovernanceFixture storage f = governanceFixture;
        _deployGovernanceFixture();

        uint256 blockedVotes = 100e18;
        uint256 cleanVotes = 25e18;
        vm.prank(f.owner);
        f.forage.transfer(f.blockedSource, blockedVotes);
        vm.prank(f.owner);
        f.forage.transfer(f.cleanSource, cleanVotes);

        vm.prank(f.blockedSource);
        f.forage.delegate(f.delegatee);
        vm.prank(f.cleanSource);
        f.forage.delegate(f.delegatee);

        uint256 governanceSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        _writeLegacyBlockedUntil(f.blocklist, f.blockedSource, governanceSnapshot + 30 days);

        vm.warp(governanceSnapshot + 2 days);
        vm.prank(f.guardian);
        f.blocklist.blockAddress(f.blockedSource);

        assertTrue(f.blocklist.isBlocked(f.blockedSource), "setup: source remains live-blocked");
        assertFalse(
            f.blocklist.wasBlockedAt(f.blockedSource, governanceSnapshot),
            "setup: later checkpoint must not cover the old snapshot directly"
        );
        assertEq(
            f.forage.getPastVotes(f.delegatee, governanceSnapshot),
            cleanVotes,
            "old governance snapshot must still exclude legacy-blocked voting power after a later checkpoint exists"
        );
        assertTrue(
            f.blocklist.wasEffectivelyBlockedAt(f.blockedSource, governanceSnapshot),
            "legacy fallback should apply before the account's first checkpoint"
        );
    }

    function test_TL1_keeperLossNonceUsesVaultStateAfterManualNonceAdvance() public {
        // PHASE5_REPRO_BINDING: V-3
        // PHASE5_REPRO_BINDING: R-V-3-1
        BridgeFixture storage f = bridgeFixture;
        _deployFundedBridgeFixture();

        vm.prank(f.reporter);
        f.vault.recordManualCustodianNAV(1, 900e6, 5);
        assertEq(f.vault.latestLossNonce(), 5, "setup: manual report advanced the vault-owned loss nonce");

        vm.prank(f.keeper);
        (bool ok,) = address(f.bridge).call(abi.encodeCall(HLTradingBridge.postNAV, (1, 950e6, 925e6, block.timestamp)));

        assertTrue(ok, "keeper loss report must derive the next nonce from vault state after manual loss");
        assertEq(f.vault.latestLossNonce(), 6, "keeper loss should continue from the vault-owned nonce");
    }

    function test_TL2_zeroNonceRecoveryClearsStaleBindingForFutureVaultLoss() public {
        // PHASE5_REPRO_BINDING: V-4
        BridgeFixture storage f = bridgeFixture;
        _deployFundedBridgeFixture();

        vm.prank(f.keeper);
        f.bridge.postNAV(7, 950e6, 900e6, block.timestamp);
        assertEq(f.vault.latestLossNonce(), 1, "setup: keeper recorded the first attested loss");
        assertEq(f.vault.lossPendingVaultId(), 7, "setup: first loss is bound to vault 7");

        vm.prank(f.reporter);
        f.vault.recordManualCustodianNAV(7, 950e6, 0);
        assertFalse(f.vault.lossPending(), "setup: visible loss pending state is cleared by zero-nonce recovery");

        vm.prank(f.keeper);
        (bool ok,) = address(f.bridge).call(abi.encodeCall(HLTradingBridge.postNAV, (8, 950e6, 900e6, block.timestamp)));

        assertTrue(ok, "zero-nonce recovery must clear stale attested-loss binding before a future vault loss");
        assertEq(f.vault.lossPendingVaultId(), 8, "future loss should bind to the newly reported vault");
    }

    function _deployQueueFixture() internal {
        QueueFixture storage f = queueFixture;
        f.owner = makeAddr("octane.queue.owner");
        f.alice = makeAddr("octane.queue.alice");
        f.bob = makeAddr("octane.queue.bob");
        f.carol = makeAddr("octane.queue.carol");
        f.keeper = makeAddr("octane.queue.keeper");

        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(f.owner, f.owner, f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();

        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), f.owner, f.owner);

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.registry = _deployVaultRegistry(f.owner);
        f.queue = _deployStakingQueue(address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner);
        f.vaultId = _registerVault(f.registry, f.owner, "Octane Queue Vault", "OQV", tierVaults, address(f.queue));

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));
    }

    function _deployGovernanceFixture() internal {
        GovernanceFixture storage f = governanceFixture;
        f.owner = makeAddr("octane.gov.owner");
        f.guardian = makeAddr("octane.gov.guardian");
        f.blockedSource = makeAddr("octane.gov.blockedSource");
        f.cleanSource = makeAddr("octane.gov.cleanSource");
        f.delegatee = makeAddr("octane.gov.delegatee");

        f.forage = _deployForageToken(f.owner, f.owner, f.owner);
        f.blocklist = _deployBlocklist(f.guardian, f.owner);
        vm.prank(f.owner);
        f.forage.setBlocklist(address(f.blocklist));
    }

    function _deployFundedBridgeFixture() internal {
        BridgeFixture storage f = bridgeFixture;
        f.owner = makeAddr("octane.bridge.owner");
        f.keeper = makeAddr("octane.bridge.keeper");
        f.executor = makeAddr("octane.bridge.executor");
        f.guardianModule = makeAddr("octane.bridge.guardianModule");
        f.reporter = makeAddr("octane.bridge.reporter");
        f.depositor = makeAddr("octane.bridge.depositor");

        f.usdc = new MockUSDC();
        f.riskusd = _deployRISKUSD(f.owner);
        f.vault = _deployRiskUSDVault(address(f.usdc), address(f.riskusd), f.owner);
        f.blocklist = _deployBlocklist(makeAddr("octane.bridge.guardian"), f.owner);
        f.bridge = _deployBridge(
            address(f.usdc),
            address(f.vault),
            makeAddr("octane.bridge.treasury"),
            makeAddr("octane.bridge.registry"),
            f.owner,
            f.keeper,
            f.executor,
            f.guardianModule,
            makeAddr("octane.bridge.coldAccount"),
            bytes32(uint256(0x1234))
        );

        vm.startPrank(f.owner);
        f.bridge.setBlocklist(address(f.blocklist));
        f.vault.setBlocklist(address(f.blocklist));
        f.riskusd.setBlocklist(address(f.blocklist));
        f.riskusd.setMinter(address(f.vault));
        f.vault.setDeploymentBufferBps(0);
        f.vault.setPerBlockMintCap(10_000, type(uint256).max);
        f.vault.setDailyMintCapBps(10_000);
        f.vault.setCustodian(address(f.bridge));
        f.vault.setManualAttestationReporter(f.reporter);
        vm.warp(block.timestamp + f.vault.FINALIZE_DELAY() + 1);
        f.riskusd.finalizeMinter();
        f.vault.finalizeCustodian();
        f.vault.finalizeManualAttestationReporter();
        vm.stopPrank();

        f.usdc.mint(f.depositor, 1_000e6);
        vm.startPrank(f.depositor);
        f.usdc.approve(address(f.vault), 1_000e6);
        f.vault.deposit(1_000e6);
        vm.stopPrank();

        vm.prank(address(f.bridge));
        f.vault.deployCapital(950e6);
        vm.prank(f.keeper);
        f.bridge.postNAV(1, 950e6, 950e6, block.timestamp);
    }

    function _enablePriorityAdmission() internal {
        QueueFixture storage f = queueFixture;
        vm.startPrank(f.owner);
        f.forage.setAuthorizedLocker(address(f.queue), true);
        f.forage.transfer(f.alice, 5_000e18);
        f.forage.transfer(f.carol, 5_000e18);
        f.queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + f.queue.FINALIZE_DELAY() + 1);
        f.queue.finalizeForagePriceUsd();
        f.queue.setPriorityMultiplier(10);
        vm.stopPrank();
    }

    function _joinStandard(address user, uint256 amount, uint256 minShares) internal returns (uint256 queueId) {
        QueueFixture storage f = queueFixture;
        _fundRiskusd(user, amount);
        queueId = f.queue.nextQueueId();
        vm.prank(user);
        f.queue.joinQueueWithBounds(amount, 0, minShares, block.timestamp + 7 days);
    }

    function _joinPriority(address user, uint256 amount, uint256 minShares) internal returns (uint256 queueId) {
        QueueFixture storage f = queueFixture;
        _fundRiskusd(user, amount);
        queueId = f.queue.nextQueueId();
        vm.prank(user);
        f.queue.joinQueueWithBounds(amount, 0, minShares, block.timestamp + 7 days);
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

    function _writeLegacyBlockedUntil(Blocklist blocklist, address account, uint256 until) internal {
        stdstore.target(address(blocklist)).sig(blocklist.blockedUntil.selector).with_key(account).checked_write(until);
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

    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _deployRiskUSDVault(address usdc, address riskusd, address owner) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, owner, owner));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployBridge(
        address usdc,
        address riskusdVault,
        address treasury,
        address registry,
        address owner,
        address keeper,
        address executor,
        address guardianModule,
        address coldAccount,
        bytes32 sourceAccount
    ) internal returns (HLTradingBridge) {
        HLTradingBridge implementation = new HLTradingBridge();
        bytes memory initData = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                usdc,
                riskusdVault,
                treasury,
                registry,
                owner,
                keeper,
                executor,
                guardianModule,
                HLTradingBridge.RouteConfig({
                    coldAccount: coldAccount, hyperliquidSourceAccount: sourceAccount, withdrawalChainSelector: 421_614
                })
            )
        );
        return HLTradingBridge(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _assertBindingPresent(string memory repros, string memory findingId) internal pure {
        assertTrue(
            _contains(repros, string.concat(BINDING_MARKER, findingId)),
            string.concat("missing concrete PHASE5_REPRO_BINDING for ", findingId)
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length;) {
            bool matched = true;
            for (uint256 j; j < n.length;) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (matched) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
