// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/ForageToken.sol";

// ============================================================
// TC-12: Invariant Tests
// Handler contract for Foundry invariant testing
// ============================================================

contract ForageTokenHandler is Test {
    ForageToken public token;
    address public owner;
    address public authorizedBurner;
    address public authorizedLocker;
    address public authorizedLocker2;
    address[] public actors;

    constructor(
        ForageToken _token,
        address _owner,
        address _burner,
        address _locker,
        address _locker2,
        address[] memory _actors
    ) {
        token = _token;
        owner = _owner;
        authorizedBurner = _burner;
        authorizedLocker = _locker;
        authorizedLocker2 = _locker2;
        actors = _actors;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;

        uint256 locked = token.lockedBalance(from);
        uint256 unlocked = balance - locked;
        if (unlocked == 0) return;

        amount = bound(amount, 1, unlocked);

        vm.prank(from);
        token.transfer(to, amount);
    }

    function lock(uint256 actorSeed, uint256 amount, uint256 lockerSeed) external {
        address account = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(account);
        uint256 locked = token.lockedBalance(account);
        uint256 unlocked = balance - locked;
        if (unlocked == 0) return;

        amount = bound(amount, 1, unlocked);
        address locker = lockerSeed % 2 == 0 ? authorizedLocker : authorizedLocker2;

        vm.prank(locker);
        token.lock(account, amount);
    }

    function unlock(uint256 actorSeed, uint256 amount, uint256 lockerSeed) external {
        address account = actors[actorSeed % actors.length];
        address locker = lockerSeed % 2 == 0 ? authorizedLocker : authorizedLocker2;
        uint256 lockerBal = token.lockerBalance(account, locker);
        if (lockerBal == 0) return;

        amount = bound(amount, 1, lockerBal);

        vm.prank(locker);
        token.unlock(account, amount);
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address account = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(account);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(authorizedBurner);
        token.burn(account, amount);
    }

    function delegate(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];

        vm.prank(from);
        token.delegate(to);
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}

contract ForageToken_TC12_Invariants is Test {
    ForageToken public token;
    ForageTokenHandler public handler;

    address public owner;
    address public teamVesting;
    address public forageTreasury;
    address public authorizedBurner;
    address public authorizedLocker;
    address public authorizedLocker2;
    address[] public actors;

    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 10 ** 18;

    // Monotonic supply tracking — updated only in the invariant function,
    // never in the handler. This ensures that if supply ever increases
    // during a handler call, the invariant catches it.
    uint256 public previousTotalSupply;

    function setUp() public {
        owner = makeAddr("owner");
        teamVesting = makeAddr("teamVesting");
        forageTreasury = makeAddr("forageTreasury");
        authorizedBurner = makeAddr("authorizedBurner");
        authorizedLocker = makeAddr("authorizedLocker");
        authorizedLocker2 = makeAddr("authorizedLocker2");

        ForageToken impl = new ForageToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner))
        );
        token = ForageToken(address(proxy));

        // Setup roles
        vm.startPrank(owner);
        token.setAuthorizedBurner(authorizedBurner, true);
        token.setAuthorizedLocker(authorizedLocker, true);
        token.setAuthorizedLocker(authorizedLocker2, true);
        vm.stopPrank();

        // All token holders are tracked — handler only transfers between these actors
        actors.push(teamVesting);
        actors.push(forageTreasury);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));

        // Transfer tokens to alice and bob
        vm.prank(forageTreasury);
        token.transfer(actors[2], 5_000_000e18);

        vm.prank(forageTreasury);
        token.transfer(actors[3], 5_000_000e18);

        // Self-delegate alice and bob for voting power invariant tests
        vm.prank(actors[2]);
        token.delegate(actors[2]);

        vm.prank(actors[3]);
        token.delegate(actors[3]);

        handler = new ForageTokenHandler(token, owner, authorizedBurner, authorizedLocker, authorizedLocker2, actors);

        // Initialize monotonic tracking
        previousTotalSupply = token.totalSupply();

        targetContract(address(handler));
    }

    /// @dev R-09: totalSupply never exceeds initial AND is monotonically non-increasing
    /// previousTotalSupply is updated HERE (in the invariant), not in the handler,
    /// so any supply increase during a handler call is caught.
    function invariant_totalSupplyNeverIncreases() public {
        uint256 current = token.totalSupply();
        assertLe(current, TOTAL_SUPPLY, "Total supply must never exceed initial");
        assertLe(current, previousTotalSupply, "Total supply must be monotonically non-increasing");
        previousTotalSupply = current;
    }

    /// @dev R-47: lockedBalance(account) <= balanceOf(account) for all accounts
    function invariant_lockCeiling() public view {
        address[] memory actorList = handler.getActors();
        for (uint256 i = 0; i < actorList.length; i++) {
            assertLe(
                token.lockedBalance(actorList[i]),
                token.balanceOf(actorList[i]),
                "Locked balance must not exceed balance"
            );
        }
    }

    /// @dev R-59: Sum of all balances == totalSupply (exact conservation)
    function invariant_supplyConservation() public view {
        address[] memory actorList = handler.getActors();
        uint256 totalBalances;
        for (uint256 i = 0; i < actorList.length; i++) {
            totalBalances += token.balanceOf(actorList[i]);
        }
        // Handler only transfers between tracked actors, so this is exact
        totalBalances += token.balanceOf(address(token));
        assertEq(totalBalances, token.totalSupply(), "Sum of all balances must equal totalSupply");
    }

    /// @dev R-10: Allocation constants sum to TOTAL_SUPPLY
    function invariant_allocationSumMatchesTotalSupply() public view {
        assertEq(
            token.TEAM_VESTING_ALLOCATION() + token.FORAGE_TREASURY_ALLOCATION(),
            token.TOTAL_SUPPLY()
        );
        assertEq(
            token.AGENT_ALLOCATION() + token.DEPOSITOR_ALLOCATION() + token.PARTNERSHIP_ALLOCATION(),
            token.FORAGE_TREASURY_ALLOCATION()
        );
    }

    /// @dev R-25, R-58: Locked tokens retain voting power for self-delegated accounts
    /// Uses assertGe because getVotes includes delegation from OTHER accounts,
    /// so votes >= balance for self-delegated accounts. Locking must not reduce votes.
    function invariant_lockedTokensRetainVotingPower() public view {
        address[] memory actorList = handler.getActors();
        for (uint256 i = 0; i < actorList.length; i++) {
            address account = actorList[i];
            // Only check self-delegated accounts
            if (token.delegates(account) == account) {
                assertGe(
                    token.getVotes(account),
                    token.balanceOf(account),
                    "Self-delegated account: votes must be >= balance (locked tokens retain voting power)"
                );
            }
        }
    }

    /// @dev R-48: Transferable balance == balanceOf - lockedBalance
    /// Tests boundary behavior: exact unlocked succeeds, unlocked+1 reverts.
    /// Non-view because it uses vm.snapshot/vm.revertTo/vm.prank.
    function invariant_transferableBalance() public {
        address[] memory actorList = handler.getActors();
        for (uint256 i = 0; i < actorList.length; i++) {
            address account = actorList[i];
            uint256 balance = token.balanceOf(account);
            uint256 locked = token.lockedBalance(account);

            assertGe(balance, locked, "Balance must be >= locked (transferable non-negative)");

            if (balance == 0) continue;

            uint256 unlocked = balance - locked;

            // Boundary test 1: transferring exact unlocked amount must succeed
            if (unlocked > 0) {
                uint256 snap = vm.snapshot();
                vm.prank(account);
                token.transfer(address(0xdead), unlocked);
                // Transfer succeeded — revert state to avoid side effects
                vm.revertTo(snap);
            }

            // Boundary test 2: transferring unlocked+1 must revert (lock enforcement)
            if (locked > 0) {
                vm.prank(account);
                (bool success,) = address(token).call(abi.encodeCall(token.transfer, (address(0xdead), unlocked + 1)));
                assertFalse(success, "Transfer of unlocked+1 must revert");
            }
        }
    }

    /// @dev OF-001: Sum of per-locker balances == aggregate locked balance for every actor
    function invariant_perLockerSumEqualsAggregate() public view {
        address[] memory actorList = handler.getActors();
        for (uint256 i = 0; i < actorList.length; i++) {
            address account = actorList[i];
            uint256 aggregate = token.lockedBalance(account);
            uint256 perLockerSum =
                token.lockerBalance(account, authorizedLocker) + token.lockerBalance(account, authorizedLocker2);
            assertEq(perLockerSum, aggregate, "Sum of per-locker balances must equal aggregate locked balance");
        }
    }

    /// @dev R-49, R-50: Timestamp-based clock at every step (Arbitrum L2)
    function invariant_timestampBasedClock() public view {
        assertEq(token.clock(), block.timestamp);
        assertEq(keccak256(bytes(token.CLOCK_MODE())), keccak256("mode=timestamp"));
    }
}
