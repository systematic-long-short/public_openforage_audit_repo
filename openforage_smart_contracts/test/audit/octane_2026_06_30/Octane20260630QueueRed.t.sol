// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/StakingQueue.sol";
import "../../../src/VaultRegistry.sol";
import "../../../src/atRISKUSD.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

contract Octane20260630QueueRedTest is Test {
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

    QueueFixture internal queueFixture;

    function test_V5_adminBackfillRewindsHeadForRevivedLegacyStandardEntry() public {
        QueueFixture storage f = queueFixture;
        _deployQueueFixture();

        uint256 amount = 1_000e6;
        uint256 legacyId = _joinStandard(f.alice, amount, 1, block.timestamp + 30 days);
        _writeQueueEntryBounds(legacyId, 0, block.timestamp - 1);
        uint256 bobId = _joinStandard(f.bob, amount, 1, block.timestamp + 30 days);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);
        assertFalse(f.queue.getQueueEntry(legacyId).processed, "setup: expired legacy entry was skipped");
        assertTrue(f.queue.getQueueEntry(bobId).processed, "setup: later entry processed");
        assertEq(f.queue.tierStandardHead(0), 2, "setup: standard head advanced past legacy entry");

        vm.prank(f.owner);
        f.queue.adminBackfillQueueEntryBounds(legacyId, 1, block.timestamp + 30 days);

        vm.prank(f.keeper);
        f.queue.processQueue(0, 1);

        assertTrue(f.queue.getQueueEntry(legacyId).processed, "backfilled legacy entry must be reachable immediately");
    }

    function _deployQueueFixture() internal {
        QueueFixture storage f = queueFixture;
        f.owner = makeAddr("octane30.queue.owner");
        f.alice = makeAddr("octane30.queue.alice");
        f.bob = makeAddr("octane30.queue.bob");
        f.keeper = makeAddr("octane30.queue.keeper");

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
        f.vaultId = _registerVault(f.registry, f.owner, "Octane 20260630 Queue", "O30Q", tierVaults, address(f.queue));

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
        f.riskusd.mint(user, amount);
        vm.prank(user);
        f.riskusd.approve(address(f.queue), amount);
        queueId = f.queue.nextQueueId();
        vm.prank(user);
        f.queue.joinQueueWithBounds(amount, 0, minShares, deadline);
    }

    function _writeQueueEntryBounds(uint256 queueId, uint256 minimumShares, uint256 deadline) internal {
        bytes32 baseSlot = keccak256(abi.encode(queueId, uint256(12)));
        vm.store(address(queueFixture.queue), bytes32(uint256(baseSlot) + 5), bytes32(minimumShares));
        vm.store(address(queueFixture.queue), bytes32(uint256(baseSlot) + 6), bytes32(deadline));
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
