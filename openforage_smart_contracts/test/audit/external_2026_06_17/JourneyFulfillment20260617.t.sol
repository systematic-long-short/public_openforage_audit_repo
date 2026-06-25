// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/RISKUSDVault.sol";
import "../../../src/StakingQueue.sol";
import "../../../src/VaultRegistry.sol";
import "../../../src/atRISKUSD.sol";

// External-boundary mocks only: USDC and yield source.
import "../../mocks/MockUSDC.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

contract JourneyFulfillment20260617Test is Test {
    struct QueueJourneyFixture {
        address owner;
        address depositor;
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

    QueueJourneyFixture internal queueFixture;

    function test_depositorVaultJourneyDepositsMintsRedeemsAndHonorsBlocklist() public {
        // JOURNEY_BINDING_20260617: depositor.vault.deposit-mint-redeem
        // JOURNEY_BINDING_20260617: compliance.blocked-depositor-denied
        address owner = makeAddr("journey-owner");
        address guardian = makeAddr("journey-blocklist-guardian");
        address depositor = makeAddr("journey-depositor");
        address blockedDepositor = makeAddr("journey-blocked-depositor");

        MockUSDC usdc = new MockUSDC();
        RISKUSD riskusd = _deployRISKUSD(owner);
        RISKUSDVault vault = _deployRiskUSDVault(address(usdc), address(riskusd), owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);

        vm.startPrank(owner);
        riskusd.setBlocklist(address(blocklist));
        vault.setBlocklist(address(blocklist));
        vault.setWeeklyRedemptionCapBps(10_000);
        vault.setDailyRedemptionCapBps(10_000);
        riskusd.setMinter(address(vault));
        vm.warp(block.timestamp + riskusd.FINALIZE_DELAY() + 1);
        riskusd.finalizeMinter();
        vm.stopPrank();

        usdc.mint(depositor, 1_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        assertEq(riskusd.balanceOf(depositor), 1_000e6, "depositor receives 1:1 RISKUSD");

        riskusd.approve(address(vault), 400e6);
        vault.redeem(400e6);
        vm.stopPrank();

        assertEq(riskusd.balanceOf(depositor), 600e6, "redeem burns RISKUSD");
        assertEq(usdc.balanceOf(depositor), 400e6, "redeem returns USDC");

        usdc.mint(blockedDepositor, 1e6);
        vm.prank(guardian);
        blocklist.blockAddress(blockedDepositor);

        vm.startPrank(blockedDepositor);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.deposit(1e6);
        vm.stopPrank();
    }

    function test_depositorQueueJourneyProcessesIntoRealTierVault() public {
        // JOURNEY_BINDING_20260617: depositor.queue.standard-to-tier0-atRISKUSD
        _deployQueueJourneyFixture();
        QueueJourneyFixture storage f = queueFixture;

        f.riskusd.mint(f.depositor, 1_000e6);
        vm.startPrank(f.depositor);
        f.riskusd.approve(address(f.queue), 1_000e6);
        uint256 queueId = f.queue.nextQueueId();
        f.queue.joinQueueWithBounds(1_000e6, 0, 1, block.timestamp + 7 days);
        vm.stopPrank();

        f.queue.processQueue(0, 1);

        assertTrue(f.queue.getQueueEntry(queueId).processed, "queue entry is processed");
        assertEq(f.riskusd.balanceOf(f.depositor), 0, "queued RISKUSD was consumed");
        assertGt(f.vault0.balanceOf(f.depositor), 0, "depositor receives tier-0 atRISKUSD shares");
    }

    function _deployQueueJourneyFixture() internal {
        QueueJourneyFixture storage f = queueFixture;
        f.owner = makeAddr("queue-journey-owner");
        f.depositor = makeAddr("queue-journey-depositor");
        f.riskusd = _deployMintableRiskUSD(f.owner);
        f.forage = _deployForageToken(makeAddr("queue-journey-team"), makeAddr("queue-journey-treasury"), f.owner);
        f.yieldSource = new MockYieldSourceForLossPending();
        f.vault0 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault1 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault2 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.vault3 = _deployAtRiskVault(address(f.riskusd), address(f.yieldSource), address(0), f.owner);
        f.registry = _deployVaultRegistry(f.owner);

        address[4] memory tierVaults = [address(f.vault0), address(f.vault1), address(f.vault2), address(f.vault3)];
        f.queue = _deployStakingQueue(address(f.riskusd), address(f.forage), tierVaults, address(f.registry), f.owner);
        f.vaultId = _registerVault(f.registry, f.owner, "Journey Vault", "JV", tierVaults, address(f.queue));

        vm.prank(f.owner);
        f.queue.setVaultId(f.vaultId);
        vm.prank(f.owner);
        f.queue.setPriorityMultiplier(0);
        _wireTierVaultToQueue(f.vault0, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault1, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault2, f.owner, address(f.queue));
        _wireTierVaultToQueue(f.vault3, f.owner, address(f.queue));
    }

    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _deployRiskUSDVault(address usdc, address riskusd, address owner) internal returns (RISKUSDVault) {
        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initializeTarget, (usdc, riskusd, owner, owner, owner));
        return RISKUSDVault(address(new ERC1967Proxy(address(implementation), initData)));
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

    function _deployVaultRegistry(address owner) internal returns (VaultRegistry) {
        VaultRegistry implementation = new VaultRegistry();
        bytes memory initData = abi.encodeCall(VaultRegistry.initialize, (owner));
        return VaultRegistry(address(new ERC1967Proxy(address(implementation), initData)));
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
