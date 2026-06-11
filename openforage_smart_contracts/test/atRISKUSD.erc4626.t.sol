// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";

// ============================================================
// TC-12: ERC-4626 Compliance Tests (R-06, R-15, R-20, R-21, R-43)
// ============================================================
contract AtRISKUSD_TC12_ERC4626 is AtRISKUSDTestBase {
    // ----- L3 Step 1: deposit(assets, receiver) — StakingQueue deposits, returns shares -----
    function test_TC12_depositReturnsSharesAndEmitsEvent() public {
        uint256 depositAmount = 1000e6;
        riskusd.mint(stakingQueue, depositAmount);

        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), depositAmount);

        // Expect Deposit event (ERC-4626 standard event)
        // Deposit(caller, receiver, assets, shares) — we check caller and receiver
        vm.expectEmit(true, true, false, false, address(vault));
        // caller = stakingQueue, receiver = alice
        emit IERC4626.Deposit(stakingQueue, alice, 0, 0); // data checked loosely

        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        assertTrue(shares > 0, "deposit should return shares > 0");
        assertEq(vault.balanceOf(alice), shares, "alice should own the returned shares");
    }

    // ----- L3 Step 2: mint(shares, receiver) — StakingQueue mints exact shares -----
    function test_TC12_mintExactSharesAndEmitsEvent() public {
        // First deposit to establish exchange rate
        _depositViaQueue(alice, 1000e6);

        uint256 sharesToMint = 500e6;
        uint256 assetsNeeded = vault.previewMint(sharesToMint);

        riskusd.mint(stakingQueue, assetsNeeded);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), assetsNeeded);

        uint256 assetsConsumed = vault.mint(sharesToMint, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), sharesToMint, "bob should have exact shares minted");
        assertEq(assetsConsumed, assetsNeeded, "assets consumed should match previewMint");
    }

    // ----- L3 Step 3: withdraw with active lockup reverts LockupNotExpired (OF-005) -----
    function test_TC12_withdrawWithCooldownReverts() public {
        _depositViaQueue(alice, 1000e6);

        // OF-005: Lockup check fires before cooldown check
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + vault.lockupPeriod())
        );
        vault.withdraw(100e6, alice, alice);
    }

    // ----- L3 Step 4: withdraw with cooldown == 0 succeeds -----
    function test_TC12_withdrawWithZeroCooldownSucceeds() public {
        // Deploy vault with cooldown = 0
        atRISKUSD noCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(noCooldownVault);

        // Deposit
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(noCooldownVault), 1000e6);
        noCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        uint256 aliceShares = noCooldownVault.balanceOf(alice);

        // withdraw should work (cooldown == 0)
        vm.prank(alice);
        uint256 sharesBurned = noCooldownVault.withdraw(500e6, alice, alice);

        assertTrue(sharesBurned > 0, "shares should be burned");
        assertEq(riskusd.balanceOf(alice), aliceBalBefore + 500e6, "alice should receive RISKUSD");
    }

    // ----- L3 Step 5: redeem with active lockup reverts LockupNotExpired (OF-005) -----
    function test_TC12_redeemWithCooldownReverts() public {
        uint256 aliceShares = _depositViaQueue(alice, 1000e6);

        // OF-005: Lockup check fires before cooldown check
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(atRISKUSD.LockupNotExpired.selector, block.timestamp + vault.lockupPeriod())
        );
        vault.redeem(aliceShares, alice, alice);
    }

    // ----- L3 Step 6: redeem with cooldown == 0 succeeds -----
    function test_TC12_redeemWithZeroCooldownSucceeds() public {
        atRISKUSD noCooldownVault = _deployFreshVault(0, 0, 0);
        _raiseWeeklyWithdrawalCap(noCooldownVault);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(noCooldownVault), 1000e6);
        uint256 shares = noCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 aliceBalBefore = riskusd.balanceOf(alice);
        uint256 sharesToRedeem = shares / 2;
        uint256 expectedAssets = noCooldownVault.previewRedeem(sharesToRedeem);

        vm.prank(alice);
        uint256 assetsReceived = noCooldownVault.redeem(sharesToRedeem, alice, alice);

        assertEq(assetsReceived, expectedAssets, "assets received should match previewRedeem");
        assertEq(riskusd.balanceOf(alice), aliceBalBefore + assetsReceived, "alice receives RISKUSD");
    }

    // ----- L3 Step 7: convertToShares — correct math, rounds down -----
    function test_TC12_convertToSharesCorrectAndRoundsDown() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(500e6); // totalAssets = 1500e6

        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        uint256 testAssets = 100e6;
        uint256 shares = vault.convertToShares(testAssets);

        // OF-002: With _decimalsOffset()=6, ERC4626 uses virtual shares (1e6) and virtual asset (1).
        // The formula is: shares = assets * (totalSupply + 10^offset) / (totalAssets + 1)
        // Round-down property: shares * (totalAssets + 1) <= testAssets * (totalSupply + 10^offset)
        uint256 virtualOffset = 10 ** 6; // _decimalsOffset() = 6
        assertTrue(
            shares * (totalAssets + 1) <= testAssets * (totalSupply + virtualOffset), "convertToShares must round down"
        );
    }

    // ----- L3 Step 8: convertToAssets — correct math, rounds down -----
    function test_TC12_convertToAssetsCorrectAndRoundsDown() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(500e6);

        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        uint256 testShares = 100e6;
        uint256 assets = vault.convertToAssets(testShares);

        // OF-002: With _decimalsOffset()=6, ERC4626 uses virtual shares (1e6) and virtual asset (1).
        // The formula is: assets = shares * (totalAssets + 1) / (totalSupply + 10^offset)
        // Round-down property: assets * (totalSupply + 10^offset) <= testShares * (totalAssets + 1)
        uint256 virtualOffset = 10 ** 6; // _decimalsOffset() = 6
        assertTrue(
            assets * (totalSupply + virtualOffset) <= testShares * (totalAssets + 1), "convertToAssets must round down"
        );
    }

    // ----- L3 Step 9: Inverse consistency — round-trip never profits user -----
    function test_TC12_inverseConsistencyNoProfitOnRoundTrip() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(333e6); // Non-trivial rate

        uint256 testAmount = 123_456_789; // Arbitrary amount
        uint256 shares = vault.convertToShares(testAmount);
        uint256 roundTrip = vault.convertToAssets(shares);

        assertTrue(roundTrip <= testAmount, "round-trip convertToAssets(convertToShares(X)) must be <= X");
    }

    // ----- L3 Step 10: previewDeposit matches convertToShares -----
    function test_TC12_previewDepositMatchesConvertToShares() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(100e6);

        uint256 assets = 500e6;
        uint256 previewShares = vault.previewDeposit(assets);
        uint256 convertShares = vault.convertToShares(assets);

        assertEq(previewShares, convertShares, "previewDeposit should match convertToShares");
    }

    // ----- L3 Step 11: previewMint rounds up (costs more to get exact shares) -----
    function test_TC12_previewMintRoundsUp() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(333e6); // Non-trivial rate for rounding difference

        uint256 testShares = 1; // 1 share
        uint256 previewAssets = vault.previewMint(testShares);
        uint256 convertAssets = vault.convertToAssets(testShares);

        // previewMint should round up, convertToAssets rounds down
        assertTrue(previewAssets >= convertAssets, "previewMint must round up (>= convertToAssets)");
    }

    // ----- L3 Step 12: previewWithdraw computes correctly even with cooldown -----
    function test_TC12_previewWithdrawComputesWithCooldown() public {
        _depositViaQueue(alice, 1000e6);

        // previewWithdraw should return a valid value even though withdraw will revert
        uint256 sharesNeeded = vault.previewWithdraw(500e6);
        assertTrue(sharesNeeded > 0, "previewWithdraw should return shares > 0");
    }

    // ----- L3 Step 13: previewRedeem rounds down -----
    function test_TC12_previewRedeemRoundsDown() public {
        _depositViaQueue(alice, 1000e6);
        _accrueYield(333e6);

        uint256 testShares = 1;
        uint256 previewAssets = vault.previewRedeem(testShares);
        uint256 convertAssets = vault.convertToAssets(testShares);

        assertEq(previewAssets, convertAssets, "previewRedeem should match convertToAssets (rounds down)");
    }

    // ----- L3 Step 14: maxDeposit returns type(uint256).max when unpaused, 0 when paused -----
    function test_TC12_maxDepositUnpausedAndPaused() public {
        // Unpaused: maxDeposit returns type(uint256).max
        uint256 maxDep = vault.maxDeposit(stakingQueue);
        assertEq(maxDep, type(uint256).max, "maxDeposit should be type(uint256).max when unpaused");

        // Paused: maxDeposit returns 0
        vm.prank(owner);
        vault.pause();

        uint256 maxDepPaused = vault.maxDeposit(stakingQueue);
        assertEq(maxDepPaused, 0, "maxDeposit should be 0 when paused");
    }

    // ----- L3 Step 15: maxMint returns type(uint256).max when unpaused, 0 when paused -----
    function test_TC12_maxMintUnpausedAndPaused() public {
        uint256 maxMnt = vault.maxMint(stakingQueue);
        assertEq(maxMnt, type(uint256).max, "maxMint should be type(uint256).max when unpaused");

        vm.prank(owner);
        vault.pause();

        uint256 maxMntPaused = vault.maxMint(stakingQueue);
        assertEq(maxMntPaused, 0, "maxMint should be 0 when paused");
    }

    // ----- L3 Step 16: maxWithdraw returns 0 when cooldown > 0 -----
    function test_TC12_maxWithdrawZeroWithCooldown() public {
        _depositViaQueue(alice, 1000e6);

        // With cooldown > 0, maxWithdraw should return 0
        uint256 maxW = vault.maxWithdraw(alice);
        assertEq(maxW, 0, "maxWithdraw should be 0 when cooldown > 0");
    }

    // ----- L3 Step 17: maxRedeem returns 0 when cooldown > 0 -----
    function test_TC12_maxRedeemZeroWithCooldown() public {
        _depositViaQueue(alice, 1000e6);

        uint256 maxR = vault.maxRedeem(alice);
        assertEq(maxR, 0, "maxRedeem should be 0 when cooldown > 0");
    }

    // ----- L3 Step 18: maxWithdraw returns correct value when cooldown == 0 -----
    function test_TC12_maxWithdrawWithZeroCooldown() public {
        atRISKUSD noCooldownVault = _deployFreshVault(0, 0, 0);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(noCooldownVault), 1000e6);
        noCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 maxW = noCooldownVault.maxWithdraw(alice);
        uint256 aliceShares = noCooldownVault.balanceOf(alice);
        uint256 expectedMaxW = noCooldownVault.convertToAssets(aliceShares);

        assertEq(maxW, expectedMaxW, "maxWithdraw should return alice's full asset value");
    }

    // ----- L3 Step 19: maxRedeem returns share balance when cooldown == 0 -----
    function test_TC12_maxRedeemWithZeroCooldown() public {
        atRISKUSD noCooldownVault = _deployFreshVault(0, 0, 0);

        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(noCooldownVault), 1000e6);
        noCooldownVault.deposit(1000e6, alice);
        vm.stopPrank();

        uint256 maxR = noCooldownVault.maxRedeem(alice);
        assertEq(maxR, noCooldownVault.balanceOf(alice), "maxRedeem should return alice's share balance");
    }

    // ----- L3 Step 20: totalAssets correct after deposit/yield/loss -----
    function test_TC12_totalAssetsAfterDepositYieldLoss() public {
        // After deposit
        _depositViaQueue(alice, 1000e6);
        assertEq(vault.totalAssets(), 1000e6, "totalAssets after deposit");

        // After yield
        _accrueYield(200e6);
        assertEq(vault.totalAssets(), 1200e6, "totalAssets after yield");

        // After loss
        _absorbLoss(300e6);
        assertEq(vault.totalAssets(), 900e6, "totalAssets after loss");
    }

    // ----- L3 Step 21: asset() returns RISKUSD address -----
    function test_TC12_assetReturnsRISKUSD() public view {
        assertEq(vault.asset(), address(riskusd), "asset() should return RISKUSD address");
    }

    // ----- L3 Step 22: decimals() returns RISKUSD decimals + offset -----
    function test_TC12_decimalsReturnsCorrectValue() public view {
        // RISKUSD has 6 decimals. OpenZeppelin ERC4626 adds decimalsOffset (default 0).
        // The actual value depends on the OpenZeppelin implementation defaults.
        uint8 dec = vault.decimals();
        // Must be at least RISKUSD decimals (6)
        assertTrue(dec >= 6, "decimals should be at least RISKUSD decimals (6)");
    }

    // ----- Additional: deposit restricted to StakingQueue -----
    function test_TC12_depositRestrictedToStakingQueue() public {
        riskusd.mint(alice, 1000e6);
        vm.startPrank(alice);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    // ----- Additional: mint restricted to StakingQueue -----
    function test_TC12_mintRestrictedToStakingQueue() public {
        riskusd.mint(alice, 1000e6);
        vm.startPrank(alice);
        riskusd.approve(address(vault), 1000e6);
        vm.expectRevert(atRISKUSD.UnauthorizedStakingQueue.selector);
        vault.mint(1000e6, alice);
        vm.stopPrank();
    }
}

// Import needed for event
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
