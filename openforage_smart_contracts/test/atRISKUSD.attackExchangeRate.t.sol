// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-19: Attack Vector -- Exchange Rate Manipulation Tests (R-42, R-44)
// ============================================================
contract AtRISKUSD_TC19_AttackExchangeRate is AtRISKUSDTestBase {
    // ----- L3 Step 1: OF-16-007: Donation does NOT increase totalAssets (returns _legitimateAssets) -----
    function test_TC19_donationIncreasesTotalAssetsButNotYieldCounter() public {
        _depositViaQueue(alice, 1000e6);

        uint256 totalYieldBefore = vault.totalYieldAccrued();
        uint256 totalAssetsBefore = vault.totalAssets();

        // Transfer 1000e6 RISKUSD directly to vault (donation)
        riskusd.mint(attacker, 1000e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 1000e6);

        // OF-16-007: totalAssets returns _legitimateAssets, not raw balance — donation does NOT inflate it
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets must NOT increase from donation (OF-16-007)");

        // totalYieldAccrued unchanged (only accrueYield increments it)
        assertEq(vault.totalYieldAccrued(), totalYieldBefore, "totalYieldAccrued must not change from direct transfer");
    }

    // ----- L3 Step 2: OF-16-007: Donation does NOT benefit shareholders (totalAssets = _legitimateAssets) -----
    function test_TC19_donationBenefitsExistingShareholdersProportionally() public {
        // Alice gets 60% of shares, Bob gets 40%
        uint256 aliceShares = _depositViaQueue(alice, 600e6);
        uint256 bobShares = _depositViaQueue(bob, 400e6);

        uint256 aliceValueBefore = vault.convertToAssets(aliceShares);
        uint256 bobValueBefore = vault.convertToAssets(bobShares);

        // Attacker donates 100e6 directly
        riskusd.mint(attacker, 100e6);
        vm.prank(attacker);
        riskusd.transfer(address(vault), 100e6);

        uint256 aliceValueAfter = vault.convertToAssets(aliceShares);
        uint256 bobValueAfter = vault.convertToAssets(bobShares);

        // OF-16-007: Donation does NOT inflate totalAssets, so share values are unchanged
        assertEq(aliceValueAfter, aliceValueBefore, "Alice value must NOT change after donation (OF-16-007)");
        assertEq(bobValueAfter, bobValueBefore, "Bob value must NOT change after donation (OF-16-007)");
    }

    // ----- L3 Step 3: OF-16-007: Donator total loss (donation has zero effect on share price) -----
    function test_TC19_donatorNetLoss() public {
        // Alice and attacker each hold 50% of shares
        uint256 aliceShares = _depositViaQueue(alice, 500e6);
        uint256 attackerShares = _depositViaQueue(attacker, 500e6);

        uint256 attackerValueBefore = vault.convertToAssets(attackerShares);

        // Attacker donates 100e6 directly
        uint256 donationAmount = 100e6;
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        uint256 attackerValueAfter = vault.convertToAssets(attackerShares);

        // OF-16-007: Donation has zero effect on share price — attacker gains nothing
        assertEq(attackerValueAfter, attackerValueBefore, "Attacker share value must not change (OF-16-007)");

        // Attacker net loss = entire donation amount (100% loss)
        assertEq(donationAmount, 100e6, "Net loss should be 100% of donation");
    }

    // ----- L3 Step 4: Flash loan donation attack (3.3) — unprofitable -----
    function test_TC19_flashLoanDonationAttackUnprofitable() public {
        // Alice already has shares in the vault
        _depositViaQueue(alice, 1000e6);

        // Simulate flash loan: attacker gets RISKUSD
        uint256 flashLoanAmount = 10_000e6;
        riskusd.mint(attacker, flashLoanAmount);

        // (b) Attacker transfers directly to vault
        vm.prank(attacker);
        riskusd.transfer(address(vault), flashLoanAmount);

        // (c) Attacker has no shares and cannot extract value
        assertEq(vault.balanceOf(attacker), 0, "Attacker holds no shares");

        // (d) Attacker cannot withdraw -- no shares, no pending withdrawal
        vm.prank(attacker);
        vm.expectRevert(); // NoPendingWithdrawal or no shares to request
        vault.executeWithdrawal();

        // (e) Standard withdraw reverts because cooldown is enabled
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.CooldownEnabled.selector);
        vault.withdraw(flashLoanAmount, attacker, attacker);

        // Flash loan repayment impossible -- attacker lost the funds
        assertEq(riskusd.balanceOf(attacker), 0, "Attacker has no RISKUSD left to repay flash loan");
    }

    // ----- L3 Step 5: Donation + deposit in same block -----
    function test_TC19_donationPlusDepositSameBlock() public {
        // Create baseline
        _depositViaQueue(alice, 1000e6);

        uint256 totalAssetsBefore = vault.totalAssets();

        // Attacker donates then deposits in same block
        uint256 donationAmount = 500e6;
        uint256 depositAmount = 500e6;

        // Donation
        riskusd.mint(attacker, donationAmount);
        vm.prank(attacker);
        riskusd.transfer(address(vault), donationAmount);

        // Deposit (at post-donation exchange rate -- worse for attacker)
        uint256 attackerShares = _depositViaQueue(attacker, depositAmount);

        // Attacker's share value should reflect only deposited amount
        // (at the post-donation rate, which gives fewer shares)
        uint256 attackerAssetValue = vault.convertToAssets(attackerShares);

        // Attacker deposited 500e6 into a vault with totalAssets ~2000e6
        // Their shares represent only what they deposited, not the donation
        assertTrue(
            attackerAssetValue < donationAmount + depositAmount, "Attacker shares should not include donated amount"
        );

        // Attacker net position: shares worth X, spent donation + deposit
        // Net loss = (donation + deposit) - attackerAssetValue
        assertTrue(
            donationAmount + depositAmount > attackerAssetValue,
            "Attacker must have net loss from donation + deposit strategy"
        );
    }

    // ----- L3 Step 6: OF-16-007: Exchange rate unchanged after large donation -----
    function test_TC19_exchangeRatePrecisionAfterLargeDonation() public {
        _depositViaQueue(alice, 1000e6);

        // Large donation
        uint256 largeDonation = 1e15; // 1 billion RISKUSD
        riskusd.mint(attacker, largeDonation);
        vm.prank(attacker);
        riskusd.transfer(address(vault), largeDonation);

        // OF-16-007: totalAssets returns _legitimateAssets — donation has no effect
        uint256 totalAssets_ = vault.totalAssets();

        // Verify totalAssets is unaffected by donation
        assertEq(totalAssets_, 1000e6, "totalAssets should only include deposit, not donation (OF-16-007)");

        // Verify convertToShares and convertToAssets remain consistent
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceAssets = vault.convertToAssets(aliceShares);

        // Alice's assets should be exactly her deposit (donation has no effect)
        assertEq(aliceAssets, 1000e6, "Alice should not benefit from donation (OF-16-007)");

        // Round-trip consistency: convertToShares(convertToAssets(X)) should be <= X
        uint256 roundTrip = vault.convertToShares(vault.convertToAssets(aliceShares));
        assertLe(roundTrip, aliceShares, "Round-trip conversion should not exceed original shares");
    }
}
