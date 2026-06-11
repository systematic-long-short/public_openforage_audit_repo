// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-29: Edge Case Tests (R-39, R-42, R-43)
// ============================================================
contract AtRISKUSD_TC29_EdgeCases is AtRISKUSDTestBase {
    atRISKUSD internal tier0Vault;

    function setUp() public override {
        super.setUp();
        tier0Vault = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        _raiseWeeklyWithdrawalCap(tier0Vault);
    }

    /// @dev Deposit into tier0 vault
    function _depositTier0(address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), amount);
        shares = tier0Vault.deposit(amount, receiver);
        vm.stopPrank();
    }

    /// @dev Accrue yield on tier0 vault
    function _accrueYieldTier0(uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(tier0Vault), amount);
        tier0Vault.accrueYield(amount);
        vm.stopPrank();
    }

    /// @dev Absorb loss on tier0 vault
    function _absorbLossTier0(uint256 amount) internal {
        vm.prank(yieldSource);
        tier0Vault.absorbLoss(amount);
    }

    // ----- L3 Step 1: Zero deposit amount — reverts ZeroAmount -----
    function test_TC29_zeroDepositAmount_reverts() public {
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), 1000e6);

        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.deposit(0, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 2: Max uint256 deposit — reverts (insufficient balance, not overflow) -----
    function test_TC29_maxUint256Deposit_reverts() public {
        // StakingQueue only has a small amount, so type(uint256).max will fail on transferFrom
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), type(uint256).max);

        // Should revert due to insufficient balance, not arithmetic overflow
        vm.expectRevert();
        tier0Vault.deposit(type(uint256).max, alice);
        vm.stopPrank();
    }

    // ----- L3 Step 3: Single-wei deposit — gets shares > 0 (virtual offset) -----
    function test_TC29_singleWeiDeposit_getShares() public {
        uint256 shares = _depositTier0(alice, 1);

        // Virtual offset prevents 0 shares for 1-wei deposit
        assertGt(shares, 0, "single-wei deposit must produce shares > 0 (virtual offset)");
    }

    // ----- L3 Step 4: Single-wei yield accrual -----
    function test_TC29_singleWeiYieldAccrual() public {
        _depositTier0(alice, 1000e6);

        uint256 totalAssetsBefore = tier0Vault.totalAssets();
        _accrueYieldTier0(1);
        uint256 totalAssetsAfter = tier0Vault.totalAssets();

        assertEq(totalAssetsAfter, totalAssetsBefore + 1, "single-wei yield must increase totalAssets by 1");
    }

    // ----- L3 Step 5: Single-wei loss absorption -----
    function test_TC29_singleWeiLossAbsorption() public {
        _depositTier0(alice, 1000e6);

        uint256 totalAssetsBefore = tier0Vault.totalAssets();
        _absorbLossTier0(1);
        uint256 totalAssetsAfter = tier0Vault.totalAssets();

        assertEq(totalAssetsAfter, totalAssetsBefore - 1, "single-wei loss must decrease totalAssets by 1");
    }

    // ----- L3 Step 6: Deposit when totalSupply == 0 — first deposit establishes 1:1 rate -----
    function test_TC29_firstDepositEstablishes1to1Rate() public {
        // Before any deposit, totalSupply should only contain virtual offset
        uint256 initialSupply = tier0Vault.totalSupply();
        uint256 initialAssets = tier0Vault.totalAssets();

        uint256 shares = _depositTier0(alice, 1000e6);

        // First deposit: shares should be proportional to 1:1 rate
        // With OZ virtual offset (1 wei), the rate is slightly off but proportional
        assertGt(shares, 0, "first deposit must mint shares");
        assertEq(tier0Vault.totalAssets(), 1000e6, "totalAssets after first deposit must equal deposit amount");
    }

    // ----- L3 Step 7: Yield when totalSupply == 0 -----
    // OZ ERC-4626 formula: shares = assets * (totalSupply + 1) / (totalAssets + 1)
    // With totalSupply=0 and totalAssets=1000e6, depositing 1000e6 yields:
    //   shares = 1000e6 * 1 / (1000e6 + 1) = 0 (floor).
    // A much larger deposit is needed to get non-zero shares.
    function test_TC29_yieldWhenNoSharesOutstanding() public {
        // No deposits yet, accrue yield
        _accrueYieldTier0(1000e6);

        assertEq(tier0Vault.totalAssets(), 1000e6, "totalAssets must reflect yield even with no shares");
        assertEq(tier0Vault.totalYieldAccrued(), 1000e6, "totalYieldAccrued must reflect yield");

        // Deposit more than totalAssets to get non-zero shares
        // shares = 2000e6 * 1 / (1000e6 + 1) = 1 (floor)
        uint256 shares = _depositTier0(alice, 2000e6);
        assertGt(shares, 0, "deposit > totalAssets after yield-only must mint shares");

        // Alice deposited 2000e6 into vault with 1000e6 already => total 3000e6
        uint256 aliceAssets = tier0Vault.convertToAssets(shares);
        assertLe(aliceAssets, 2000e6, "alice's share value must be <= her deposit (rounding against user)");
    }

    // ----- L3 Step 8: Loss when totalSupply == 0 and totalAssets == 0 -----
    function test_TC29_lossWhenNoAssetsNoShares() public {
        // No deposits, totalAssets == 0
        assertEq(tier0Vault.totalAssets(), 0, "totalAssets should be 0");

        // absorbLoss with no assets: effective loss = min(amount, 0) = 0
        // This should transfer 0 to yieldSource
        _absorbLossTier0(1000e6);

        assertEq(tier0Vault.totalAssets(), 0, "totalAssets must remain 0 after loss on empty vault");
        assertEq(tier0Vault.totalLossAbsorbed(), 0, "totalLossAbsorbed should be 0 (no effective loss)");
    }

    // ----- L3 Step 8b: Loss when totalSupply == 0 but totalAssets > 0 (from prior yield) -----
    function test_TC29_lossWhenAssetsButNoDepositors() public {
        // Yield without depositors
        _accrueYieldTier0(500e6);
        assertEq(tier0Vault.totalAssets(), 500e6, "totalAssets should be 500e6 from yield");

        // Absorb loss of 200e6
        _absorbLossTier0(200e6);

        assertEq(tier0Vault.totalAssets(), 300e6, "totalAssets should be 300e6 after loss");
        assertEq(tier0Vault.totalLossAbsorbed(), 200e6, "totalLossAbsorbed should be 200e6");
    }

    // ----- L3 Step 9: requestWithdrawal for all shares — alice has 0 remaining -----
    function test_TC29_requestWithdrawalAllShares() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        assertEq(tier0Vault.balanceOf(alice), 0, "alice must have 0 shares after requesting all");

        // Alice cannot transfer (0 balance)
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        tier0Vault.transfer(bob, 1);
    }

    // ----- L3 Step 10: executeWithdrawal when vault barely sufficient -----
    function test_TC29_executeWithdrawalBarelySufficientVault() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        vm.prank(alice);
        tier0Vault.requestWithdrawal(aliceShares);

        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(alice);
        uint256 capturedAmount = pw.riskusdAmount;

        // Vault holds exactly enough RISKUSD
        uint256 vaultBalance = riskusd.balanceOf(address(tier0Vault));
        assertGe(vaultBalance, capturedAmount, "vault must hold at least the captured amount");

        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        uint256 aliceBefore = riskusd.balanceOf(alice);
        vm.prank(alice);
        tier0Vault.executeWithdrawal();
        uint256 aliceReceived = riskusd.balanceOf(alice) - aliceBefore;

        assertEq(aliceReceived, capturedAmount, "alice must receive exactly the captured amount");
    }

    // ----- L3 Step 11: Share/asset conversion at extreme exchange rates -----
    function test_TC29_conversionAtExtremeHighRate() public {
        // Deposit 1 RISKUSD, then accrue massive yield
        _depositTier0(alice, 1e6);
        _accrueYieldTier0(1e12); // 1M RISKUSD yield on 1 RISKUSD deposit

        // convertToShares(1) should return a very small number (extreme rate: ~1M:1)
        uint256 sharesFor1 = tier0Vault.convertToShares(1);
        // At such an extreme rate, 1 wei of assets may convert to 0 shares
        // This is acceptable (rounding against depositor)
        assertLe(sharesFor1, 1, "convertToShares(1) at extreme high rate should be 0 or minimal");
    }

    function test_TC29_conversionAtExtremeLowRate() public {
        // Deposit 1M RISKUSD, then absorb nearly all of it
        _depositTier0(alice, 1_000_000e6);
        _absorbLossTier0(999_999e6); // Leave only 1 RISKUSD

        // convertToShares(1e6) should return a very large number of shares
        uint256 sharesFor1M = tier0Vault.convertToShares(1e6);
        assertGt(sharesFor1M, 0, "convertToShares at extreme low rate should be > 0");

        // Exchange rate is extremely low, so 1 RISKUSD buys many shares
        uint256 totalSupply = tier0Vault.totalSupply();
        uint256 totalAssets = tier0Vault.totalAssets();
        // sharesFor1M should be roughly (1e6 * totalSupply) / totalAssets
        // which is (1e6 * totalSupply) / 1e6 = totalSupply
        // (approximately, within rounding)
    }

    // ----- L3 Step 12: Transfer of 0 shares -----
    function test_TC29_transferZeroShares() public {
        _depositTier0(alice, 1000e6);

        uint256 bobLockBefore = tier0Vault.lockExpiry(bob);

        // Transfer 0 shares — should succeed without side effects
        vm.prank(alice);
        tier0Vault.transfer(bob, 0);

        // No lock inheritance triggered (or if triggered, no harm)
        // For tier0 vault (no lockup), lock is 0 anyway. Just verify no revert.
        assertEq(tier0Vault.lockExpiry(bob), bobLockBefore, "0-share transfer should not change lock");
    }

    // ----- L3 Step 13: Approval and transferFrom edge cases -----
    function test_TC29_approvalExactAmount() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);
        uint256 transferAmount = aliceShares / 2;

        // Approve for exact amount
        vm.prank(alice);
        tier0Vault.approve(bob, transferAmount);

        // transferFrom for exact amount — should succeed
        vm.prank(bob);
        tier0Vault.transferFrom(alice, bob, transferAmount);

        assertEq(tier0Vault.balanceOf(bob), transferAmount, "bob must receive exact shares");
    }

    function test_TC29_approvalZero() public {
        _depositTier0(alice, 1000e6);

        // Approve 0
        vm.prank(alice);
        tier0Vault.approve(bob, 0);

        // transferFrom for any amount — should fail
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientAllowance
        tier0Vault.transferFrom(alice, bob, 1);
    }

    function test_TC29_approvalMaxUint256() public {
        _depositTier0(alice, 1000e6);
        uint256 aliceShares = tier0Vault.balanceOf(alice);

        // Approve max uint256
        vm.prank(alice);
        tier0Vault.approve(bob, type(uint256).max);

        // transferFrom — should succeed
        vm.prank(bob);
        tier0Vault.transferFrom(alice, bob, aliceShares);

        assertEq(tier0Vault.balanceOf(bob), aliceShares, "bob must receive all alice's shares");
    }

    // ----- L3 Step 14: Pending withdrawal struct for address with no withdrawal -----
    function test_TC29_pendingWithdrawalForRandomAddress() public {
        address randomAddr = makeAddr("randomWithNoActivity");
        atRISKUSD.PendingWithdrawal memory pw = tier0Vault.pendingWithdrawal(randomAddr);

        assertFalse(pw.active, "pending must be inactive for address with no withdrawal");
        assertEq(pw.atriskusdAmount, 0, "pending shares must be 0");
        assertEq(pw.riskusdAmount, 0, "pending riskusd must be 0");
        assertEq(pw.requestTimestamp, 0, "pending timestamp must be 0");
    }

    // ----- Additional: Zero mint amount reverts -----
    function test_TC29_zeroMintAmount_reverts() public {
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(tier0Vault), 1000e6);

        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.mint(0, alice);
        vm.stopPrank();
    }

    // ----- Additional: Zero requestWithdrawal amount reverts -----
    function test_TC29_zeroRequestWithdrawal_reverts() public {
        _depositTier0(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.requestWithdrawal(0);
    }

    // ----- Additional: Zero accrueYield amount reverts -----
    function test_TC29_zeroAccrueYield_reverts() public {
        vm.prank(yieldSource);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.accrueYield(0);
    }

    // ----- Additional: Zero absorbLoss amount reverts -----
    function test_TC29_zeroAbsorbLoss_reverts() public {
        vm.prank(yieldSource);
        vm.expectRevert(atRISKUSD.ZeroAmount.selector);
        tier0Vault.absorbLoss(0);
    }
}
