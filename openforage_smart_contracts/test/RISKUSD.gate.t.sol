// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/RISKUSDTestBase.sol";
import "../src/interfaces/IAllowlist.sol";

// ============================================================
// KYC-01: Caller gate negative proof for RISKUSD
// ============================================================
contract RISKUSD_Gate is RISKUSDTestBase {
    function setUp() public override {
        super.setUp();
        _setupMinter();
    }

    /// @dev KYC-01: a denied caller reverts CallerNotAllowed on mint before the minter check runs.
    function test_gate_unverifiedMintRevertsCallerNotAllowed() public {
        allowlist.setAllAllowed(false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, minterAddr));
        vm.prank(minterAddr);
        token.mint(alice, 1000e6);

        allowlist.setAllAllowed(true);

        vm.prank(minterAddr);
        token.mint(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);
    }

    /// @dev KYC-01: a caller denied on purpose (not only by omission) also reverts CallerNotAllowed.
    function test_gate_deniedMintRevertsBeforeMinterCheck() public {
        allowlist.setAllowed(attacker, false);

        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, attacker));
        vm.prank(attacker);
        token.mint(alice, 1000e6);
    }
}
