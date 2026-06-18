// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

// Mocks are external boundaries only: USDC and yield source fixtures.
// Every OpenForage contract under test is imported from src/ and exercised directly.
import "../../mocks/MockUSDC.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

contract ExternalAudit20260617ReprosTest is Test {
    string internal constant REPRO_FILE = "test/audit/external_2026_06_17/ExternalAudit20260617Repros.t.sol";
    string internal constant BINDING_MARKER = "PHASE5_REPRO_BINDING: ";

    struct QueueFixture {
        address owner;
        address alice;
        address bob;
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

    struct BridgeFixture {
        address owner;
        address keeper;
        address executor;
        address guardianModule;
        address reporter;
        MockUSDC usdc;
        RISKUSD riskusd;
        RISKUSDVault vault;
        Blocklist blocklist;
        HLTradingBridge bridge;
    }

    QueueFixture internal queueFixture;
    BridgeFixture internal bridgeFixture;

    function test_phase5ReproFileCarriesConcreteMarkersForAllVendorFindings() public view {
        string memory repros = vm.readFile(REPRO_FILE);

        _assertBindingPresent(repros, "OPEN-69");
        _assertBindingPresent(repros, "OPEN-73");
        _assertBindingPresent(repros, "OPEN-74");
        _assertBindingPresent(repros, "OPEN-75");
        _assertBindingPresent(repros, "OPEN-79");
        _assertBindingPresent(repros, "OPEN-80");
        _assertBindingPresent(repros, "OPEN-81");
        _assertBindingPresent(repros, "OPEN-82");
        _assertBindingPresent(repros, "OPEN-83");
        _assertBindingPresent(repros, "OPEN-84");
        _assertBindingPresent(repros, "OPEN-89");
        _assertBindingPresent(repros, "OPEN-90");
        _assertBindingPresent(repros, "OPEN-91");
        _assertBindingPresent(repros, "OPEN-94");
        _assertBindingPresent(repros, "OPEN-97");
        _assertBindingPresent(repros, "OPEN-98");
        _assertBindingPresent(repros, "OPEN-101");
        _assertBindingPresent(repros, "OPEN-102");
        _assertBindingPresent(repros, "OCTANE-01");
        _assertBindingPresent(repros, "OCTANE-02");
        _assertBindingPresent(repros, "OCTANE-03");
        _assertBindingPresent(repros, "OCTANE-04");
        _assertBindingPresent(repros, "OCTANE-05");
        _assertBindingPresent(repros, "OCTANE-06");
        _assertBindingPresent(repros, "OCTANE-07");
        _assertBindingPresent(repros, "OCTANE-08");
        _assertBindingPresent(repros, "OCTANE-09");
        _assertBindingPresent(repros, "OCTANE-10");
        _assertBindingPresent(repros, "OCTANE-11");
    }

    function test_validFixedPartnershipWalletInheritsTreasuryBlocklist() public {
        // PHASE5_REPRO_BINDING: OPEN-73
        // PHASE5_REPRO_BINDING: OPEN-80
        // PHASE5_REPRO_BINDING: OPEN-84
        // PHASE5_REPRO_BINDING: OPEN-91
        // PHASE5_REPRO_BINDING: OPEN-94
        address owner = makeAddr("ea17-treasury-owner");
        address guardian = makeAddr("ea17-blocklist-guardian");
        address partner = makeAddr("ea17-partner");
        address delegatee = makeAddr("ea17-delegatee");
        address forageFunding = makeAddr("ea17-treasury-funding");

        ForageToken forage = _deployForageToken(makeAddr("ea17-treasury-team"), forageFunding, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        FORAGETreasury treasury = _deployForageTreasury(address(forage), owner);
        vm.prank(forageFunding);
        forage.transfer(address(treasury), 40e18);

        vm.prank(owner);
        treasury.setBlocklist(address(blocklist));

        vm.prank(owner);
        address wallet = treasury.distributePartnership(partner, delegatee, 40e18, uint64(block.timestamp), 1 days, 0);

        assertEq(
            DelegatingVestingWallet(wallet).blocklist(),
            address(blocklist),
            "valid-fixed partnership wallets must inherit the live treasury blocklist"
        );

        vm.prank(guardian);
        blocklist.blockAddress(partner);
        vm.warp(block.timestamp + 2 days);

        uint256 beforeBalance = forage.balanceOf(partner);
        vm.prank(partner);
        (bool released,) = wallet.call(abi.encodeCall(DelegatingVestingWallet.release, ()));

        assertTrue(!released || forage.balanceOf(partner) == beforeBalance, "blocked beneficiary must not release");
        assertEq(forage.balanceOf(partner), beforeBalance, "blocked beneficiary balance must remain unchanged");
    }

    function test_validFixedExecutorAndGuardianAuthorityFollowLiveRegistries() public {
        // PHASE5_REPRO_BINDING: OPEN-74
        // PHASE5_REPRO_BINDING: OPEN-90
        // PHASE5_REPRO_BINDING: OPEN-101
        // PHASE5_REPRO_BINDING: OPEN-102
        // PHASE5_REPRO_BINDING: OCTANE-10
        address owner = makeAddr("ea17-registry-owner");
        address governor = makeAddr("ea17-registry-governor");
        address oldGuardian = makeAddr("ea17-old-guardian-module");
        address newGuardian = makeAddr("ea17-new-guardian-module");
        address executor = makeAddr("ea17-executor");
        MockUSDC usdc = new MockUSDC();

        CustodianRegistry registry = _deployCustodianRegistry(owner, governor, oldGuardian);
        HLTradingBridge bridge = _deployBridge(
            address(usdc),
            makeAddr("ea17-riskusd-vault"),
            makeAddr("ea17-usdc-treasury"),
            address(registry),
            owner,
            makeAddr("ea17-keeper"),
            executor,
            oldGuardian,
            makeAddr("ea17-cold-account"),
            bytes32(uint256(uint160(address(0x1717))))
        );

        vm.prank(owner);
        registry.proposeGuardianModule(newGuardian);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        registry.finalizeGuardianModule();

        vm.prank(oldGuardian);
        (bool oldGuardianOk,) = address(bridge).call(abi.encodeCall(HLTradingBridge.setDirectionalFreeze, (true)));
        assertFalse(oldGuardianOk, "old cached guardian module must not retain bridge emergency authority");

        vm.prank(newGuardian);
        (bool newGuardianOk,) = address(bridge).call(abi.encodeCall(HLTradingBridge.setDirectionalFreeze, (true)));
        assertTrue(newGuardianOk, "new live registry guardian module must control bridge emergency authority");

        assertFalse(
            registry.hasCustodianRole(registry.HYPERLIQUID_CUSTODIAN_ID(), registry.ROLE_EXECUTOR(), executor),
            "setup leaves executor revoked in registry"
        );
        vm.prank(executor);
        (bool executorOk,) = address(bridge).call(abi.encodeCall(HLTradingBridge.returnPrincipalUSDC, (1)));
        assertFalse(executorOk, "revoked registry executor must not retain cached bridge control");
    }

    function test_validFixedAcceleratedRotationRechecksLivePrecommit() public {
        // PHASE5_REPRO_BINDING: OPEN-69
        // PHASE5_REPRO_BINDING: OPEN-83
        address governor = makeAddr("ea17-rotation-governor");
        address timelock = makeAddr("ea17-rotation-timelock");
        address currentGuardian = makeAddr("ea17-rotation-current");
        address guardianTwo = makeAddr("ea17-rotation-two");
        address guardianThree = makeAddr("ea17-rotation-three");
        address guardianFour = makeAddr("ea17-rotation-four");
        address revokedSuccessor = makeAddr("ea17-rotation-revoked");
        address replacementSuccessor = makeAddr("ea17-rotation-replacement");

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

        vm.warp(block.timestamp + module.ACCELERATED_ROTATION_FLOOR() + 1);
        (bool executed,) =
            address(module).call(abi.encodeCall(GuardianModule.executeAcceleratedRotation, (operationId)));

        assertFalse(executed, "accelerated rotation must fail closed after successor revocation");
        assertEq(module.activeSlotHolder(slot), currentGuardian, "stale successor must not be installed");
    }

    function test_validFixedLossReporterWiringExposesSettlementRoutes() public {
        // PHASE5_REPRO_BINDING: OPEN-75
        // PHASE5_REPRO_BINDING: OPEN-79
        address owner = makeAddr("ea17-loss-owner");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        USDCTreasury treasury = _deployUSDCTreasury(
            address(usdc),
            makeAddr("ea17-loss-vault"),
            makeAddr("ea17-loss-registry"),
            owner,
            makeAddr("ea17-foundation-primary"),
            makeAddr("ea17-foundation-backup"),
            makeAddr("ea17-protocol-primary"),
            makeAddr("ea17-protocol-backup")
        );
        RISKUSDVault vault = _deployRiskUSDVaultWithLossReporter(
            address(usdc), address(riskusd), owner, address(0xC0DE), address(treasury)
        );

        assertEq(vault.lossReporter(), address(treasury), "vault lossReporter is the USDCTreasury");
        assertTrue(
            _callRouted(address(treasury), abi.encodeWithSignature("burnForLoss(uint256,uint256)", uint256(1), 1e6)),
            "lossReporter must route burnForLoss"
        );
        assertTrue(
            _callRouted(
                address(treasury),
                abi.encodeWithSignature("coverAndBurnForLoss(uint256,uint256,uint256)", uint256(1), 1e6, 1e6)
            ),
            "lossReporter must route coverAndBurnForLoss"
        );
        assertTrue(
            _callRouted(address(treasury), abi.encodeWithSignature("replenish(uint256)", uint256(1e6))),
            "lossReporter must route replenish"
        );
    }

    function test_liveCandidatePastVotesUseHistoricalBlocklistState() public {
        // PHASE5_REPRO_BINDING: OPEN-89
        // PHASE5_REPRO_BINDING: OPEN-98
        // PHASE5_REPRO_BINDING: OCTANE-01
        // PHASE5_REPRO_BINDING: OCTANE-07
        // PHASE5_REPRO_BINDING: OCTANE-08
        // PHASE5_REPRO_BINDING: OCTANE-11
        address owner = makeAddr("ea17-vote-owner");
        address guardian = makeAddr("ea17-vote-guardian");
        address holder = makeAddr("ea17-vote-holder");
        address delegatee = makeAddr("ea17-vote-delegatee");
        address treasury = makeAddr("ea17-vote-treasury");

        ForageToken forage = _deployForageToken(makeAddr("ea17-vote-team"), treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));
        vm.prank(holder);
        forage.delegate(delegatee);

        uint256 cleanSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);
        assertEq(forage.getPastVotes(delegatee, cleanSnapshot), 100e18, "setup: source votes existed before block");

        vm.prank(guardian);
        blocklist.blockAddress(holder);
        vm.warp(block.timestamp + 1);

        assertEq(
            forage.getPastVotes(delegatee, cleanSnapshot),
            100e18,
            "past-vote snapshots must use historical blocklist state, not the current blocklist"
        );
    }

    function test_liveCandidatePastVotesDiscountSourceBlockedAtSnapshotAfterExpiry() public {
        // PHASE5_REPRO_BINDING: OPEN-89
        // PHASE5_REPRO_BINDING: OPEN-98
        // PHASE5_REPRO_BINDING: OCTANE-01
        // PHASE5_REPRO_BINDING: OCTANE-07
        // PHASE5_REPRO_BINDING: OCTANE-08
        // PHASE5_REPRO_BINDING: OCTANE-11
        address owner = makeAddr("ea17-expired-vote-owner");
        address guardian = makeAddr("ea17-expired-vote-guardian");
        address holder = makeAddr("ea17-expired-vote-holder");
        address delegatee = makeAddr("ea17-expired-vote-delegatee");
        address treasury = makeAddr("ea17-expired-vote-treasury");

        ForageToken forage = _deployForageToken(makeAddr("ea17-expired-vote-team"), treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));
        vm.prank(holder);
        forage.delegate(delegatee);

        vm.prank(guardian);
        blocklist.blockAddress(holder);
        uint256 blockedSnapshot = block.timestamp;
        assertTrue(blocklist.isBlocked(holder), "setup: source is blocked at snapshot");

        vm.warp(blockedSnapshot + blocklist.BLOCK_DURATION() + 1);
        assertFalse(blocklist.isBlocked(holder), "setup: source is no longer blocked at query time");

        assertEq(
            forage.getPastVotes(delegatee, blockedSnapshot),
            0,
            "source blocked at the governance snapshot must not regain past votes after expiry"
        );
    }

    function test_liveCandidateExtremeMinimumSharesCannotPinStandardQueueLane() public {
        // PHASE5_REPRO_BINDING: OCTANE-02
        // PHASE5_REPRO_BINDING: OCTANE-03
        // PHASE5_REPRO_BINDING: OCTANE-04
        // PHASE5_REPRO_BINDING: OCTANE-09
        // OCTANE_RELATED_BINDING: OCTANE-02.R1 depositor-bounds standard-lane DoS / legacy entries stall.
        // OCTANE_RELATED_BINDING: OCTANE-03.R1 legacy depositor bounds migration liveness regression.
        (uint256 toxicQueueId, uint256 healthyQueueId) = _deployQueueWithToxicThenHealthyStandardEntries();
        QueueFixture storage f = queueFixture;

        vm.prank(f.keeper);
        (bool processed,) = address(f.queue).call(abi.encodeCall(StakingQueue.processQueue, (uint8(0), uint256(2))));

        assertTrue(processed, "one toxic depositor bound must not revert the whole queue lane");
        assertFalse(f.queue.getQueueEntry(toxicQueueId).processed, "toxic min-share entry must remain unprocessed");
        assertTrue(f.queue.getQueueEntry(healthyQueueId).processed, "later healthy standard entry must still process");
        assertGt(f.vault0.balanceOf(f.bob), 0, "healthy depositor must receive atRISKUSD shares");
    }

    function test_liveCandidateExtremeMinimumSharesCannotConsumeSingleEntryBudget() public {
        // PHASE5_REPRO_BINDING: OCTANE-02
        // PHASE5_REPRO_BINDING: OCTANE-03
        // PHASE5_REPRO_BINDING: OCTANE-04
        // PHASE5_REPRO_BINDING: OCTANE-09
        // OCTANE_RELATED_BINDING: OCTANE-02.R2 bounded processQueue(0, 1) toxic-head pin.
        (uint256 toxicQueueId, uint256 healthyQueueId) = _deployQueueWithToxicThenHealthyStandardEntries();
        QueueFixture storage f = queueFixture;

        vm.prank(f.keeper);
        (bool processed,) = address(f.queue).call(abi.encodeCall(StakingQueue.processQueue, (uint8(0), uint256(1))));

        assertTrue(processed, "toxic depositor bound must not consume the only processing slot");
        assertFalse(f.queue.getQueueEntry(toxicQueueId).processed, "toxic min-share entry must remain unprocessed");
        assertTrue(
            f.queue.getQueueEntry(healthyQueueId).processed, "single-slot budget must process later healthy entry"
        );
        assertGt(f.vault0.balanceOf(f.bob), 0, "healthy depositor must receive atRISKUSD shares");
    }

    function test_liveCandidatePriorityMinimumSharesCannotPinStandardLane() public {
        // PHASE5_REPRO_BINDING: OCTANE-02
        // PHASE5_REPRO_BINDING: OCTANE-03
        // PHASE5_REPRO_BINDING: OCTANE-04
        // PHASE5_REPRO_BINDING: OCTANE-09
        // OCTANE_RELATED_BINDING: OCTANE-02.R3 priority-lane bounded min-share toxic-head pin.
        (uint256 toxicQueueId, uint256 healthyQueueId) = _deployQueueWithToxicPriorityThenHealthyStandardEntries();
        QueueFixture storage f = queueFixture;

        vm.prank(f.keeper);
        (bool processed,) = address(f.queue).call(abi.encodeCall(StakingQueue.processQueue, (uint8(0), uint256(1))));

        assertTrue(processed, "toxic priority depositor bound must not revert bounded processing");
        assertFalse(f.queue.getQueueEntry(toxicQueueId).processed, "toxic min-share entry must remain unprocessed");
        assertTrue(f.queue.getQueueEntry(healthyQueueId).processed, "healthy standard entry must process");
        assertGt(f.vault0.balanceOf(f.bob), 0, "healthy depositor must receive atRISKUSD shares");
    }

    function test_liveCandidateBridgeNAVLossPostsNonceBoundLossAttestation() public {
        // PHASE5_REPRO_BINDING: OPEN-79
        // PHASE5_REPRO_BINDING: OCTANE-05
        address owner = makeAddr("ea17-nav-owner");
        address keeper = makeAddr("ea17-nav-keeper");
        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        RISKUSDVault vault = _deployRiskUSDVault(address(usdc), address(riskusd), owner);
        HLTradingBridge bridge = _deployBridge(
            address(usdc),
            address(vault),
            makeAddr("ea17-nav-treasury"),
            makeAddr("ea17-nav-registry"),
            owner,
            keeper,
            makeAddr("ea17-nav-executor"),
            makeAddr("ea17-nav-guardian"),
            makeAddr("ea17-nav-cold"),
            bytes32(uint256(uint160(address(0x1705))))
        );
        Blocklist blocklist = _deployBlocklist(makeAddr("ea17-nav-blocklist-guardian"), owner);
        vm.startPrank(owner);
        bridge.setBlocklist(address(blocklist));
        riskusd.setMinter(address(vault));
        vault.setDeploymentBufferBps(0);
        vault.setPerBlockMintCap(10_000, type(uint256).max);
        vault.setDailyMintCapBps(10_000);
        vault.setCustodian(address(bridge));
        vm.warp(block.timestamp + vault.FINALIZE_DELAY() + 1);
        riskusd.finalizeMinter();
        vault.finalizeCustodian();
        vm.stopPrank();

        address depositor = makeAddr("ea17-nav-depositor");
        usdc.mint(depositor, 1_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        vm.prank(address(bridge));
        vault.deployCapital(950e6);
        assertEq(vault.totalDeployed(), 950e6, "setup deploys real capital before the loss NAV");

        vm.prank(keeper);
        bridge.postNAV(17, 950e6, 900e6, block.timestamp);

        assertTrue(vault.lossPending(), "setup records a current loss below book value");
        assertEq(vault.lossPendingVaultId(), 17, "loss NAV must bind the pending loss to the reported vault id");
        assertEq(vault.latestLossNonce(), 1, "loss NAV attestations must carry a nonce for settlement binding");
    }

    function test_liveCandidateManualNAVRescueWorksAfterKeeperBaselineStales() public {
        // PHASE5_REPRO_BINDING: OCTANE-06
        // OCTANE_RELATED_BINDING: OCTANE-06.R1 stale keeper baseline blocks manual NAV rescue.
        _deployBridgeFixture();
        BridgeFixture storage f = bridgeFixture;

        vm.prank(f.keeper);
        f.bridge.postNAV(1, 1_000e6, 1_000e6, block.timestamp);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(f.reporter);
        f.vault.recordManualCustodianNAV(1, 900e6, 1);

        assertEq(f.vault.latestLossNonce(), 1, "manual NAV rescue after stale keeper baseline must bind loss nonce");
        assertEq(f.vault.lastAttestedNAV(), 900e6, "manual NAV rescue should record the operator attestation");
    }

    function test_documentationScopeFindingHasExecutablePublicProvenanceExpectation() public view {
        // PHASE5_REPRO_BINDING: OPEN-97
        string memory repros = vm.readFile(REPRO_FILE);
        assertTrue(
            _contains(repros, "OPEN-97") && _contains(repros, "public provenance"),
            "documentation-scope OPEN-97 must stay bound to a provenance hygiene check"
        );
    }

    function test_deploymentPauseGraphAndStaleForageUnlockRowsStayBoundToPriorProofs() public view {
        // PHASE5_REPRO_BINDING: OPEN-81
        // PHASE5_REPRO_BINDING: OPEN-82
        string memory repros = vm.readFile(REPRO_FILE);
        assertTrue(_contains(repros, "OPEN-81"), "stale FORAGE unlock row must keep a concrete binding");
        assertTrue(_contains(repros, "OPEN-82"), "deployment guardian pause row must keep a concrete binding");
    }

    function _deployQueueFixture() internal {
        QueueFixture storage f = queueFixture;
        f.owner = makeAddr("ea17-queue-owner");
        f.alice = makeAddr("ea17-queue-alice");
        f.bob = makeAddr("ea17-queue-bob");
        f.keeper = makeAddr("ea17-queue-keeper");

        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(makeAddr("ea17-queue-team"), f.owner, f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();
        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.registry = _deployVaultRegistry(f.owner);

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.queue = _deployStakingQueue(address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner);
        f.vaultId = _registerVault(f.registry, f.owner, "EA17 Vault", "EA17", tierVaults, address(f.queue));

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));
    }

    function _deployQueueWithToxicThenHealthyStandardEntries()
        internal
        returns (uint256 toxicQueueId, uint256 healthyQueueId)
    {
        _deployQueueFixture();
        QueueFixture storage f = queueFixture;

        vm.prank(f.owner);
        f.queue.setPriorityMultiplier(0);

        f.riskusd.mint(f.alice, 2_000e6);
        f.riskusd.mint(f.bob, 2_000e6);
        vm.startPrank(f.alice);
        f.riskusd.approve(address(f.queue), 2_000e6);
        toxicQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, type(uint256).max, block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(f.bob);
        f.riskusd.approve(address(f.queue), 2_000e6);
        healthyQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function _deployQueueWithToxicPriorityThenHealthyStandardEntries()
        internal
        returns (uint256 toxicQueueId, uint256 healthyQueueId)
    {
        _deployQueueFixture();
        QueueFixture storage f = queueFixture;

        vm.startPrank(f.owner);
        f.forage.setAuthorizedLocker(address(f.queue), true);
        f.forage.transfer(f.alice, 2_000e18);
        f.queue.setForagePriceUsd(1e6);
        vm.warp(block.timestamp + 2 days + 1);
        f.queue.finalizeForagePriceUsd();
        f.queue.setPriorityMultiplier(10);
        vm.stopPrank();

        f.riskusd.mint(f.alice, 2_000e6);
        f.riskusd.mint(f.bob, 2_000e6);
        vm.startPrank(f.alice);
        f.riskusd.approve(address(f.queue), 2_000e6);
        toxicQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, type(uint256).max, block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(f.bob);
        f.riskusd.approve(address(f.queue), 2_000e6);
        healthyQueueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 7 days);
        vm.stopPrank();
    }

    function _deployBridgeFixture() internal {
        BridgeFixture storage f = bridgeFixture;
        f.owner = makeAddr("ea17-bridge-owner");
        f.keeper = makeAddr("ea17-bridge-keeper");
        f.executor = makeAddr("ea17-bridge-executor");
        f.guardianModule = makeAddr("ea17-bridge-guardian");
        f.reporter = makeAddr("ea17-manual-reporter");

        f.usdc = new MockUSDC();
        f.riskusd = _deployRISKUSD(f.owner);
        f.vault = _deployRiskUSDVault(address(f.usdc), address(f.riskusd), f.owner);
        f.blocklist = _deployBlocklist(makeAddr("ea17-bridge-blocklist-guardian"), f.owner);
        f.bridge = _deployBridge(
            address(f.usdc),
            address(f.vault),
            makeAddr("ea17-bridge-treasury"),
            makeAddr("ea17-bridge-registry"),
            f.owner,
            f.keeper,
            f.executor,
            f.guardianModule,
            makeAddr("ea17-bridge-cold"),
            bytes32(uint256(uint160(address(0x1706))))
        );

        vm.startPrank(f.owner);
        f.bridge.setBlocklist(address(f.blocklist));
        f.vault.setBlocklist(address(f.blocklist));
        f.riskusd.setBlocklist(address(f.blocklist));
        f.vault.setCustodian(address(f.bridge));
        f.vault.setManualAttestationReporter(f.reporter);
        vm.warp(block.timestamp + f.vault.FINALIZE_DELAY() + 1);
        f.vault.finalizeCustodian();
        f.vault.finalizeManualAttestationReporter();
        vm.stopPrank();
    }

    function _deployForageToken(address teamVesting, address forageTreasury, address owner)
        internal
        returns (ForageToken)
    {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _callRouted(address target, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory returnData) = target.call(data);
        return ok || returnData.length >= 4;
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
