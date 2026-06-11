// Reconstructed from documentation/smart_contract_audits/2026-05-25-v12-audit/addressed_findings.html
// ID #74891: Blocked spenders retain allowances across all tokens.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../src/Blocklist.sol";
import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../../src/atRISKUSD.sol";
import "../../mocks/MockYieldSourceForLossPending.sol";

interface IV12_74891_BlocklistManaged {
    function setBlocklist(address blocklist_) external;
    function blocklist() external view returns (address);
}

contract V12_74891_BlockedAllowanceZeroingTest is Test {
    Blocklist internal registry;
    ForageToken internal forage;
    RISKUSD internal riskusd;
    atRISKUSD internal atRisk;
    MockYieldSourceForLossPending internal yieldSourceContract;

    address internal owner;
    address internal blockGuardian;
    address internal teamVesting;
    address internal forageTreasury;
    address internal riskMinter;
    address internal stakingQueue;
    address internal yieldSource;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        owner = makeAddr("v12AllowanceOwner");
        blockGuardian = makeAddr("v12AllowanceBlockGuardian");
        teamVesting = makeAddr("v12AllowanceTeamVesting");
        forageTreasury = makeAddr("v12AllowanceForageTreasury");
        riskMinter = makeAddr("v12AllowanceRiskMinter");
        stakingQueue = makeAddr("v12AllowanceStakingQueue");
        yieldSourceContract = new MockYieldSourceForLossPending();
        yieldSource = address(yieldSourceContract);
        alice = makeAddr("v12AllowanceAlice");
        bob = makeAddr("v12AllowanceBob");
        spender = makeAddr("v12AllowanceSpender");

        registry = _deployBlocklist();
        forage = _deployForage();
        riskusd = _deployRiskusd();
        atRisk = _deployAtRisk();

        vm.startPrank(owner);
        IV12_74891_BlocklistManaged(address(forage)).setBlocklist(address(registry));
        IV12_74891_BlocklistManaged(address(riskusd)).setBlocklist(address(registry));
        IV12_74891_BlocklistManaged(address(atRisk)).setBlocklist(address(registry));
        vm.stopPrank();

        vm.prank(forageTreasury);
        forage.transfer(alice, 1_000e18);

        vm.prank(riskMinter);
        riskusd.mint(alice, 1_000e6);

        _depositAtRisk(alice, 1_000e6);
    }

    function test_74891_fix_forageZeroAllowanceToBlockedSpenderClearsStaleApproval() public {
        uint256 allowanceAmount = 25e18;

        vm.prank(alice);
        forage.approve(spender, allowanceAmount);
        _block(spender);

        vm.prank(spender);
        vm.expectRevert(_forageBlocked(spender));
        forage.transferFrom(alice, bob, 1e18);

        vm.prank(alice);
        vm.expectRevert(_forageBlocked(spender));
        forage.approve(spender, allowanceAmount);

        vm.prank(alice);
        assertTrue(forage.approve(spender, 0), "blocked FORAGE spender allowance can be zeroed");
        assertEq(forage.allowance(alice, spender), 0, "FORAGE allowance cleared while spender blocked");

        vm.prank(alice);
        vm.expectRevert(_forageBlocked(spender));
        forage.approve(spender, 1);
        assertEq(forage.allowance(alice, spender), 0, "blocked FORAGE spender cannot receive fresh allowance");

        _unblock(spender);

        vm.prank(spender);
        vm.expectRevert();
        forage.transferFrom(alice, bob, 1e18);
        assertEq(forage.balanceOf(bob), 0, "cleared FORAGE allowance cannot revive after unblock");
    }

    function test_74891_fix_riskusdZeroAllowanceToBlockedSpenderClearsStaleApproval() public {
        uint256 allowanceAmount = 25e6;

        vm.prank(alice);
        riskusd.approve(spender, allowanceAmount);
        _block(spender);

        vm.prank(spender);
        vm.expectRevert(_riskusdBlocked(spender));
        riskusd.transferFrom(alice, bob, 1e6);

        vm.prank(alice);
        vm.expectRevert(_riskusdBlocked(spender));
        riskusd.approve(spender, allowanceAmount);

        vm.prank(alice);
        assertTrue(riskusd.approve(spender, 0), "blocked RISKUSD spender allowance can be zeroed");
        assertEq(riskusd.allowance(alice, spender), 0, "RISKUSD allowance cleared while spender blocked");

        vm.prank(alice);
        vm.expectRevert(_riskusdBlocked(spender));
        riskusd.approve(spender, 1);
        assertEq(riskusd.allowance(alice, spender), 0, "blocked RISKUSD spender cannot receive fresh allowance");

        _unblock(spender);

        vm.prank(spender);
        vm.expectRevert();
        riskusd.transferFrom(alice, bob, 1e6);
        assertEq(riskusd.balanceOf(bob), 0, "cleared RISKUSD allowance cannot revive after unblock");
    }

    function test_74891_fix_atRiskZeroAllowanceToBlockedSpenderClearsStaleApproval() public {
        uint256 allowanceAmount = atRisk.balanceOf(alice) / 4;
        assertGt(allowanceAmount, 0, "atRISKUSD shares available");

        vm.prank(alice);
        atRisk.approve(spender, allowanceAmount);
        _block(spender);

        vm.prank(spender);
        vm.expectRevert(_atRiskBlocked(spender));
        atRisk.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(_atRiskBlocked(spender));
        atRisk.approve(spender, allowanceAmount);

        vm.prank(alice);
        assertTrue(atRisk.approve(spender, 0), "blocked atRISKUSD spender allowance can be zeroed");
        assertEq(atRisk.allowance(alice, spender), 0, "atRISKUSD allowance cleared while spender blocked");

        vm.prank(alice);
        vm.expectRevert(_atRiskBlocked(spender));
        atRisk.approve(spender, 1);
        assertEq(atRisk.allowance(alice, spender), 0, "blocked atRISKUSD spender cannot receive fresh allowance");

        _unblock(spender);

        vm.prank(spender);
        vm.expectRevert();
        atRisk.transferFrom(alice, bob, 1);
        assertEq(atRisk.balanceOf(bob), 0, "cleared atRISKUSD allowance cannot revive after unblock");
    }

    function _deployBlocklist() internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (blockGuardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployForage() internal returns (ForageToken) {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployRiskusd() internal returns (RISKUSD) {
        RISKUSD implementation = new RISKUSD();
        RISKUSD token =
            RISKUSD(address(new ERC1967Proxy(address(implementation), abi.encodeCall(RISKUSD.initialize, (owner)))));

        vm.startPrank(owner);
        token.setMinter(riskMinter);
        vm.warp(block.timestamp + token.FINALIZE_DELAY() + 1);
        token.finalizeMinter();
        vm.stopPrank();

        return token;
    }

    function _deployAtRisk() internal returns (atRISKUSD) {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData =
            abi.encodeCall(atRISKUSD.initialize, (address(riskusd), yieldSource, stakingQueue, 0, 0, 0, "0D", owner));
        return atRISKUSD(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _depositAtRisk(address receiver, uint256 assets) internal {
        vm.prank(riskMinter);
        riskusd.mint(stakingQueue, assets);

        vm.startPrank(stakingQueue);
        riskusd.approve(address(atRisk), assets);
        atRisk.deposit(assets, receiver);
        vm.stopPrank();
    }

    function _block(address account) internal {
        vm.prank(blockGuardian);
        registry.blockAddress(account);
        assertTrue(registry.isBlocked(account), "account blocked");
    }

    function _unblock(address account) internal {
        vm.prank(owner);
        registry.proposeUnblock(account);
        vm.warp(block.timestamp + registry.FINALIZE_DELAY() + 1);
        vm.prank(owner);
        registry.finalizeUnblock(account);
        assertFalse(registry.isBlocked(account), "account unblocked");
    }

    function _forageBlocked(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ForageToken.BlockedAddress.selector, account);
    }

    function _riskusdBlocked(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RISKUSD.BlockedAddress.selector, account);
    }

    function _atRiskBlocked(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(atRISKUSD.BlockedAddress.selector, account);
    }
}
