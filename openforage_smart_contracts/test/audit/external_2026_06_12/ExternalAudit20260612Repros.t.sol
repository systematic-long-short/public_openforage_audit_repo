// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../script/DeployMainnet.s.sol";
import "../../../src/Blocklist.sol";
import "../../../src/CustodianRegistry.sol";
import "../../../src/DelegatingVestingWallet.sol";
import "../../../src/FORAGETreasury.sol";
import "../../../src/ForageToken.sol";
import "../../../src/GuardianModule.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/StakingQueue.sol";
import "../../../src/USDCTreasury.sol";
import "../../../src/VaultRegistry.sol";
import "../../../src/atRISKUSD.sol";
import "../../../src/hyperliquid/HLTradingBridge.sol";
import "./fixtures/ExternalAuditLegacyUpgradeFixtures.sol";
// Mocks model external token, vault-registry, and yield-source boundaries.
// Every reported system under test above is imported from src/ and exercised directly.
import "../../mocks/MockForageTokenSimple.sol";
import "../../mocks/MockUSDC.sol";
import "../../mocks/MockVaultRegistry.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

contract PagedOnlyVaultRegistryBoundary {
    address public immutable riskusdVault;
    uint256[] private _vaultIds;
    mapping(uint256 => VaultConfig) private _vaults;

    error UnboundedEnumerationDisabled();

    constructor(address riskusdVault_) {
        riskusdVault = riskusdVault_;
    }

    function addTestVault(uint256 vaultId, VaultConfig memory config) external {
        _vaults[vaultId] = config;
        _vaultIds.push(vaultId);
    }

    function getVault(uint256 vaultId) external view returns (VaultConfig memory) {
        return _vaults[vaultId];
    }

    function getVaultsPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        total = _vaultIds.length;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total, total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length;) {
            ids[i] = _vaultIds[offset + i];
            unchecked {
                ++i;
            }
        }
        nextOffset = end;
    }

    function getAllVaults() external pure returns (uint256[] memory) {
        revert UnboundedEnumerationDisabled();
    }

    function notifyLossResolved() external {}
}

contract ExternalAudit20260612ReprosTest is Test {
    string internal constant CANTINA =
        "../documentation/smart_contract_audits/2026-06-12-external-audit/cantina/cantina_findings.md";
    string internal constant OCTANE =
        "../documentation/smart_contract_audits/2026-06-12-external-audit/octane/octane_findings.md";
    string internal constant REPRO_FILE = "test/audit/external_2026_06_12/ExternalAudit20260612Repros.t.sol";

    struct BridgeFixture {
        address owner;
        address governor;
        address guardianModule;
        address keeper;
        address executor;
        address vaultRegistry;
        address foundationPrimary;
        address foundationBackup;
        address protocolPrimary;
        address protocolBackup;
        address vaultDepositor;
        address coldAccount;
        bytes32 sourceAccount;
        MockUSDC usdc;
        RISKUSD riskusd;
        CustodianRegistry registry;
        RISKUSDVault vault;
        USDCTreasury treasury;
        Blocklist blocklist;
        HLTradingBridge bridge;
    }

    BridgeFixture internal bridgeFixture;

    struct StakingFixture {
        address owner;
        address teamVesting;
        address forageTreasury;
        address alice;
        address keeper;
        RISKUSD riskusd;
        ForageToken forage;
        MockYieldSourceForLossPending yieldSource;
        atRISKUSD vault0;
        atRISKUSD vault1;
        atRISKUSD vault2;
        atRISKUSD vault3;
        MockVaultRegistry registry;
        StakingQueue queue;
        uint256 vaultId;
    }

    struct LossRaceFixture {
        address owner;
        address depositor;
        address attacker;
        RISKUSD riskusd;
        ForageToken forage;
        MockYieldSourceForLossPending yieldSource;
        atRISKUSD vault0;
        atRISKUSD vault1;
        atRISKUSD vault2;
        atRISKUSD vault3;
        MockVaultRegistry registry;
        StakingQueue queue;
        uint256 vaultId;
    }

    StakingFixture internal stakingFixture;
    LossRaceFixture internal lossRaceFixture;

    function test_phase7DocumentsBindTruePositivesToConcreteRepros() public view {
        string memory cantina = vm.readFile(CANTINA);
        string memory octane = vm.readFile(OCTANE);
        string memory repros = vm.readFile(REPRO_FILE);
        string memory bindingMarker = string.concat("PHASE7_REPRO_", "BINDING: ");

        bool anyTruePositive = _contains(cantina, "Verdict: TP") || _contains(octane, "Verdict: TP");
        bool docsNameRepro = _contains(cantina, "Foundry repro:")
            || _contains(cantina, "Shared root-cause repro cluster:") || _contains(octane, "Foundry repro:")
            || _contains(octane, "Shared root-cause repro cluster:");

        assertTrue(
            !anyTruePositive || docsNameRepro,
            "phase 7 must bind confirmed true positives to a Foundry repro or shared root-cause cluster"
        );
        assertTrue(
            !anyTruePositive || (_contains(repros, bindingMarker) && _contains(repros, "function test")),
            "phase 7 must add concrete reproduction tests with in-function PHASE7_REPRO_BINDING markers"
        );
        _assertBindingPresent(repros, bindingMarker, "OPEN-69");
        _assertBindingPresent(repros, bindingMarker, "OPEN-73");
        _assertBindingPresent(repros, bindingMarker, "OPEN-74");
        _assertBindingPresent(repros, bindingMarker, "OPEN-75");
        _assertBindingPresent(repros, bindingMarker, "OPEN-79");
        _assertBindingPresent(repros, bindingMarker, "OPEN-80");
        _assertBindingPresent(repros, bindingMarker, "OPEN-81");
        _assertBindingPresent(repros, bindingMarker, "OPEN-82");
        _assertBindingPresent(repros, bindingMarker, "OPEN-83");
        _assertBindingPresent(repros, bindingMarker, "OPEN-84");
        _assertBindingPresent(repros, bindingMarker, "OPEN-89");
        _assertBindingPresent(repros, bindingMarker, "OPEN-90");
        _assertBindingPresent(repros, bindingMarker, "OPEN-91");
        _assertBindingPresent(repros, bindingMarker, "OPEN-94");
        _assertBindingPresent(repros, bindingMarker, "OPEN-98");
        _assertBindingPresent(repros, bindingMarker, "OPEN-101");
        _assertBindingPresent(repros, bindingMarker, "OPEN-102");
        _assertBindingPresent(repros, bindingMarker, "V-2");
        _assertBindingPresent(repros, bindingMarker, "R-V-2-1");
        _assertBindingPresent(repros, bindingMarker, "V-4");
        _assertBindingPresent(repros, bindingMarker, "V-12");
        _assertBindingPresent(repros, bindingMarker, "V-13");
        _assertBindingPresent(repros, bindingMarker, "V-15");
        _assertBindingPresent(repros, bindingMarker, "V-40");
        _assertBindingPresent(repros, bindingMarker, "V-48");
        _assertBindingPresent(repros, bindingMarker, "W-5");
    }

    function test_partnershipWalletInheritsBlocklistAndBlocksReleaseAfterBeneficiaryBlocked() public {
        // PHASE7_REPRO_BINDING: OPEN-73
        // PHASE7_REPRO_BINDING: OPEN-80
        // PHASE7_REPRO_BINDING: OPEN-84
        // PHASE7_REPRO_BINDING: OPEN-91
        // PHASE7_REPRO_BINDING: OPEN-94
        // PHASE7_REPRO_BINDING: V-15
        address owner = makeAddr("treasury-owner");
        address guardian = makeAddr("blocklist-guardian");
        address partner = makeAddr("partner");
        address delegatee = makeAddr("delegatee");

        MockForageTokenSimple forage = new MockForageTokenSimple();
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        FORAGETreasury treasury = _deployForageTreasury(address(forage), owner);
        forage.mint(address(treasury), 40e18);

        vm.prank(owner);
        treasury.setBlocklist(address(blocklist));

        uint64 start = uint64(block.timestamp);
        vm.prank(owner);
        address wallet = treasury.distributePartnership(partner, delegatee, 40e18, start, 1 days, 0);
        assertEq(
            DelegatingVestingWallet(wallet).blocklist(),
            address(blocklist),
            "treasury-created vesting wallet must inherit the treasury blocklist before finalization"
        );

        vm.prank(guardian);
        blocklist.blockAddress(partner);
        assertTrue(blocklist.isBlocked(partner), "beneficiary is blocked after wallet creation");

        vm.warp(block.timestamp + 2 days);
        uint256 beforeBalance = forage.balanceOf(partner);
        vm.prank(partner);
        (bool released,) = wallet.call(abi.encodeCall(DelegatingVestingWallet.release, ()));

        assertTrue(
            !released || forage.balanceOf(partner) == beforeBalance,
            "blocklisted beneficiary release must fail closed or leave the beneficiary balance unchanged"
        );
        assertEq(
            forage.balanceOf(partner),
            beforeBalance,
            "blocked beneficiary must not receive vested FORAGE through a treasury-created child wallet"
        );
    }

    function test_blockedHolderDelegatedVotesAreDiscountedAtLiveVoteSource() public {
        // PHASE7_REPRO_BINDING: OPEN-89
        // PHASE7_REPRO_BINDING: OPEN-98
        // PHASE7_REPRO_BINDING: V-2
        // PHASE7_REPRO_BINDING: R-V-2-1
        address owner = makeAddr("vote-owner");
        address guardian = makeAddr("vote-guardian");
        address holder = makeAddr("blocked-holder");
        address delegatee = makeAddr("prearranged-delegatee");
        address treasury = makeAddr("vote-treasury");

        ForageToken forage = _deployForageToken(makeAddr("vote-team"), treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));
        vm.prank(holder);
        forage.delegate(delegatee);
        assertEq(forage.getVotes(delegatee), 100e18, "delegatee receives holder votes before block");

        vm.prank(guardian);
        blocklist.blockAddress(holder);

        assertTrue(blocklist.isBlocked(holder), "holder is blocklisted");
        assertEq(
            forage.getVotes(delegatee),
            0,
            "pre-block delegated votes sourced from a blocked holder must not remain usable"
        );
    }

    function test_ownerCanBackfillPreUpgradeDelegateSourcesWithoutMovingBlocklistSlot() public {
        // PHASE7_REPRO_BINDING: OPEN-89
        // PHASE7_REPRO_BINDING: OPEN-98
        // PHASE7_REPRO_BINDING: V-2
        // PHASE7_REPRO_BINDING: R-V-2-1
        address owner = makeAddr("backfill-owner");
        address guardian = makeAddr("backfill-guardian");
        address holder = makeAddr("backfill-holder");
        address unblockedHolder = makeAddr("backfill-unblocked-holder");
        address delegatee = makeAddr("backfill-delegatee");
        address treasury = makeAddr("backfill-treasury");

        ForageToken forage =
            _deployLegacyForageTokenWithoutDelegateSourceTracking(makeAddr("backfill-team"), treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.prank(owner);
        forage.setBlocklist(address(blocklist));
        assertEq(forage.blocklist(), address(blocklist), "old implementation must expose the preserved blocklist");

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(treasury);
        forage.transfer(unblockedHolder, 25e18);
        vm.prank(holder);
        forage.delegate(delegatee);
        vm.prank(unblockedHolder);
        forage.delegate(delegatee);
        assertEq(forage.getVotes(delegatee), 125e18, "delegate checkpoint exists before upgrade");

        _upgradeLegacyForageTokenToCurrent(forage, owner);

        vm.prank(guardian);
        blocklist.blockAddress(holder);
        assertEq(
            forage.getVotes(delegatee), 0, "old proxy state must fail closed while delegate-source trackers are empty"
        );
        uint256 preBackfillSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        address[] memory sources = new address[](1);
        sources[0] = unblockedHolder;
        vm.prank(owner);
        forage.syncDelegateSources(sources);

        uint256 postBackfillSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        assertEq(
            forage.getVotes(delegatee), 25e18, "owner backfill must restore only tracked unblocked delegated votes"
        );
        assertEq(
            forage.getPastVotes(delegatee, preBackfillSnapshot),
            0,
            "pre-backfill snapshots must fail closed when delegate-source tracking was absent"
        );
        assertEq(
            forage.getPastVotes(delegatee, postBackfillSnapshot),
            25e18,
            "post-upgrade snapshots after backfill must restore only tracked unblocked source votes"
        );
        assertEq(forage.blocklist(), address(blocklist), "backfill must not corrupt the preserved blocklist");
    }

    function test_pastVotesKeepPreBlockHistoricalSourcesWhileLiveVotesDiscountBlockedHolders() public {
        // PHASE7_REPRO_BINDING: OPEN-89
        // PHASE7_REPRO_BINDING: OPEN-98
        // PHASE7_REPRO_BINDING: V-2
        // PHASE7_REPRO_BINDING: R-V-2-1
        address owner = makeAddr("snapshot-vote-owner");
        address guardian = makeAddr("snapshot-vote-guardian");
        address treasury = makeAddr("snapshot-vote-treasury");
        address holder = makeAddr("snapshot-holder");
        address recipient = makeAddr("snapshot-recipient");
        address lateSource = makeAddr("late-delegate-source");
        address blockedHolder = makeAddr("snapshot-blocked-holder");
        address delegatee = makeAddr("snapshot-delegatee");
        address newDelegate = makeAddr("snapshot-new-delegate");

        ForageToken forage = _deployForageToken(makeAddr("snapshot-team"), treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));
        vm.prank(holder);
        forage.delegate(delegatee);

        uint256 originalSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        assertEq(forage.getPastVotes(delegatee, originalSnapshot), 100e18, "initial snapshot is checkpointed");

        vm.prank(holder);
        forage.transfer(recipient, 40e18);
        vm.prank(holder);
        forage.delegate(newDelegate);

        vm.prank(treasury);
        forage.transfer(lateSource, 25e18);
        vm.prank(lateSource);
        forage.delegate(delegatee);

        vm.prank(treasury);
        forage.transfer(blockedHolder, 40e18);
        vm.prank(blockedHolder);
        forage.delegate(delegatee);

        uint256 blockedHolderSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        vm.prank(guardian);
        blocklist.blockAddress(blockedHolder);

        assertTrue(blocklist.isBlocked(blockedHolder), "holder is blocklisted after delegation");
        assertEq(forage.getVotes(delegatee), 25e18, "blocked holder is removed from live delegated votes");
        assertEq(
            forage.getPastVotes(delegatee, originalSnapshot),
            100e18,
            "later transfers, redelegation, and current balances must not rewrite the original snapshot"
        );
        assertEq(
            forage.getPastVotes(delegatee, blockedHolderSnapshot),
            65e18,
            "pre-block snapshot keeps sources that were unblocked at that timepoint"
        );
    }

    function test_revokedRegistryExecutorCannotControlBridgeValueMovingPath() public {
        // PHASE7_REPRO_BINDING: OPEN-74
        // PHASE7_REPRO_BINDING: OPEN-101
        // PHASE7_REPRO_BINDING: OPEN-102
        _deployBridgeFixture();
        _finalizeBridgeFixture();

        CustodianRegistry registry = bridgeFixture.registry;
        address executor = bridgeFixture.executor;
        address vaultDepositor = bridgeFixture.vaultDepositor;
        address coldAccount = bridgeFixture.coldAccount;

        assertFalse(
            registry.hasCustodianRole(registry.HYPERLIQUID_CUSTODIAN_ID(), registry.ROLE_EXECUTOR(), executor),
            "registry executor role is revoked"
        );

        bridgeFixture.usdc.mint(vaultDepositor, 2_000_000e6);
        vm.startPrank(vaultDepositor);
        bridgeFixture.usdc.approve(address(bridgeFixture.vault), 2_000_000e6);
        bridgeFixture.vault.deposit(2_000_000e6);
        vm.stopPrank();

        uint256 coldBefore = bridgeFixture.usdc.balanceOf(coldAccount);
        vm.prank(executor);
        (bool deployed,) =
            address(bridgeFixture.bridge).call(abi.encodeCall(HLTradingBridge.deployToHyperLiquid, (1_000e6)));

        assertFalse(deployed, "bridge value-moving paths must re-check the live registry executor role");
        assertEq(
            bridgeFixture.usdc.balanceOf(coldAccount),
            coldBefore,
            "revoked registry executor must not move USDC through the cached bridge executor"
        );
    }

    function test_retryForageUnlockCannotSpendLaterPriorityEntryLock() public {
        // PHASE7_REPRO_BINDING: OPEN-81
        _deployStakingFixture();
        StakingFixture storage f = stakingFixture;

        uint256 staleQueueId = _joinPriority(f, f.alice, 1_000e6);
        assertEq(f.forage.lockerBalance(f.alice, address(f.queue)), 100e18, "first priority entry locks FORAGE");

        vm.prank(f.owner);
        f.forage.setAuthorizedLocker(address(f.queue), false);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertTrue(f.queue.getQueueEntry(staleQueueId).processed, "stale entry is processed");
        assertEq(f.queue.forageLockedPerEntry(staleQueueId), 100e18, "stale per-entry amount remains retryable");
        assertEq(f.forage.lockerBalance(f.alice, address(f.queue)), 100e18, "stale lock remains on token");

        vm.prank(f.owner);
        f.forage.emergencyUnlock(f.alice, address(f.queue));
        assertEq(f.forage.lockerBalance(f.alice, address(f.queue)), 0, "owner clears the stale token-side lock");

        vm.prank(f.owner);
        f.forage.setAuthorizedLocker(address(f.queue), true);
        uint256 freshQueueId = _joinPriority(f, f.alice, 1_000e6);
        StakingQueue.QueueEntry memory freshEntry = f.queue.getQueueEntry(freshQueueId);
        assertTrue(freshEntry.priority, "fresh entry is still in the priority lane");
        assertEq(f.queue.forageLockedPerEntry(freshQueueId), 100e18, "fresh entry has its own per-entry lock record");
        assertEq(f.forage.lockerBalance(f.alice, address(f.queue)), 100e18, "fresh entry owns the live token lock");

        (bool retrySucceeded,) = address(f.queue).call(abi.encodeCall(StakingQueue.retryForageUnlock, (staleQueueId)));

        assertTrue(
            !retrySucceeded || f.forage.lockerBalance(f.alice, address(f.queue)) == 100e18,
            "retrying a stale entry must fail closed or preserve the later entry's live token lock"
        );
        assertEq(f.forage.lockerBalance(f.alice, address(f.queue)), 100e18, "fresh token lock must remain live");
        assertEq(f.queue.forageLockedPerEntry(freshQueueId), 100e18, "fresh priority entry still records a lock");
        assertTrue(f.queue.getQueueEntry(freshQueueId).priority, "fresh entry remains priority with matching backing");
    }

    function test_permissionlessQueueProcessingCannotForceSettleWithoutDepositorBounds() public {
        // PHASE7_REPRO_BINDING: V-12
        _deployLossRaceFixture();
        LossRaceFixture storage f = lossRaceFixture;

        f.riskusd.mint(f.depositor, 1_000e6);
        vm.startPrank(f.depositor);
        f.riskusd.approve(address(f.queue), 1_000e6);
        uint256 queueId = f.queue.nextQueueId();
        f.queue.joinQueue(1_000e6, 0);
        vm.stopPrank();
        _upgradeLegacyStakingQueueToCurrent(f.queue, f.owner);
        StakingQueue.QueueEntry memory unboundedEntry = f.queue.getQueueEntry(queueId);
        assertEq(unboundedEntry.minimumShares, 0, "test setup must model preserved unbounded storage");
        assertEq(unboundedEntry.deadline, 0, "test setup must model preserved unbounded storage");

        vm.prank(f.attacker);
        (bool processed,) = address(f.queue).call(abi.encodeCall(StakingQueue.processQueue, (uint8(0), uint256(1))));

        StakingQueue.QueueEntry memory entry = f.queue.getQueueEntry(queueId);
        assertTrue(
            !processed || (!entry.processed && f.vault0.balanceOf(f.depositor) == 0),
            "permissionless queue processing must not settle entries that lack depositor min-share/deadline bounds"
        );
        assertFalse(entry.processed, "unbounded queue entry must remain unsettled until depositor constraints are met");
        assertEq(f.vault0.balanceOf(f.depositor), 0, "depositor must not receive forced atRISKUSD shares");

        vm.prank(f.attacker);
        vm.expectRevert(StakingQueue.NotQueueEntryDepositor.selector);
        f.queue.setQueueEntryBounds(queueId, 1, block.timestamp + 1 days);

        vm.prank(f.depositor);
        f.queue.setQueueEntryBounds(queueId, 1, block.timestamp + 1 days);

        vm.prank(f.attacker);
        f.queue.processQueue(0, 1);

        entry = f.queue.getQueueEntry(queueId);
        assertTrue(entry.processed, "depositor-supplied bounds must make the legacy entry processable");
        assertGt(f.vault0.balanceOf(f.depositor), 0, "normal queue processing must settle after depositor bounds");
    }

    function test_priorityQueueProcessingSkipsExpiredDepositorDeadline() public {
        // PHASE7_REPRO_BINDING: V-12
        _deployStakingFixture();
        StakingFixture storage f = stakingFixture;

        f.riskusd.mint(f.alice, 2_000e6);
        vm.startPrank(f.alice);
        f.riskusd.approve(address(f.queue), 2_000e6);
        uint256 expiredQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 1);
        uint256 validQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 1 days);
        vm.stopPrank();
        assertTrue(f.queue.getQueueEntry(expiredQueueId).priority, "expired setup should enter the priority lane");
        assertTrue(f.queue.getQueueEntry(validQueueId).priority, "valid setup should enter the priority lane");

        vm.warp(block.timestamp + 2);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        StakingQueue.QueueEntry memory expiredEntry = f.queue.getQueueEntry(expiredQueueId);
        assertFalse(expiredEntry.processed, "expired priority queue deadline must prevent settlement");
        assertTrue(
            f.queue.getQueueEntry(validQueueId).processed, "valid priority entry must process after expired prefix"
        );
        assertGt(f.vault0.balanceOf(f.alice), 0, "valid priority entry must mint shares");
    }

    function test_standardQueueExpiredDeadlinePrefixDoesNotPinLaterBoundedEntry() public {
        // PHASE7_REPRO_BINDING: V-12
        _deployStakingFixture();
        StakingFixture storage f = stakingFixture;

        vm.prank(f.owner);
        f.queue.setPriorityMultiplier(0);

        f.riskusd.mint(f.alice, 2_000e6);
        vm.startPrank(f.alice);
        f.riskusd.approve(address(f.queue), 2_000e6);
        uint256 expiredQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 1);
        uint256 validQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 1 days);
        vm.stopPrank();
        assertFalse(f.queue.getQueueEntry(expiredQueueId).priority, "expired setup should enter the standard lane");
        assertFalse(f.queue.getQueueEntry(validQueueId).priority, "valid setup should enter the standard lane");

        vm.warp(block.timestamp + 2);
        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        StakingQueue.QueueEntry memory expiredEntry = f.queue.getQueueEntry(expiredQueueId);
        assertFalse(expiredEntry.processed, "expired standard queue deadline must prevent settlement");
        assertTrue(
            f.queue.getQueueEntry(validQueueId).processed, "valid standard entry must process after expired prefix"
        );
        assertGt(f.vault0.balanceOf(f.alice), 0, "valid standard entry must mint shares");
    }

    function test_deploymentSetupWiresGuardianModuleBeforePauseFastPathUse() public {
        // PHASE7_REPRO_BINDING: OPEN-82
        vm.chainId(42161);

        address guardian = makeAddr("open82-guardian-0");
        DeployMainnet deployer = new DeployMainnet();
        _setOpen82DeployEnv(guardian);
        deployer.runWithConfig(
            address(new MockUSDC()),
            makeAddr("open82-beneficiary"),
            makeAddr("open82-foundation-primary"),
            makeAddr("open82-foundation-backup"),
            makeAddr("open82-protocol-primary"),
            makeAddr("open82-protocol-backup"),
            makeAddr("open82-launch-delegate")
        );

        _assertOpen82GuardianGraph(deployer);
        _assertOpen82RiskusdPause(deployer, guardian);
        _assertOpen82RiskusdVaultPause(deployer, guardian);
        _assertOpen82StakingQueuePause(deployer, guardian);
        _assertOpen82AtRiskPause(deployer, guardian);
    }

    function test_manualCustodianNAVNormalizerFailsClosedUntilFreshBridgeBaselineThenCaps() public {
        // PHASE7_REPRO_BINDING: V-13
        address reporter = makeAddr("manual-nav-reporter");

        _deployBridgeFixture();
        _finalizeBridgeFixture();
        BridgeFixture storage f = bridgeFixture;

        vm.startPrank(f.owner);
        f.vault.setManualAttestationReporter(reporter);
        vm.warp(block.timestamp + f.vault.FINALIZE_DELAY() + 1);
        f.vault.finalizeManualAttestationReporter();
        vm.stopPrank();

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(RISKUSDVault.ManualAttestationNormalizationFailed.selector, address(f.bridge))
        );
        f.vault.recordManualCustodianNAV(1, 1_000e6, 0);

        vm.expectRevert(abi.encodeWithSelector(HLTradingBridge.UnauthorizedVault.selector, address(this)));
        f.bridge.normalizeManualCustodianNAV(1, 1_000e6, 0);

        vm.prank(f.keeper);
        f.bridge.postNAV(1, 1_000e6, 1_000e6, block.timestamp);

        vm.prank(reporter);
        f.vault.recordManualCustodianNAV(1, 1_250e6, 0);
        assertEq(f.vault.lastAttestedNAV(), 1_100e6, "manual NAV must reuse the bridge 10% upward cap");

        vm.prank(f.guardianModule);
        f.bridge.setDirectionalFreeze(true);
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(RISKUSDVault.ManualAttestationNormalizationFailed.selector, address(f.bridge))
        );
        f.vault.recordManualCustodianNAV(1, 1_001e6, 0);

        vm.prank(f.owner);
        f.bridge.setDirectionalFreeze(false);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(RISKUSDVault.ManualAttestationNormalizationFailed.selector, address(f.bridge))
        );
        f.vault.recordManualCustodianNAV(1, 900e6, 0);
    }

    function test_lossReporterWiringExposesSettlementSelectors() public {
        // PHASE7_REPRO_BINDING: OPEN-75
        // PHASE7_REPRO_BINDING: OPEN-79
        // PHASE7_REPRO_BINDING: V-4
        address owner = makeAddr("loss-wiring-owner");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        USDCTreasury treasury = _deployUSDCTreasury(
            address(usdc),
            makeAddr("loss-riskusd-vault-address"),
            makeAddr("loss-vault-registry-address"),
            owner,
            makeAddr("foundation-primary-loss"),
            makeAddr("foundation-backup-loss"),
            makeAddr("protocol-primary-loss"),
            makeAddr("protocol-backup-loss")
        );
        RISKUSDVault vault = _deployRiskUSDVaultWithLossReporter(
            address(usdc), address(riskusd), owner, makeAddr("custodian"), address(treasury)
        );

        assertEq(vault.lossReporter(), address(treasury), "vault loss reporter is USDCTreasury");
        assertTrue(
            _callRouted(address(treasury), abi.encodeWithSignature("burnForLoss(uint256,uint256)", uint256(1), 1e6)),
            "configured loss reporter must expose or route burnForLoss(uint256,uint256)"
        );
        assertTrue(
            _callRouted(
                address(treasury),
                abi.encodeWithSignature("coverAndBurnForLoss(uint256,uint256,uint256)", uint256(1), 1e6, 1e6)
            ),
            "configured loss reporter must expose or route coverAndBurnForLoss(uint256,uint256,uint256)"
        );
        assertTrue(
            _callRouted(address(treasury), abi.encodeWithSignature("replenish(uint256)", uint256(1e6))),
            "configured loss reporter must expose or route replenish(uint256)"
        );
    }

    function test_bridgeGuardianAuthorityFollowsLiveRegistrySourceOfTruth() public {
        // PHASE7_REPRO_BINDING: OPEN-90
        // PHASE7_REPRO_BINDING: V-48
        address owner = makeAddr("static-guardian-owner");
        address governor = makeAddr("static-guardian-governor");
        address oldGuardianModule = makeAddr("old-guardian-module");
        address newGuardianModule = makeAddr("new-guardian-module");
        MockUSDC usdc = new MockUSDC();
        CustodianRegistry registry = _deployCustodianRegistry(owner, governor, oldGuardianModule);
        HLTradingBridge bridge = _deployBridge(
            address(usdc),
            makeAddr("riskusd-vault-static-guardian"),
            makeAddr("usdc-treasury-static-guardian"),
            address(registry),
            owner,
            makeAddr("keeper-static-guardian"),
            makeAddr("executor-static-guardian"),
            oldGuardianModule,
            makeAddr("cold-static-guardian"),
            bytes32(uint256(uint160(address(0x1234))))
        );

        vm.prank(owner);
        registry.proposeGuardianModule(newGuardianModule);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        registry.finalizeGuardianModule();
        assertEq(registry.guardianModule(), newGuardianModule, "registry guardian source of truth rotated");

        vm.prank(oldGuardianModule);
        (bool oldGuardianCanFreeze,) =
            address(bridge).call(abi.encodeCall(HLTradingBridge.setDirectionalFreeze, (true)));
        assertFalse(oldGuardianCanFreeze, "old cached guardian module must not control bridge freeze after rotation");
        assertFalse(bridge.directionalFreeze(), "old cached guardian module must not mutate bridge freeze state");

        vm.prank(newGuardianModule);
        (bool newGuardianCanFreeze,) =
            address(bridge).call(abi.encodeCall(HLTradingBridge.setDirectionalFreeze, (true)));
        assertTrue(newGuardianCanFreeze, "bridge guardian authority must follow the live registry source of truth");
        assertTrue(bridge.directionalFreeze(), "live guardian module must be able to freeze the bridge");
    }

    function test_acceleratedRotationRechecksLivePrecommitAtExecution() public {
        // PHASE7_REPRO_BINDING: OPEN-69
        // PHASE7_REPRO_BINDING: OPEN-83
        address governor = makeAddr("rotation-governor");
        address timelock = makeAddr("rotation-timelock");
        address currentGuardian = makeAddr("rotation-current-guardian");
        address guardianTwo = makeAddr("rotation-guardian-two");
        address guardianThree = makeAddr("rotation-guardian-three");
        address guardianFour = makeAddr("rotation-guardian-four");
        address revokedSuccessor = makeAddr("rotation-revoked-successor");
        address replacementSuccessor = makeAddr("rotation-replacement-successor");

        address[] memory guardians = new address[](4);
        guardians[0] = currentGuardian;
        guardians[1] = guardianTwo;
        guardians[2] = guardianThree;
        guardians[3] = guardianFour;
        uint256[] memory permissions = new uint256[](4);
        permissions[0] = 1;
        permissions[1] = 1;
        permissions[2] = 1;
        permissions[3] = 1;

        GuardianModule module = _deployGuardianModule(governor, timelock, guardians, permissions);
        bytes32 slot = module.SLOT_GUARDIAN_SEAT();

        vm.prank(timelock);
        module.setPreCommittedSuccessor(slot, currentGuardian, revokedSuccessor);
        vm.prank(currentGuardian);
        bytes32 operationId = module.proposeAcceleratedRotation(slot, currentGuardian, revokedSuccessor);

        vm.prank(currentGuardian);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianTwo);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianThree);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianFour);
        module.approveAcceleratedRotation(operationId);

        vm.prank(timelock);
        module.setPreCommittedSuccessor(slot, currentGuardian, replacementSuccessor);
        assertEq(
            module.preCommittedSuccessor(slot, currentGuardian),
            replacementSuccessor,
            "timelock retargeted the live precommit"
        );

        vm.warp(block.timestamp + module.ACCELERATED_ROTATION_FLOOR() + 1);
        (bool executed,) =
            address(module).call(abi.encodeCall(GuardianModule.executeAcceleratedRotation, (operationId)));

        assertFalse(executed, "accelerated rotation execution must re-check the live precommit/generation");
        assertEq(module.activeSlotHolder(slot), currentGuardian, "stale successor must not be installed");
        assertEq(module.guardianPermissions(currentGuardian), 1, "current guardian must retain permissions");
        assertEq(module.guardianPermissions(revokedSuccessor), 0, "revoked successor must not inherit permissions");
        assertEq(
            module.preCommittedSuccessor(slot, currentGuardian), replacementSuccessor, "live precommit remains active"
        );
    }

    function test_deterministicAcceleratedRotationIdCannotBeReusedAfterExecution() public {
        // PHASE7_REPRO_BINDING: V-40
        address governor = makeAddr("reuse-governor");
        address timelock = makeAddr("reuse-timelock");
        address currentGuardian = makeAddr("reuse-current-guardian");
        address guardianTwo = makeAddr("reuse-guardian-two");
        address guardianThree = makeAddr("reuse-guardian-three");
        address guardianFour = makeAddr("reuse-guardian-four");
        address successor = makeAddr("reuse-successor");

        address[] memory guardians = new address[](4);
        guardians[0] = currentGuardian;
        guardians[1] = guardianTwo;
        guardians[2] = guardianThree;
        guardians[3] = guardianFour;
        uint256[] memory permissions = new uint256[](4);
        permissions[0] = 1;
        permissions[1] = 1;
        permissions[2] = 1;
        permissions[3] = 1;

        GuardianModule module = _deployGuardianModule(governor, timelock, guardians, permissions);
        bytes32 slot = module.SLOT_GUARDIAN_SEAT();

        vm.prank(timelock);
        module.setPreCommittedSuccessor(slot, currentGuardian, successor);
        vm.prank(currentGuardian);
        bytes32 operationId = module.proposeAcceleratedRotation(slot, currentGuardian, successor);
        assertEq(
            operationId,
            keccak256(abi.encode("accelerated", slot, currentGuardian, successor)),
            "accelerated rotation id is tuple-derived without a nonce"
        );

        vm.prank(currentGuardian);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianTwo);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianThree);
        module.approveAcceleratedRotation(operationId);
        vm.prank(guardianFour);
        module.approveAcceleratedRotation(operationId);

        vm.warp(block.timestamp + module.ACCELERATED_ROTATION_FLOOR() + 1);
        module.executeAcceleratedRotation(operationId);
        assertEq(module.activeSlotHolder(slot), successor, "first execution completes");

        vm.prank(successor);
        bytes32 reusedOperationId = module.proposeAcceleratedRotation(slot, currentGuardian, successor);
        assertNotEq(
            reusedOperationId, operationId, "same tuple rotation must use a fresh nonce/generation after execution"
        );
    }

    function test_vaultRegistryEnumerationRequiresBoundedPagesForConsumers() public {
        // PHASE7_REPRO_BINDING: W-5
        address owner = makeAddr("w5-owner");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        RISKUSDVault vault = _deployRiskUSDVault(address(usdc), address(riskusd), owner);
        PagedOnlyVaultRegistryBoundary registry = new PagedOnlyVaultRegistryBoundary(address(vault));

        (bool pageSelectorAvailable, bytes memory pageData) = address(registry)
            .staticcall(abi.encodeWithSignature("getVaultsPage(uint256,uint256)", uint256(0), uint256(1)));
        assertTrue(pageSelectorAvailable && pageData.length >= 96, "vault registry boundary exposes bounded pages");

        vm.prank(owner);
        (bool initialized,) = address(vault).call(abi.encodeCall(RISKUSDVault.initializeV2, (address(registry))));
        assertTrue(
            initialized,
            "RISKUSDVault must accept a paged-only VaultRegistry and must not require unbounded getAllVaults()"
        );

        assertEq(vault.vaultRegistry(), address(registry), "consumer must use the paged registry source");

        VaultRegistry realImplementation = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        VaultRegistry realRegistry = VaultRegistry(address(new ERC1967Proxy(address(realImplementation), initData)));
        (bool realPageSelector,) = address(realRegistry)
            .staticcall(abi.encodeWithSignature("getVaultsPage(uint256,uint256)", uint256(0), uint256(1)));
        assertTrue(realPageSelector, "real VaultRegistry must expose bounded page enumeration");
    }

    function _deployBridgeFixture() internal {
        BridgeFixture storage f = bridgeFixture;
        f.owner = makeAddr("timelock");
        f.governor = makeAddr("governor");
        f.guardianModule = makeAddr("guardian-module");
        f.keeper = makeAddr("keeper");
        f.executor = makeAddr("executor");
        f.vaultRegistry = makeAddr("vault-registry");
        f.foundationPrimary = makeAddr("foundation-primary");
        f.foundationBackup = makeAddr("foundation-backup");
        f.protocolPrimary = makeAddr("protocol-primary");
        f.protocolBackup = makeAddr("protocol-backup");
        f.vaultDepositor = makeAddr("vault-depositor");
        f.coldAccount = makeAddr("hyperliquid-cold-account");
        f.sourceAccount = bytes32(uint256(uint160(address(0xBEEF))));

        f.usdc = new MockUSDC();
        f.riskusd = _deployRISKUSD(f.owner);
        f.registry = _deployCustodianRegistry(f.owner, f.governor, f.guardianModule);
        f.vault = _deployRiskUSDVault(address(f.usdc), address(f.riskusd), f.owner);
        f.treasury = _deployUSDCTreasury(
            address(f.usdc),
            address(f.vault),
            f.vaultRegistry,
            f.owner,
            f.foundationPrimary,
            f.foundationBackup,
            f.protocolPrimary,
            f.protocolBackup
        );
        f.blocklist = _deployBlocklist(makeAddr("blocklist-guardian"), f.owner);
        f.bridge = _deployBridge(
            address(f.usdc),
            address(f.vault),
            address(f.treasury),
            address(f.registry),
            f.owner,
            f.keeper,
            f.executor,
            f.guardianModule,
            f.coldAccount,
            f.sourceAccount
        );
    }

    function _deployStakingFixture() internal {
        StakingFixture storage f = stakingFixture;
        f.owner = makeAddr("staking-owner");
        f.teamVesting = makeAddr("team-vesting");
        f.forageTreasury = makeAddr("forage-treasury");
        f.alice = makeAddr("staking-alice");
        f.keeper = makeAddr("staking-keeper");

        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(f.teamVesting, f.forageTreasury, f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();
        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.registry = new MockVaultRegistry();

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.vaultId = _registerMockVault(f.registry, tierVaults, address(0));
        f.queue = _deployStakingQueue(address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner);

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        vm.prank(f.owner);
        f.forage.setAuthorizedLocker(address(f.queue), true);
        vm.prank(f.owner);
        f.queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + f.queue.FINALIZE_DELAY() + 1);
        vm.prank(f.owner);
        f.queue.finalizeForagePriceUsd();
        vm.prank(f.owner);
        f.queue.setPriorityMultiplier(10);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));

        vm.prank(f.forageTreasury);
        f.forage.transfer(f.alice, 1_000e18);
    }

    function _deployLossRaceFixture() internal {
        LossRaceFixture storage f = lossRaceFixture;
        f.owner = makeAddr("loss-owner");
        f.depositor = makeAddr("loss-depositor");
        f.attacker = makeAddr("loss-attacker");

        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(makeAddr("loss-team"), makeAddr("loss-treasury"), f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();
        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.registry = new MockVaultRegistry();

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.vaultId = _registerMockVault(f.registry, tierVaults, address(0));
        f.queue = _deployLegacyStakingQueueWithoutEntryBounds(
            address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner
        );

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));
    }

    function _joinPriority(StakingFixture storage f, address depositor, uint256 amount)
        internal
        returns (uint256 queueId)
    {
        f.riskusd.mint(depositor, amount);
        queueId = f.queue.nextQueueId();
        vm.startPrank(depositor);
        f.riskusd.approve(address(f.queue), amount);
        f.queue.joinQueue(amount, 0);
        vm.stopPrank();
        assertTrue(f.queue.getQueueEntry(queueId).priority, "test setup must enter priority lane");
    }

    function _deployForageToken(address teamVesting, address forageTreasury, address owner)
        internal
        returns (ForageToken)
    {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployLegacyForageTokenWithoutDelegateSourceTracking(
        address teamVesting,
        address forageTreasury,
        address owner
    ) internal returns (ForageToken) {
        LegacyForageTokenWithoutDelegateSourceTracking implementation =
            new LegacyForageTokenWithoutDelegateSourceTracking();
        bytes memory initData = abi.encodeCall(
            LegacyForageTokenWithoutDelegateSourceTracking.initialize, (teamVesting, forageTreasury, owner)
        );
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _upgradeLegacyForageTokenToCurrent(ForageToken forage, address owner) internal {
        ForageToken implementation = new ForageToken();
        vm.prank(owner);
        forage.upgradeToAndCall(address(implementation), "");
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

    function _deployLegacyStakingQueueWithoutEntryBounds(
        address riskusd,
        address forage,
        address[4] memory tierVaults,
        address vaultRegistry,
        address owner
    ) internal returns (StakingQueue) {
        LegacyStakingQueueWithoutEntryBounds implementation = new LegacyStakingQueueWithoutEntryBounds();
        bytes memory initData = abi.encodeCall(
            LegacyStakingQueueWithoutEntryBounds.initialize, (riskusd, forage, tierVaults, vaultRegistry, owner)
        );
        return StakingQueue(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _upgradeLegacyStakingQueueToCurrent(StakingQueue queue, address owner) internal {
        StakingQueue implementation = new StakingQueue();
        vm.prank(owner);
        queue.upgradeToAndCall(address(implementation), "");
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

    function _registerMockVault(MockVaultRegistry registry, address[4] memory tierVaults, address stakingQueue)
        internal
        returns (uint256)
    {
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(360 days)];
        uint16[4] memory yieldBps = [uint16(5_000), uint16(5_500), uint16(6_000), uint16(6_500)];
        uint16[4] memory fundingBps = [uint16(2_000), uint16(2_000), uint16(1_500), uint16(1_500)];
        return registry.addTestVault(
            "Audit Vault", "AUD", tierVaults, stakingQueue, 10_000_000e6, lockups, yieldBps, fundingBps
        );
    }

    function _finalizeBridgeFixture() internal {
        BridgeFixture storage f = bridgeFixture;
        CustodianRegistry.CustodianConfig memory hlConfig =
            f.registry.hyperLiquidLaunchConfig(address(f.bridge), f.executor, 421_614, f.sourceAccount, 10_000_000e6);

        vm.startPrank(f.owner);
        f.registry.proposeCustodianConfig(hlConfig);
        f.treasury.setHLTradingBridge(address(f.bridge));
        f.treasury.setBlocklist(address(f.blocklist));
        f.bridge.setBlocklist(address(f.blocklist));
        f.riskusd.setBlocklist(address(f.blocklist));
        f.riskusd.setMinter(address(f.vault));
        f.vault.setBlocklist(address(f.blocklist));
        f.vault.setCustodian(address(f.bridge));
        f.vault.setDeploymentBufferBps(0);
        f.vault.setPerBlockMintCap(10_000, type(uint256).max);
        f.vault.setDailyMintCapBps(10_000);
        f.vault.setWeeklyMintCapBps(20_000);
        vm.warp(block.timestamp + f.registry.FINALIZE_DELAY() + 1);
        f.registry.finalizeCustodianConfig(hlConfig.id);
        f.riskusd.finalizeMinter();
        f.vault.finalizeCustodian();
        f.registry
            .setCustodianRole(f.registry.HYPERLIQUID_CUSTODIAN_ID(), f.registry.ROLE_EXECUTOR(), f.executor, false);
        vm.stopPrank();
    }

    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployForageTreasury(address forage, address owner) internal returns (FORAGETreasury) {
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (forage, owner));
        return FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _deployCustodianRegistry(address owner, address governor, address guardianModule)
        internal
        returns (CustodianRegistry)
    {
        CustodianRegistry implementation = new CustodianRegistry();
        bytes memory initData = abi.encodeCall(CustodianRegistry.initialize, (owner, governor, guardianModule));
        return CustodianRegistry(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployGuardianModule(
        address governor,
        address timelock,
        address[] memory guardians,
        uint256[] memory permissions
    ) internal returns (GuardianModule) {
        GuardianModule implementation = new GuardianModule();
        bytes memory initData = abi.encodeCall(GuardianModule.initialize, (governor, timelock, guardians, permissions));
        return GuardianModule(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRiskUSDVault(address usdc, address riskusd, address owner) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, owner, owner));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRiskUSDVaultWithLossReporter(
        address usdc,
        address riskusd,
        address owner,
        address custodian,
        address lossReporter
    ) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData =
            abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, custodian, lossReporter));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployUSDCTreasury(
        address usdc,
        address riskusdVault,
        address vaultRegistry,
        address owner,
        address foundationPrimary,
        address foundationBackup,
        address protocolPrimary,
        address protocolBackup
    ) internal returns (USDCTreasury) {
        USDCTreasury implementation = new USDCTreasury();
        bytes memory initData = abi.encodeCall(
            USDCTreasury.initialize,
            (
                usdc,
                riskusdVault,
                vaultRegistry,
                owner,
                foundationPrimary,
                foundationBackup,
                protocolPrimary,
                protocolBackup
            )
        );
        return USDCTreasury(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _wireTierVaultToQueue(atRISKUSD vault, address owner, address queue) internal {
        vm.prank(owner);
        vault.setStakingQueue(queue);
        vm.warp(block.timestamp + vault.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        vault.finalizeStakingQueue();
    }

    function _assertOpen82GuardianGraph(DeployMainnet deployer) internal view {
        GuardianModule guardianModule = GuardianModule(deployer.deployedGuardianModule());
        address governor = deployer.deployedForageGovernor();

        assertEq(guardianModule.governor(), governor, "deployed GuardianModule must point at deployed governor");
        assertEq(
            address(ForageGovernor(payable(governor)).guardianModule()),
            address(guardianModule),
            "deployed governor must point at deployed GuardianModule"
        );
    }

    function _assertOpen82RiskusdPause(DeployMainnet deployer, address guardian) internal {
        GuardianModule guardianModule = GuardianModule(deployer.deployedGuardianModule());
        address governor = deployer.deployedForageGovernor();
        RISKUSD riskusd = RISKUSD(deployer.deployedRiskusd());
        bool pausedByGuardian = _guardianPauseSucceeded(guardianModule, guardian, address(riskusd));

        assertTrue(
            riskusd.forageGovernor() == governor,
            "deployment dry-run must finalize deployed ForageGovernor on RISKUSD before ownership handoff"
        );
        assertTrue(pausedByGuardian && riskusd.paused(), "real guardian must pause deployed RISKUSD fast path");
    }

    function _assertOpen82RiskusdVaultPause(DeployMainnet deployer, address guardian) internal {
        GuardianModule guardianModule = GuardianModule(deployer.deployedGuardianModule());
        address governor = deployer.deployedForageGovernor();
        RISKUSDVault vault = RISKUSDVault(deployer.deployedRiskusdVault());
        bool pausedByGuardian = _guardianPauseSucceeded(guardianModule, guardian, address(vault));

        assertTrue(
            vault.forageGovernor() == governor,
            "deployment dry-run must finalize deployed ForageGovernor on RISKUSDVault before ownership handoff"
        );
        assertTrue(pausedByGuardian && vault.paused(), "real guardian must pause deployed RISKUSDVault fast path");
    }

    function _assertOpen82StakingQueuePause(DeployMainnet deployer, address guardian) internal {
        GuardianModule guardianModule = GuardianModule(deployer.deployedGuardianModule());
        address governor = deployer.deployedForageGovernor();
        StakingQueue queue = StakingQueue(deployer.deployedStakingQueue());
        bool pausedByGuardian = _guardianPauseSucceeded(guardianModule, guardian, address(queue));

        assertTrue(
            queue.forageGovernor() == governor,
            "deployment dry-run must finalize deployed ForageGovernor on StakingQueue before ownership handoff"
        );
        assertTrue(pausedByGuardian && queue.paused(), "real guardian must pause deployed StakingQueue fast path");
    }

    function _assertOpen82AtRiskPause(DeployMainnet deployer, address guardian) internal {
        GuardianModule guardianModule = GuardianModule(deployer.deployedGuardianModule());
        address governor = deployer.deployedForageGovernor();
        atRISKUSD tier = atRISKUSD(deployer.deployedAtRiskTier(0));
        bool pausedByGuardian = _guardianPauseSucceeded(guardianModule, guardian, address(tier));

        assertTrue(
            tier.forageGovernor() == governor,
            "deployment dry-run must finalize deployed ForageGovernor on atRISKUSD before ownership handoff"
        );
        assertTrue(pausedByGuardian && tier.paused(), "real guardian must pause deployed atRISKUSD fast path");
    }

    function _setOpen82DeployEnv(address firstGuardian) internal {
        for (uint256 i; i < 7;) {
            address guardian = i == 0 ? firstGuardian : _derivedAddress("open82-guardian", i);
            vm.setEnv(string.concat("GUARDIAN_", vm.toString(i)), vm.toString(guardian));
            unchecked {
                ++i;
            }
        }
        vm.setEnv("KEEPER_ADDRESS", vm.toString(_derivedAddress("open82-keeper", 0)));
        vm.setEnv("CUSTODIAN_EXECUTOR", vm.toString(_derivedAddress("open82-executor", 0)));
        vm.setEnv("COLD_ACCOUNT_ADDRESS", vm.toString(_derivedAddress("open82-cold", 0)));
        vm.setEnv(
            "HYPERLIQUID_SOURCE_ACCOUNT", vm.toString(bytes32(uint256(uint160(_derivedAddress("open82-cold", 0)))))
        );
        vm.setEnv("WITHDRAWAL_CHAIN_SELECTOR", "42161");
    }

    function _derivedAddress(string memory seed, uint256 index) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(seed, index)))));
    }

    function _guardianPauseSucceeded(GuardianModule module, address guardian, address target) internal returns (bool) {
        vm.prank(guardian);
        (bool ok,) = address(module).call(abi.encodeCall(GuardianModule.guardianPause, (target)));
        return ok;
    }

    function _assertBindingPresent(string memory repros, string memory bindingMarker, string memory findingId)
        internal
        pure
    {
        assertTrue(
            _contains(repros, string.concat(bindingMarker, findingId)),
            string.concat("missing concrete PHASE7_REPRO_BINDING for ", findingId)
        );
    }

    function _callRouted(address target, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory returnData) = target.call(data);
        return ok || returnData.length >= 4;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
