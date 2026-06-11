// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDVaultTestBase.sol";

contract MockGovernorGuardianView {
    address public guardianModule;

    constructor(address guardianModule_) {
        guardianModule = guardianModule_;
    }
}

contract RISKUSDVaultEmergencyCapsTest is RISKUSDVaultTestBase {
    function _wireGuardianModule(address guardianModule_) internal {
        MockGovernorGuardianView governor = new MockGovernorGuardianView(guardianModule_);
        vm.startPrank(owner);
        vault.setForageGovernor(address(governor));
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeForageGovernor();
        vm.stopPrank();
    }

    function test_guardianCanTightenAllHotPathCaps() public {
        address guardianModule = makeAddr("guardianModule");
        _wireGuardianModule(guardianModule);

        vm.startPrank(guardianModule);
        vault.shrinkWeeklyRedemptionCapBps(250);
        vault.shrinkWeeklyMintCapBps(10_000);
        vault.shrinkPerBlockMintCap(50, 1_000_000e6);
        vault.tightenMaxDeploymentRatioBps(9_000);
        vault.tightenDeploymentBufferBps(1_000);
        vm.stopPrank();

        assertEq(vault.weeklyRedemptionCapBps(), 250, "redemption cap tightened");
        assertEq(vault.weeklyMintCapBps(), 10_000, "weekly mint cap tightened");
        assertEq(vault.perBlockMintCapBps(), 50, "per-block mint bps tightened");
        assertEq(vault.perBlockMintCapMax(), 1_000_000e6, "per-block mint max tightened");
        assertEq(vault.maxDeploymentRatioBps(), 9_000, "deployment ratio tightened");
        assertEq(vault.deploymentBufferBps(), 1_000, "deployment buffer tightened");
    }

    function test_emergencyCapFunctionsCannotWiden() public {
        address guardianModule = makeAddr("guardianModule");
        _wireGuardianModule(guardianModule);

        vm.startPrank(guardianModule);
        vault.shrinkWeeklyRedemptionCapBps(250);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.shrinkWeeklyRedemptionCapBps(251);
        vm.expectRevert(RISKUSDVault.InvalidParameter.selector);
        vault.shrinkWeeklyRedemptionCapBps(0);

        vault.shrinkWeeklyMintCapBps(10_000);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.shrinkWeeklyMintCapBps(10_001);

        vault.shrinkPerBlockMintCap(50, 1_000_000e6);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.shrinkPerBlockMintCap(51, 1_000_000e6);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.shrinkPerBlockMintCap(50, 1_000_001e6);

        vault.tightenMaxDeploymentRatioBps(9_000);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.tightenMaxDeploymentRatioBps(9_001);

        vault.tightenDeploymentBufferBps(1_000);
        vm.expectRevert(RISKUSDVault.CapTighteningOnly.selector);
        vault.tightenDeploymentBufferBps(999);
        vm.stopPrank();
    }

    function test_emergencyCapFunctionsRejectUnauthorizedCaller() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.UnauthorizedCapTightener.selector, attacker));
        vault.shrinkWeeklyRedemptionCapBps(250);
    }

    function test_zeroEmergencyMintCapsBlockPublicDeposits() public {
        address guardianModule = makeAddr("guardianModule");
        _wireGuardianModule(guardianModule);

        vm.prank(guardianModule);
        vault.shrinkWeeklyMintCapBps(0);

        assertEq(vault.effectiveWeeklyMintCap(), 0, "zero weekly cap reports halted mint capacity");
        assertEq(vault.weeklyMintRemaining(), 0, "zero weekly cap reports no remaining mint capacity");

        _fundAndApproveUSDC(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(RISKUSDVault.WeeklyMintCapExceeded.selector);
        vault.deposit(1e6);

        vm.prank(guardianModule);
        vault.shrinkPerBlockMintCap(0, 0);

        _fundAndApproveUSDC(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RISKUSDVault.PerBlockMintCapExceeded.selector, 1e6, 0));
        vault.deposit(1e6);
    }
}
