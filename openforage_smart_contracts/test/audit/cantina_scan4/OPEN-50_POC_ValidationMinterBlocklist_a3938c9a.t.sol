// Materialized from documentation/smart_contract_audits/2026-05-30-cantina-audit/openforage_audit_repo — Scan #4 — findings.md lines 3735-3788.
// Original audit path: test/POC_ValidationMinterBlocklist_a3938c9a.t.sol. Finding: OPEN-50 (Informational).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../src/Blocklist.sol";
import "../../../src/RISKUSD.sol";
import "../../helpers/RISKUSDTestBase.sol";

interface IPOCBlocklistManaged {
    function setBlocklist(address blocklist_) external;
}

/**
 * @title Fix proof: Blocklisted minter cannot retain RISKUSD mint and paused-burn authority
 * @notice Proof Statement: Proves that after the current minter is blocklisted, `RISKUSD.mint()`
 * and `RISKUSD.burn()` both reject the blocked caller while non-blocked minter paths remain live.
 */
contract POC_ValidationMinterBlocklist_a3938c9a_Test is RISKUSDTestBase {
    Blocklist internal registry;
    address internal blockGuardian;

    function setUp() public override {
        super.setUp();
        blockGuardian = makeAddr("blockGuardian");

        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (blockGuardian, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        registry = Blocklist(address(proxy));

        vm.prank(owner);
        IPOCBlocklistManaged(address(token)).setBlocklist(address(registry));

        _setupMinter();
        _mintTokens(alice, 1_000e6);
    }

    function test_fix_blocklistedMinterCannotMintOrBurnWhilePaused() public {
        vm.prank(minterAddr);
        token.mint(bob, 25e6);
        assertEq(token.balanceOf(bob), 25e6, "non-blocked minter still mints");

        vm.prank(owner);
        token.pause();

        vm.prank(minterAddr);
        token.burn(alice, 25e6);
        assertEq(token.balanceOf(alice), 975e6, "non-blocked minter still burns while paused");

        vm.prank(owner);
        token.unpause();

        vm.prank(blockGuardian);
        registry.blockAddress(minterAddr);
        assertTrue(registry.isBlocked(minterAddr), "minter should be blocklisted");

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.BlockedAddress.selector, minterAddr));
        token.mint(bob, 100e6);
        assertEq(token.balanceOf(bob), 25e6, "blocklisted minter cannot mint");

        vm.prank(owner);
        token.pause();

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.BlockedAddress.selector, minterAddr));
        token.burn(alice, 250e6);
        assertEq(token.balanceOf(alice), 975e6, "blocklisted minter cannot burn while paused");
    }
}
