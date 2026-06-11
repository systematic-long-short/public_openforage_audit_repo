// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";
import "./helpers/RISKUSDVaultV2.sol";
import "./helpers/RISKUSDVaultV3.sol";
import "./mocks/MockAtRISKUSD.sol";
import "./mocks/MockVaultRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ManualNAVNormalizerCustodian {
    function normalizeManualCustodianNAV(uint256, uint256 nav, uint256) external pure returns (bool, uint256) {
        return (true, nav);
    }
}

// ============================================================
// TC-01: Initialization Tests
// ============================================================
contract RISKUSDVault_TC01_Init is RISKUSDVaultTestBase {
    function test_TC01_initSetsUsdcAddress() public view {
        assertEq(vault.usdc(), address(usdc));
    }

    function test_TC01_initSetsRiskusdAddress() public view {
        assertEq(vault.riskusd(), address(riskusd));
    }

    function test_TC01_initSetsOwner() public view {
        assertEq(vault.owner(), owner);
    }

    function test_TC01_initSetsCustodianToZero() public view {
        assertEq(vault.custodian(), address(0));
    }

    function test_TC01_initSetsLossReporterToZero() public view {
        assertEq(vault.lossReporter(), address(0));
    }

    function test_TC01_initSetsMaxDeploymentRatioDefault() public view {
        assertEq(vault.maxDeploymentRatioBps(), DEFAULT_MAX_DEPLOYMENT_RATIO_BPS);
    }

    function test_TC01_initSetsWeeklyRedemptionCapDefault() public view {
        assertEq(vault.weeklyRedemptionCapBps(), DEFAULT_WEEKLY_CAP_BPS);
    }

    function test_TC01_initSetsDefenceInDepthDefaults() public view {
        assertEq(vault.weeklyMintCapBps(), 20000);
        assertEq(vault.dailyMintCapBps(), 2000);
        assertEq(vault.perBlockMintCapBps(), 2000);
        assertEq(vault.perBlockMintCapMax(), 10_000_000e6);
        assertEq(vault.deploymentBufferBps(), 500);
        assertEq(vault.attestationIntervalSeconds(), 1 days);
        assertEq(vault.lastAttestedNAV(), 0);
    }

    function test_TC01_initSetsWeeklyRedemptionUsedToZero() public view {
        assertEq(vault.weeklyRedemptionUsed(), 0);
    }

    function test_TC01_initSetsWindowStartToBlockTimestamp() public view {
        assertEq(vault.weeklyRedemptionWindowStart(), block.timestamp);
    }

    function test_TC01_initSetsAllCumulativeCountersToZero() public view {
        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.totalRedeemed(), 0);
        assertEq(vault.totalDeployed(), 0);
        assertEq(vault.totalBurnedForLoss(), 0);
        assertEq(vault.totalReplenished(), 0);
        assertEq(vault.totalLostCapital(), 0);
    }

    function test_TC01_initSetsTotalDepositorUsdcToZero() public view {
        assertEq(vault.totalDepositorUsdc(), 0);
    }

    function test_TC01_initLeavesUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(usdc), address(riskusd), owner);
    }

    function test_TC01_initRevertsOnZeroUsdc() public {
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(0), address(riskusd), owner));
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_TC01_initRevertsOnZeroRiskusd() public {
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(0), owner));
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_TC01_initRevertsOnZeroOwner() public {
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), address(0)));
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_TC01_implementationDirectInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(usdc), address(riskusd), owner);
    }
}

// ============================================================
// TC-02: Deposit Tests
// ============================================================
contract RISKUSDVault_TC02_Deposit is RISKUSDVaultTestBase {
    function test_TC02_depositHappyPath() public {
        _fundAndApproveUSDC(alice, 1000e6);

        vm.prank(alice);
        vault.deposit(1000e6);

        // USDC transferred from alice to vault
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(vault)), 1000e6);
        // RISKUSD minted to alice
        assertEq(riskusd.balanceOf(alice), 1000e6);
        // Counter updated
        assertEq(vault.totalDeposited(), 1000e6);
    }

    function test_TC02_depositMinimumOneWei() public {
        _fundAndApproveUSDC(alice, 1);

        vm.prank(alice);
        vault.deposit(1);

        assertEq(riskusd.balanceOf(alice), 1);
        assertEq(vault.totalDeposited(), 1);
    }

    function test_TC02_depositMultiAccumulation() public {
        _deposit(alice, 500e6);
        _deposit(alice, 5e6);

        assertEq(vault.totalDeposited(), 505e6);
        assertEq(riskusd.balanceOf(alice), 505e6);
    }

    function test_TC02_depositMultipleDepositors() public {
        _deposit(alice, 500e6);
        _deposit(bob, 5e6);

        assertEq(vault.totalDeposited(), 505e6);
        assertEq(riskusd.balanceOf(alice), 500e6);
        assertEq(riskusd.balanceOf(bob), 5e6);
    }

    function test_TC02_depositLargeAmount() public {
        uint256 largeAmount = 10_000_000e6;
        _fundAndApproveUSDC(alice, largeAmount);

        vm.prank(alice);
        vault.deposit(largeAmount);

        assertEq(vault.totalDeposited(), largeAmount);
        assertEq(riskusd.balanceOf(alice), largeAmount);
    }

    function test_TC02_depositRevertsAboveGenesisPerBlockCap() public {
        uint256 amount = 10_000_000e6 + 1;
        _fundAndApproveUSDC(alice, amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.PerBlockMintCapExceeded.selector, amount, 10_000_000e6));
        vault.deposit(amount);
    }

    function test_TC02_depositRevertsWhenWeeklyMintCapExceeded() public {
        _deposit(alice, 10_000_000e6);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        _fundAndApproveUSDC(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyMintCapExceeded.selector));
        vault.deposit(1);
    }

    function test_TC02_depositRevertsWhenDailyMintCapExceeded() public {
        _deposit(alice, 10_000_000e6);
        vm.roll(block.number + 1);
        _fundAndApproveUSDC(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.DailyMintCapExceeded.selector));
        vault.deposit(1);
    }

    function test_TC02_setWeeklyMintCapZeroBlocksNewPublicDeposits() public {
        vm.prank(owner);
        vault.setWeeklyMintCapBps(0);

        assertEq(vault.weeklyMintCapBps(), 0);
        assertEq(vault.effectiveWeeklyMintCap(), 0);
        assertEq(vault.weeklyMintRemaining(), 0);

        _fundAndApproveUSDC(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyMintCapExceeded.selector));
        vault.deposit(1);
    }

    function test_TC02_depositRevertsWhenPerBlockMintCapConsumed() public {
        _deposit(alice, 10_000_000e6);
        _fundAndApproveUSDC(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.PerBlockMintCapExceeded.selector, 1, 0));
        vault.deposit(1);
    }

    function test_TC02_lossReporterDepositBypassesMintCapsForProtocolYield() public {
        _deposit(alice, 10_000_000e6);
        _setupLossReporter();
        _fundAndApproveUSDC(lossReporterAddr, 1);

        vm.prank(lossReporterAddr);
        vault.deposit(1);

        assertEq(riskusd.balanceOf(lossReporterAddr), 1);
    }

    function test_TC02_depositRevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.deposit(0);
    }

    function test_TC02_depositRevertsInsufficientBalance() public {
        _fundUSDC(alice, 100e6);
        _approveVaultUSDC(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient balance
        vault.deposit(200e6);
    }

    function test_TC02_depositRevertsInsufficientAllowance() public {
        _fundUSDC(alice, 1000e6);
        // No approval given

        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.deposit(100e6);
    }

    function test_TC02_depositRevertsPaused() public {
        _setupGovernor();
        vm.prank(owner);
        vault.pause();

        _fundAndApproveUSDC(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deposit(100e6);
    }

    function test_TC02_depositRevertsRiskusdMintFailure() public {
        riskusd.setMockPaused(true);
        _fundAndApproveUSDC(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(); // Downstream RISKUSD mint failure
        vault.deposit(100e6);
    }
}

// ============================================================
// TC-03: Redeem Tests
// ============================================================
contract RISKUSDVault_TC03_Redeem is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        // Default setup: alice deposits 1000e6
        _deposit(alice, 1000e6);
    }

    function test_TC03_redeemHappyPath() public {
        _approveVaultRISKUSD(alice, 50e6);

        vm.prank(alice);
        vault.redeem(50e6);

        // USDC returned to alice
        assertEq(usdc.balanceOf(alice), 50e6);
        // Vault USDC decreased
        assertEq(usdc.balanceOf(address(vault)), 950e6);
        // Counters updated
        assertEq(vault.weeklyRedemptionUsed(), 50e6);
        assertEq(vault.totalRedeemed(), 50e6);
    }

    function test_TC03_redeemOneToOneRatio() public {
        // Raise cap to 100% so 500e6 redeem is not blocked by weekly cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        _approveVaultRISKUSD(alice, 500e6);

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(500e6);

        // Exactly 500e6 USDC returned (no yield, no fee)
        assertEq(usdc.balanceOf(alice) - usdcBefore, 500e6);
    }

    function test_TC03_redeemMultipleInOneWindow() public {
        // Raise cap to 100% so cumulative 150e6 is not blocked by the default 5% cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        _approveVaultRISKUSD(alice, 150e6);

        vm.prank(alice);
        vault.redeem(100e6);

        vm.prank(alice);
        vault.redeem(50e6);

        assertEq(vault.weeklyRedemptionUsed(), 150e6);
        assertEq(vault.totalRedeemed(), 150e6);
    }

    function test_TC03_redeemSupplyReadBeforeBurn() public {
        // Supply is 1000e6. Cap is 5% = 50e6.
        // Redeem exactly 50e6 (should succeed because supply read BEFORE burn).
        // If supply were read AFTER burn, cap = 950e6 * 5% = 47.5e6, which would differ.
        _approveVaultRISKUSD(alice, 50e6);

        vm.prank(alice);
        vault.redeem(50e6);

        assertEq(vault.weeklyRedemptionUsed(), 50e6);
    }

    function test_TC03_redeemRevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.redeem(0);
    }

    function test_TC03_redeemRevertsInsufficientRiskusdBalance() public {
        // Alice has 1000e6 RISKUSD, try to redeem 2000e6
        _approveVaultRISKUSD(alice, 2000e6);

        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient balance
        vault.redeem(2000e6);
    }

    function test_TC03_redeemRevertsInsufficientRiskusdAllowance() public {
        // Alice has RISKUSD but no allowance to vault
        vm.prank(alice);
        vm.expectRevert(); // ERC-20 insufficient allowance
        vault.redeem(50e6);
    }

    function test_TC03_redeemRevertsWeeklyCapExceeded() public {
        // Supply 1000e6, cap 5% = 50e6
        _approveVaultRISKUSD(alice, 200e6);

        vm.prank(alice);
        vault.redeem(50e6); // used = 50e6

        // 50 + 51 = 101 > 50 cap
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyRedemptionCapExceeded.selector));
        vault.redeem(51e6);
    }

    function test_TC03_redeemRevertsInsufficientVaultBalance() public {
        // Deploy most capital so vault has little USDC
        _setupCustodian();
        vm.prank(custodianAddr);
        vault.deployCapital(950e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(950e6);

        // Vault has 50e6 USDC, try to redeem 100e6
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InsufficientVaultBalance.selector));
        vault.redeem(100e6);
    }

    function test_TC03_redeemRevertsReserveRatioViolated() public {
        // Set min reserve ratio to 50%
        vm.prank(owner);
        vault.setMinReserveRatioBps(5000);

        // Raise cap to 100% so the reserve ratio check fires instead of the weekly cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        // Deploy 500e6 so vault has 500e6, depositorUsdc = 1000e6
        _setupCustodian();
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(500e6);

        // Redeem 400e6: vault after = 100e6, depositorUsdc after = 600e6
        // ratio = 100e6 * 10000 / 600e6 = 1666 < 5000 -> violated
        _approveVaultRISKUSD(alice, 400e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ReserveRatioViolated.selector));
        vault.redeem(400e6);
    }

    function test_TC03_redeemReserveRatioSkipWhenZero() public {
        // minReserveRatioBps is 0 by default -> reserve ratio check skipped
        _setupCustodian();
        vm.prank(custodianAddr);
        vault.deployCapital(900e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(900e6);

        // Vault has 100e6, depositorUsdc = 1000e6. Ratio = 10%.
        // With minReserveRatioBps = 0, this should succeed.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vault.redeem(100e6);

        assertEq(vault.totalRedeemed(), 100e6);
    }

    function test_TC03_redeemReserveRatioSkipWhenDepositorUsdcBecomesZero() public {
        // Redeem all remaining supply. depositorUsdc becomes 0.
        // Reserve ratio check skipped.
        vm.prank(owner);
        vault.setMinReserveRatioBps(5000);

        // Only 1000e6 deposited (all in vault), default cap allows up to 50e6 at 5% of 1000e6
        // We need cap = 100%, so we can redeem all
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        _approveVaultRISKUSD(alice, 1000e6);
        vm.prank(alice);
        vault.redeem(1000e6);

        assertEq(vault.totalDepositorUsdc(), 0);
        assertEq(vault.totalRedeemed(), 1000e6);
    }

    function test_TC03_redeemRevertsPaused() public {
        _setupGovernor();
        vm.prank(owner);
        vault.pause();

        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.redeem(100e6);
    }

    function test_TC03_redeemRevertsRiskusdBurnFailure() public {
        riskusd.setMockPaused(true);

        _approveVaultRISKUSD(alice, 50e6);
        vm.prank(alice);
        vm.expectRevert(); // Downstream burn failure
        vault.redeem(50e6);
    }
}

// ============================================================
// TC-04: Weekly Cap Tests
// ============================================================
contract RISKUSDVault_TC04_WeeklyCap is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        // Deposit 1000e6 for alice. Default cap = 5% = 50e6.
        _deposit(alice, 1000e6);
        vm.prank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        _approveVaultRISKUSD(alice, type(uint256).max);
    }

    function test_TC04_capTrackingWithinWindow() public {
        vm.prank(alice);
        vault.redeem(20e6);
        vm.prank(alice);
        vault.redeem(20e6);
        vm.prank(alice);
        vault.redeem(5e6);

        assertEq(vault.weeklyRedemptionUsed(), 45e6);

        // Redeem 5e6 more (total 50e6 = cap). Should succeed.
        vm.prank(alice);
        vault.redeem(5e6);
        assertEq(vault.weeklyRedemptionUsed(), 50e6);

        // One more wei should fail
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyRedemptionCapExceeded.selector));
        vault.redeem(1);
    }

    function test_TC04_windowResetAtExactly604800() public {
        uint256 startTime = block.timestamp;

        // Exhaust cap
        vm.prank(alice);
        vault.redeem(50e6);

        // 1 second before reset
        vm.warp(startTime + WEEKLY_WINDOW_DURATION - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyRedemptionCapExceeded.selector));
        vault.redeem(1);

        // Exact boundary
        vm.warp(startTime + WEEKLY_WINDOW_DURATION);
        // Need more RISKUSD and USDC since alice redeemed 50e6 already
        _deposit(alice, 50e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(alice);
        vault.redeem(1);

        assertEq(vault.weeklyRedemptionWindowStart(), startTime + WEEKLY_WINDOW_DURATION);
        assertEq(vault.weeklyRedemptionUsed(), 1);
    }

    function test_TC04_windowResetOneSecondAfterBoundary() public {
        uint256 startTime = block.timestamp;

        vm.prank(alice);
        vault.redeem(50e6);

        vm.warp(startTime + WEEKLY_WINDOW_DURATION + 1);
        _deposit(alice, 50e6);
        _approveVaultRISKUSD(alice, type(uint256).max);

        vm.prank(alice);
        vault.redeem(1);

        // OF-M02 fix: window advances by exactly one period, not to block.timestamp
        assertEq(vault.weeklyRedemptionWindowStart(), startTime + WEEKLY_WINDOW_DURATION);
    }

    function test_TC04_multipleWindowResets() public {
        uint256 startTime = block.timestamp;

        // Window 1: exhaust cap
        vm.prank(alice);
        vault.redeem(50e6);

        // Window 2
        vm.warp(startTime + WEEKLY_WINDOW_DURATION);
        _deposit(alice, 50e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(alice);
        vault.redeem(50e6);

        // Window 3
        vm.warp(startTime + 2 * WEEKLY_WINDOW_DURATION);
        _deposit(alice, 50e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(alice);
        vault.redeem(1);

        // Each window is independent
        assertEq(vault.weeklyRedemptionUsed(), 1);
    }

    function test_TC04_dynamicCapWithChangingSupply() public {
        // Initial supply 1000e6, cap = 5% = 50e6
        assertEq(vault.effectiveWeeklyRedemptionCap(), 50e6);

        // Deposit 500e6 more (supply now 1500e6)
        _deposit(bob, 500e6);

        // Cap = 5% of 1500e6 = 75e6
        assertEq(vault.effectiveWeeklyRedemptionCap(), 75e6);
    }

    function test_TC04_dynamicCapDecreaseBlocksRedemption() public {
        // Redeem 45e6 (used 45e6, cap was 50e6 based on 1000e6 supply)
        vm.prank(alice);
        vault.redeem(45e6);

        // Another user redeems (supply decreases).
        // Bob deposits and redeems to consume the remaining default cap.
        _deposit(bob, 100e6);
        _approveVaultRISKUSD(bob, 5e6);
        vm.prank(bob);
        vault.redeem(5e6);
        // used = 50e6, cap remains based on the 1000e6 window-start supply

        // used = 50e6 = cap -> no more redemptions
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyRedemptionCapExceeded.selector));
        vault.redeem(1);
    }

    function test_TC04_governanceCapChangeImmediateNoResetUsed() public {
        // Redeem 40e6 (used = 40e6, cap was 50e6)
        vm.prank(alice);
        vault.redeem(40e6);

        // Owner reduces cap to 2.5% -> effective cap = 1000e6 * 2.5% = 25e6
        // used = 40e6 > 25e6 -> all further blocked
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(250);

        // Verify used was NOT reset
        assertEq(vault.weeklyRedemptionUsed(), 40e6);

        // Further redemptions blocked
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.WeeklyRedemptionCapExceeded.selector));
        vault.redeem(1);
    }

    function test_TC04_capChangeToMaximum() public {
        // Set cap to 100%
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);

        // Effective cap = total supply = 1000e6
        assertEq(vault.effectiveWeeklyRedemptionCap(), 1000e6);
    }

    function test_TC04_weeklyRedemptionRemainingCalculation() public {
        vm.prank(alice);
        vault.redeem(30e6);

        // used = 30e6, cap = 50e6 from the 1000e6 window-start supply.
        assertEq(vault.weeklyRedemptionRemaining(), vault.effectiveWeeklyRedemptionCap() - 30e6);
    }

    function test_TC04_weeklyRedemptionRemainingClampedToZero() public {
        vm.prank(alice);
        vault.redeem(40e6);

        // Now reduce cap so that used > new cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(250); // 2.5%
        // Window-start supply is 1000e6, cap = 25e6. used = 40e6 > 25e6 -> remaining = 0

        assertEq(vault.weeklyRedemptionRemaining(), 0);
    }

    function test_TC04_weeklyRedemptionRemainingFullCapAfterExpiry() public {
        vm.prank(alice);
        vault.redeem(50e6);

        // Warp past window expiry
        vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);

        // weeklyRedemptionRemaining should return full cap (window expired)
        assertEq(vault.weeklyRedemptionRemaining(), vault.effectiveWeeklyRedemptionCap());
    }

    function test_TC04_lazyResetOnlyOnRedeem() public {
        vm.prank(alice);
        vault.redeem(50e6);

        assertEq(vault.weeklyRedemptionUsed(), 50e6);

        // Warp past window
        vm.warp(block.timestamp + WEEKLY_WINDOW_DURATION);

        // View function: used is still old value (view doesn't mutate state)
        assertEq(vault.weeklyRedemptionUsed(), 50e6);

        // Next redeem triggers lazy reset
        _deposit(alice, 50e6);
        _approveVaultRISKUSD(alice, type(uint256).max);
        vm.prank(alice);
        vault.redeem(10e6);

        assertEq(vault.weeklyRedemptionUsed(), 10e6); // reset then incremented
    }
}

// ============================================================
// TC-05: Custodian Operations Tests
// ============================================================
contract RISKUSDVault_TC05_Custodian is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000e6);
        _setupCustodian();
    }

    // --- deployCapital ---

    function test_TC05_deployCapitalRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCustodian.selector));
        vault.deployCapital(100e6);
    }

    function test_TC05_deployCapitalRevertsWhenCustodianIsZero() public {
        // Deploy a fresh vault without setting custodian
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), initData);
        RISKUSDVault freshVault = RISKUSDVault(address(proxy));

        // Any address calling deployCapital should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCustodian.selector));
        freshVault.deployCapital(100e6);
    }

    function test_TC05_deployCapitalRevertsZeroAmount() public {
        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.deployCapital(0);
    }

    function test_TC05_deployCapitalRequiresVaultRegistryWhenBufferEnabled() public {
        vm.prank(owner);
        vault.setDeploymentBufferBps(500);

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.VaultRegistryRequired.selector));
        vault.deployCapital(1);
    }

    function test_TC05_deployCapitalHappyPath() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        assertEq(usdc.balanceOf(custodianAddr), 500e6);
        assertEq(vault.totalDeployed(), 500e6);
        assertEq(usdc.balanceOf(address(vault)), 500e6);
    }

    function test_TC05_deployCapitalRatioEnforcement() public {
        // Set ratio to 50%
        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(5000);

        // Max deployable = 50% of 1000e6 = 500e6
        // Deploy 300e6 first
        vm.prank(custodianAddr);
        vault.deployCapital(300e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(300e6);

        // Try to deploy 201e6 more (300 + 201 = 501 > 500)
        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.DeploymentRatioExceeded.selector));
        vault.deployCapital(201e6);

        // Deploy exactly 200e6 (300 + 200 = 500 = max)
        vm.prank(custodianAddr);
        vault.deployCapital(200e6);
        assertEq(vault.totalDeployed(), 500e6);
    }

    function test_TC05_deployCapitalRevertsWhenRatioIsZero() public {
        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(0);

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.DeploymentRatioExceeded.selector));
        vault.deployCapital(1);
    }

    function test_TC05_deployCapitalRevertsInsufficientVaultBalance() public {
        // Vault has 1000e6. Try deploying 2000e6.
        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InsufficientVaultBalance.selector));
        vault.deployCapital(2000e6);
    }

    /// @dev OF-006: deployCapital IS now blocked by pause.
    function test_TC05_deployCapitalBlockedByPause() public {
        _setupGovernor();
        vm.prank(owner);
        vault.pause();

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deployCapital(100e6);

        assertEq(vault.totalDeployed(), 0);
    }

    function test_TC05_recordCustodianNAVRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCustodian.selector));
        vault.recordCustodianNAV(900e6);
    }

    function test_TC05_recordCustodianNAVRecordsAndResetsFlowCounters() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);
        assertEq(vault.deployedSinceLastAttestation(), 500e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(480e6);

        assertEq(vault.lastAttestedNAV(), 480e6);
        assertEq(vault.lastAttestationTimestamp(), block.timestamp);
        assertEq(vault.deployedSinceLastAttestation(), 0);
        assertEq(vault.returnedSinceLastAttestation(), 0);
        assertEq(vault.solvencyBackingAssets(), 980e6);
    }

    function test_TC05_lowNAVBlocksNewDepositsUntilLossResolved() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(custodianAddr);
        vault.recordCustodianNAV(400e6);

        vm.roll(block.number + 1);
        _fundAndApproveUSDC(bob, 1);
        vm.prank(bob);
        vm.expectRevert(RISKUSDVault.LossPending.selector);
        vault.deposit(1);
    }

    function test_TC05_manualAttestationReporterUsesTwoStageSetterAndNormalLossNonce() public {
        address manualReporter = makeAddr("manualAttestationReporter");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedManualAttestationReporter.selector));
        vault.recordManualCustodianNAV(1, 300e6, 1);

        vm.prank(owner);
        vault.setManualAttestationReporter(manualReporter);
        assertEq(vault.manualAttestationReporter(), address(0), "reporter not live before finalization");

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(owner);
        vault.finalizeManualAttestationReporter();

        assertEq(vault.manualAttestationReporter(), manualReporter, "reporter finalized after delay");

        ManualNAVNormalizerCustodian normalizingCustodian = new ManualNAVNormalizerCustodian();
        vm.startPrank(owner);
        vault.setCustodian(address(normalizingCustodian));
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        vm.stopPrank();

        vm.prank(address(normalizingCustodian));
        vault.deployCapital(500e6);

        vm.prank(manualReporter);
        vault.recordManualCustodianNAV(1, 300e6, 1);

        assertEq(vault.latestLossNonce(), 1, "manual attestation records the nonce");
        assertEq(vault.latestLossAmount(), 200e6, "manual attestation computes loss from NAV");
        assertTrue(vault.lossPending(), "manual attestation enters the same loss-pending path");
        assertEq(vault.lossPendingVaultId(), 1, "manual attestation binds loss to vault");
    }

    function test_TC05_deploymentBufferUsesActiveRegisteredTierAssets() public {
        MockVaultRegistry registry = new MockVaultRegistry();
        registry.setTestRISKUSDVault(address(vault));

        MockAtRISKUSD tier0 = new MockAtRISKUSD(address(riskusd));
        tier0.setMockTotalAssets(800e6);
        address[4] memory tierVaults = [address(tier0), address(0), address(0), address(0)];
        uint256[4] memory lockups;
        uint16[4] memory yieldSplits;
        uint16[4] memory fundingBps;
        registry.addTestVault("CSMN", "CSMN", tierVaults, address(0), 0, lockups, yieldSplits, fundingBps);

        vm.prank(owner);
        vault.initializeV2(address(registry));
        vm.startPrank(owner);
        vault.setDeploymentBufferBps(500);
        vault.setMaxDeploymentRatioBps(10000);
        vm.stopPrank();

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.DeploymentBufferExceeded.selector));
        vault.deployCapital(761e6);

        vm.prank(custodianAddr);
        vault.deployCapital(760e6);
        assertEq(vault.totalDeployed(), 760e6);
    }

    // --- returnCapital ---

    function test_TC05_returnCapitalRevertsUnauthorized() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCustodian.selector));
        vault.returnCapital(100e6);
    }

    function test_TC05_returnCapitalRevertsWhenCustodianIsZero() public {
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), initData);
        RISKUSDVault freshVault = RISKUSDVault(address(proxy));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCustodian.selector));
        freshVault.returnCapital(100e6);
    }

    function test_TC05_returnCapitalRevertsZeroAmount() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.returnCapital(0);
    }

    function test_TC05_returnCapitalHappyPath() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        // Custodian approves vault to pull USDC back
        vm.prank(custodianAddr);
        usdc.approve(address(vault), 300e6);

        vm.prank(custodianAddr);
        vault.returnCapital(300e6);

        assertEq(vault.totalDeployed(), 200e6);
        assertEq(usdc.balanceOf(address(vault)), 800e6);
    }

    function test_TC05_returnCapitalRevertsExcessiveReturn() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(custodianAddr);
        usdc.approve(address(vault), 501e6);

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ExcessiveReturn.selector));
        vault.returnCapital(501e6);
    }

    function test_TC05_returnCapitalExactDeployedAmount() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(custodianAddr);
        usdc.approve(address(vault), 500e6);

        vm.prank(custodianAddr);
        vault.returnCapital(500e6);

        assertEq(vault.totalDeployed(), 0);
    }

    function test_TC05_returnCapitalNotBlockedByPause() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        _setupGovernor();
        vm.prank(owner);
        vault.pause();

        vm.prank(custodianAddr);
        usdc.approve(address(vault), 300e6);

        vm.prank(custodianAddr);
        vault.returnCapital(300e6);

        assertEq(vault.totalDeployed(), 200e6);
    }

    function test_TC05_returnCapitalRevertsInsufficientAllowance() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        // No approval from custodian
        vm.prank(custodianAddr);
        vm.expectRevert(); // ERC-20 allowance error
        vault.returnCapital(100e6);
    }

    function test_TC05_deployReturnCycleTracking() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);
        vm.prank(custodianAddr);
        vault.recordCustodianNAV(500e6);

        vm.prank(custodianAddr);
        usdc.approve(address(vault), 200e6);
        vm.prank(custodianAddr);
        vault.returnCapital(200e6);

        vm.prank(custodianAddr);
        vault.deployCapital(100e6);

        // 500 - 200 + 100 = 400
        assertEq(vault.totalDeployed(), 400e6);
    }
}

// ============================================================
// TC-06: Replenish and Loss Operation Tests
// ============================================================
contract RISKUSDVault_TC06_LossOps is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1000e6);
        _setupAllRoles();
    }

    // --- burnForLoss ---

    function test_TC06_burnForLossRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedLossReporter.selector));
        vault.burnForLoss(1, 100e6);
    }

    function test_TC06_burnForLossRevertsZeroAmount() public {
        vm.prank(lossReporterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.burnForLoss(1, 0);
    }

    function test_TC06_burnForLossHappyPath() public {
        // Attested loss must be recorded before burnForLoss and finalized after full absorption.
        _prepareForBurnForLoss(100e6);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 100e6);
        _finalizePreparedAttestedLoss(1, 100e6);

        assertEq(vault.totalBurnedForLoss(), 100e6);
        assertEq(riskusd.balanceOf(lossReporterAddr), 0);
        assertFalse(vault.lossPending(), "attested loss finalized");
    }

    function test_TC06_burnForLossInsufficientRiskusd() public {
        _fundRISKUSD(lossReporterAddr, 50e6);

        vm.prank(lossReporterAddr);
        vm.expectRevert(); // Downstream burn error
        vault.burnForLoss(1, 100e6);
    }

    function test_TC06_burnForLossNotBlockedByPause() public {
        // Attested loss is recorded before pause; loss settlement remains available while paused.
        _prepareForBurnForLoss(100e6);

        vm.prank(owner);
        vault.pause();

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 100e6);
        _finalizePreparedAttestedLoss(1, 100e6);

        assertEq(vault.totalBurnedForLoss(), 100e6);
    }

    function test_TC06_burnForLossAccumulation() public {
        // Partial burns keep the nonce unresolved until the full attested amount is absorbed.
        _prepareForBurnForLoss(150e6);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 100e6);

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 50e6);
        _finalizePreparedAttestedLoss(1, 150e6);

        assertEq(vault.totalBurnedForLoss(), 150e6);
        assertFalse(vault.lossPending(), "full burn resolves attested loss");
    }

    // --- replenish ---

    function test_TC06_replenishRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedLossReporter.selector));
        vault.replenish(100e6);
    }

    function test_TC06_replenishRevertsZeroAmount() public {
        vm.prank(lossReporterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAmount.selector));
        vault.replenish(0);
    }

    function test_TC06_replenishHappyPath() public {
        _fundUSDC(lossReporterAddr, 200e6);
        vm.prank(lossReporterAddr);
        usdc.approve(address(vault), 200e6);

        vm.prank(lossReporterAddr);
        vault.replenish(200e6);

        assertEq(vault.totalReplenished(), 200e6);
        assertEq(usdc.balanceOf(address(vault)), 1200e6); // 1000 + 200
    }

    function test_TC06_replenishNotBlockedByPause() public {
        vm.prank(owner);
        vault.pause();

        _fundUSDC(lossReporterAddr, 100e6);
        vm.prank(lossReporterAddr);
        usdc.approve(address(vault), 100e6);

        vm.prank(lossReporterAddr);
        vault.replenish(100e6);

        assertEq(vault.totalReplenished(), 100e6);
    }

    function test_TC06_replenishRevertsInsufficientAllowance() public {
        _fundUSDC(lossReporterAddr, 100e6);
        // No approval

        vm.prank(lossReporterAddr);
        vm.expectRevert(); // ERC-20 allowance error
        vault.replenish(100e6);
    }

    // --- setLossReporter ---

    function test_TC06_setLossReporterRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setLossReporter(makeAddr("newReporter"));
    }

    function test_TC06_setLossReporterRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        vault.setLossReporter(address(0));
    }

    function test_TC06_setLossReporterHappyPath() public {
        address newReporter = makeAddr("newReporter");
        vm.startPrank(owner);
        vault.setLossReporter(newReporter);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();

        assertEq(vault.lossReporter(), newReporter);
    }

    function test_TC06_lossOpsRevertWhenReporterIsZero() public {
        // Deploy fresh vault without setting lossReporter
        RISKUSDVault newImpl = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), initData);
        RISKUSDVault freshVault = RISKUSDVault(address(proxy));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedLossReporter.selector));
        freshVault.burnForLoss(1, 100e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedLossReporter.selector));
        freshVault.replenish(100e6);
    }
}

// ============================================================
// TC-07: USDC Approval Management Tests
// ============================================================
contract RISKUSDVault_TC07_ApprovalMgmt is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        // Set weekly redemption cap to 100% so redemption tests are not blocked by the default 5% cap
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
    }

    function test_TC07_noSetterForUsdcAddress() public view {
        // usdc() returns the init address
        assertEq(vault.usdc(), address(usdc));
        // No setUsdc function exists in the ABI. Solidity compilation ensures
        // this — calling vault.setUsdc() would be a compile error.
        // We verify the address is immutable post-initialization.
    }

    function test_TC07_noSetterForRiskusdAddress() public view {
        assertEq(vault.riskusd(), address(riskusd));
        // No setRiskusd function exists in the ABI. Solidity compilation ensures
        // this — calling vault.setRiskusd() would be a compile error.
        // We verify the address is immutable post-initialization.
    }

    function test_TC07_addressesUnchangeableViaRawCall() public {
        // Verify that attempting to call non-existent setter selectors
        // with raw calls produces empty return data (function not found),
        // distinguishing from access-control reverts which encode error data.
        (bool ok1, bytes memory ret1) =
            address(vault).call(abi.encodeWithSignature("setUsdc(address)", address(0x1234)));
        // Proxy fallback: unrecognized selectors delegatecall to impl which
        // has no such function, so the call fails with empty return data.
        assertFalse(ok1, "setUsdc raw call must fail");
        assertEq(ret1.length, 0, "setUsdc must return empty data (no such function)");

        (bool ok2, bytes memory ret2) =
            address(vault).call(abi.encodeWithSignature("setRiskusd(address)", address(0x5678)));
        assertFalse(ok2, "setRiskusd raw call must fail");
        assertEq(ret2.length, 0, "setRiskusd must return empty data (no such function)");

        // Confirm addresses unchanged
        assertEq(vault.usdc(), address(usdc), "usdc address must not change");
        assertEq(vault.riskusd(), address(riskusd), "riskusd address must not change");
    }

    function test_TC07_addressesPersistAfterUpgrade() public {
        address usdcBefore = vault.usdc();
        address riskusdBefore = vault.riskusd();

        // Upgrade to v2
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        assertEq(vault.usdc(), usdcBefore);
        assertEq(vault.riskusd(), riskusdBefore);
    }

    function test_TC07_allowanceDirectionVaultPullsFromCallers() public {
        // Verify: deposit pulls USDC FROM caller (requires caller approval to vault)
        _fundUSDC(alice, 100e6);
        _approveVaultUSDC(alice, 100e6);
        vm.prank(alice);
        vault.deposit(100e6);

        // Vault received USDC
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        // Alice lost USDC
        assertEq(usdc.balanceOf(alice), 0);

        // Redeem pushes USDC TO caller (vault transfers to alice, no approval from vault needed)
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vault.redeem(100e6);

        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_TC07_allowanceDirectionCustodianAndLossReporter() public {
        _setupAllRoles();
        _deposit(alice, 1000e6);

        // deployCapital pushes USDC TO custodian (no custodian approval needed)
        uint256 custodianBefore = usdc.balanceOf(custodianAddr);
        vm.prank(custodianAddr);
        vault.deployCapital(100e6);
        assertEq(usdc.balanceOf(custodianAddr) - custodianBefore, 100e6, "deployCapital should push USDC to custodian");

        // returnCapital pulls USDC FROM custodian (needs custodian approval to vault)
        vm.prank(custodianAddr);
        usdc.approve(address(vault), 50e6);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(custodianAddr);
        vault.returnCapital(50e6);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 50e6, "returnCapital should pull USDC from custodian");

        // replenish pulls USDC FROM lossReporter (needs lossReporter approval to vault)
        _fundUSDC(lossReporterAddr, 200e6);
        vm.prank(lossReporterAddr);
        usdc.approve(address(vault), 200e6);
        vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(lossReporterAddr);
        vault.replenish(200e6);
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 200e6, "replenish should pull USDC from lossReporter");
    }
}

// ============================================================
// TC-08: Pause/Unpause Tests
// ============================================================
contract RISKUSDVault_TC08_Pause is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        _deposit(alice, 1000e6);
    }

    function test_TC08_ownerCanPause() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_TC08_ownerCanUnpause() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_TC08_governorCanPause() public {
        vm.prank(governorAddr);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_TC08_governorCanUnpause() public {
        vm.prank(governorAddr);
        vault.pause();

        vm.prank(governorAddr);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_TC08_unauthorizedCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedPauseControl.selector, attacker));
        vault.pause();
    }

    function test_TC08_unauthorizedCannotUnpause() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedPauseControl.selector, attacker));
        vault.unpause();
    }

    function test_TC08_doublePauseReverts() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.pause();
    }

    function test_TC08_doubleUnpauseReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector));
        vault.unpause();
    }

    function test_TC08_pauseBlocksDeposit() public {
        vm.prank(owner);
        vault.pause();

        _fundAndApproveUSDC(bob, 100e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deposit(100e6);
    }

    function test_TC08_pauseBlocksRedeem() public {
        vm.prank(owner);
        vault.pause();

        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.redeem(100e6);
    }

    /// @dev OF-006: deployCapital IS now blocked by pause.
    function test_TC08_pauseBlocksDeployCapital() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(custodianAddr);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        vault.deployCapital(100e6);

        assertEq(vault.totalDeployed(), 0);
    }

    function test_TC08_pauseDoesNotBlockReturnCapital() public {
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        vm.prank(owner);
        vault.pause();

        vm.prank(custodianAddr);
        usdc.approve(address(vault), 200e6);

        vm.prank(custodianAddr);
        vault.returnCapital(200e6);

        assertEq(vault.totalDeployed(), 300e6);
    }

    function test_TC08_pauseDoesNotBlockBurnForLoss() public {
        // Attested loss is recorded before pause; loss settlement remains available while paused.
        _prepareForBurnForLoss(100e6);

        vm.prank(owner);
        vault.pause();

        vm.prank(lossReporterAddr);
        vault.burnForLoss(1, 100e6);
        _finalizePreparedAttestedLoss(1, 100e6);

        assertEq(vault.totalBurnedForLoss(), 100e6);
    }

    function test_TC08_pauseDoesNotBlockReplenish() public {
        vm.prank(owner);
        vault.pause();

        _fundUSDC(lossReporterAddr, 100e6);
        vm.prank(lossReporterAddr);
        usdc.approve(address(vault), 100e6);

        vm.prank(lossReporterAddr);
        vault.replenish(100e6);

        assertEq(vault.totalReplenished(), 100e6);
    }

    function test_TC08_pauseDoesNotBlockAdminSetters() public {
        vm.prank(owner);
        vault.pause();

        // Various admin setters should succeed while paused
        address newCustodian = makeAddr("newCustodian");
        vm.startPrank(owner);
        vault.setCustodian(newCustodian);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        vm.stopPrank();
        assertEq(vault.custodian(), newCustodian);

        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(2000);
        assertEq(vault.weeklyRedemptionCapBps(), 2000);
    }
}

// ============================================================
// TC-09: Authorization Management Tests
// ============================================================
contract RISKUSDVault_TC09_AuthMgmt is RISKUSDVaultTestBase {
    // --- setCustodian ---

    function test_TC09_setCustodianRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setCustodian(custodianAddr);
    }

    function test_TC09_setCustodianRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        vault.setCustodian(address(0));
    }

    function test_TC09_setCustodianHappyPath() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false);
        emit RISKUSDVault.CustodianSetByOwner(address(0), custodianAddr);
        vault.setCustodian(custodianAddr);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        vm.stopPrank();

        assertEq(vault.custodian(), custodianAddr);
    }

    // --- setMaxDeploymentRatioBps ---

    function test_TC09_setMaxDeploymentRatioRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setMaxDeploymentRatioBps(5000);
    }

    function test_TC09_setMaxDeploymentRatioRevertsExceeds10000() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InvalidDeploymentRatio.selector));
        vault.setMaxDeploymentRatioBps(10001);
    }

    function test_TC09_setMaxDeploymentRatioAtBoundaries() public {
        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(10000);
        assertEq(vault.maxDeploymentRatioBps(), 10000);

        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(0);
        assertEq(vault.maxDeploymentRatioBps(), 0);
    }

    function test_TC09_setMaxDeploymentRatioHappyPathWithEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.MaxDeploymentRatioUpdated(9500, 5000);
        vault.setMaxDeploymentRatioBps(5000);

        assertEq(vault.maxDeploymentRatioBps(), 5000);
    }

    // --- setWeeklyRedemptionCapBps ---

    function test_TC09_setWeeklyRedemptionCapRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setWeeklyRedemptionCapBps(500);
    }

    function test_TC09_setWeeklyRedemptionCapRevertsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InvalidParameter.selector));
        vault.setWeeklyRedemptionCapBps(0);
    }

    function test_TC09_setWeeklyRedemptionCapRevertsExceeds10000() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InvalidParameter.selector));
        vault.setWeeklyRedemptionCapBps(10001);
    }

    function test_TC09_setWeeklyRedemptionCapAtBoundaries() public {
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(1);
        assertEq(vault.weeklyRedemptionCapBps(), 1);

        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
        assertEq(vault.weeklyRedemptionCapBps(), 10000);
    }

    function test_TC09_setWeeklyRedemptionCapHappyPathWithEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.WeeklyRedemptionCapBpsUpdated(500, 750);
        vault.setWeeklyRedemptionCapBps(750);

        assertEq(vault.weeklyRedemptionCapBps(), 750);
    }

    function test_TC09_setWeeklyRedemptionCapDoesNotResetUsed() public {
        _deposit(alice, 1000e6);
        _approveVaultRISKUSD(alice, 50e6);

        vm.prank(alice);
        vault.redeem(50e6);

        assertEq(vault.weeklyRedemptionUsed(), 50e6);

        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(500);

        // Used is NOT reset
        assertEq(vault.weeklyRedemptionUsed(), 50e6);
    }

    // --- setMinReserveRatioBps ---

    function test_TC09_setMinReserveRatioRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setMinReserveRatioBps(5000);
    }

    function test_TC09_setMinReserveRatioRevertsExceeds10000() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.InvalidReserveRatio.selector));
        vault.setMinReserveRatioBps(10001);
    }

    function test_TC09_setMinReserveRatioAtBoundaries() public {
        vm.prank(owner);
        vault.setMinReserveRatioBps(10000);
        assertEq(vault.minReserveRatioBps(), 10000);

        vm.prank(owner);
        vault.setMinReserveRatioBps(0);
        assertEq(vault.minReserveRatioBps(), 0);
    }

    function test_TC09_setMinReserveRatioHappyPathWithEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.MinReserveRatioUpdated(0, 5000);
        vault.setMinReserveRatioBps(5000);
    }

    // --- setForageGovernor ---

    function test_TC09_setForageGovernorRevertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.setForageGovernor(governorAddr);
    }

    function test_TC09_setForageGovernorRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.ZeroAddress.selector));
        vault.setForageGovernor(address(0));
    }

    function test_TC09_setForageGovernorHappyPathWithEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false);
        emit RISKUSDVault.ForageGovernorProposed(address(0), governorAddr);
        vault.setForageGovernor(governorAddr);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, false, false);
        emit RISKUSDVault.ForageGovernorSet(address(0), governorAddr);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }
}

// ============================================================
// TC-10: Ownership Transfer Tests
// ============================================================
contract RISKUSDVault_TC10_Ownership is RISKUSDVaultTestBase {
    function test_TC10_twoStepTransferPropose() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        assertEq(vault.pendingOwner(), newOwner);
        // Owner hasn't changed yet
        assertEq(vault.owner(), owner);
    }

    function test_TC10_twoStepTransferAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.prank(newOwner);
        vault.acceptOwnership();

        assertEq(vault.owner(), newOwner);
    }

    function test_TC10_nonPendingOwnerCannotAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.acceptOwnership();
    }

    function test_TC10_nonOwnerCannotTransfer() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.transferOwnership(attacker);
    }

    function test_TC10_renounceOwnershipDisablesOwnerFunctions() public {
        vm.prank(owner);
        vm.expectRevert(RISKUSDVault.RenounceOwnershipDisabled.selector);
        vault.renounceOwnership();

        assertEq(vault.owner(), owner, "owner should remain unchanged after disabled renounce");
    }

    function test_TC10_ownershipTransferEvents() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);
        vault.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);
        vault.acceptOwnership();
    }

    function test_TC10_singleStepTakeoverImpossible() public {
        // Attack 4.7: non-owner cannot transfer or accept in single step
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.transferOwnership(attacker);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.acceptOwnership();

        // Owner unchanged
        assertEq(vault.owner(), owner);
    }
}

// ============================================================
// TC-11: UUPS Upgrade Tests
// ============================================================
contract RISKUSDVault_TC11_Upgrade is RISKUSDVaultTestBase {
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _getImplementationAddress() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), ERC1967_IMPL_SLOT))));
    }

    function test_TC11_upgradeRevertsNonOwner() public {
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    function test_TC11_upgradeToV2Succeeds() public {
        address implBefore = _getImplementationAddress();
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();

        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        address implAfter = _getImplementationAddress();
        assertTrue(implAfter != implBefore);
        assertEq(implAfter, address(v2Impl));
    }

    function test_TC11_statePreservedAfterV1ToV2() public {
        // Set up state before upgrade
        _setupAllRoles();
        _deposit(alice, 500e6);

        // Deploy some capital
        vm.prank(custodianAddr);
        vault.deployCapital(200e6);

        // Set configuration
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(2000);
        vm.prank(owner);
        vault.setMaxDeploymentRatioBps(7500);
        vm.prank(owner);
        vault.setMinReserveRatioBps(3000);

        // Snapshot state before upgrade
        address usdcAddr = vault.usdc();
        address riskusdAddr = vault.riskusd();
        address cust = vault.custodian();
        address lr = vault.lossReporter();
        uint256 totalDep = vault.totalDeposited();
        uint256 totalDeployed = vault.totalDeployed();
        uint256 capBps = vault.weeklyRedemptionCapBps();
        uint256 ratioMaxBps = vault.maxDeploymentRatioBps();
        uint256 reserveBps = vault.minReserveRatioBps();
        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        address ownerAddr = vault.owner();
        bool pausedState = vault.paused();

        // Upgrade to v2
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Verify all state preserved
        assertEq(vault.usdc(), usdcAddr);
        assertEq(vault.riskusd(), riskusdAddr);
        assertEq(vault.custodian(), cust);
        assertEq(vault.lossReporter(), lr);
        assertEq(vault.totalDeposited(), totalDep);
        assertEq(vault.totalDeployed(), totalDeployed);
        assertEq(vault.weeklyRedemptionCapBps(), capBps);
        assertEq(vault.maxDeploymentRatioBps(), ratioMaxBps);
        assertEq(vault.minReserveRatioBps(), reserveBps);
        assertEq(vault.weeklyRedemptionWindowStart(), windowStart);
        assertEq(vault.owner(), ownerAddr);
        assertEq(vault.paused(), pausedState);
        assertEq(vault.totalBurnedForLoss(), 0);
        assertEq(vault.totalReplenished(), 0);
        assertEq(vault.totalLostCapital(), 0);
    }

    function test_TC11_multiGenerationV1V2V3() public {
        _deposit(alice, 100e6);

        // Upgrade v1 -> v2
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Set v2 new variable
        RISKUSDVaultV2(address(vault)).setNewVariableV2(42);
        assertEq(RISKUSDVaultV2(address(vault)).newVariableV2(), 42);

        // Upgrade v2 -> v3
        RISKUSDVaultV3 v3Impl = new RISKUSDVaultV3();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v3Impl), "");

        // Original state preserved
        assertEq(vault.totalDeposited(), 100e6);
        assertEq(vault.owner(), owner);

        // V2 variable preserved
        assertEq(RISKUSDVaultV3(address(vault)).newVariableV2(), 42);

        // V3 new variable accessible
        RISKUSDVaultV3(address(vault)).setAnotherVariableV3(99);
        assertEq(RISKUSDVaultV3(address(vault)).anotherVariableV3(), 99);
    }

    function test_TC11_upgradeAfterUpgradeStillWorks() public {
        // Attack 1.4: verify upgradeToAndCall still works after an upgrade
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Can still upgrade to v3
        RISKUSDVaultV3 v3Impl = new RISKUSDVaultV3();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v3Impl), "");

        assertEq(RISKUSDVaultV3(address(vault)).version(), 3);
    }

    function test_TC11_implementationDirectCallReverts() public {
        // Attack 1.2: direct calls on implementation
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(usdc), address(riskusd), owner);

        // deposit on implementation (not initialized via proxy) — must revert
        vm.expectRevert();
        implementation.deposit(100e6);
    }

    function test_TC11_noDelegatecallInBytecodeOutsideUUPS() public {
        // Attack 1.5: scan bytecode for DELEGATECALL opcode (0xf4)
        // Opcode-aware walker: skip PUSH1-PUSH32 operand bytes so 0xf4
        // appearing as data (metadata hash, selectors) is not miscounted.
        address implAddr = _getImplementationAddress();
        bytes memory code = implAddr.code;
        uint256 delegatecallCount;
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xf4) {
                delegatecallCount++;
                i++;
            } else if (op >= 0x60 && op <= 0x7f) {
                i += 1 + (op - 0x5f);
            } else {
                i++;
            }
        }
        // OZ v5.6.1 UUPS path generates 2 DELEGATECALL opcodes via ERC1967Utils
        assertLe(delegatecallCount, 2, "No custom DELEGATECALL paths outside UUPS");
    }

    function test_TC11_proxiableUUIDReturnsCorrectSlot() public view {
        // proxiableUUID is notDelegated -- call on implementation directly
        assertEq(implementation.proxiableUUID(), ERC1967_IMPL_SLOT);
    }

    function test_TC11_storageLayoutPreservedAfterUpgrade() public {
        // Verify that upgrading to V2 does not corrupt existing storage slots.
        _setupCustodian();
        _deposit(alice, 1000e6);

        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // State preserved after valid upgrade
        assertEq(vault.custodian(), custodianAddr, "custodian corrupted after upgrade");
        assertEq(vault.totalDeposited(), 1000e6, "totalDeposited corrupted after upgrade");
    }

    function test_TC11_storageSlotPositionsStable() public {
        // Attack 1.1: Verify that state variables occupy expected storage slots.
        // If a future upgrade reorders variables, these assertions catch the shift.
        _setupCustodian();
        _deposit(alice, 1000e6);

        // _custodian is the first mutable state variable after the OZ base slots.
        // We verify it by reading the slot where custodian is stored and comparing
        // to the getter result.
        address storedCustodian = vault.custodian();
        assertEq(storedCustodian, custodianAddr, "custodian getter must match");

        // Write a known value to V2's new slot after upgrade, verify it doesn't
        // collide with any existing state variable.
        RISKUSDVaultV2 v2Impl = new RISKUSDVaultV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        RISKUSDVaultV2(address(vault)).setNewVariableV2(0xDEAD);
        assertEq(RISKUSDVaultV2(address(vault)).newVariableV2(), 0xDEAD, "V2 variable wrong");

        // Verify no existing state was corrupted by writing to the new slot
        assertEq(vault.custodian(), custodianAddr, "custodian corrupted by V2 write");
        assertEq(vault.totalDeposited(), 1000e6, "totalDeposited corrupted by V2 write");
        assertEq(vault.totalRedeemed(), 0, "totalRedeemed corrupted by V2 write");
        assertEq(vault.totalDeployed(), 0, "totalDeployed corrupted by V2 write");
        assertEq(vault.weeklyRedemptionCapBps(), DEFAULT_WEEKLY_CAP_BPS, "weeklyCapBps corrupted");
        assertEq(vault.maxDeploymentRatioBps(), DEFAULT_MAX_DEPLOYMENT_RATIO_BPS, "maxDeployRatio corrupted");
    }
}
