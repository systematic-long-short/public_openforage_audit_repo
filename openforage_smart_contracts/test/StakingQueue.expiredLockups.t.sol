// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ============================================================
// TC-08: Expired Lockup Processing Tests (L3 steps 1-14)
// ============================================================
contract StakingQueue_TC08_ExpiredLockups is StakingQueueTestBase {
    /// @dev L3 step 1: processExpiredLockups with tier 0 MUST revert InvalidTier.
    ///      Tier 0 has no lockup.
    function test_TC08_invalidTierZero() public {
        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.processExpiredLockups(depositors, 0);
    }

    /// @dev L3 step 2: processExpiredLockups with tier 4 MUST revert InvalidTier.
    function test_TC08_invalidTierFour() public {
        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.processExpiredLockups(depositors, 4);
    }

    /// @dev L3 step 3: processExpiredLockups with tier 255 MUST revert InvalidTier.
    function test_TC08_invalidTier255() public {
        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectRevert(StakingQueue.InvalidTier.selector);
        queue.processExpiredLockups(depositors, 255);
    }

    /// @dev L3 step 4: processExpiredLockups with empty depositors array MUST revert ZeroAmount.
    function test_TC08_emptyDepositorsArray() public {
        address[] memory depositors = new address[](0);

        vm.expectRevert(StakingQueue.ZeroAmount.selector);
        queue.processExpiredLockups(depositors, 1);
    }

    /// @dev L3 step 5: processExpiredLockups while paused MUST revert EnforcedPause.
    function test_TC08_pausedReverts() public {
        vm.prank(owner);
        queue.pause();

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.processExpiredLockups(depositors, 1);
    }

    /// @dev L3 step 6: Happy path reversion (auto-renewal disabled).
    ///      Alice has expired lockup in tier 1, auto-renewal disabled.
    ///      Calls redeemForReversion on tier vault, deposits RISKUSD into tier 0.
    ///      Emits LockupReverted event.
    function test_TC08_happyPathReversion() public {
        // Set up Alice's lockup state on tier 1 vault: expired, no auto-renew
        vault1.setLockupInfo(alice, true, true, false, false, 1000e6);
        vault1.setRedeemForReversionReturnAmount(1000e6);
        riskusd.mint(address(vault1), 1000e6);

        // Mock the vault to report lockup state when StakingQueue queries it
        // The real contract will call vault functions to check lockup state.
        // We use vm.mockCall to simulate the vault's lockup query responses.
        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));
        vm.mockCall(
            address(vault1), abi.encodeWithSignature("lockupShares(address)", alice), abi.encode(uint256(1000e6))
        );

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectEmit(true, false, false, true);
        emit StakingQueue.LockupReverted(alice, 1, 1000e6);

        queue.processExpiredLockups(depositors, 1);

        // Verify redeemForReversion called on vault1
        assertEq(vault1.redeemForReversionCallCount(), 1, "redeemForReversion should be called once on vault1");

        // Verify deposit called on vault0 (Tier 0)
        assertEq(vault0.depositCallCount(), 1, "deposit should be called once on vault0 for tier 0 reversion");
    }

    /// @dev L3 step 7: Happy path auto-renewal (enabled).
    ///      Alice has expired lockup in tier 2, auto-renewal enabled.
    ///      Calls renewLockup on tier vault. Emits LockupRenewed event.
    function test_TC08_happyPathAutoRenewal() public {
        // Set up Alice's lockup state: expired, auto-renew enabled
        vault2.setLockupInfo(alice, true, true, true, false, 500e6);
        uint256 newExpiry = block.timestamp + 180 days;
        vault2.setRenewLockupReturnExpiry(newExpiry);

        vm.mockCall(address(vault2), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault2), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(true));
        vm.mockCall(address(vault2), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        vm.expectEmit(true, false, false, true);
        emit StakingQueue.LockupRenewed(alice, 2, newExpiry);

        queue.processExpiredLockups(depositors, 2);

        // Verify renewLockup called on vault2
        assertEq(vault2.renewLockupCallCount(), 1, "renewLockup should be called once on vault2");

        // Verify NO reversion happened (no redeemForReversion, no deposit to vault0)
        assertEq(vault2.redeemForReversionCallCount(), 0, "no redeemForReversion should be called");
        assertEq(vault0.depositCallCount(), 0, "no deposit to vault0 for auto-renewal");
    }

    /// @dev L3 step 8: Non-expired lockup skipped. No calls, no events.
    function test_TC08_nonExpiredLockupSkipped() public {
        // Alice's lockup is NOT expired
        vault1.setLockupInfo(alice, true, false, false, false, 500e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        queue.processExpiredLockups(depositors, 1);

        // Verify no calls made
        assertEq(vault1.redeemForReversionCallCount(), 0, "no redeemForReversion for non-expired");
        assertEq(vault1.renewLockupCallCount(), 0, "no renewLockup for non-expired");
        assertEq(vault0.depositCallCount(), 0, "no deposit for non-expired");
    }

    /// @dev L3 step 9: Pending withdrawal skipped. No revert, no action.
    function test_TC08_pendingWithdrawalSkipped() public {
        // Alice has a pending withdrawal
        vault1.setLockupInfo(alice, true, true, false, true, 500e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(true));

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        // Should NOT revert, just skip alice
        queue.processExpiredLockups(depositors, 1);

        assertEq(vault1.redeemForReversionCallCount(), 0, "no redeemForReversion for pending withdrawal");
        assertEq(vault1.renewLockupCallCount(), 0, "no renewLockup for pending withdrawal");
    }

    /// @dev L3 step 10: Batch processing with mixed states.
    ///      Alice: expired, no auto-renew -> revert to tier 0.
    ///      Bob: expired, auto-renew -> renew.
    ///      Charlie: not expired -> skip.
    function test_TC08_batchProcessingMixedStates() public {
        // Alice: expired, no auto-renew
        vault1.setLockupInfo(alice, true, true, false, false, 1000e6);
        vault1.setRedeemForReversionReturnAmount(1000e6);
        riskusd.mint(address(vault1), 1000e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));
        vm.mockCall(
            address(vault1), abi.encodeWithSignature("lockupShares(address)", alice), abi.encode(uint256(1000e6))
        );

        // Bob: expired, auto-renew
        vault1.setLockupInfo(bob, true, true, true, false, 500e6);
        uint256 bobExpiry = block.timestamp + 90 days;
        vault1.setRenewLockupReturnExpiry(bobExpiry);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", bob), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", bob), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", bob), abi.encode(false));

        // Charlie: not expired
        vault1.setLockupInfo(charlie, true, false, false, false, 300e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", charlie), abi.encode(false));
        vm.mockCall(
            address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", charlie), abi.encode(false)
        );

        address[] memory depositors = new address[](3);
        depositors[0] = alice;
        depositors[1] = bob;
        depositors[2] = charlie;

        queue.processExpiredLockups(depositors, 1);

        // Alice: reversion (redeemForReversion + deposit to vault0)
        assertEq(vault1.redeemForReversionCallCount(), 1, "alice reversion: redeemForReversion called once");
        assertEq(vault0.depositCallCount(), 1, "alice reversion: deposit to vault0 called once");

        // Bob: renewal (renewLockup called)
        assertEq(vault1.renewLockupCallCount(), 1, "bob renewal: renewLockup called once");
    }

    /// @dev L3 step 11: Per-depositor error isolation.
    ///      Alice's reversion fails (vault reverts). Bob's succeeds. Batch does not revert.
    function test_TC08_perDepositorErrorIsolation() public {
        // Alice: will fail (mock revert on redeemForReversion)
        vault1.setLockupInfo(alice, true, true, false, false, 500e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));
        vm.mockCall(
            address(vault1), abi.encodeWithSignature("lockupShares(address)", alice), abi.encode(uint256(500e6))
        );

        // Bob: will succeed
        vault1.setLockupInfo(bob, true, true, false, false, 300e6);
        vault1.setRedeemForReversionReturnAmount(300e6);
        riskusd.mint(address(vault1), 300e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", bob), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", bob), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", bob), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("lockupShares(address)", bob), abi.encode(uint256(300e6)));

        // Make alice's reversion fail at the vault level
        // We need to make the vault revert for alice but succeed for bob.
        // Since MockAtRISKUSD uses a global shouldRevertRedeemForReversion flag,
        // we use vm.mockCallRevert for alice's specific call.
        vm.mockCallRevert(
            address(vault1),
            abi.encodeWithSignature("redeemForReversion(address,uint256)", alice, 500e6),
            "MockAtRISKUSD: redeemForReversion reverted for alice"
        );

        address[] memory depositors = new address[](2);
        depositors[0] = alice;
        depositors[1] = bob;

        // Batch should NOT revert despite alice's failure
        queue.processExpiredLockups(depositors, 1);

        // Bob's reversion should have succeeded. Alice's should have been skipped/caught.
        // Exact count assertions: only bob's calls should succeed.
        assertEq(
            vault1.redeemForReversionCallCount(), 1, "only bob's redeemForReversion should succeed (alice's reverted)"
        );
        assertEq(vault0.depositCallCount(), 1, "only bob's deposit to vault0 should occur");

        // Verify the successful deposit was for bob, not alice
        (uint256 depositedAmount, address depositor) = vault0.depositCalls(0);
        assertEq(depositor, bob, "deposit to vault0 should be for bob, not alice");
        assertEq(depositedAmount, 300e6, "deposited amount should match bob's reversion amount");
    }

    /// @dev L3 step 12: Reversion across all tiers (1, 2, 3).
    ///      Each routes to correct tier vault and deposits into Tier 0.
    function test_TC08_reversionAcrossAllTiers() public {
        MockAtRISKUSD[3] memory tierVaults = [vault1, vault2, vault3];

        for (uint8 tier = 1; tier <= 3; tier++) {
            MockAtRISKUSD vault = tierVaults[tier - 1];

            vault.setLockupInfo(alice, true, true, false, false, 100e6);
            vault.setRedeemForReversionReturnAmount(100e6);
            riskusd.mint(address(vault), 100e6);

            vm.mockCall(address(vault), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
            vm.mockCall(address(vault), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(false));
            vm.mockCall(
                address(vault), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false)
            );
            vm.mockCall(
                address(vault), abi.encodeWithSignature("lockupShares(address)", alice), abi.encode(uint256(100e6))
            );

            address[] memory depositors = new address[](1);
            depositors[0] = alice;

            vm.expectEmit(true, false, false, true);
            emit StakingQueue.LockupReverted(alice, tier, 100e6);

            queue.processExpiredLockups(depositors, tier);
        }

        // All 3 tier reversions should deposit into vault0
        assertEq(vault0.depositCallCount(), 3, "vault0 should have 3 deposits (one per tier reversion)");
    }

    /// @dev L3 step 13: Approved keeper can process another depositor; arbitrary callers cannot.
    function test_TC08_approvedProcessorRequiredForThirdPartyCaller() public {
        vault1.setLockupInfo(alice, true, true, false, false, 100e6);
        vault1.setRedeemForReversionReturnAmount(100e6);
        riskusd.mint(address(vault1), 100e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", alice), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", alice), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", alice), abi.encode(false));
        vm.mockCall(
            address(vault1), abi.encodeWithSignature("lockupShares(address)", alice), abi.encode(uint256(100e6))
        );

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        // Approved keeper can process another depositor.
        vm.prank(keeper);
        queue.processExpiredLockups(depositors, 1);

        // Call from attacker - should also succeed (permissionless)
        // Reset vault state for another call
        vault1.setLockupInfo(bob, true, true, false, false, 50e6);
        vault1.setRedeemForReversionReturnAmount(50e6);
        riskusd.mint(address(vault1), 50e6);

        vm.mockCall(address(vault1), abi.encodeWithSignature("isLockupExpired(address)", bob), abi.encode(true));
        vm.mockCall(address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", bob), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("hasPendingWithdrawal(address)", bob), abi.encode(false));
        vm.mockCall(address(vault1), abi.encodeWithSignature("lockupShares(address)", bob), abi.encode(uint256(50e6)));

        address[] memory depositors2 = new address[](1);
        depositors2[0] = bob;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(StakingQueue.UnauthorizedLockupProcessor.selector, attacker));
        queue.processExpiredLockups(depositors2, 1);
    }

    /// @dev L3 step 14: Large batch - 50 depositors with mixed states.
    function test_TC08_largeBatch50Depositors() public {
        uint256 batchSize = 50;
        address[] memory depositors = new address[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            address depositor = address(uint160(0x1000 + i));
            depositors[i] = depositor;

            if (i % 3 == 0) {
                // Every 3rd depositor: expired, no auto-renew (reversion)
                vault1.setLockupInfo(depositor, true, true, false, false, 100e6);

                vm.mockCall(
                    address(vault1), abi.encodeWithSignature("isLockupExpired(address)", depositor), abi.encode(true)
                );
                vm.mockCall(
                    address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", depositor), abi.encode(false)
                );
                vm.mockCall(
                    address(vault1),
                    abi.encodeWithSignature("hasPendingWithdrawal(address)", depositor),
                    abi.encode(false)
                );
                vm.mockCall(
                    address(vault1),
                    abi.encodeWithSignature("lockupShares(address)", depositor),
                    abi.encode(uint256(100e6))
                );
            } else if (i % 3 == 1) {
                // Every 3rd+1 depositor: expired, auto-renew (renewal)
                vault1.setLockupInfo(depositor, true, true, true, false, 100e6);

                vm.mockCall(
                    address(vault1), abi.encodeWithSignature("isLockupExpired(address)", depositor), abi.encode(true)
                );
                vm.mockCall(
                    address(vault1), abi.encodeWithSignature("autoRenewEnabled(address)", depositor), abi.encode(true)
                );
                vm.mockCall(
                    address(vault1),
                    abi.encodeWithSignature("hasPendingWithdrawal(address)", depositor),
                    abi.encode(false)
                );
            } else {
                // Every 3rd+2 depositor: not expired (skip)
                vault1.setLockupInfo(depositor, true, false, false, false, 100e6);

                vm.mockCall(
                    address(vault1), abi.encodeWithSignature("isLockupExpired(address)", depositor), abi.encode(false)
                );
                vm.mockCall(
                    address(vault1),
                    abi.encodeWithSignature("hasPendingWithdrawal(address)", depositor),
                    abi.encode(false)
                );
            }
        }

        // Fund vault1 with enough RISKUSD for all reversions (17 reversions * 100e6)
        vault1.setRedeemForReversionReturnAmount(100e6);
        riskusd.mint(address(vault1), 17 * 100e6);

        uint256 renewExpiry = block.timestamp + 90 days;
        vault1.setRenewLockupReturnExpiry(renewExpiry);

        // Should not revert - process all 50 depositors
        queue.processExpiredLockups(depositors, 1);

        // 17 depositors reverted (indices 0,3,6,...,48) -> 17 deposits to vault0
        assertEq(vault0.depositCallCount(), 17, "17 reversions should deposit to vault0");

        // 17 depositors renewed (indices 1,4,7,...,49) -> 17 renewLockup calls
        assertEq(vault1.renewLockupCallCount(), 17, "17 renewals should call renewLockup");

        // 16 depositors skipped (indices 2,5,8,...,47) -> no action
    }
}
