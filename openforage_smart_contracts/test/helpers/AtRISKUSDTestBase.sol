// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/atRISKUSD.sol";
import "../mocks/MockRISKUSD.sol";
import "../mocks/MockYieldSourceForLossPending.sol";

/// @dev Abstract base for atRISKUSD tests.
/// Deploys atRISKUSD behind an ERC1967 proxy with tier 1 config
/// (90-day lockup, 7-day cooldown, tierId=1).
/// setUp() reverts against the stub since initialize() reverts "STUB: not implemented".
abstract contract AtRISKUSDTestBase is Test {
    atRISKUSD public vault;
    atRISKUSD public implementation;
    MockRISKUSD public riskusd;
    MockYieldSourceForLossPending public mockYieldSource;

    address public owner;
    address public yieldSource;
    address public stakingQueue;
    address public governor;
    address public alice;
    address public bob;
    address public attacker;

    uint256 public constant LOCKUP_PERIOD = 7_776_000; // 90 days in seconds
    uint256 public constant COOLDOWN_PERIOD = 604_800; // 7 days in seconds
    uint8 public constant TIER_ID = 1;
    string public constant TIER_ABBREVIATION = "90D";
    uint256 internal constant LEGACY_TEST_WEEKLY_WITHDRAWAL_CAP_BPS = 10_000;

    function setUp() public virtual {
        owner = makeAddr("timelock");
        mockYieldSource = new MockYieldSourceForLossPending();
        yieldSource = address(mockYieldSource);
        stakingQueue = makeAddr("stakingQueue");
        governor = makeAddr("governor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        // Deploy mock RISKUSD
        riskusd = new MockRISKUSD();

        // Deploy implementation
        implementation = new atRISKUSD();

        // Deploy proxy with initialize call
        bytes memory initData = abi.encodeCall(
            atRISKUSD.initialize,
            (
                address(riskusd),
                yieldSource,
                stakingQueue,
                LOCKUP_PERIOD,
                COOLDOWN_PERIOD,
                TIER_ID,
                TIER_ABBREVIATION,
                owner
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = atRISKUSD(address(proxy));
        if (_legacyRaiseWeeklyWithdrawalCap()) {
            _raiseWeeklyWithdrawalCap(vault);
        }
    }

    function _legacyRaiseWeeklyWithdrawalCap() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Legacy atRISKUSD tests predate Round 4's default 5% exit cap.
    /// Round4ExitPathCaps.t.sol deploys explicit fresh vaults when it needs the default.
    function _raiseWeeklyWithdrawalCap(atRISKUSD target) internal {
        vm.prank(owner);
        target.setWeeklyWithdrawalCapBps(LEGACY_TEST_WEEKLY_WITHDRAWAL_CAP_BPS);
    }

    /// @dev Deposit RISKUSD into the vault via the stakingQueue.
    /// Mints RISKUSD to stakingQueue, approves vault, and calls deposit().
    function _depositViaQueue(address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), amount);
        shares = vault.deposit(amount, receiver);
        vm.stopPrank();
    }

    /// @dev Accrue yield: mints RISKUSD to yieldSource, approves vault, calls accrueYield().
    function _accrueYield(uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), amount);
        vault.accrueYield(amount);
        vm.stopPrank();
    }

    /// @dev Absorb loss: calls absorbLoss() as yieldSource.
    function _absorbLoss(uint256 amount) internal {
        vm.prank(yieldSource);
        vault.absorbLoss(amount);
    }

    /// @dev Deploy a fresh atRISKUSD proxy with custom parameters.
    function _deployFreshVault(uint256 lockupPeriod_, uint256 cooldownPeriod_, uint8 tierId_)
        internal
        returns (atRISKUSD)
    {
        atRISKUSD impl = new atRISKUSD();
        bytes memory initData = abi.encodeCall(
            atRISKUSD.initialize,
            (
                address(riskusd),
                yieldSource,
                stakingQueue,
                lockupPeriod_,
                cooldownPeriod_,
                tierId_,
                _tierAbbreviation(tierId_),
                owner
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return atRISKUSD(address(proxy));
    }

    function _tierAbbreviation(uint8 tierId_) internal pure returns (string memory) {
        if (tierId_ == 0) return "0D";
        if (tierId_ == 1) return "90D";
        if (tierId_ == 2) return "180D";
        if (tierId_ == 3) return "360D";
        return "";
    }
}
