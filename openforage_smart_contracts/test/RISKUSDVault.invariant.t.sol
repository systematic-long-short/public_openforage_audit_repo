// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/RISKUSDVault.sol";
import "./mocks/MockUSDC.sol";
import "./mocks/MockRISKUSD.sol";

// ============================================================
// TC-12: Invariant Tests
// Handler contract for Foundry invariant testing of RISKUSDVault
// ============================================================

contract RISKUSDVaultHandler is Test {
    RISKUSDVault public vault;
    MockUSDC public usdc;
    MockRISKUSD public riskusd;

    address public ownerAddr;
    address public custodianAddr;
    address public lossReporterAddr;
    address[] public actors;

    // Ghost variables for behavioral invariant checking
    bool public noRedemptionExceededCapAtCallTime;
    bool public allDepositsOneToOne;
    bool public allRedemptionsOneToOne;
    bool public nonCustodianDeployAlwaysReverts;
    bool public nonCustodianReturnAlwaysReverts;

    // Counter snapshots for monotonicity
    uint256 public prevTotalDeposited;
    uint256 public prevTotalRedeemed;
    uint256 public prevTotalBurnedForLoss;
    uint256 public prevTotalReplenished;
    uint256 public prevTotalLostCapital;

    // Operation tracking
    uint256 public depositCount;
    uint256 public redeemCount;
    uint256 public deployCount;
    uint256 public returnCount;
    uint256 public burnCount;
    uint256 public replenishCount;

    constructor(
        RISKUSDVault _vault,
        MockUSDC _usdc,
        MockRISKUSD _riskusd,
        address _owner,
        address _custodian,
        address _lossReporter,
        address[] memory _actors
    ) {
        vault = _vault;
        usdc = _usdc;
        riskusd = _riskusd;
        ownerAddr = _owner;
        custodianAddr = _custodian;
        lossReporterAddr = _lossReporter;
        actors = _actors;

        // Initialize ghost variables to true (no violations yet)
        noRedemptionExceededCapAtCallTime = true;
        allDepositsOneToOne = true;
        allRedemptionsOneToOne = true;
        nonCustodianDeployAlwaysReverts = true;
        nonCustodianReturnAlwaysReverts = true;
    }

    function _snapshotCounters() internal {
        prevTotalDeposited = vault.totalDeposited();
        prevTotalRedeemed = vault.totalRedeemed();
        prevTotalBurnedForLoss = vault.totalBurnedForLoss();
        prevTotalReplenished = vault.totalReplenished();
        prevTotalLostCapital = vault.totalLostCapital();
    }

    // --- Deposit: fund actor with USDC, approve, and deposit ---
    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        // Fund the actor with USDC
        usdc.mint(actor, amount);
        vm.prank(actor);
        usdc.approve(address(vault), amount);

        _snapshotCounters();

        uint256 riskusdBefore = riskusd.balanceOf(actor);

        vm.prank(actor);
        (bool success,) = address(vault).call(abi.encodeCall(vault.deposit, (amount)));

        if (success) {
            depositCount++;
            uint256 riskusdAfter = riskusd.balanceOf(actor);
            // Verify 1:1 ratio
            if (riskusdAfter - riskusdBefore != amount) {
                allDepositsOneToOne = false;
            }
        }
    }

    // --- Redeem: approve RISKUSD, redeem ---
    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 riskusdBalance = riskusd.balanceOf(actor);
        if (riskusdBalance == 0) return;

        amount = bound(amount, 1, riskusdBalance);

        // Approve vault for RISKUSD
        vm.prank(actor);
        riskusd.approve(address(vault), amount);

        _snapshotCounters();

        // Check cap at call time (before the redeem)
        uint256 capAtCallTime = vault.effectiveWeeklyRedemptionCap();
        uint256 usedAtCallTime = vault.weeklyRedemptionUsed();
        uint256 windowStart = vault.weeklyRedemptionWindowStart();
        bool windowExpired = block.timestamp >= windowStart + 604800;

        uint256 usdcBefore = usdc.balanceOf(actor);

        vm.prank(actor);
        (bool success,) = address(vault).call(abi.encodeCall(vault.redeem, (amount)));

        if (success) {
            redeemCount++;

            // Verify 1:1 ratio
            uint256 usdcAfter = usdc.balanceOf(actor);
            if (usdcAfter - usdcBefore != amount) {
                allRedemptionsOneToOne = false;
            }

            // If window was not expired, check that used + amount <= cap at call time
            if (!windowExpired && usedAtCallTime + amount > capAtCallTime) {
                noRedemptionExceededCapAtCallTime = false;
            }
        }
    }

    // --- Deploy capital: custodian deploys ---
    function deployCapital(uint256 amount) external {
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        if (vaultBalance == 0) return;

        amount = bound(amount, 1, vaultBalance);

        _snapshotCounters();

        vm.prank(custodianAddr);
        (bool success,) = address(vault).call(abi.encodeCall(vault.deployCapital, (amount)));

        if (success) {
            deployCount++;
        }
    }

    // --- Return capital: custodian returns ---
    function returnCapital(uint256 amount) external {
        uint256 deployed = vault.totalDeployed();
        if (deployed == 0) return;

        amount = bound(amount, 1, deployed);

        // Fund custodian with USDC to return
        usdc.mint(custodianAddr, amount);
        vm.prank(custodianAddr);
        usdc.approve(address(vault), amount);

        _snapshotCounters();

        vm.prank(custodianAddr);
        (bool success,) = address(vault).call(abi.encodeCall(vault.returnCapital, (amount)));

        if (success) {
            returnCount++;
        }
    }

    // --- Burn for loss: loss reporter burns RISKUSD ---
    function burnForLoss(uint256 amount) external {
        uint256 reporterBalance = riskusd.balanceOf(lossReporterAddr);
        if (reporterBalance == 0) return;

        amount = bound(amount, 1, reporterBalance);

        _snapshotCounters();

        vm.prank(lossReporterAddr);
        (bool success,) = address(vault).call(abi.encodeCall(vault.burnForLoss, (1, amount)));

        if (success) {
            burnCount++;
        }
    }

    // --- Replenish: loss reporter sends USDC ---
    function replenish(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);

        usdc.mint(lossReporterAddr, amount);
        vm.prank(lossReporterAddr);
        usdc.approve(address(vault), amount);

        _snapshotCounters();

        vm.prank(lossReporterAddr);
        (bool success,) = address(vault).call(abi.encodeCall(vault.replenish, (amount)));

        if (success) {
            replenishCount++;
        }
    }

    // --- Attempt unauthorized deploy (non-custodian) ---
    function attemptUnauthorizedDeploy(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        vm.prank(actor);
        (bool success,) = address(vault).call(abi.encodeCall(vault.deployCapital, (amount)));

        if (success) {
            nonCustodianDeployAlwaysReverts = false;
        }
    }

    // --- Attempt unauthorized return (non-custodian) ---
    function attemptUnauthorizedReturn(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000e6);

        vm.prank(actor);
        (bool success,) = address(vault).call(abi.encodeCall(vault.returnCapital, (amount)));

        if (success) {
            nonCustodianReturnAlwaysReverts = false;
        }
    }

    // --- Fund loss reporter with RISKUSD for burn scenarios ---
    function fundLossReporter(uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        // Fund through vault deposit to maintain supply invariant
        // (direct riskusd.mint bypasses vault accounting, breaking totalDeposited tracking)
        usdc.mint(lossReporterAddr, amount);
        vm.startPrank(lossReporterAddr);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        // lossReporter now has RISKUSD via proper deposit flow
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}

contract RISKUSDVault_TC12_Invariants is Test {
    RISKUSDVault public vault;
    RISKUSDVault public implementation;
    MockUSDC public usdc;
    MockRISKUSD public riskusd;
    RISKUSDVaultHandler public handler;

    address public owner;
    address public custodianAddr;
    address public lossReporterAddr;
    address[] public actors;

    function setUp() public {
        owner = makeAddr("timelock");
        custodianAddr = makeAddr("custodian");
        lossReporterAddr = makeAddr("lossReporter");

        // Deploy mocks
        usdc = new MockUSDC();
        riskusd = new MockRISKUSD();

        // Deploy proxy
        implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RISKUSDVault(address(proxy));

        // Setup roles
        vm.startPrank(owner);
        vault.setCustodian(custodianAddr);
        vault.setLossReporter(lossReporterAddr);
        vault.setDailyRedemptionCapBps(10000);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeCustodian();
        vault.finalizeLossReporter();
        vm.stopPrank();

        // Set RISKUSD minter to vault (vault needs to call riskusd.mint)
        // MockRISKUSD has public mint, so no minter setup needed

        // Create actors (none of these are custodian or lossReporter)
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));

        // Create handler
        handler = new RISKUSDVaultHandler(vault, usdc, riskusd, owner, custodianAddr, lossReporterAddr, actors);

        targetContract(address(handler));
    }

    /// @dev R-42: Supply invariant: riskusd.totalSupply() == _totalDeposited - _totalRedeemed - _totalBurnedForLoss
    function invariant_supplyMatchesDeposits() public view {
        assertEq(
            riskusd.totalSupply(),
            vault.totalDeposited() - vault.totalRedeemed() - vault.totalBurnedForLoss(),
            "Supply invariant: totalSupply must equal totalDeposited - totalRedeemed - totalBurnedForLoss"
        );
    }

    /// @dev R-43: USDC accounting: vaultBalance + deployed + redeemed + lost == deposited + replenished
    function invariant_usdcAccountingBalance() public view {
        assertEq(
            usdc.balanceOf(address(vault)) + vault.totalDeployed() + vault.totalRedeemed() + vault.totalLostCapital(),
            vault.totalDeposited() + vault.totalReplenished(),
            "USDC accounting: vault + deployed + redeemed + lost must equal deposited + replenished"
        );
    }

    /// @dev R-10: Weekly redemption used does not exceed effective cap at the time of each redeem call
    function invariant_weeklyCapNotExceeded() public view {
        assertTrue(handler.noRedemptionExceededCapAtCallTime(), "No redemption must exceed the weekly cap at call time");
    }

    /// @dev R-49: 1 RISKUSD == 1 USDC (no yield) — all deposits and redemptions use 1:1 ratio
    function invariant_noYield() public view {
        assertTrue(handler.allDepositsOneToOne(), "All deposits must use 1:1 USDC-to-RISKUSD ratio");
        assertTrue(handler.allRedemptionsOneToOne(), "All redemptions must use 1:1 RISKUSD-to-USDC ratio");
    }

    /// @dev R-16, R-20: Only custodian can successfully deploy or return capital
    function invariant_custodianOnlyDeployment() public view {
        assertTrue(handler.nonCustodianDeployAlwaysReverts(), "Non-custodian deploy must always revert");
        assertTrue(handler.nonCustodianReturnAlwaysReverts(), "Non-custodian return must always revert");
    }

    /// @dev totalDepositorUsdc must never underflow (totalDeposited >= totalRedeemed + totalBurnedForLoss)
    function invariant_totalDepositorUsdcNonNegative() public view {
        assertGe(
            vault.totalDeposited(),
            vault.totalRedeemed() + vault.totalBurnedForLoss(),
            "totalDepositorUsdc must be non-negative (no underflow)"
        );
    }

    /// @dev Cumulative counters must be monotonically increasing
    function invariant_cumulativeCounterMonotonicity() public view {
        assertGe(
            vault.totalDeposited(), handler.prevTotalDeposited(), "totalDeposited must be monotonically increasing"
        );
        assertGe(vault.totalRedeemed(), handler.prevTotalRedeemed(), "totalRedeemed must be monotonically increasing");
        assertGe(
            vault.totalBurnedForLoss(),
            handler.prevTotalBurnedForLoss(),
            "totalBurnedForLoss must be monotonically increasing"
        );
        assertGe(
            vault.totalReplenished(),
            handler.prevTotalReplenished(),
            "totalReplenished must be monotonically increasing"
        );
        assertGe(
            vault.totalLostCapital(),
            handler.prevTotalLostCapital(),
            "totalLostCapital must be monotonically increasing"
        );
    }
}
