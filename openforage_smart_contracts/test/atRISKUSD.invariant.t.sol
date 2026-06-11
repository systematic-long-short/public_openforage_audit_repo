// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-17: Invariant Tests (Foundry Invariant Test Suite)
// R-06, R-07, R-09, R-11, R-12, R-13, R-14, R-16, R-41, R-42, R-44, R-45
// ============================================================

/// @dev Malicious ERC20 that attempts to re-enter the vault during transferFrom.
/// The reentrancy vault is configured so this token IS the authorized stakingQueue
/// and yieldSource. Therefore the ONLY reason reentrant calls should revert is the
/// nonReentrant guard (ReentrancyGuardReentrantCall). This makes the test
/// discriminatory: removing the guard would let these calls succeed.
contract ReentrancyAttackToken is MockRISKUSD {
    atRISKUSD public targetVault;
    bool public attacking;
    bool public reentrantCallSucceeded;
    bool public wrongRevertReason;
    uint256 public attackAttempts;

    // ReentrancyGuardReentrantCall() selector
    bytes4 constant REENTRANCY_SELECTOR = 0x3ee5aeb5;

    function setTarget(atRISKUSD vault_) external {
        targetVault = vault_;
    }

    function resetAttackState() external {
        reentrantCallSucceeded = false;
        wrongRevertReason = false;
    }

    function _checkRevert(bytes memory reason) internal {
        if (reason.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(reason, 32)) }
            if (sel != REENTRANCY_SELECTOR) {
                wrongRevertReason = true;
            }
        } else {
            wrongRevertReason = true;
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);

        if (!attacking && address(targetVault) != address(0)) {
            attacking = true;
            attackAttempts++;

            // Attempt reentrant deposit (authorized: this contract == stakingQueue)
            try targetVault.deposit(1, address(this)) {
                reentrantCallSucceeded = true;
            } catch (bytes memory reason) {
                _checkRevert(reason);
            }

            // Attempt reentrant accrueYield (authorized: this contract == yieldSource)
            try targetVault.accrueYield(1) {
                reentrantCallSucceeded = true;
            } catch (bytes memory reason) {
                _checkRevert(reason);
            }

            // Attempt reentrant absorbLoss (authorized: this contract == yieldSource)
            // absorbLoss doesn't pull tokens, only reduces accounting — would succeed without guard
            try targetVault.absorbLoss(1) {
                reentrantCallSucceeded = true;
            } catch (bytes memory reason) {
                _checkRevert(reason);
            }

            attacking = false;
        }
        return result;
    }
}

/// @dev Handler contract that randomly calls vault operations with bounded inputs.
/// Tracks depositors, pending withdrawals, exchange rate snapshots, yield/loss sequences.
contract AtRISKUSDHandler is Test {
    atRISKUSD public vault;
    MockRISKUSD public riskusd;
    address public yieldSource;
    address public stakingQueue;

    // Reentrancy attack vault
    atRISKUSD public reentrancyVault;
    ReentrancyAttackToken public attackToken;

    uint256 public constant LOCKUP_PERIOD = 7_776_000;
    uint256 public constant COOLDOWN_PERIOD = 604_800;

    // ---------- Tracking state ----------
    address[] public depositors;
    mapping(address => bool) public isDepositor;

    // Exchange rate tracking for yield-only monotonicity
    uint256 public previousExchangeRate;
    uint256 public currentExchangeRate;
    bool public onlyYieldSinceLastCheck;
    bool public exchangeRateCheckValid;

    // Single pending withdrawal per user tracking
    bool public noDuplicatePendingWithdrawals;

    // Deposit authorization tracking
    bool public allDepositsFromStakingQueue;

    // Counter monotonicity tracking
    uint256 public prevTotalYieldAccrued;
    uint256 public prevTotalLossAbsorbed;
    bool public counterMonotonicityHolds;

    // Reentrancy tracking
    bool public allReentrantCallsBlocked;
    bool public allReentrantRevertsCorrect;

    // Early-execution tracking
    bool public earlyWithdrawalRequestSucceeded;
    bool public earlyExecutionSucceeded;

    // Ghost counters
    uint256 public depositCallCount;
    uint256 public yieldCallCount;
    uint256 public lossCallCount;
    uint256 public requestCallCount;
    uint256 public executeCallCount;
    uint256 public cancelCallCount;
    uint256 public transferCallCount;
    uint256 public autoRenewCallCount;
    uint256 public reentrancyAttemptCount;

    constructor(
        atRISKUSD vault_,
        MockRISKUSD riskusd_,
        address yieldSource_,
        address stakingQueue_,
        atRISKUSD reentrancyVault_,
        ReentrancyAttackToken attackToken_
    ) {
        vault = vault_;
        riskusd = riskusd_;
        yieldSource = yieldSource_;
        stakingQueue = stakingQueue_;
        reentrancyVault = reentrancyVault_;
        attackToken = attackToken_;

        noDuplicatePendingWithdrawals = true;
        allDepositsFromStakingQueue = true;
        onlyYieldSinceLastCheck = true;
        exchangeRateCheckValid = false;
        counterMonotonicityHolds = true;
        allReentrantCallsBlocked = true;
        allReentrantRevertsCorrect = true;
        earlyWithdrawalRequestSucceeded = false;
        earlyExecutionSucceeded = false;

        for (uint256 i = 0; i < 5; i++) {
            address d = makeAddr(string(abi.encodePacked("handler_depositor_", vm.toString(i))));
            depositors.push(d);
            isDepositor[d] = true;
        }
    }

    function _selectDepositor(uint256 seed) internal view returns (address) {
        return depositors[seed % depositors.length];
    }

    function _updateExchangeRate() internal {
        if (vault.totalSupply() > 0) {
            previousExchangeRate = currentExchangeRate;
            currentExchangeRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
            exchangeRateCheckValid = true;
        }
    }

    function _checkCounterMonotonicity() internal {
        uint256 yieldNow = vault.totalYieldAccrued();
        uint256 lossNow = vault.totalLossAbsorbed();
        if (yieldNow < prevTotalYieldAccrued || lossNow < prevTotalLossAbsorbed) {
            counterMonotonicityHolds = false;
        }
        prevTotalYieldAccrued = yieldNow;
        prevTotalLossAbsorbed = lossNow;
    }

    // ---------- Handler functions ----------

    function deposit(uint256 amount, uint256 depositorSeed) external {
        amount = bound(amount, 1, 1e12);
        address receiver = _selectDepositor(depositorSeed);

        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), amount);
        try vault.deposit(amount, receiver) {
            depositCallCount++;
            // OF-002: Don't update exchange rate on deposits — deposits are rate-neutral,
            // but integer rounding with virtual offset can cause 1-wei rate artifacts.
            // Only track rate changes between yield/loss events.
            _checkCounterMonotonicity();
        } catch {}
        vm.stopPrank();
    }

    function accrueYield(uint256 amount) external {
        if (vault.totalSupply() == 0) return;
        amount = bound(amount, 1, 1e10);

        // Record rate BEFORE yield for monotonicity check
        uint256 rateBefore = (vault.totalAssets() * 1e18) / vault.totalSupply();

        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(vault), amount);
        try vault.accrueYield(amount) {
            yieldCallCount++;
            // Record rate AFTER yield — check yield only increases rate
            uint256 rateAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
            previousExchangeRate = rateBefore;
            currentExchangeRate = rateAfter;
            exchangeRateCheckValid = true;
            _checkCounterMonotonicity();
        } catch {}
        vm.stopPrank();
    }

    function absorbLoss(uint256 amount) external {
        if (vault.totalAssets() == 0) return;
        amount = bound(amount, 1, vault.totalAssets());

        vm.prank(yieldSource);
        try vault.absorbLoss(amount) {
            lossCallCount++;
            onlyYieldSinceLastCheck = false;
            _updateExchangeRate();
            _checkCounterMonotonicity();
        } catch {}
    }

    function requestWithdrawal(uint256 depositorSeed, uint256 shareFraction) external {
        address depositor = _selectDepositor(depositorSeed);
        uint256 balance = vault.balanceOf(depositor);
        if (balance == 0) return;

        shareFraction = bound(shareFraction, 1, balance);

        uint256 lockExp = vault.lockExpiry(depositor);
        if (block.timestamp < lockExp) {
            vm.warp(lockExp);
        }

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(depositor);
        if (pw.active) {
            vm.prank(depositor);
            try vault.requestWithdrawal(shareFraction) {
                noDuplicatePendingWithdrawals = false;
            } catch {}
            return;
        }

        vm.prank(depositor);
        try vault.requestWithdrawal(shareFraction) {
            requestCallCount++;
        } catch {}
    }

    function attemptEarlyWithdrawalRequest(uint256 depositorSeed, uint256 shareFraction) external {
        address depositor = _selectDepositor(depositorSeed);
        uint256 balance = vault.balanceOf(depositor);
        if (balance == 0) return;

        shareFraction = bound(shareFraction, 1, balance);

        uint256 lockExp = vault.lockExpiry(depositor);
        if (lockExp == 0 || block.timestamp >= lockExp) return;

        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(depositor);
        if (pw.active) return;

        vm.prank(depositor);
        try vault.requestWithdrawal(shareFraction) {
            earlyWithdrawalRequestSucceeded = true;
        } catch {}
    }

    function executeWithdrawal(uint256 depositorSeed) external {
        address depositor = _selectDepositor(depositorSeed);
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(depositor);
        if (!pw.active) return;

        uint256 cooldownEnd = pw.requestTimestamp + vault.cooldownPeriod();
        if (block.timestamp < cooldownEnd) {
            vm.warp(cooldownEnd);
        }

        vm.prank(depositor);
        try vault.executeWithdrawal() {
            executeCallCount++;
        } catch {}
    }

    function attemptEarlyExecution(uint256 depositorSeed) external {
        address depositor = _selectDepositor(depositorSeed);
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(depositor);
        if (!pw.active) return;

        uint256 cooldownEnd = pw.requestTimestamp + vault.cooldownPeriod();
        if (block.timestamp >= cooldownEnd) return;

        vm.prank(depositor);
        try vault.executeWithdrawal() {
            earlyExecutionSucceeded = true;
        } catch {}
    }

    function cancelWithdrawal(uint256 depositorSeed) external {
        address depositor = _selectDepositor(depositorSeed);
        atRISKUSD.PendingWithdrawal memory pw = vault.pendingWithdrawal(depositor);
        if (!pw.active) return;

        vm.prank(depositor);
        try vault.cancelWithdrawal() {
            cancelCallCount++;
        } catch {}
    }

    function setAutoRenew(uint256 depositorSeed, bool enabled) external {
        address depositor = _selectDepositor(depositorSeed);
        vm.prank(depositor);
        try vault.setAutoRenew(enabled) {
            autoRenewCallCount++;
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _selectDepositor(fromSeed);
        address to = _selectDepositor(toSeed);
        if (from == to) return;

        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(from);
        try vault.transfer(to, amount) {
            transferCallCount++;
        } catch {}
    }

    function depositFromNonQueue(uint256 amount, uint256 depositorSeed) external {
        amount = bound(amount, 1, 1e12);
        address receiver = _selectDepositor(depositorSeed);
        address nonQueue = makeAddr("nonQueueDepositor");

        riskusd.mint(nonQueue, amount);
        vm.startPrank(nonQueue);
        riskusd.approve(address(vault), amount);
        try vault.deposit(amount, receiver) {
            allDepositsFromStakingQueue = false;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Attempt reentrancy via malicious ERC20 callback (R-45).
    /// The reentrancy vault is configured with stakingQueue = attackToken and
    /// yieldSource = attackToken, so reentrant calls are AUTHORIZED. The ONLY
    /// barrier is the nonReentrant modifier. Pre-minted balance and max approval
    /// ensure the inner transferFrom would also succeed without the guard.
    function attemptReentrantDeposit(uint256 amount) external {
        amount = bound(amount, 1, 1e10);

        attackToken.resetAttackState();

        // Ensure attack token has balance for both outer + inner transfers
        attackToken.mint(address(attackToken), amount + 1000e6);

        // Set max approval from attackToken to reentrancy vault
        vm.prank(address(attackToken));
        attackToken.approve(address(reentrancyVault), type(uint256).max);

        // Outer deposit: prank as attackToken (== reentrancy vault's stakingQueue)
        vm.startPrank(address(attackToken));
        reentrancyVault.deposit(amount, depositors[0]);
        vm.stopPrank();

        reentrancyAttemptCount++;

        if (attackToken.reentrantCallSucceeded()) {
            allReentrantCallsBlocked = false;
        }
        if (attackToken.wrongRevertReason()) {
            allReentrantRevertsCorrect = false;
        }
    }

    function resetYieldOnlyTracking() external {
        onlyYieldSinceLastCheck = true;
        if (vault.totalSupply() > 0) {
            previousExchangeRate = (vault.totalAssets() * 1e18) / vault.totalSupply();
            currentExchangeRate = previousExchangeRate;
        }
    }
}

/// @dev Invariant test contract using Foundry's invariant testing framework.
contract AtRISKUSD_TC17_Invariant is AtRISKUSDTestBase {
    AtRISKUSDHandler public handler;

    function setUp() public override {
        super.setUp();

        // Deploy reentrancy attack setup: malicious token + separate vault
        // Key: stakingQueue and yieldSource are set to the attack token address
        // so reentrant calls are AUTHORIZED — the only barrier is the nonReentrant guard
        ReentrancyAttackToken attackToken = new ReentrancyAttackToken();
        atRISKUSD reentrancyImpl = new atRISKUSD();
        bytes memory reentrancyInitData = abi.encodeCall(
            atRISKUSD.initialize,
            (
                address(attackToken), // underlying asset = attack token
                address(attackToken), // yieldSource = attack token (authorized for accrueYield/absorbLoss)
                address(attackToken), // stakingQueue = attack token (authorized for deposit/mint)
                LOCKUP_PERIOD,
                COOLDOWN_PERIOD,
                TIER_ID,
                TIER_ABBREVIATION,
                owner
            )
        );
        ERC1967Proxy reentrancyProxy = new ERC1967Proxy(address(reentrancyImpl), reentrancyInitData);
        atRISKUSD reentrancyVault = atRISKUSD(address(reentrancyProxy));
        attackToken.setTarget(reentrancyVault);

        handler = new AtRISKUSDHandler(vault, riskusd, yieldSource, stakingQueue, reentrancyVault, attackToken);

        vm.prank(owner);
        vault.setForageGovernor(governor);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = AtRISKUSDHandler.deposit.selector;
        selectors[1] = AtRISKUSDHandler.accrueYield.selector;
        selectors[2] = AtRISKUSDHandler.absorbLoss.selector;
        selectors[3] = AtRISKUSDHandler.requestWithdrawal.selector;
        selectors[4] = AtRISKUSDHandler.executeWithdrawal.selector;
        selectors[5] = AtRISKUSDHandler.cancelWithdrawal.selector;
        selectors[6] = AtRISKUSDHandler.setAutoRenew.selector;
        selectors[7] = AtRISKUSDHandler.transfer.selector;
        selectors[8] = AtRISKUSDHandler.depositFromNonQueue.selector;
        selectors[9] = AtRISKUSDHandler.attemptEarlyWithdrawalRequest.selector;
        selectors[10] = AtRISKUSDHandler.attemptEarlyExecution.selector;
        selectors[11] = AtRISKUSDHandler.attemptReentrantDeposit.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ----- Invariant 1: totalAssets matches actual RISKUSD balance -----
    function invariant_totalAssetsMatchesBalance() external view {
        assertEq(
            vault.totalAssets(),
            riskusd.balanceOf(address(vault)),
            "Invariant: totalAssets must match RISKUSD balance in vault"
        );
    }

    // ----- Invariant 2: Exchange rate monotonically non-decreasing during yield-only sequences -----
    function invariant_exchangeRateNonDecreasingUnderYieldOnly() external view {
        if (handler.exchangeRateCheckValid() && handler.onlyYieldSinceLastCheck()) {
            assertGe(
                handler.currentExchangeRate(),
                handler.previousExchangeRate(),
                "Invariant: exchange rate must not decrease during yield-only sequence"
            );
        }
    }

    // ----- Invariant 3: No early withdrawal execution before cooldown -----
    function invariant_noEarlyExecution() external view {
        assertFalse(
            handler.earlyExecutionSucceeded(), "Invariant: executeWithdrawal must never succeed before cooldown elapses"
        );
    }

    // ----- Invariant 4: No early withdrawal request before lockup -----
    function invariant_noEarlyWithdrawalRequest() external view {
        assertFalse(
            handler.earlyWithdrawalRequestSucceeded(),
            "Invariant: requestWithdrawal must never succeed before lockup expires"
        );
    }

    // ----- Invariant 5: At most one pending withdrawal per user -----
    function invariant_singlePendingWithdrawalPerUser() external view {
        assertTrue(
            handler.noDuplicatePendingWithdrawals(),
            "Invariant: each user can have at most one active pending withdrawal"
        );
    }

    // ----- Invariant 6: deposit only callable by StakingQueue -----
    function invariant_stakingQueueOnlyDeposit() external view {
        assertTrue(handler.allDepositsFromStakingQueue(), "Invariant: only StakingQueue can successfully call deposit");
    }

    // ----- Invariant 7: convertToAssets(totalSupply) <= totalAssets + rounding tolerance -----
    function invariant_sharesToAssetsConsistency() external view {
        if (vault.totalSupply() > 0) {
            uint256 assetsFromShares = vault.convertToAssets(vault.totalSupply());
            assertLe(
                assetsFromShares,
                vault.totalAssets() + 1,
                "Invariant: convertToAssets(totalSupply) must not exceed totalAssets + 1 rounding"
            );
        }
    }

    // ----- Invariant 8: Cumulative counters never decrease (monotonicity) -----
    function invariant_counterMonotonicity() external view {
        assertTrue(
            handler.counterMonotonicityHolds(), "Invariant: totalYieldAccrued and totalLossAbsorbed must never decrease"
        );
    }

    // ----- Invariant 9: All reentrant callback attempts blocked (R-45) -----
    // Discriminatory: reentrancy vault has stakingQueue=attackToken, yieldSource=attackToken,
    // so reentrant calls are fully authorized. Only the nonReentrant guard blocks them.
    function invariant_reentrancyBlocked() external view {
        assertTrue(
            handler.allReentrantCallsBlocked(),
            "Invariant: authorized reentrant calls via malicious token callback must be blocked (R-45)"
        );
    }

    // ----- Invariant 10: Reentrant calls revert with ReentrancyGuardReentrantCall specifically -----
    function invariant_reentrancyRevertReason() external view {
        assertTrue(
            handler.allReentrantRevertsCorrect(),
            "Invariant: reentrant calls must revert with ReentrancyGuardReentrantCall, not auth/state errors"
        );
    }
}
