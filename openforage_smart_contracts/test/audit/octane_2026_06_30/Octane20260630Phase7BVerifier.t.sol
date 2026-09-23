// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Octane20260630VaultBridgeRed.t.sol";
import "../../../src/DelegatingVestingWallet.sol";
import "../../mocks/MockAllowlist.sol";

contract Octane20260630Phase7BMutableBlocklist {
    bool internal _broken;

    function setBroken(bool broken_) external {
        _broken = broken_;
    }

    function isBlocked(address) external view returns (bool) {
        if (_broken) revert("blocklist broken");
        return false;
    }
}

contract Octane20260630Phase7BVerifierTest is Octane20260630VaultBridgeRedTest {
    function test_Phase7B_B02_riskusdMinterInactiveUntilDelayedFinalization() public {
        address owner = makeAddr("phase7b.b02.owner");
        address pendingVaultMinter = makeAddr("phase7b.b02.pendingVaultMinter");
        address holder = makeAddr("phase7b.b02.holder");
        RISKUSD token = _deployRISKUSD(owner);

        vm.prank(owner);
        token.setMinter(pendingVaultMinter);
        assertEq(token.pendingMinter(), pendingVaultMinter, "vault minter is only pending before finalization");
        assertEq(token.minter(), address(0), "no active minter before finalization");

        vm.prank(pendingVaultMinter);
        vm.expectRevert(RISKUSD.UnauthorizedMinter.selector);
        token.mint(holder, 1e6);

        vm.prank(owner);
        vm.expectRevert(RISKUSD.FinalizeDelayNotElapsed.selector);
        token.finalizeMinter();

        vm.warp(block.timestamp + token.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        token.finalizeMinter();
        assertEq(token.minter(), pendingVaultMinter, "owner finalization activates vault minter");
        assertEq(token.pendingMinter(), address(0), "pending minter clears after finalization");

        vm.prank(pendingVaultMinter);
        token.mint(holder, 1e6);
        assertEq(token.balanceOf(holder), 1e6, "finalized minter can mint");

        vm.prank(pendingVaultMinter);
        token.burn(holder, 1e6);
        assertEq(token.balanceOf(holder), 0, "finalized minter can burn");
    }

    function test_Phase7B_B04_childBlocklistRecoveryOnlyReplacesBrokenBlocklist() public {
        address beneficiary = makeAddr("phase7b.b04.beneficiary");
        address tokenSetter = makeAddr("phase7b.b04.tokenSetter");
        MockAllowlist mockAllowlist = new MockAllowlist();
        mockAllowlist.setAllAllowed(true);
        DelegatingVestingWallet wallet = new DelegatingVestingWallet(
            beneficiary, uint64(block.timestamp), 365 days, 30 days, tokenSetter, address(mockAllowlist)
        );
        Octane20260630Phase7BMutableBlocklist oldBlocklist = new Octane20260630Phase7BMutableBlocklist();
        Octane20260630Phase7BMutableBlocklist replacement = new Octane20260630Phase7BMutableBlocklist();

        vm.prank(tokenSetter);
        wallet.setBlocklist(address(oldBlocklist));
        assertEq(wallet.blocklist(), address(oldBlocklist), "healthy blocklist is installed");

        vm.prank(tokenSetter);
        vm.expectRevert(DelegatingVestingWallet.BlocklistAlreadySet.selector);
        wallet.replaceBrokenBlocklist(address(replacement));
        assertEq(wallet.blocklist(), address(oldBlocklist), "healthy blocklist cannot be silently replaced");

        oldBlocklist.setBroken(true);
        vm.prank(tokenSetter);
        wallet.replaceBrokenBlocklist(address(replacement));
        assertEq(wallet.blocklist(), address(replacement), "broken child blocklist can be recovered");
    }

    function test_Phase7B_B04_foundationPrimaryFinalizerExpiresStaleProposal() public {
        address owner = makeAddr("phase7b.b04.foundationOwner");
        address newFoundationPrimary = makeAddr("phase7b.b04.newFoundationPrimary");
        address oldFoundationPrimary = makeAddr("phase7b.b04.foundationPrimary");
        USDCTreasury treasury = _deployTreasury(
            address(new MockUSDC()),
            makeAddr("phase7b.b04.vault"),
            makeAddr("phase7b.b04.registry"),
            owner,
            oldFoundationPrimary,
            makeAddr("phase7b.b04.foundationBackup"),
            makeAddr("phase7b.b04.protocolPrimary"),
            makeAddr("phase7b.b04.protocolBackup")
        );

        vm.prank(owner);
        treasury.proposeFoundationPrimary(newFoundationPrimary);
        vm.warp(block.timestamp + 365 days);

        vm.prank(owner);
        vm.expectRevert(USDCTreasury.ProposalExpired.selector);
        treasury.finalizeFoundationPrimary();
        assertEq(
            treasury.foundationPrimary(),
            oldFoundationPrimary,
            "foundation primary finalizer must not execute after a stale delay"
        );

        vm.prank(owner);
        treasury.cancelPendingFoundationPrimary();
        assertEq(treasury.pendingFoundationPrimary(), address(0), "stale proposal can be explicitly cancelled");
    }

    function test_Phase7B_B04_finalizeDelayProfileUsesProductionDelayOutsideLocalAndSepolia() public {
        address owner = makeAddr("phase7b.b04.delayOwner");
        RISKUSD token = _deployRISKUSD(owner);

        vm.chainId(31_337);
        assertEq(token.FINALIZE_DELAY(), 10 minutes, "local chain uses accelerated verifier delay");

        vm.chainId(42_161);
        assertEq(token.FINALIZE_DELAY(), 2 days, "Arbitrum One uses production finalizer delay");

        vm.chainId(31_337);
    }
}
