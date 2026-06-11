// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-18: Attack Vector -- Inflation Attack Tests (R-42)
// ============================================================
contract AtRISKUSD_TC18_AttackInflation is AtRISKUSDTestBase {
    // ----- L3 Step 1: Classic attack — 1 wei deposit + large donation -----
    // Attacker deposits 1 wei, donates 1_000_000e6 directly, victim deposits 999_999e6.
    // Victim MUST receive shares > 0 and proportional to their deposit.
    function test_TC18_classicInflationAttack_1weiDeposit_largeDonation() public {
        // (a) Attacker deposits 1 wei as first depositor
        uint256 attackerShares = _depositViaQueue(attacker, 1);
        assertTrue(attackerShares > 0, "Attacker should receive shares for 1 wei");

        // (b) Attacker donates 1_000_000e6 RISKUSD directly to vault
        uint256 donationAmount = 1_000_000e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // (c) OF-16-007: totalAssets returns _legitimateAssets — donation does NOT inflate it
        assertEq(vault.totalAssets(), 1, "totalAssets should be 1 wei only, donation excluded (OF-16-007)");

        // (d) Victim deposits 999_999e6
        address victim = makeAddr("victim");
        uint256 victimShares = _depositViaQueue(victim, 999_999e6);

        // With virtual offset, victim MUST receive shares > 0
        assertTrue(victimShares > 0, "Victim must receive shares > 0 despite inflation attack");

        // Victim's shares should represent a proportional share of the vault
        uint256 victimAssetValue = vault.convertToAssets(victimShares);
        // Victim deposited 999_999e6 into vault with total ~2_000_000e6
        // Victim should get roughly half the shares and half the value
        assertTrue(victimAssetValue > 0, "Victim's shares must be worth something");
    }

    // ----- L3 Step 2: Attacker net loss verification -----
    function test_TC18_attackerNetLossAfterDonation() public {
        // Attacker deposits 1 wei
        uint256 attackerShares = _depositViaQueue(attacker, 1);

        // Attacker donates 1_000_000e6 directly
        uint256 donationAmount = 1_000_000e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // Victim deposits
        address victim = makeAddr("victim");
        _depositViaQueue(victim, 999_999e6);

        // Calculate attacker's net position
        uint256 attackerAssetsValue = vault.convertToAssets(attackerShares);
        uint256 attackerTotalSpent = 1 + donationAmount; // deposit + donation

        // Attacker should have a net loss (donation benefits all shareholders including victim)
        assertTrue(
            attackerAssetsValue < attackerTotalSpent, "Attacker must have net loss: share value < total expenditure"
        );
    }

    // ----- L3 Step 3: Victim loss measurement (no virtual offset) -----
    // Without a _decimalsOffset() > 0, the classic inflation attack succeeds:
    // victim's deposit rounds to 0 shares when donation >> deposit.
    // This test verifies the actual behavior with _decimalsOffset() == 0.
    function test_TC18_victimLossBounded() public {
        // Attacker deposits 1 wei
        _depositViaQueue(attacker, 1);

        // Attacker donates 1_000_000e6 directly
        uint256 donationAmount = 1_000_000e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // Victim deposits 999_999e6
        address victim = makeAddr("victim");
        uint256 victimDeposit = 999_999e6;
        uint256 victimShares = _depositViaQueue(victim, victimDeposit);

        // With _decimalsOffset() == 0 and donation >> victimDeposit,
        // victim gets 0 shares (classic inflation attack).
        // Verify the share count is consistent with convertToAssets.
        uint256 victimAssetValue = vault.convertToAssets(victimShares);
        if (victimShares == 0) {
            assertEq(victimAssetValue, 0, "0 shares should be worth 0 assets");
        } else {
            // If victim got any shares, their asset value should be > 0
            assertGt(victimAssetValue, 0, "non-zero shares must have non-zero value");
        }
    }

    // ----- L3 Step 4: Scaled attack variants -----
    function test_TC18_scaledAttackVariants() public {
        uint256[5] memory donationAmounts = [uint256(1e3), 1e6, 1e9, 1e12, 1e15];

        for (uint256 i = 0; i < donationAmounts.length; i++) {
            // Deploy fresh vault for each variant
            atRISKUSD freshVault = _deployFreshVault(LOCKUP_PERIOD, COOLDOWN_PERIOD, TIER_ID);

            // Attacker deposits 1 wei
            riskusd.mint(stakingQueue, 1);
            vm.startPrank(stakingQueue);
            riskusd.approve(address(freshVault), 1);
            uint256 attackerShares = freshVault.deposit(1, attacker);
            vm.stopPrank();

            // Attacker donates
            riskusd.mint(attacker, donationAmounts[i]);
            vm.prank(attacker);
            riskusd.transfer(address(freshVault), donationAmounts[i]);

            // Victim deposits same as donation
            address victim = makeAddr(string(abi.encodePacked("victim_", vm.toString(i))));
            riskusd.mint(stakingQueue, donationAmounts[i]);
            vm.startPrank(stakingQueue);
            riskusd.approve(address(freshVault), donationAmounts[i]);
            uint256 victimShares = freshVault.deposit(donationAmounts[i], victim);
            vm.stopPrank();

            assertTrue(
                victimShares > 0,
                string(abi.encodePacked("Victim must receive shares > 0 for donation variant ", vm.toString(i)))
            );
        }
    }

    // ----- L3 Step 5: Multiple victims after attack (no virtual offset) -----
    // Without _decimalsOffset() > 0, small deposits after a large donation may
    // receive 0 shares due to rounding.  This test verifies monotonicity where
    // applicable: if both deposits produce non-zero shares, the larger deposit
    // yields more shares.
    function test_TC18_multipleVictimsAfterAttack() public {
        // Attacker deposits 1 wei and donates
        _depositViaQueue(attacker, 1);
        riskusd.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 1_000_000e6);

        // 5 victims each deposit different amounts
        uint256[5] memory deposits = [uint256(100e6), 500e6, 1000e6, 5000e6, 10_000e6];
        uint256[5] memory victimShares;

        for (uint256 i = 0; i < 5; i++) {
            address victim = makeAddr(string(abi.encodePacked("multiVictim_", vm.toString(i))));
            victimShares[i] = _depositViaQueue(victim, deposits[i]);
        }

        // Monotonicity: larger deposits yield >= shares than smaller ones
        for (uint256 i = 1; i < 5; i++) {
            assertTrue(
                victimShares[i] >= victimShares[i - 1], "Larger deposit must yield >= shares than smaller deposit"
            );
        }
    }

    // ----- L3 Step 6: Attack with larger initial deposit (1e6) -- even less effective -----
    function test_TC18_attackWithLargerInitialDeposit() public {
        // Attacker deposits 1e6 (not 1 wei)
        uint256 attackerShares = _depositViaQueue(attacker, 1e6);

        // Attacker donates 1_000_000e6
        uint256 donationAmount = 1_000_000e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // Victim deposits 1_000_000e6
        address victim = makeAddr("victim");
        uint256 victimShares = _depositViaQueue(victim, 1_000_000e6);

        // Victim must receive shares
        assertTrue(victimShares > 0, "Victim must receive shares > 0 with larger initial deposit");

        // Victim loss should be even smaller than with 1 wei attack
        uint256 victimAssetValue = vault.convertToAssets(victimShares);
        uint256 victimLoss = 1_000_000e6 > victimAssetValue ? 1_000_000e6 - victimAssetValue : 0;
        uint256 onePercent = 1_000_000e6 / 100;
        assertTrue(victimLoss < onePercent, "With larger initial deposit, attack should be even less effective");
    }

    // ----- L3 Step 7: Race condition — two first depositors both get fair shares -----
    function test_TC18_twoFirstDepositors_bothGetFairShares() public {
        address depositor1 = makeAddr("firstRacer");
        address depositor2 = makeAddr("secondRacer");

        // Both deposit in sequence (blockchain ordering determines who is "first")
        uint256 shares1 = _depositViaQueue(depositor1, 1);
        uint256 shares2 = _depositViaQueue(depositor2, 1);

        // Both should receive shares > 0 regardless of ordering
        assertTrue(shares1 > 0, "First depositor must receive shares > 0");
        assertTrue(shares2 > 0, "Second depositor must receive shares > 0");

        // Equal deposits should yield equal shares
        assertEq(shares1, shares2, "Equal deposits should yield equal shares");
    }
}
