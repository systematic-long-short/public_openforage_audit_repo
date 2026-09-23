// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./echidna/AllowlistGateInvariants.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/interfaces/IAllowlist.sol";

contract AllowlistGateInvariantsCompileTest is Test {
    address internal constant UNVERIFIED = address(0xBAD0);

    function _deployHarness() private returns (AllowlistGateInvariants harness) {
        vm.warp(2);
        harness = new AllowlistGateInvariants();
    }

    function test_echidnaHarnessGatePropertyHoldsOnUntouchedDeployment() public {
        AllowlistGateInvariants harness = _deployHarness();

        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "gate property must hold on the untouched deployment"
        );
    }

    function test_echidnaHarnessGatePropertyHoldsAfterUnverifiedCalls() public {
        AllowlistGateInvariants harness = _deployHarness();

        harness.gate_RISKUSDVault_deposit(0, 1e6);
        harness.gate_ForageToken_delegate(1, address(0xBEEF));
        harness.gate_GuardianModule_guardianPause(2, address(0xBEEF));
        harness.gate_RISKUSD_approve(0, address(0xBEEF), 0);
        harness.gate_ForageToken_transfer(1, address(0xBEEF), 0);

        assertTrue(harness.echidna_gate_noUnverifiedStateChange(), "gate property must hold after unverified calls");
    }

    function test_echidnaHarnessGatePropertyDetectsForcedViolation() public {
        AllowlistGateInvariants harness = _deployHarness();

        vm.prank(harness.FORGE_BREAK_CALLER());
        harness.forge_breakGate();

        assertFalse(harness.echidna_gate_noUnverifiedStateChange(), "gate property must fail after forced violation");
    }

    // --- Negative controls: one per moved selector wrapped by the harness; an unverified caller
    //     reverts CallerNotAllowed at the forwarder and the monitored snapshot stays unchanged. ---

    function test_movedRISKUSDVaultPauseBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).pause();
        harness.gate_RISKUSDVault_pause(0);
        assertTrue(harness.echidna_gate_noUnverifiedStateChange(), "pause must not change state for unverified caller");
    }

    function test_movedRISKUSDVaultUnpauseBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).unpause();
        harness.gate_RISKUSDVault_unpause(0);
        assertTrue(harness.echidna_gate_noUnverifiedStateChange(), "unpause must not change state for unverified caller");
    }

    function test_movedRISKUSDVaultSetBlocklistBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).setBlocklist(address(0xBEEF));
        harness.gate_RISKUSDVault_setBlocklist(0, address(0xBEEF));
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "setBlocklist must not change state for unverified caller"
        );
    }

    function test_movedRISKUSDVaultSetDailyMintCapBpsBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).setDailyMintCapBps(1);
        harness.gate_RISKUSDVault_setDailyMintCapBps(0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(),
            "setDailyMintCapBps must not change state for unverified caller"
        );
    }

    function test_movedRISKUSDVaultSetDailyRedemptionCapBpsBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).setDailyRedemptionCapBps(1);
        harness.gate_RISKUSDVault_setDailyRedemptionCapBps(0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(),
            "setDailyRedemptionCapBps must not change state for unverified caller"
        );
    }

    function test_movedRISKUSDVaultBurnForLossBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).burnForLoss(0, 1);
        harness.gate_RISKUSDVault_burnForLoss(0, 0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "burnForLoss must not change state for unverified caller"
        );
    }

    function test_movedRISKUSDVaultReplenishBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).replenish(1);
        harness.gate_RISKUSDVault_replenish(0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "replenish must not change state for unverified caller"
        );
    }

    function test_movedRISKUSDVaultRecordCustodianNAVBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address vaultAddr = harness.vaultAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        RISKUSDVault(vaultAddr).recordCustodianNAV(0, 0, 0);
        harness.gate_RISKUSDVault_recordCustodianNAV(0, 0, 0, 0);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(),
            "recordCustodianNAV must not change state for unverified caller"
        );
    }

    function test_movedStakingQueueJoinQueueBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address queueAddr = harness.queueAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        StakingQueue(queueAddr).joinQueue(1, 0);
        harness.gate_StakingQueue_joinQueue(0, 1, 0);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "joinQueue must not change state for unverified caller"
        );
    }

    function test_movedStakingQueueJoinQueueWithBoundsBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address queueAddr = harness.queueAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        StakingQueue(queueAddr).joinQueueWithBounds(1, 0, 1, block.timestamp + 1);
        harness.gate_StakingQueue_joinQueueWithBounds(0, 1, 0, 1, block.timestamp + 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(),
            "joinQueueWithBounds must not change state for unverified caller"
        );
    }

    function test_movedStakingQueueCancelQueueBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address queueAddr = harness.queueAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        StakingQueue(queueAddr).cancelQueue(0);
        harness.gate_StakingQueue_cancelQueue(0, 0);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "cancelQueue must not change state for unverified caller"
        );
    }

    function test_movedStakingQueueProcessQueueBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address queueAddr = harness.queueAddress();
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        StakingQueue(queueAddr).processQueue(0, 1);
        harness.gate_StakingQueue_processQueue(0, 0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(), "processQueue must not change state for unverified caller"
        );
    }

    function test_movedStakingQueueProcessExpiredLockupsBlocksUnverifiedCaller() public {
        AllowlistGateInvariants harness = _deployHarness();
        address queueAddr = harness.queueAddress();
        address[] memory depositors = new address[](1);
        depositors[0] = address(0xBEEF);
        vm.prank(UNVERIFIED);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, UNVERIFIED));
        StakingQueue(queueAddr).processExpiredLockups(depositors, 1);
        harness.gate_StakingQueue_processExpiredLockups(0, 1);
        assertTrue(
            harness.echidna_gate_noUnverifiedStateChange(),
            "processExpiredLockups must not change state for unverified caller"
        );
    }
}
