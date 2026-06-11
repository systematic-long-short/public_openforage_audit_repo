// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-09: Inflation Attack Defense Tests (R-42)
// ============================================================
contract AtRISKUSD_TC09_InflationAttack is AtRISKUSDTestBase {
    // ----- L3 Step 1: Classic inflation attack — victim must receive shares > 0 -----
    function test_TC09_classicInflationAttack_victimGetsShares() public {
        // (a) Attacker deposits 1 wei as first depositor
        uint256 attackerShares = _depositViaQueue(attacker, 1);

        // (b) Attacker donates 1_000_000e6 RISKUSD directly to vault (not via deposit)
        riskusd.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 1_000_000e6);

        // (c) Victim deposits 999_999e6
        address victim = makeAddr("victim");
        uint256 victimShares = _depositViaQueue(victim, 999_999e6);

        // (d) With virtual offset, victim MUST receive shares > 0
        assertTrue(victimShares > 0, "Victim must receive shares > 0 despite inflation attack");
    }

    // ----- L3 Step 2: Attacker profitability check — net loss or near-zero gain -----
    function test_TC09_attackerProfitabilityCheck() public {
        // Attacker deposits 1 wei
        uint256 attackerShares = _depositViaQueue(attacker, 1);

        // Attacker donates 1_000_000e6 directly
        uint256 donationAmount = 1_000_000e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // Victim deposits 999_999e6
        address victim = makeAddr("victim");
        _depositViaQueue(victim, 999_999e6);

        // Calculate attacker's net position
        uint256 attackerAssetsValue = vault.convertToAssets(attackerShares);
        uint256 attackerTotalSpent = 1 + donationAmount; // 1 wei deposit + donation

        // Attacker should have net loss or negligible gain
        // (donation benefits all shareholders proportionally, including victim)
        assertTrue(attackerAssetsValue <= attackerTotalSpent, "Attacker should not profit from inflation attack");
    }

    // ----- L3 Step 3: No-donation baseline — second depositor gets proportional shares -----
    function test_TC09_noDonationBaseline() public {
        // First depositor: 1 wei
        uint256 firstShares = _depositViaQueue(attacker, 1);
        assertTrue(firstShares > 0, "First depositor should receive shares for 1 wei");

        // Second depositor: 1_000_000e6
        address secondDepositor = makeAddr("secondDepositor");
        uint256 secondShares = _depositViaQueue(secondDepositor, 1_000_000e6);

        // Second depositor should receive proportional shares (not 0 due to rounding)
        assertTrue(secondShares > 0, "Second depositor must receive shares > 0");
        // Second depositor deposited much more, so should have much more shares
        assertTrue(secondShares > firstShares, "Second depositor should have more shares");
    }

    // ----- L3 Step 4: Offset verification — decimalsOffset() == 0 (no virtual shares) -----
    function test_TC09_virtualOffsetActive() public {
        // OF-002: _decimalsOffset() = 6, so 1 asset unit → 10^6 share units
        _depositViaQueue(alice, 1);

        uint256 totalSupply = vault.totalSupply();
        assertEq(totalSupply, 1e6, "totalSupply should be 1e6 (decimalsOffset=6: 1 asset -> 1e6 shares)");

        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, 1, "totalAssets should be exactly 1");
    }

    // ----- L3 Step 5: Multiple small deposits — each gets shares > 0 -----
    function test_TC09_multipleSmallDepositsAllGetShares() public {
        address[10] memory depositors;
        uint256[10] memory shares;

        for (uint256 i = 0; i < 10; i++) {
            depositors[i] = makeAddr(string(abi.encodePacked("depositor", i)));
            shares[i] = _depositViaQueue(depositors[i], 1);
            assertTrue(shares[i] > 0, "Each 1-wei depositor must receive shares > 0");
        }

        // Verify no share concentration via rounding theft
        // All depositors deposited the same amount, so should have similar shares
        for (uint256 i = 1; i < 10; i++) {
            assertEq(shares[i], shares[0], "Equal depositors should have equal shares");
        }
    }

    // ----- L3 Step 6: Large donation with existing depositors — proportional benefit -----
    function test_TC09_largeDonationBenefitsExistingProportionally() public {
        // Alice and Bob each deposit 500e6
        uint256 aliceShares = _depositViaQueue(alice, 500e6);
        uint256 bobShares = _depositViaQueue(bob, 500e6);

        uint256 aliceValueBefore = vault.convertToAssets(aliceShares);
        uint256 bobValueBefore = vault.convertToAssets(bobShares);

        // Attacker donates 1_000_000e6 directly (holds no shares)
        riskusd.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 1_000_000e6);

        uint256 aliceValueAfter = vault.convertToAssets(aliceShares);
        uint256 bobValueAfter = vault.convertToAssets(bobShares);

        // OF-16-007: Donation does NOT inflate totalAssets, so share values are unchanged
        assertEq(aliceValueAfter, aliceValueBefore, "Alice's value should NOT change after donation (OF-16-007)");
        assertEq(bobValueAfter, bobValueBefore, "Bob's value should NOT change after donation (OF-16-007)");

        // Attacker holds 0 shares, gained nothing
        assertEq(vault.balanceOf(attacker), 0, "Attacker holds no shares");
    }

    // ----- L3 Step 7: Donation + immediate deposit — shares only for deposited amount -----
    function test_TC09_donationPlusDepositSharesOnlyForDeposit() public {
        // First, create a baseline with alice
        _depositViaQueue(alice, 1000e6);

        // Attacker donates 1e6 directly
        riskusd.mint(attacker, 1e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 1e6);

        // Attacker deposits 1e6 via StakingQueue
        uint256 attackerShares = _depositViaQueue(attacker, 1e6);

        // Attacker's share value should reflect only the deposited amount, not the donation
        uint256 attackerAssetsValue = vault.convertToAssets(attackerShares);

        // Attacker deposited 1e6 into a vault with totalAssets ~2001e6 and got shares
        // Their share value should be approximately 1e6 (not 2e6)
        // Allow generous tolerance for rounding but confirm it's not double
        assertTrue(attackerAssetsValue < 2e6, "Attacker shares should not include donated amount");
    }
}
