// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "./helpers/AtRISKUSDV2.sol";
import "./helpers/AtRISKUSDV3.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-16: UUPS Upgrade Tests (R-02, R-37)
// ============================================================
contract AtRISKUSD_TC16_Upgrade is AtRISKUSDTestBase {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public override {
        super.setUp();
        _raiseWeeklyWithdrawalCap(vault);
    }

    /// @dev Helper to read the implementation address from the ERC1967 proxy storage slot.
    function _getImplementationAddress() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), ERC1967_IMPL_SLOT))));
    }

    // ----- L3 Step 1: Unauthorized upgrade reverts -----
    function test_TC16_nonOwnerUpgradeReverts() public {
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    // ----- L3 Step 2: Owner upgrade to v2 succeeds -----
    function test_TC16_ownerUpgradeToV2Succeeds() public {
        address implBefore = _getImplementationAddress();
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();

        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        address implAfter = _getImplementationAddress();
        assertTrue(implAfter != implBefore, "implementation address should change after upgrade");
        assertEq(implAfter, address(v2Impl), "implementation should be v2");
    }

    /// @dev State snapshot struct to avoid stack-too-deep in state preservation tests.
    struct StateSnapshot {
        uint8 tierId;
        uint256 lockupPeriod;
        uint256 cooldownPeriod;
        address yieldSourceAddr;
        address stakingQueueAddr;
        address governorAddr;
        address ownerAddr;
        uint256 totalYieldAccrued;
        uint256 totalLossAbsorbed;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 aliceBalance;
        uint256 bobBalance;
        uint256 aliceLockExpiry;
        uint256 bobLockExpiry;
        bool aliceAutoRenew;
        bool bobAutoRenew;
    }

    function _takeSnapshot() internal view returns (StateSnapshot memory s) {
        s.tierId = vault.tierId();
        s.lockupPeriod = vault.lockupPeriod();
        s.cooldownPeriod = vault.cooldownPeriod();
        s.yieldSourceAddr = vault.yieldSource();
        s.stakingQueueAddr = vault.stakingQueue();
        s.governorAddr = vault.forageGovernor();
        s.ownerAddr = vault.owner();
        s.totalYieldAccrued = vault.totalYieldAccrued();
        s.totalLossAbsorbed = vault.totalLossAbsorbed();
        s.totalSupply = vault.totalSupply();
        s.totalAssets = vault.totalAssets();
        s.aliceBalance = vault.balanceOf(alice);
        s.bobBalance = vault.balanceOf(bob);
        s.aliceLockExpiry = vault.lockExpiry(alice);
        s.bobLockExpiry = vault.lockExpiry(bob);
        s.aliceAutoRenew = vault.autoRenewEnabled(alice);
        s.bobAutoRenew = vault.autoRenewEnabled(bob);
    }

    function _verifySnapshot(StateSnapshot memory s) internal view {
        assertEq(vault.tierId(), s.tierId, "tierId should be preserved");
        assertEq(vault.lockupPeriod(), s.lockupPeriod, "lockupPeriod should be preserved");
        assertEq(vault.cooldownPeriod(), s.cooldownPeriod, "cooldownPeriod should be preserved");
        assertEq(vault.yieldSource(), s.yieldSourceAddr, "yieldSource should be preserved");
        assertEq(vault.stakingQueue(), s.stakingQueueAddr, "stakingQueue should be preserved");
        assertEq(vault.forageGovernor(), s.governorAddr, "forageGovernor should be preserved");
        assertEq(vault.owner(), s.ownerAddr, "owner should be preserved");
        assertEq(vault.totalYieldAccrued(), s.totalYieldAccrued, "totalYieldAccrued should be preserved");
        assertEq(vault.totalLossAbsorbed(), s.totalLossAbsorbed, "totalLossAbsorbed should be preserved");
        assertEq(vault.totalSupply(), s.totalSupply, "totalSupply should be preserved");
        assertEq(vault.totalAssets(), s.totalAssets, "totalAssets should be preserved");
        assertEq(vault.balanceOf(alice), s.aliceBalance, "alice balance should be preserved");
        assertEq(vault.balanceOf(bob), s.bobBalance, "bob balance should be preserved");
        assertEq(vault.lockExpiry(alice), s.aliceLockExpiry, "alice lockExpiry should be preserved");
        assertEq(vault.lockExpiry(bob), s.bobLockExpiry, "bob lockExpiry should be preserved");
        assertEq(vault.autoRenewEnabled(alice), s.aliceAutoRenew, "alice autoRenew should be preserved");
        assertEq(vault.autoRenewEnabled(bob), s.bobAutoRenew, "bob autoRenew should be preserved");
    }

    // ----- L3 Step 3: State preserved after upgrade -----
    function test_TC16_statePreservedAfterUpgrade() public {
        // Set up state before upgrade:
        // Deposit for alice and bob
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);
        _depositViaQueue(bob, 500e6);

        // Accrue some yield
        _accrueYield(200e6);

        // Absorb some loss
        _absorbLoss(50e6);

        // Alice disables auto-renew
        vm.prank(alice);
        vault.setAutoRenew(false);

        // Set governor
        vm.prank(owner);
        vault.setForageGovernor(governor);

        // Warp past lockup for alice, then request withdrawal
        vm.warp(block.timestamp + LOCKUP_PERIOD);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares / 2);

        // Snapshot state before upgrade
        StateSnapshot memory snap = _takeSnapshot();
        atRISKUSD.PendingWithdrawal memory snapAlicePw = vault.pendingWithdrawal(alice);

        // Upgrade to v2
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Verify all state preserved (L3 Step 3a-g)
        _verifySnapshot(snap);

        // Pending withdrawal preserved
        atRISKUSD.PendingWithdrawal memory postPw = vault.pendingWithdrawal(alice);
        assertEq(postPw.atriskusdAmount, snapAlicePw.atriskusdAmount, "pending withdrawal atriskusdAmount preserved");
        assertEq(postPw.riskusdAmount, snapAlicePw.riskusdAmount, "pending withdrawal riskusdAmount preserved");
        assertEq(postPw.requestTimestamp, snapAlicePw.requestTimestamp, "pending withdrawal requestTimestamp preserved");
        assertEq(postPw.active, snapAlicePw.active, "pending withdrawal active preserved");
    }

    // ----- L3 Step 4 & 5: Multi-generation upgrade v1 -> v2 -> v3 -----
    function test_TC16_multiGenerationUpgrade() public {
        // Deposit so there is state
        _depositViaQueue(alice, 1000e6);

        // Upgrade v1 -> v2
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Set v2 new variable
        AtRISKUSDV2(address(vault)).setNewVariableV2(42);
        assertEq(AtRISKUSDV2(address(vault)).newVariableV2(), 42, "v2 variable should be set");
        assertEq(AtRISKUSDV2(address(vault)).version(), 2, "should be v2");

        // Upgrade v2 -> v3
        AtRISKUSDV3 v3Impl = new AtRISKUSDV3();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v3Impl), "");

        // Original state preserved
        assertEq(vault.owner(), owner, "owner should be preserved across v2->v3");
        assertTrue(vault.balanceOf(alice) > 0, "alice balance should survive v2->v3");

        // V2 variable preserved through v3 upgrade
        assertEq(AtRISKUSDV3(address(vault)).newVariableV2(), 42, "v2 variable should survive v2->v3");

        // V3 new variable accessible
        AtRISKUSDV3(address(vault)).setAnotherVariableV3(99);
        assertEq(AtRISKUSDV3(address(vault)).anotherVariableV3(), 99, "v3 variable should be accessible");
        assertEq(AtRISKUSDV3(address(vault)).version(), 3, "should be v3");
    }

    // ----- L3 Step 6: Implementation direct call -- MUST revert InvalidInitialization -----
    function test_TC16_implementationInitBlocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(riskusd),
            yieldSource,
            stakingQueue,
            LOCKUP_PERIOD,
            COOLDOWN_PERIOD,
            TIER_ID,
            TIER_ABBREVIATION,
            owner
        );
    }

    // ----- L3 Step 7: Unauthorized upgrade (attack 1.3) -----
    function test_TC16_unauthorizedUpgradeAliceReverts() public {
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    // ----- L3 Step 9: New functionality in v2 -----
    function test_TC16_newFunctionalityInV2() public {
        // Deposit before upgrade
        uint256 shares = _depositViaQueue(alice, 1000e6);

        // Upgrade to v2
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // New v2 function works
        AtRISKUSDV2(address(vault)).setNewVariableV2(777);
        assertEq(AtRISKUSDV2(address(vault)).newVariableV2(), 777, "v2 function should work");

        // Old functionality still works
        assertEq(vault.balanceOf(alice), shares, "old balance should be preserved");
        assertEq(vault.tierId(), TIER_ID, "old tierId should be preserved");
        assertEq(vault.owner(), owner, "old owner should be preserved");
    }

    // ----- L3 Step 10: Functionality after deposits, yields, losses, and withdrawals -----
    function test_TC16_functionalityAfterComplexStateUpgrade() public {
        // Perform multiple operations to build complex state
        uint256 aliceShares = _depositViaQueue(alice, 2000e6);
        uint256 bobShares = _depositViaQueue(bob, 1000e6);

        // Accrue yield
        _accrueYield(300e6);

        // Absorb loss
        _absorbLoss(100e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Alice requests withdrawal for half shares
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares / 2);

        // Snapshot
        uint256 snapAliceBalance = vault.balanceOf(alice);
        uint256 snapBobBalance = vault.balanceOf(bob);
        uint256 snapTotalAssets = vault.totalAssets();

        // Upgrade to v2
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Verify state preserved
        assertEq(vault.balanceOf(alice), snapAliceBalance, "alice balance preserved after upgrade");
        assertEq(vault.balanceOf(bob), snapBobBalance, "bob balance preserved after upgrade");
        assertEq(vault.totalAssets(), snapTotalAssets, "totalAssets preserved after upgrade");

        // Operations continue correctly after upgrade
        // Alice can execute withdrawal (cooldown elapsed since lockup warp was large)
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        uint256 aliceRiskusdBefore = riskusd.balanceOf(alice);
        vm.prank(alice);
        vault.executeWithdrawal();
        assertTrue(
            riskusd.balanceOf(alice) > aliceRiskusdBefore,
            "alice should receive RISKUSD after executeWithdrawal post-upgrade"
        );

        // Bob can still deposit (new shares via new staking queue deposit)
        uint256 newBobShares = _depositViaQueue(bob, 500e6);
        assertTrue(newBobShares > 0, "bob should receive shares from new deposit post-upgrade");

        // Yield accrual still works post-upgrade
        _accrueYield(100e6);
        assertTrue(vault.totalYieldAccrued() > 300e6, "totalYieldAccrued should increase after post-upgrade yield");
    }

    // ----- proxiableUUID returns correct EIP-1822 slot -----
    function test_TC16_proxiableUUIDReturnsCorrectSlot() public view {
        // proxiableUUID has notDelegated modifier -- call on implementation directly
        bytes32 expected = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(implementation.proxiableUUID(), expected, "proxiableUUID should return ERC1967 implementation slot");
        assertEq(implementation.proxiableUUID(), ERC1967_IMPL_SLOT, "proxiableUUID should match constant");
    }
}
