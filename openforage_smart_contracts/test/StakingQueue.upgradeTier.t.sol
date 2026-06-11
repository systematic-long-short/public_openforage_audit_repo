// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-05: Tier Upgrade Tests (L3 steps 8-19)
// ============================================================
contract StakingQueue_TC05_TierUpgrade is StakingQueueTestBase {
    /// @dev L3 step 8: upgradeTier with zero amount MUST revert ZeroAmount.
    function test_TC05_upgradeTierZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.upgradeTier(0, 1, 0);
    }

    /// @dev L3 step 9: upgradeTier with invalid fromTier (4) MUST revert InvalidTier.
    function test_TC05_upgradeTierInvalidFromTierReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.upgradeTier(4, 5, 100e6);
    }

    /// @dev L3 step 10: upgradeTier with same tier MUST revert InvalidTierUpgrade.
    function test_TC05_upgradeTierSameTierReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTierUpgrade.selector);
        queue.upgradeTier(1, 1, 100e6);
    }

    /// @dev L3 step 11: upgradeTier downgrade MUST revert InvalidTierUpgrade.
    function test_TC05_upgradeTierDowngradeReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingQueue.InvalidTierUpgrade.selector);
        queue.upgradeTier(2, 1, 100e6);
    }

    /// @dev L3 step 12: upgradeTier while paused MUST revert EnforcedPause.
    function test_TC05_upgradeTierPausedReverts() public {
        // Pause the contract
        vm.prank(owner);
        queue.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.upgradeTier(0, 1, 500e6);
    }

    /// @dev L3 step 13: Happy path tier 0 to tier 1.
    ///      Calls redeemForUpgrade on source vault, deposit on destination vault.
    ///      Emits TierUpgraded event.
    function test_TC05_upgradeTierHappyPath_0to1() public {
        uint256 atriskusdAmount = 500e6;

        // Set up the source vault to return RISKUSD
        vault0.setRedeemForUpgradeReturnAmount(500e6);
        // Fund vault0 with RISKUSD so it can transfer back
        riskusd.mint(address(vault0), 500e6);

        vm.expectEmit(true, false, false, true);
        emit StakingQueue.TierUpgraded(alice, 0, 1, atriskusdAmount, 500e6, 500e6);

        vm.prank(alice);
        queue.upgradeTier(0, 1, atriskusdAmount);

        // Verify redeemForUpgrade was called on vault0
        assertEq(vault0.redeemForUpgradeCallCount(), 1, "redeemForUpgrade should be called once on vault0");
        (address depositor0, uint256 amount0) = vault0.redeemForUpgradeCalls(0);
        assertEq(depositor0, alice, "redeemForUpgrade depositor should be alice");
        assertEq(amount0, atriskusdAmount, "redeemForUpgrade amount should match");

        // Verify deposit was called on vault1
        assertEq(vault1.depositCallCount(), 1, "deposit should be called once on vault1");
        (uint256 depositAmount1, address depositor1) = vault1.depositCalls(0);
        assertEq(depositor1, alice, "deposit depositor should be alice");
        assertEq(depositAmount1, 500e6, "deposit amount should match RISKUSD returned");
    }

    /// @dev L3 step 14: Happy path tier 0 to tier 3 (multi-tier jump).
    function test_TC05_upgradeTierHappyPath_0to3() public {
        uint256 atriskusdAmount = 1000e6;
        vault0.setRedeemForUpgradeReturnAmount(1000e6);
        riskusd.mint(address(vault0), 1000e6);

        vm.expectEmit(true, false, false, true);
        emit StakingQueue.TierUpgraded(alice, 0, 3, atriskusdAmount, 1000e6, 1000e6);

        vm.prank(alice);
        queue.upgradeTier(0, 3, atriskusdAmount);

        // Verify redeemForUpgrade called on vault0, deposit on vault3
        assertEq(vault0.redeemForUpgradeCallCount(), 1, "redeemForUpgrade should be called on vault0");
        assertEq(vault3.depositCallCount(), 1, "deposit should be called on vault3");
    }

    /// @dev L3 step 15: Happy path tier 1 to tier 2 (mid-tier upgrade).
    function test_TC05_upgradeTierHappyPath_1to2() public {
        uint256 atriskusdAmount = 750e6;
        vault1.setRedeemForUpgradeReturnAmount(750e6);
        riskusd.mint(address(vault1), 750e6);

        vm.expectEmit(true, false, false, true);
        emit StakingQueue.TierUpgraded(alice, 1, 2, atriskusdAmount, 750e6, 750e6);

        vm.prank(alice);
        queue.upgradeTier(1, 2, atriskusdAmount);

        assertEq(vault1.redeemForUpgradeCallCount(), 1, "redeemForUpgrade should be called on vault1");
        assertEq(vault2.depositCallCount(), 1, "deposit should be called on vault2");
    }

    /// @dev L3 step 16: All 6 valid tier upgrade pairs: (0,1), (0,2), (0,3), (1,2), (1,3), (2,3).
    function test_TC05_upgradeTierAllValidPairs() public {
        uint8[2][6] memory pairs = [
            [uint8(0), uint8(1)],
            [uint8(0), uint8(2)],
            [uint8(0), uint8(3)],
            [uint8(1), uint8(2)],
            [uint8(1), uint8(3)],
            [uint8(2), uint8(3)]
        ];

        MockAtRISKUSD[4] memory vaults = [vault0, vault1, vault2, vault3];

        for (uint256 i = 0; i < 6; i++) {
            uint8 from = pairs[i][0];
            uint8 to = pairs[i][1];

            // Deploy fresh proxy for each pair to avoid state contamination
            StakingQueue freshQueue = _deployFreshProxy(
                address(riskusd),
                address(forage),
                [address(vault0), address(vault1), address(vault2), address(vault3)],
                address(mockVaultRegistry),
                owner
            );
            vm.prank(owner);
            freshQueue.setVaultId(1);

            uint256 amount = 100e6;
            vaults[from].setRedeemForUpgradeReturnAmount(amount);
            riskusd.mint(address(vaults[from]), amount);

            // Approve fresh queue for RISKUSD transfers
            vm.prank(address(freshQueue));
            riskusd.approve(address(vaults[to]), type(uint256).max);

            vm.prank(alice);
            freshQueue.upgradeTier(from, to, amount);
        }
    }

    /// @dev L3 step 17: Atomicity on destination failure.
    ///      Mock destination vault's deposit() to revert. Entire tx reverts.
    function test_TC05_upgradeTierAtomicityDestinationFailure() public {
        uint256 atriskusdAmount = 500e6;
        vault0.setRedeemForUpgradeReturnAmount(500e6);
        riskusd.mint(address(vault0), 500e6);

        // Make destination vault revert on deposit
        vault1.setShouldRevertDeposit(true);

        vm.prank(alice);
        vm.expectRevert("MockAtRISKUSD: deposit reverted");
        queue.upgradeTier(0, 1, atriskusdAmount);

        // Verify no partial state changes
        assertEq(vault1.depositCallCount(), 0, "deposit should not have been recorded");
    }

    /// @dev L3 step 18: Atomicity on source failure.
    ///      Mock source vault's redeemForUpgrade() to revert. Entire tx reverts.
    function test_TC05_upgradeTierAtomicitySourceFailure() public {
        // Make source vault revert on redeemForUpgrade
        vault0.setShouldRevertRedeemForUpgrade(true);

        vm.prank(alice);
        vm.expectRevert("MockAtRISKUSD: redeemForUpgrade reverted");
        queue.upgradeTier(0, 1, 500e6);

        // Verify no calls made to destination
        assertEq(vault1.depositCallCount(), 0, "deposit should not be called on destination");
        assertEq(vault0.redeemForUpgradeCallCount(), 0, "redeemForUpgrade should not have been recorded");
    }

    /// @dev L3 step 19: Upgrade bypasses queue. No queue entry created.
    function test_TC05_upgradeTierBypassesQueue() public {
        uint256 queueIdBefore = queue.nextQueueId();
        uint256 totalQueuedBefore = queue.totalQueuedRiskusd();

        uint256 atriskusdAmount = 500e6;
        vault0.setRedeemForUpgradeReturnAmount(500e6);
        riskusd.mint(address(vault0), 500e6);

        vm.prank(alice);
        queue.upgradeTier(0, 1, atriskusdAmount);

        // Queue state should be unchanged
        assertEq(queue.nextQueueId(), queueIdBefore, "nextQueueId should not change from upgrade");
        assertEq(queue.totalQueuedRiskusd(), totalQueuedBefore, "totalQueuedRiskusd should not change from upgrade");
    }
}
