// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./helpers/StakingQueueTestBase.sol";
import "./helpers/ForageTokenTestBase.sol";
import "./mocks/MockAtRISKUSD.sol";
import "./mocks/MockForagePriceOracle.sol";
import "./mocks/MockForageTokenLocking.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";

contract OctaneFailingProbeVault {
    IERC20 public immutable riskusd;
    bool public revertLegitimateAssets = true;
    uint256 public mockTotalAssets;
    uint256 public mockTotalSupply;
    uint256 public depositCallCount;

    constructor(address riskusd_) {
        riskusd = IERC20(riskusd_);
    }

    function deposit(uint256 riskusdAmount, address) external returns (uint256) {
        depositCallCount++;
        mockTotalAssets += riskusdAmount;
        mockTotalSupply += riskusdAmount;
        riskusd.transferFrom(msg.sender, address(this), riskusdAmount);
        return riskusdAmount;
    }

    function legitimateAssets() external view returns (uint256) {
        if (revertLegitimateAssets) revert("legitimateAssets probe failed");
        return mockTotalAssets;
    }

    function totalAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return mockTotalSupply;
    }
}

contract OctaneStakingQueueRed is StakingQueueTestBase {
    function test_CHAIN_V13_stalePriorityPriceDoesNotBlockStandardDeposit() public {
        _activatePriority(1e6, 10);
        forage.mint(alice, 1_000e18);
        _fundUser(alice, STANDARD_DEPOSIT);
        vm.warp(block.timestamp + 7 days + 1);

        uint256 queueId = queue.nextQueueId();
        vm.prank(alice);
        (bool ok,) =
            address(queue).call(abi.encodeWithSelector(StakingQueue.joinQueue.selector, STANDARD_DEPOSIT, uint8(0)));

        assertTrue(ok, "stale priority price should degrade to standard lane instead of blocking deposit liveness");
        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertEq(entry.depositor, alice, "queued depositor");
        assertFalse(entry.priority, "stale priority pricing must not route into priority lane");
        assertEq(queue.tierStandardQueueLength(0), 1, "standard lane entry recorded");
    }

    function test_CHAIN_V16_permissionlessProcessingCannotForceDustShareSettlement() public {
        uint256 queueId = _joinQueue(alice, 1_000e6, 0);
        uint256 queuedBefore = queue.totalQueuedRiskusd();
        vault0.setCustomDepositReturn(true, 1);
        vm.warp(block.timestamp + 1 days);

        vm.prank(attacker);
        (bool processedCall,) =
            address(queue).call(abi.encodeWithSelector(StakingQueue.processQueue.selector, uint8(0), uint256(1)));
        processedCall;

        StakingQueue.QueueEntry memory entry = queue.getQueueEntry(queueId);
        assertFalse(entry.processed, "entry without slippage/expiry guard must not be force-settled for dust shares");
        assertEq(queue.totalQueuedRiskusd(), queuedBefore, "queued accounting should remain until guarded settlement");
        assertEq(vault0.depositCallCount(), 0, "vault deposit should not execute below depositor minimum");
    }

    function test_CHAIN_V20_oversizedHeadDoesNotStallLaterProcessableEntry() public {
        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 1_000e6);

        uint256 headId = _joinQueue(alice, 1_500e6, 0);
        uint256 laterId = _joinQueue(bob, 500e6, 0);

        vm.prank(keeper);
        queue.processQueue(0, 2);

        assertFalse(queue.getQueueEntry(headId).processed, "oversized head remains queued");
        assertTrue(queue.getQueueEntry(laterId).processed, "later processable entry should settle within scan budget");
        assertEq(vault0.depositCallCount(), 1, "one processable entry should be deposited");
        (, address depositor) = vault0.depositCalls(0);
        assertEq(depositor, bob, "later depositor processed");
    }

    function test_CHAIN_V21_oracleModeReadsConfiguredOracleWithoutFixedPrice() public {
        MockForagePriceOracle oracle = new MockForagePriceOracle(8);
        vm.startPrank(owner);
        queue.setForagePriceOracle(address(oracle), 1 hours);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceOracle();
        queue.setForagePriceMode(StakingQueue.PriceMode.ORACLE);
        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        queue.finalizeForagePriceMode();
        vm.stopPrank();

        oracle.setRoundData(1e8, block.timestamp);
        assertEq(queue.foragePriceUsd(), 0, "fixed price remains unset");
        assertEq(uint8(queue.foragePriceMode()), uint8(StakingQueue.PriceMode.ORACLE), "oracle mode active");
        assertEq(queue.effectiveForagePriceUsd(), 1e6, "oracle price source should drive active FORAGE price");
    }

    function test_CHAIN_W24_selfRevertRejectsZeroRedeemOrDepositOutput() public {
        vault1.setLockupInfo(alice, true, true, false, false, 1);
        vault1.setRedeemForReversionReturnAmount(0);

        vm.prank(alice);
        (bool ok,) = address(queue).call(abi.encodeWithSelector(StakingQueue.selfRevert.selector, uint8(1)));

        assertFalse(ok, "zero redemption/deposit output should fail cleanly");
        assertEq(vault0.depositCallCount(), 0, "zero-output reversion must not emit success-path deposit");
    }

    function test_OPEN41_selfRevertKeepsExpiredLockupRetryableWhenTier0DepositFails() public {
        vault1.setLockupInfo(alice, true, true, false, false, 1_000e6);
        vault1.setMockTotalAssets(1_000e6);
        vault1.setRedeemForReversionReturnAmount(1_000e6);
        riskusd.mint(address(vault1), 1_000e6);
        vault0.setShouldRevertDeposit(true);

        uint256 aliceRiskusdBefore = riskusd.balanceOf(alice);
        uint256 vault1SupplyBefore = vault1.totalSupply();

        vm.prank(alice);
        vm.expectRevert(StakingQueue.Tier0DepositFailed.selector);
        queue.selfRevert(1);

        assertEq(riskusd.balanceOf(alice), aliceRiskusdBefore, "OPEN-41: no liquid RISKUSD fallback");
        assertEq(vault1.totalSupply(), vault1SupplyBefore, "OPEN-41: lockup remains retryable");
        assertEq(vault0.depositCallCount(), 0, "OPEN-41: failed tier0 deposit rolls back");
    }

    function test_CHAIN_W27_failedCapacityProbeFailsClosedBeforeDeposit() public {
        OctaneFailingProbeVault bad0 = new OctaneFailingProbeVault(address(riskusd));
        OctaneFailingProbeVault bad1 = new OctaneFailingProbeVault(address(riskusd));
        OctaneFailingProbeVault bad2 = new OctaneFailingProbeVault(address(riskusd));
        OctaneFailingProbeVault bad3 = new OctaneFailingProbeVault(address(riskusd));
        address[4] memory tierVaults = [address(bad0), address(bad1), address(bad2), address(bad3)];

        mockVaultRegistry.setTestCapacityCap(registeredVaultId, 1_000e6);
        mockVaultRegistry.setTestTierVaults(registeredVaultId, tierVaults);
        _joinQueue(alice, 100e6, 0);

        vm.prank(keeper);
        (bool ok,) =
            address(queue).call(abi.encodeWithSelector(StakingQueue.processQueue.selector, uint8(0), uint256(1)));

        assertFalse(ok, "failed legitimateAssets probes must fail closed");
        assertEq(bad0.depositCallCount(), 0, "deposit must not proceed after failed utilization probe");
    }

    function test_CHAIN_W29_pendingFixedPriceDoesNotAffectPriorityBeforeFinalize() public {
        _activatePriority(1e6, 10);
        forage.mint(alice, 200e18);

        vm.prank(owner);
        queue.setForagePriceUsd(2e6);

        assertEq(queue.foragePriceUsd(), 1e6, "active price should remain old value during pending period");
        (bool exists, uint256 pendingPrice,) = queue.pendingForagePriceUsd();
        assertTrue(exists, "pending price exists");
        assertEq(pendingPrice, 2e6, "pending price recorded");

        uint256 queueId = _joinQueue(alice, 1_000e6, 0);

        assertEq(queue.forageLockedPerEntry(queueId), 100e18, "priority lock should use old finalized price");
    }

    function test_CHAIN_W37_fixedPriceRejectsOrNormalizesEighteenDecimalInput() public {
        vm.prank(owner);
        (bool proposed,) = address(queue).call(abi.encodeWithSelector(StakingQueue.setForagePriceUsd.selector, 1e18));
        if (!proposed) return;

        vm.warp(block.timestamp + queue.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        (bool finalized,) = address(queue).call(abi.encodeWithSelector(StakingQueue.finalizeForagePriceUsd.selector));
        if (!finalized) return;

        assertEq(queue.effectiveForagePriceUsd(), 1e6, "accepted fixed prices must normalize to 6-decimal USD scale");
    }
}

contract OctaneStakingQueueForageLockRed is Test {
    StakingQueue public queue;
    MockRISKUSD public riskusd;
    MockForageTokenLocking public forageLock;
    MockAtRISKUSD public vault0;
    MockAtRISKUSD public vault1;
    MockAtRISKUSD public vault2;
    MockAtRISKUSD public vault3;
    MockVaultRegistry public mockVaultRegistry;
    uint256 public registeredVaultId;

    address public owner;
    address public alice;
    address public keeper;

    function setUp() public {
        owner = makeAddr("timelock");
        alice = makeAddr("alice");
        keeper = makeAddr("keeper");

        riskusd = new MockRISKUSD();
        forageLock = new MockForageTokenLocking();
        vault0 = new MockAtRISKUSD(address(riskusd));
        vault1 = new MockAtRISKUSD(address(riskusd));
        vault2 = new MockAtRISKUSD(address(riskusd));
        vault3 = new MockAtRISKUSD(address(riskusd));
        mockVaultRegistry = new MockVaultRegistry();

        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(360 days)];
        uint16[4] memory yieldBps = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(1500), uint16(1500)];
        registeredVaultId = mockVaultRegistry.addTestVault(
            "Test Vault", "TV", tierVaults, address(0), 10_000_000e6, lockups, yieldBps, fundingBps
        );

        StakingQueue implementation = new StakingQueue();
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize,
            (address(riskusd), address(forageLock), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        queue = StakingQueue(address(proxy));

        vm.prank(owner);
        queue.setVaultId(registeredVaultId);
        forageLock.setAuthorizedLocker(address(queue), true);
    }

    function _fundUser(address user, uint256 amount) internal {
        riskusd.mint(user, amount);
        vm.prank(user);
        riskusd.approve(address(queue), amount);
    }

    function _joinQueue(address user, uint256 amount, uint8 tier) internal returns (uint256 queueId) {
        _fundUser(user, amount);
        queueId = queue.nextQueueId();
        vm.prank(user);
        queue.joinQueue(amount, tier);
    }

    function test_CHAIN_W12_retryClearsActualQueueLockerBalanceWhenEntryAccountingMissing() public {
        uint256 queueId = _joinQueue(alice, 1_000e6, 0);
        vm.prank(keeper);
        queue.processQueue(0, 1);

        forageLock.mint(alice, 25e18);
        forageLock.setLockedBalance(alice, 25e18);
        forageLock.setLockerBalance(alice, address(queue), 25e18);

        (bool ok,) = address(queue).call(abi.encodeWithSelector(StakingQueue.retryForageUnlock.selector, queueId));

        assertTrue(ok, "retry should reconcile the queue's actual per-locker FORAGE balance");
        assertEq(forageLock.lockerBalance(alice, address(queue)), 0, "queue locker balance cleared");
        assertEq(forageLock.lockedBalance(alice), 0, "aggregate lock cleared");
    }
}

contract OctaneForageTokenRed is ForageTokenTestBase {
    using stdStorage for StdStorage;

    function test_CHAIN_W01_nonZeroToNonZeroApproveIsRejected() public {
        _fundAlice(1_000e18);

        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.prank(alice);
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(ForageToken.approve.selector, bob, 200e18));
        bool accepted = ok && (data.length == 0 || abi.decode(data, (bool)));

        assertFalse(accepted, "non-zero allowance must be zeroed before setting a new non-zero value");

        vm.prank(alice);
        token.approve(bob, 0);
        vm.prank(alice);
        assertTrue(token.approve(bob, 200e18), "zero-first allowance update remains usable");
    }

    function test_CHAIN_W16_setLockExemptFalseDoesNotCreateAggregateOnlyFreeze() public {
        _fundAlice(1_000e18);
        _setupLocker();
        _lockTokens(alice, 800e18);

        stdstore.target(address(token)).sig("balanceOf(address)").with_key(alice).checked_write(400e18);
        assertEq(token.balanceOf(alice), 400e18, "test setup balance");
        assertEq(token.lockerBalance(alice, authorizedLocker), 800e18, "test setup per-locker balance");

        vm.prank(owner);
        (bool ok,) = address(token).call(abi.encodeWithSelector(ForageToken.setLockExempt.selector, alice, false));
        if (!ok) return;

        uint256 lockedAfter = token.lockedBalance(alice);
        uint256 lockerAfter = token.lockerBalance(alice, authorizedLocker);
        assertEq(lockedAfter, lockerAfter, "aggregate lock must remain owned by an unlock-capable locker");

        if (lockedAfter > 0) {
            vm.prank(authorizedLocker);
            token.unlock(alice, lockedAfter);
            assertEq(token.lockedBalance(alice), 0, "locker should be able to clear reconciled lock");
        }
    }

    function test_CHAIN_W30_lockerGrowthIsCappedOrPrivilegedBurnIsBounded() public {
        (uint256 fewGas, bool fewBounded) = _burnGasAfterDistinctLockers(4);
        assertFalse(fewBounded, "small locker count should remain usable");

        (uint256 manyGas, bool manyBounded) = _burnGasAfterDistinctLockers(96);
        if (manyBounded) return;

        assertLe(manyGas, fewGas * 2, "burn gas should not scale with unbounded per-account locker count");
    }

    function _burnGasAfterDistinctLockers(uint256 lockerCount) internal returns (uint256 gasUsed, bool bounded) {
        ForageToken fresh = _deployFreshForageToken();
        vm.prank(forageTreasury);
        fresh.transfer(alice, 200e18);
        vm.prank(owner);
        fresh.setAuthorizedBurner(authorizedBurner, true);

        for (uint256 i; i < lockerCount; i++) {
            address locker = address(uint160(uint256(keccak256(abi.encodePacked("octane-locker", lockerCount, i)))));
            vm.prank(owner);
            fresh.setAuthorizedLocker(locker, true);

            vm.prank(locker);
            (bool lockOk,) = address(fresh).call(abi.encodeWithSelector(ForageToken.lock.selector, alice, 1e18));
            if (!lockOk) return (0, true);
        }

        uint256 burnAmount = 200e18 - ((lockerCount - 1) * 1e18);
        uint256 gasBefore = gasleft();
        vm.prank(authorizedBurner);
        (bool burnOk,) = address(fresh).call(abi.encodeWithSelector(ForageToken.burn.selector, alice, burnAmount));
        gasUsed = gasBefore - gasleft();
        if (!burnOk) return (0, true);
    }

    function _deployFreshForageToken() internal returns (ForageToken fresh) {
        ForageToken impl = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        fresh = ForageToken(address(proxy));
    }
}
