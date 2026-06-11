// Reconstructed from documentation/smart_contract_audits/2026-05-25-v12-audit/addressed_findings.html
// ID #74892: Privileged callers bypass emergency blocklist.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../src/Blocklist.sol";
import "../../../src/ForageToken.sol";
import "../../../src/RISKUSD.sol";
import "../../helpers/ForageTokenTestBase.sol";
import "../../helpers/RISKUSDTestBase.sol";

interface IV12BlocklistManaged {
    function setBlocklist(address blocklist_) external;
    function blocklist() external view returns (address);
}

abstract contract V12_74892_BlocklistSupport {
    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _blockedAddressRevert(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ForageToken.BlockedAddress.selector, account);
    }
}

contract V12_74892_RISKUSDPrivilegedCallerBlocklistTest is RISKUSDTestBase, V12_74892_BlocklistSupport {
    Blocklist internal registry;
    address internal blockGuardian;

    function setUp() public override {
        super.setUp();
        blockGuardian = makeAddr("v12RiskusdBlockGuardian");
        registry = _deployBlocklist(blockGuardian, owner);

        vm.prank(owner);
        IV12BlocklistManaged(address(token)).setBlocklist(address(registry));
        assertEq(IV12BlocklistManaged(address(token)).blocklist(), address(registry), "RISKUSD blocklist");

        _setupMinter();
        _mintTokens(alice, 1_000e6);
    }

    function test_74892_fix_blockedRiskusdMinterCannotMint() public {
        vm.prank(blockGuardian);
        registry.blockAddress(minterAddr);

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.BlockedAddress.selector, minterAddr));
        token.mint(bob, 100e6);
        assertEq(token.balanceOf(bob), 0, "blocked minter cannot mint RISKUSD");
    }

    function test_74892_fix_blockedRiskusdMinterCannotBurn() public {
        vm.prank(blockGuardian);
        registry.blockAddress(minterAddr);

        vm.prank(minterAddr);
        vm.expectRevert(abi.encodeWithSelector(RISKUSD.BlockedAddress.selector, minterAddr));
        token.burn(alice, 100e6);
        assertEq(token.balanceOf(alice), 1_000e6, "blocked minter cannot burn RISKUSD");
    }
}

contract V12_74892_ForagePrivilegedCallerBlocklistTest is ForageTokenTestBase, V12_74892_BlocklistSupport {
    Blocklist internal registry;
    address internal blockGuardian;

    function setUp() public override {
        super.setUp();
        blockGuardian = makeAddr("v12ForageBlockGuardian");
        registry = _deployBlocklist(blockGuardian, owner);

        vm.prank(owner);
        IV12BlocklistManaged(address(token)).setBlocklist(address(registry));
        assertEq(IV12BlocklistManaged(address(token)).blocklist(), address(registry), "FORAGE blocklist");

        _fundAlice(1_000e18);
        _setupLocker();
        _setupBurner();
    }

    function test_74892_fix_blockedForageLockerCannotLock() public {
        vm.prank(authorizedLocker);
        token.lock(alice, 100e18);
        assertEq(token.lockedBalance(alice), 100e18, "non-blocked locker still locks");

        vm.prank(blockGuardian);
        registry.blockAddress(authorizedLocker);

        vm.prank(authorizedLocker);
        vm.expectRevert(_blockedAddressRevert(authorizedLocker));
        token.lock(alice, 50e18);
        assertEq(token.lockedBalance(alice), 100e18, "blocked locker cannot add locks");
    }

    function test_74892_fix_blockedForageLockerCannotUnlock() public {
        vm.prank(authorizedLocker);
        token.lock(alice, 150e18);

        vm.prank(authorizedLocker);
        token.unlock(alice, 50e18);
        assertEq(token.lockedBalance(alice), 100e18, "non-blocked locker still unlocks");

        vm.prank(blockGuardian);
        registry.blockAddress(authorizedLocker);

        vm.prank(authorizedLocker);
        vm.expectRevert(_blockedAddressRevert(authorizedLocker));
        token.unlock(alice, 50e18);
        assertEq(token.lockedBalance(alice), 100e18, "blocked locker cannot unlock");
    }

    function test_74892_fix_blockedForageBurnerCannotBurn() public {
        vm.prank(authorizedBurner);
        token.burn(alice, 25e18);
        assertEq(token.balanceOf(alice), 975e18, "non-blocked burner still burns");

        vm.prank(blockGuardian);
        registry.blockAddress(authorizedBurner);

        vm.prank(authorizedBurner);
        vm.expectRevert(_blockedAddressRevert(authorizedBurner));
        token.burn(alice, 25e18);
        assertEq(token.balanceOf(alice), 975e18, "blocked burner cannot burn");
    }
}
