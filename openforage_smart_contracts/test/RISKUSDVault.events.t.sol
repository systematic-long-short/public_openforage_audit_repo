// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// ============================================================
// TC-21: Event Emission Tests
// ============================================================
contract RISKUSDVault_TC21_Events is RISKUSDVaultTestBase {
    function setUp() public override {
        super.setUp();
        _setupAllRoles();
        // Set weekly redemption cap to 100% so redeem event tests are not blocked by the 5% launch default.
        vm.prank(owner);
        vault.setWeeklyRedemptionCapBps(10000);
    }

    // ---- Custom Events ----

    /// @dev R-08, R-50: deposit() emits Deposited(depositor, usdcAmount) with depositor indexed
    function test_TC21_depositedEvent() public {
        _fundAndApproveUSDC(alice, 500e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit RISKUSDVault.Deposited(alice, 500e6);
        vault.deposit(500e6);
    }

    /// @dev R-14, R-50: redeem() emits Redeemed(redeemer, riskusdAmount) with redeemer indexed
    function test_TC21_redeemedEvent() public {
        _deposit(alice, 1000e6);
        _approveVaultRISKUSD(alice, 200e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit RISKUSDVault.Redeemed(alice, 200e6);
        vault.redeem(200e6);
    }

    /// @dev R-50: deployCapital() emits CapitalDeployed(custodian, usdcAmount, totalDeployed) with custodian indexed
    function test_TC21_capitalDeployedEvent() public {
        _deposit(alice, 1000e6);

        vm.prank(custodianAddr);
        vm.expectEmit(true, false, false, true);
        emit RISKUSDVault.CapitalDeployed(custodianAddr, 300e6, 300e6);
        vault.deployCapital(300e6);
    }

    /// @dev R-50: returnCapital() emits CapitalReturned(custodian, usdcAmount, totalDeployed) with custodian indexed
    function test_TC21_capitalReturnedEvent() public {
        _deposit(alice, 1000e6);

        // Deploy first
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        // Return 200e6
        _fundAndApproveUSDC(custodianAddr, 200e6);
        vm.prank(custodianAddr);
        vm.expectEmit(true, false, false, true);
        emit RISKUSDVault.CapitalReturned(custodianAddr, 200e6, 300e6);
        vault.returnCapital(200e6);
    }

    /// @dev R-50: setCustodian() emits CustodianUpdated(oldCustodian, newCustodian) with both indexed
    function test_TC21_custodianUpdatedEvent() public {
        address newCustodian = makeAddr("newCustodian");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSDVault.CustodianSetByOwner(custodianAddr, newCustodian);
        vault.setCustodian(newCustodian);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        vm.stopPrank();
    }

    /// @dev R-50: setMaxDeploymentRatioBps() emits MaxDeploymentRatioUpdated(oldRatio, newRatio)
    function test_TC21_maxDeploymentRatioUpdatedEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.MaxDeploymentRatioUpdated(DEFAULT_MAX_DEPLOYMENT_RATIO_BPS, 5000);
        vault.setMaxDeploymentRatioBps(5000);
    }

    /// @dev R-50: setWeeklyRedemptionCapBps() emits WeeklyRedemptionCapBpsUpdated(oldBps, newBps)
    function test_TC21_weeklyRedemptionCapBpsUpdatedEvent() public {
        // setUp changed cap to 10000 (100%), so oldBps is 10000
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.WeeklyRedemptionCapBpsUpdated(10000, 500);
        vault.setWeeklyRedemptionCapBps(500);
    }

    /// @dev R-50: setMinReserveRatioBps() emits MinReserveRatioUpdated(oldRatio, newRatio)
    function test_TC21_minReserveRatioUpdatedEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.MinReserveRatioUpdated(0, 5000);
        vault.setMinReserveRatioBps(5000);
    }

    /// @dev R-50: setForageGovernor() emits ForageGovernorSet(oldGovernor, newGovernor) with both indexed
    function test_TC21_forageGovernorSetEvent() public {
        address newGovernor = makeAddr("newGovernor");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSDVault.ForageGovernorProposed(governorAddr, newGovernor);
        vault.setForageGovernor(newGovernor);

        vm.warp(block.timestamp + 2 days + 1);
        vm.expectEmit(true, true, false, true);
        emit RISKUSDVault.ForageGovernorSet(governorAddr, newGovernor);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }

    /// @dev R-50: burnForLoss() emits LossBurned(riskusdAmount)
    function test_TC21_lossBurnedEvent() public {
        // The helper records the nonce-bound NAV loss; finalization is explicit.
        _prepareForBurnForLoss(200e6);

        vm.prank(lossReporterAddr);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.LossBurned(200e6);
        vault.burnForLoss(1, 200e6);

        _finalizePreparedAttestedLoss(1, 200e6);
    }

    /// @dev R-50: replenish() emits Replenished(usdcAmount)
    function test_TC21_replenishedEvent() public {
        _fundAndApproveUSDC(lossReporterAddr, 300e6);

        vm.prank(lossReporterAddr);
        vm.expectEmit(false, false, false, true);
        emit RISKUSDVault.Replenished(300e6);
        vault.replenish(300e6);
    }

    /// @dev R-50: recordCustodianNAV(vaultId, nav, nonce) emits CustodianNAVAttested(...)
    function test_TC21_custodianNAVAttestedEvent() public {
        _deposit(alice, 1000e6);
        vm.prank(custodianAddr);
        vault.deployCapital(500e6);

        uint256 lossNonce = vault.latestLossNonce() + 1;
        vm.prank(custodianAddr);
        vm.expectEmit(true, true, false, true);
        emit RISKUSDVault.CustodianNAVAttested(1, 300e6, lossNonce, block.timestamp);
        vault.recordCustodianNAV(1, 300e6, lossNonce);
    }

    /// @dev R-50: setLossReporter() emits LossReporterUpdated(oldReporter, newReporter) with both indexed
    function test_TC21_lossReporterUpdatedEvent() public {
        address newReporter = makeAddr("newReporter");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true);
        emit RISKUSDVault.LossReporterSetByOwner(lossReporterAddr, newReporter);
        vault.setLossReporter(newReporter);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();
    }

    // ---- Inherited Events ----

    /// @dev R-50: pause() emits Paused(account), unpause() emits Unpaused(account)
    function test_TC21_pausedUnpausedEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PausableUpgradeable.Paused(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PausableUpgradeable.Unpaused(owner);
        vault.unpause();
    }

    /// @dev R-50: Ownership transfer emits OwnershipTransferStarted and OwnershipTransferred
    function test_TC21_ownershipTransferEvents() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, newOwner);
        vault.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, true);
        emit OwnableUpgradeable.OwnershipTransferred(owner, newOwner);
        vault.acceptOwnership();
    }

    // ---- No Spurious Events ----

    /// @dev R-50: Operations that revert must NOT emit any events
    function test_TC21_noSpuriousEventsOnRevert() public {
        // deposit(0) should revert with ZeroAmount -- no Deposited event
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.ZeroAmount.selector);
        vault.deposit(0);
        // If we got here without events, the test passes.

        // redeem(0) should revert with ZeroAmount -- no Redeemed event
        _deposit(alice, 100e6);
        _approveVaultRISKUSD(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.ZeroAmount.selector);
        vault.redeem(0);
    }

    /// @dev R-50: View function calls must NOT emit any events
    function test_TC21_noSpuriousEventsOnViewCalls() public {
        _deposit(alice, 1000e6);

        // View calls should emit no events
        // vm.recordLogs() captures any emitted events
        vm.recordLogs();
        vault.totalDeposited();
        vault.totalRedeemed();
        vault.vaultUsdcBalance();
        vault.reserveRatio();
        vault.effectiveWeeklyRedemptionCap();
        vault.weeklyRedemptionRemaining();
        vault.availableForRedemption();
        vault.totalDepositorUsdc();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "View functions must not emit events");
    }
}
