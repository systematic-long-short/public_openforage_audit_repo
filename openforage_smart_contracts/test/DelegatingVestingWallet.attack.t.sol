// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/DelegatingVestingWalletTestBase.sol";

// ============================================================
// TC-13: Attack Vector Tests (R-04, R-16, R-20)
// Reproduces attack scenarios from attack_surface.md sections 8.6 and 8.7.
// ============================================================
contract DelegatingVestingWallet_TC13_AttackVectors is DelegatingVestingWalletTestBase {
    // ---- Attack 8.6: One-Time ForageToken Setter Hijack ----

    /// @dev Attack 8.6 step 1: Attacker cannot call setForageToken (not tokenSetter).
    function test_TC13_attack86_unauthorizedSetterBlocked() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, attacker));
        wallet.setForageToken(address(mockToken));
    }

    /// @dev Attack 8.6 step 2: Legitimate setter succeeds, then second call reverts.
    function test_TC13_attack86_legitimateSetThenSecondCallBlocked() public {
        mockToken.mint(address(wallet), TOTAL_ALLOCATION);

        // Legitimate set
        vm.prank(tokenSetterAddr);
        wallet.precommitForageToken(address(mockToken));
        vm.prank(tokenSetterAddr);
        wallet.setForageToken(address(mockToken));

        // Attacker tries to override with malicious token
        MockForageTokenSimple maliciousToken = new MockForageTokenSimple();
        vm.prank(attacker);
        vm.expectRevert(DelegatingVestingWallet.ForageTokenAlreadySet.selector);
        wallet.setForageToken(address(maliciousToken));
    }

    /// @dev Attack 8.6 step 3: After successful set, tokenSetter is cleared — no privileged setter remains.
    function test_TC13_attack86_tokenSetterClearedAfterSet() public {
        _fundAndSetTokenDefault();
        assertEq(wallet.tokenSetter(), address(0), "tokenSetter must be address(0) after set");
    }

    /// @dev Attack 8.6 step 4: Attacker front-runs deployer — still blocked by access control.
    function test_TC13_attack86_frontRunBlocked() public {
        // Deploy fresh wallet
        DelegatingVestingWallet freshWallet =
            _deployWallet(beneficiary, startTimestamp, TEAM_DURATION, TEAM_CLIFF, tokenSetterAddr);

        // Attacker tries to front-run
        MockForageTokenSimple maliciousToken = new MockForageTokenSimple();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedTokenSetter.selector, attacker));
        freshWallet.setForageToken(address(maliciousToken));

        // Legitimate deployer still can set
        // OF-NEW-08: setForageToken requires non-zero token balance
        mockToken.mint(address(freshWallet), 1e18);
        vm.prank(tokenSetterAddr);
        freshWallet.precommitForageToken(address(mockToken));
        vm.prank(tokenSetterAddr);
        freshWallet.setForageToken(address(mockToken));
        assertEq(freshWallet.forageToken(), address(mockToken));
    }

    // ---- Attack 8.7: Vesting Vote-Delegation Hijack ----

    /// @dev Attack 8.7 step 1: Attacker cannot delegate (not beneficiary).
    function test_TC13_attack87_unauthorizedDelegationBlocked() public {
        _fundAndSetTokenDefault();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedBeneficiary.selector, attacker));
        wallet.delegateVotingPower(attacker);
    }

    /// @dev Attack 8.7 step 2: Delegatee unchanged after failed attack — still beneficiary.
    function test_TC13_attack87_delegateeUnchangedAfterFailedAttack() public {
        _fundAndSetTokenDefault();

        // Record delegatee before attack
        address delegateeBefore = wallet.delegatee();
        assertEq(delegateeBefore, beneficiary, "initial delegatee is beneficiary");

        // Attack fails
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegatingVestingWallet.UnauthorizedBeneficiary.selector, attacker));
        wallet.delegateVotingPower(attacker);

        // Delegatee unchanged
        assertEq(wallet.delegatee(), delegateeBefore, "delegatee must be unchanged after failed attack");
    }
}
