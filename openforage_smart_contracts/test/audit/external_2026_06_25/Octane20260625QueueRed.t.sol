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
        QueueFixture storage f = queueFixture;
        _fundRiskusd(user, amount);
        queueId = f.queue.nextQueueId();
        vm.prank(user);
        f.queue.joinQueueWithBounds(amount, 0, minShares, deadline);
    }

    function _fundRiskusd(address user, uint256 amount) internal {
        QueueFixture storage f = queueFixture;
        f.riskusd.mint(user, amount);
        vm.prank(user);
        f.riskusd.approve(address(f.queue), amount);
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
}
