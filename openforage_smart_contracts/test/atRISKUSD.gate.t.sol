// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "../src/interfaces/IAllowlist.sol";

/// @dev DEC-1074/DEC-1045 negative proof for the atRISKUSD caller gate:
/// an unverified caller is refused before any check the body would run.
contract AtRISKUSDGateTest is AtRISKUSDTestBase {
    function test_gate_unverifiedDepositRevertsCallerNotAllowed() public {
        allowlist.setAllowed(stakingQueue, false);

        riskusd.mint(stakingQueue, 1_000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, stakingQueue));
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_gate_unverifiedCallerRevertsBeforeQueueAuthorization() public {
        allowlist.setAllowed(attacker, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        vault.deposit(1_000e6, alice);
    }

    function test_gate_allowedCallerDepositSucceeds() public {
        allowlist.setAllAllowed(true);

        riskusd.mint(stakingQueue, 1_000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "deposit should mint shares");
        assertEq(vault.balanceOf(alice), shares, "shares should belong to the receiver");
    }
}
