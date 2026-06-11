// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/ForageToken.sol";

abstract contract ForageTokenTestBase is Test {
    ForageToken public token;
    ForageToken public implementation;

    address public owner;
    address public teamVesting;
    address public forageTreasury;
    address public alice;
    address public bob;
    address public charlie;
    address public authorizedBurner;
    address public authorizedLocker;
    address public authorizedLocker2;
    address public attacker;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10 ** 18;
    uint256 public constant TEAM_ALLOCATION = 20_000_000 * 10 ** 18;
    uint256 public constant AGENT_ALLOCATION = 30_000_000 * 10 ** 18;
    uint256 public constant DEPOSITOR_ALLOCATION = 10_000_000 * 10 ** 18;
    uint256 public constant PARTNERSHIP_ALLOCATION = 40_000_000 * 10 ** 18;
    uint256 public constant FORAGE_TREASURY_ALLOCATION = 80_000_000 * 10 ** 18;

    function setUp() public virtual {
        owner = makeAddr("owner");
        teamVesting = makeAddr("teamVesting");
        forageTreasury = makeAddr("forageTreasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        authorizedBurner = makeAddr("authorizedBurner");
        authorizedLocker = makeAddr("authorizedLocker");
        authorizedLocker2 = makeAddr("authorizedLocker2");
        attacker = makeAddr("attacker");

        // Deploy implementation
        implementation = new ForageToken();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        token = ForageToken(address(proxy));
    }

    /// @dev Transfer tokens from a recipient to alice for testing
    function _fundAlice(uint256 amount) internal {
        vm.prank(forageTreasury);
        token.transfer(alice, amount);
    }

    /// @dev Transfer tokens from a recipient to bob for testing
    function _fundBob(uint256 amount) internal {
        vm.prank(forageTreasury);
        token.transfer(bob, amount);
    }

    /// @dev Grant burner role and optionally fund an account
    function _setupBurner() internal {
        vm.prank(owner);
        token.setAuthorizedBurner(authorizedBurner, true);
    }

    /// @dev Grant locker role
    function _setupLocker() internal {
        vm.prank(owner);
        token.setAuthorizedLocker(authorizedLocker, true);
    }

    /// @dev Grant second locker role
    function _setupLocker2() internal {
        vm.prank(owner);
        token.setAuthorizedLocker(authorizedLocker2, true);
    }

    /// @dev Lock tokens for an account
    function _lockTokens(address account, uint256 amount) internal {
        vm.prank(authorizedLocker);
        token.lock(account, amount);
    }

    /// @dev Lock tokens for an account as a specific locker
    function _lockTokensAs(address locker, address account, uint256 amount) internal {
        vm.prank(locker);
        token.lock(account, amount);
    }
}
