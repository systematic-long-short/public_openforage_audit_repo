// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-20: Attack Vector -- Cooldown Bypass Attempts (R-16, R-20)
// ============================================================
contract AtRISKUSD_TC20_AttackCooldown is AtRISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _raiseWeeklyWithdrawalCap(vault);
    }

    // ----- L3 Step 1: Flash loan yield extraction (3.1) -----
    // Deposit + immediate withdraw/execute in same block fails.
    function test_TC20_flashLoanYieldExtraction_standardWithdrawReverts() public {
        // Deposit via StakingQueue
        _depositViaQueue(attacker, 1000e6);

        // OF-005: Lockup check fires before cooldown -- MUST revert with LockupNotExpired
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + vault.lockupPeriod())
        );
        vault.withdraw(1000e6, attacker, attacker);
    }

    function test_TC20_flashLoanYieldExtraction_requestThenExecuteSameBlock() public {
        // Deposit via StakingQueue
        uint256 shares = _depositViaQueue(attacker, 1000e6);

        // Warp past lockup to allow request
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Request withdrawal
        vm.prank(attacker);
        vault.requestWithdrawal(shares);

        // Immediately try to execute in same block -- MUST revert
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, block.timestamp + COOLDOWN_PERIOD)
        );
        vault.executeWithdrawal();
    }

    // ----- L3 Step 2: Transfer to bypass cooldown -----
    // OF-016: Alice cannot transfer during active lockup.
    // After lockup expires, Alice transfers to Bob. Bob must still wait cooldown.
    function test_TC20_transferDoesNotBypassCooldown() public {
        // Alice deposits
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // OF-016: Transfer during lockup reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + LOCKUP_PERIOD));
        vault.transfer(bob, aliceShares);

        // Warp past lockup so Alice can transfer
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Alice transfers shares to Bob (now allowed — lockup expired)
        vm.prank(alice);
        vault.transfer(bob, aliceShares);

        // Bob can request withdrawal (no lockup propagated from non-StakingQueue transfer)
        vm.prank(bob);
        vault.requestWithdrawal(aliceShares);

        // But still must wait cooldown to execute
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, block.timestamp + COOLDOWN_PERIOD)
        );
        vault.executeWithdrawal();

        // Only after cooldown can Bob execute
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        vm.prank(bob);
        vault.executeWithdrawal(); // should succeed
    }

    // ----- L3 Step 3: redeemForUpgrade as cooldown bypass -----
    // Regular users cannot call redeemForUpgrade -- only StakingQueue.
    function test_TC20_redeemForUpgradeNotBypassForRegularUsers() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Alice tries to bypass cooldown using redeemForUpgrade
        vm.prank(alice);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.redeemForUpgrade(alice, aliceShares);

        // Attacker tries
        vm.prank(attacker);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.redeemForUpgrade(alice, aliceShares);
    }

    // ----- L3 Step 4: Standard ERC-4626 redeem as bypass -----
    function test_TC20_standardRedeemRevertsWithCooldownEnabled() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // OF-005: Lockup check fires before cooldown check
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + vault.lockupPeriod())
        );
        vault.redeem(aliceShares, alice, alice);
    }

    // ----- L3 Step 5: cancelWithdrawal + re-request resets cooldown -----
    function test_TC20_cancelAndReRequestResetsCooldown() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        uint256 requestTime1 = block.timestamp;

        // Alice requests withdrawal
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares / 2);

        // Alice cancels after 3 days
        vm.warp(requestTime1 + 3 days);
        vm.prank(alice);
        vault.cancelWithdrawal();

        // Alice re-requests -- new cooldown starts from now
        uint256 requestTime2 = block.timestamp;
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares / 2);

        // Cannot execute at original cooldown end (requestTime1 + 7 days)
        // because new cooldown is from requestTime2
        vm.warp(requestTime1 + COOLDOWN_PERIOD);
        // This should revert because requestTime2 + COOLDOWN_PERIOD > requestTime1 + COOLDOWN_PERIOD
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, requestTime2 + COOLDOWN_PERIOD));
        vault.executeWithdrawal();

        // Can execute after new cooldown (requestTime2 + COOLDOWN_PERIOD)
        vm.warp(requestTime2 + COOLDOWN_PERIOD);
        vm.prank(alice);
        vault.executeWithdrawal(); // should succeed
    }

    // ----- L3 Step 6: Timestamp manipulation — cooldown uses block.timestamp -----
    // Verify no caller-supplied timestamp can influence cooldown.
    function test_TC20_cooldownUsesBlockTimestampNotCallerInput() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // Warp past lockup
        vm.warp(block.timestamp + LOCKUP_PERIOD);

        // Request withdrawal
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        // Verify the request timestamp stored matches block.timestamp
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(alice);
        assertEq(pw.requestTimestamp, block.timestamp, "Request timestamp must use block.timestamp");

        // Exact boundary test: 1 second before cooldown -- reverts
        vm.warp(pw.requestTimestamp + COOLDOWN_PERIOD - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.CooldownNotElapsed.selector, pw.requestTimestamp + COOLDOWN_PERIOD)
        );
        vault.executeWithdrawal();

        // At exactly cooldown -- succeeds
        vm.warp(pw.requestTimestamp + COOLDOWN_PERIOD);
        vm.prank(alice);
        vault.executeWithdrawal(); // should succeed
    }
}
