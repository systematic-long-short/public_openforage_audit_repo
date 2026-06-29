// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/atRISKUSD.sol";
import "./helpers/AtRISKUSDTestBase.sol";
import "./mocks/MockForageTokenLocked.sol";
import "./mocks/MockRISKUSD.sol";
import "./mocks/MockUSDC.sol";
import "./mocks/MockVaultRegistry.sol";
import "./mocks/MockYieldSourceForLossPending.sol";

contract MaliciousRound4RISKUSD is ERC20 {
    bool public overmintByOne;
    bool public underburnByOne;

    constructor() ERC20("Malicious RISKUSD", "mRISKUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setOvermintByOne(bool enabled) external {
        overmintByOne = enabled;
    }

    function setUnderburnByOne(bool enabled) external {
        underburnByOne = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount + (overmintByOne ? 1 : 0));
    }

    function burn(address from, uint256 amount) external {
        uint256 burnAmount = underburnByOne && amount > 0 ? amount - 1 : amount;
        _burn(from, burnAmount);
    }
}

contract RISKUSDVault_I4_BackingPerShareMonotonicity is Test {
    uint256 internal constant RAY = 1e27;
    bytes4 internal constant BACKING_MARGIN_DECREASED =
        bytes4(keccak256("BackingMarginDecreased(uint256,uint256,uint256,uint256)"));

    RISKUSDVault internal vault;
    MockUSDC internal usdc;
    MaliciousRound4RISKUSD internal riskusd;

    address internal owner = makeAddr("timelock");
    address internal alice = makeAddr("alice");
    address internal lossReporter = makeAddr("lossReporter");

    function setUp() public {
        usdc = new MockUSDC();
        riskusd = new MaliciousRound4RISKUSD();

        RISKUSDVault implementation = new RISKUSDVault();
        bytes memory initData = abi.encodeCall(RISKUSDVault.initialize, (address(usdc), address(riskusd), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RISKUSDVault(address(proxy));

        vm.startPrank(owner);
        vault.setPerBlockMintCap(10000, type(uint256).max);
        vault.setWeeklyMintCapBps(20000);
        vault.setWeeklyRedemptionCapBps(10000);
        vault.setDailyRedemptionCapBps(10000);
        vault.setMaxDeploymentRatioBps(10000);
        vault.setDeploymentBufferBps(0);
        vault.setLossReporter(lossReporter);
        vm.warp(block.timestamp + 2 days + 1);
        vault.finalizeLossReporter();
        vm.stopPrank();
    }

    function test_I4_depositMustRejectOvermintThatDropsBackingPerShareEvenWhenSolvent() public {
        _depositAs(alice, 1_000_000e6);
        usdc.mint(address(vault), 1);
        riskusd.setOvermintByOne(true);

        uint256 beforeRay = _vaultBackingPerShareRay();
        uint256 exploitDeposit = 1;
        usdc.mint(alice, exploitDeposit);
        vm.prank(alice);
        usdc.approve(address(vault), exploitDeposit);

        vm.roll(block.number + 1);
        vm.prank(alice);
        try vault.deposit(exploitDeposit) {
            uint256 afterRay = _vaultBackingPerShareRay();
            assertGe(_vaultBackingAssets(), riskusd.totalSupply(), "setup should remain system-solvent");
            assertGe(afterRay, beforeRay, "deposit succeeded after lowering backing/share");
        } catch (bytes memory reason) {
            _assertFutureBackingShareRevert(reason);
        }
    }

    function test_I4_redeemMustRejectUnderburnThatDropsBackingPerShareEvenWhenSolvent() public {
        _depositAs(alice, 1_000_000e6);
        usdc.mint(address(vault), 1);
        riskusd.setUnderburnByOne(true);

        uint256 beforeRay = _vaultBackingPerShareRay();

        vm.prank(alice);
        riskusd.approve(address(vault), 1);

        vm.prank(alice);
        try vault.redeem(1) {
            uint256 afterRay = _vaultBackingPerShareRay();
            assertGe(_vaultBackingAssets(), riskusd.totalSupply(), "setup should remain system-solvent");
            assertGe(afterRay, beforeRay, "redeem succeeded after lowering backing/share");
        } catch (bytes memory reason) {
            _assertFutureBackingShareRevert(reason);
        }
    }

    function test_I4_honestDepositAfterSurplusDonationPreservesBackingMargin() public {
        _depositAs(alice, 1_000e6);
        usdc.mint(address(vault), 1);

        uint256 beforeMargin = _vaultBackingMargin();
        vm.roll(block.number + 1);
        _depositAs(alice, 100e6);

        assertEq(_vaultBackingMargin(), beforeMargin, "honest 1:1 deposit must preserve surplus margin");
    }

    function test_I4_lossReporterDepositAfterReplenishPreservesBackingMargin() public {
        _depositAs(alice, 1_000e6);

        usdc.mint(lossReporter, 100e6);
        vm.startPrank(lossReporter);
        usdc.approve(address(vault), 100e6);
        vault.replenish(100e6);
        vm.stopPrank();

        uint256 beforeMargin = _vaultBackingMargin();
        vm.roll(block.number + 1);
        _depositAs(lossReporter, 50e6);

        assertEq(_vaultBackingMargin(), beforeMargin, "lossReporter yield deposit must preserve surplus margin");
    }

    function test_I4_fullRedeemAllowsZeroSupplyDrainAfterSurplus() public {
        _depositAs(alice, 1_000e6);
        usdc.mint(address(vault), 1);

        uint256 beforeRay = _vaultBackingPerShareRay();
        uint256 fullBalance = riskusd.balanceOf(alice);

        vm.prank(alice);
        riskusd.approve(address(vault), fullBalance);

        vm.prank(alice);
        vault.redeem(fullBalance);

        assertEq(riskusd.totalSupply(), 0, "full redeem should drain all RISKUSD supply");
        assertLt(_vaultBackingPerShareRay(), beforeRay, "zero-supply helper should normalize below surplus rate");
    }

    function _depositAs(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _vaultBackingPerShareRay() internal view returns (uint256) {
        uint256 supply = riskusd.totalSupply();
        if (supply == 0) return RAY;
        return _vaultBackingAssets() * RAY / supply;
    }

    function _vaultBackingAssets() internal view returns (uint256) {
        uint256 bookValue = vault.totalDeployed();
        uint256 adjustedNav = vault.adjustedCustodianNAV();
        uint256 conservativeCustodianValue = adjustedNav < bookValue ? adjustedNav : bookValue;
        return vault.vaultUsdcBalance() + conservativeCustodianValue;
    }

    function _vaultBackingMargin() internal view returns (uint256) {
        uint256 backingAssets = _vaultBackingAssets();
        uint256 supply = riskusd.totalSupply();
        require(backingAssets >= supply, "test setup must be solvent");
        return backingAssets - supply;
    }

    function _assertFutureBackingShareRevert(bytes memory reason) internal pure {
        require(reason.length >= 4, "expected backing/share custom error");
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        require(selector == BACKING_MARGIN_DECREASED, "unexpected revert selector");
    }
}

contract AtRISKUSD_I4_BackingPerShareMonotonicity is AtRISKUSDTestBase {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant AT_RISK_SHARE_SCALE = 1e6;
    bytes4 internal constant BACKING_PER_SHARE_DECREASED =
        bytes4(keccak256("BackingPerShareDecreased(uint256,uint256)"));

    function test_I4_depositBlocksBackingPerShareDropAfterYield() public {
        _depositViaQueue(alice, 1_000e6);
        _accrueYield(1_000e6);

        uint256 amount = 100e6;
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), amount);

        uint256 beforeRay = _backingPerShareRay(vault);
        try vault.deposit(amount, bob) {
            vm.stopPrank();
            assertGe(_backingPerShareRay(vault), beforeRay, "deposit lowered backing/share");
        } catch (bytes memory reason) {
            vm.stopPrank();
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_mintBlocksBackingPerShareDropAfterYield() public {
        _depositViaQueue(alice, 1_000e6);
        _accrueYield(1_000e6);

        uint256 sharesToMint = vault.balanceOf(alice) / 10;
        uint256 assetsNeeded = vault.previewMint(sharesToMint);
        riskusd.mint(stakingQueue, assetsNeeded);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(vault), assetsNeeded);

        uint256 beforeRay = _backingPerShareRay(vault);
        try vault.mint(sharesToMint, bob) {
            vm.stopPrank();
            assertGe(_backingPerShareRay(vault), beforeRay, "mint lowered backing/share");
        } catch (bytes memory reason) {
            vm.stopPrank();
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_withdrawBlocksBackingPerShareDropAfterLoss() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        _depositViaQueue(target, alice, 1_000e6);
        _absorbLoss(target, 500e6);

        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(alice);
        try target.withdraw(100e6, alice, alice) {
            assertGe(_backingPerShareRay(target), beforeRay, "withdraw lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_redeemBlocksBackingPerShareDropAfterLoss() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        _depositViaQueue(target, alice, 1_000e6);
        _absorbLoss(target, 500e6);

        uint256 shares = target.balanceOf(alice) / 10;
        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(alice);
        try target.redeem(shares, alice, alice) {
            assertGe(_backingPerShareRay(target), beforeRay, "redeem lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_requestWithdrawalKeepsBackingPerShareNonDecreasing() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, COOLDOWN_PERIOD, 0);
        _depositViaQueue(target, alice, 1_000e6);
        _absorbLoss(target, 500e6);

        uint256 shares = target.balanceOf(alice) / 10;
        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(alice);
        try target.requestWithdrawal(shares) {
            assertGe(_backingPerShareRay(target), beforeRay, "requestWithdrawal lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_executeWithdrawalBlocksBackingPerShareDropAfterLoss() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        _depositViaQueue(target, alice, 1_000e6);

        uint256 shares = target.balanceOf(alice) / 10;
        vm.prank(alice);
        target.requestWithdrawal(shares);
        _absorbLoss(target, 500e6);

        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(alice);
        try target.executeWithdrawal() {
            assertGe(_backingPerShareRay(target), beforeRay, "executeWithdrawal lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_redeemForUpgradeBlocksBackingPerShareDropAfterLoss() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        _depositViaQueue(target, alice, 1_000e6);
        _absorbLoss(target, 500e6);

        uint256 shares = target.balanceOf(alice) / 10;
        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(stakingQueue);
        try target.redeemForUpgrade(alice, shares) {
            assertGe(_backingPerShareRay(target), beforeRay, "redeemForUpgrade lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_redeemForReversionBlocksBackingPerShareDropAfterLoss() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        _depositViaQueue(target, alice, 1_000e6);
        vm.prank(alice);
        target.setAutoRenew(false);
        _absorbLoss(target, 500e6);

        uint256 shares = target.balanceOf(alice) / 10;
        uint256 beforeRay = _backingPerShareRay(target);
        vm.prank(stakingQueue);
        try target.redeemForReversion(alice, shares) {
            assertGe(_backingPerShareRay(target), beforeRay, "redeemForReversion lowered backing/share");
        } catch (bytes memory reason) {
            _assertAtRiskGuardRevert(reason);
        }
    }

    function test_I4_fullRedeemAllowsZeroSupplyDrainAfterYield() public {
        atRISKUSD target = _deployFreshVaultWithRaisedCap(0, 0, 0);
        uint256 shares = _depositViaQueue(target, alice, 1_000e6);
        _accrueYield(target, 1_000e6);

        vm.prank(alice);
        target.redeem(shares, alice, alice);

        assertEq(target.totalSupply(), 0, "full redeem should drain all atRISK supply");
    }

    function _deployFreshVaultWithRaisedCap(uint256 lockupPeriod_, uint256 cooldownPeriod_, uint8 tierId_)
        internal
        returns (atRISKUSD target)
    {
        target = _deployFreshVault(lockupPeriod_, cooldownPeriod_, tierId_);
        _raiseWeeklyWithdrawalCap(target);
    }

    function _depositViaQueue(atRISKUSD target, address receiver, uint256 amount) internal returns (uint256 shares) {
        riskusd.mint(stakingQueue, amount);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(target), amount);
        shares = target.deposit(amount, receiver);
        vm.stopPrank();
    }

    function _absorbLoss(atRISKUSD target, uint256 amount) internal {
        vm.prank(yieldSource);
        target.absorbLoss(amount);
    }

    function _accrueYield(atRISKUSD target, uint256 amount) internal {
        riskusd.mint(yieldSource, amount);
        vm.startPrank(yieldSource);
        riskusd.approve(address(target), amount);
        target.accrueYield(amount);
        vm.stopPrank();
    }

    function _backingPerShareRay(atRISKUSD target) internal view returns (uint256) {
        return
            Math.mulDiv(target.totalAssets() + 1, RAY * AT_RISK_SHARE_SCALE, target.totalSupply() + AT_RISK_SHARE_SCALE);
    }

    function _assertAtRiskGuardRevert(bytes memory reason) internal pure {
        require(reason.length >= 4, "expected atRISKUSD backing/share custom error");
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        require(
            selector == atRISKUSD.ExchangeRateDecreased.selector || selector == BACKING_PER_SHARE_DECREASED,
            "unexpected revert selector"
        );
    }
}

contract StakingQueue_I4_BackingPerShareMonotonicity is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant AT_RISK_SHARE_SCALE = 1e6;
    bytes4 internal constant COMBINED_BACKING_PER_SHARE_DECREASED =
        bytes4(keccak256("CombinedBackingPerShareDecreased(uint256,uint256)"));

    StakingQueue internal queue;
    MockRISKUSD internal riskusd;
    MockForageTokenLocked internal forage;
    MockVaultRegistry internal registry;
    MockYieldSourceForLossPending internal yieldSource;
    atRISKUSD[4] internal tiers;

    address internal owner = makeAddr("timelock");
    address internal placeholderQueue = makeAddr("placeholderQueue");
    address internal alice = makeAddr("alice");
    uint256 internal registeredVaultId;

    function setUp() public {
        riskusd = new MockRISKUSD();
        forage = new MockForageTokenLocked();
        registry = new MockVaultRegistry();
        yieldSource = new MockYieldSourceForLossPending();

        tiers[0] = _deployTier(0, 0);
        tiers[1] = _deployTier(90 days, 1);
        tiers[2] = _deployTier(180 days, 2);
        tiers[3] = _deployTier(365 days, 3);

        address[4] memory tierVaults = [address(tiers[0]), address(tiers[1]), address(tiers[2]), address(tiers[3])];
        uint256[4] memory lockups = [uint256(0), uint256(90 days), uint256(180 days), uint256(365 days)];
        uint16[4] memory yieldBps = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(1500), uint16(1500)];
        registeredVaultId = registry.addTestVault(
            "Round 4 Test Vault", "R4TV", tierVaults, address(0), 10_000_000e6, lockups, yieldBps, fundingBps
        );

        StakingQueue implementation = new StakingQueue();
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(registry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        queue = StakingQueue(address(proxy));

        vm.prank(owner);
        queue.setVaultId(registeredVaultId);

        vm.startPrank(owner);
        for (uint256 i; i < 4; i++) {
            tiers[i].setStakingQueue(address(queue));
            tiers[i].setWeeklyWithdrawalCapBps(10_000);
        }
        vm.warp(block.timestamp + 2 days + 1);
        for (uint256 i; i < 4; i++) {
            tiers[i].finalizeStakingQueue();
        }
        vm.stopPrank();
    }

    function test_I4_upgradeTierBlocksCombinedBackingPerShareDropAfterSourceLoss() public {
        _stake(alice, 1_000e6, 0);
        _absorbTierLoss(0, 500e6);

        uint256 shares = tiers[0].balanceOf(alice) / 10;
        uint256 beforeRay = _combinedBackingPerShareRay();
        vm.prank(alice);
        try queue.upgradeTier(0, 1, shares) {
            assertGe(_combinedBackingPerShareRay(), beforeRay, "upgradeTier lowered combined backing/share");
        } catch (bytes memory reason) {
            _assertCombinedGuardRevert(reason);
        }
    }

    function test_I4_processExpiredLockupsBlocksCombinedBackingPerShareDropAfterSourceLoss() public {
        _stake(alice, 1_000e6, 1);
        vm.prank(alice);
        tiers[1].setAutoRenew(false);
        _absorbTierLoss(1, 500e6);
        vm.warp(block.timestamp + 90 days + 1);

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        uint256 beforeRay = _combinedBackingPerShareRay();
        vm.prank(alice);
        try queue.processExpiredLockups(depositors, 1) {
            assertGe(
                _combinedBackingPerShareRay(), beforeRay, "expired-lockup reversion lowered combined backing/share"
            );
        } catch (bytes memory reason) {
            _assertCombinedGuardRevert(reason);
        }
    }

    function test_I4_processExpiredLockupsAllowsYieldedReversionAndPreservesAssets() public {
        _stake(alice, 1_000e6, 1);
        vm.prank(alice);
        tiers[1].setAutoRenew(false);
        _accrueTierYield(1, 500e6);
        vm.warp(block.timestamp + 90 days + 1);

        address[] memory depositors = new address[](1);
        depositors[0] = alice;

        uint256 beforeAssets = _combinedTierAssets();
        vm.prank(alice);
        queue.processExpiredLockups(depositors, 1);

        assertEq(tiers[1].balanceOf(alice), 0, "yielded source shares should be redeemed");
        assertGt(tiers[0].balanceOf(alice), 0, "yielded reversion should mint tier 0 shares");
        assertEq(_combinedTierAssets(), beforeAssets, "yielded reversion should conserve combined tier assets");
    }

    function test_I4_selfRevertAllowsYieldedReversionAndPreservesAssets() public {
        _stake(alice, 1_000e6, 1);
        vm.prank(alice);
        tiers[1].setAutoRenew(false);
        _accrueTierYield(1, 500e6);
        vm.warp(block.timestamp + 90 days + 1);

        uint256 beforeAssets = _combinedTierAssets();
        vm.prank(alice);
        queue.selfRevert(1);

        assertEq(tiers[1].balanceOf(alice), 0, "yielded source shares should be redeemed");
        assertGt(tiers[0].balanceOf(alice), 0, "yielded self-revert should mint tier 0 shares");
        assertEq(_combinedTierAssets(), beforeAssets, "yielded self-revert should conserve combined tier assets");
    }

    function _deployTier(uint256 lockup, uint8 tierId) internal returns (atRISKUSD) {
        atRISKUSD implementation = new atRISKUSD();
        bytes memory initData = abi.encodeCall(
            atRISKUSD.initialize,
            (
                address(riskusd),
                address(yieldSource),
                placeholderQueue,
                lockup,
                0,
                tierId,
                _tierAbbreviation(tierId),
                owner
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return atRISKUSD(address(proxy));
    }

    function _tierAbbreviation(uint8 tierId) internal pure returns (string memory) {
        if (tierId == 0) return "0D";
        if (tierId == 1) return "90D";
        if (tierId == 2) return "180D";
        if (tierId == 3) return "360D";
        return "";
    }

    function _stake(address depositor, uint256 amount, uint8 tier) internal {
        riskusd.mint(depositor, amount);
        vm.startPrank(depositor);
        riskusd.approve(address(queue), amount);
        queue.joinQueue(amount, tier);
        vm.stopPrank();
        queue.processQueue(tier, 10);
    }

    function _absorbTierLoss(uint8 tier, uint256 amount) internal {
        vm.prank(address(yieldSource));
        tiers[tier].absorbLoss(amount);
    }

    function _accrueTierYield(uint8 tier, uint256 amount) internal {
        riskusd.mint(address(yieldSource), amount);
        vm.startPrank(address(yieldSource));
        riskusd.approve(address(tiers[tier]), amount);
        tiers[tier].accrueYield(amount);
        vm.stopPrank();
    }

    function _combinedBackingPerShareRay() internal view returns (uint256) {
        uint256 totalAssets;
        uint256 totalSupply;
        for (uint256 i; i < 4; i++) {
            totalAssets += tiers[i].totalAssets() + 1;
            totalSupply += tiers[i].totalSupply() + AT_RISK_SHARE_SCALE;
        }
        return Math.mulDiv(totalAssets, RAY * AT_RISK_SHARE_SCALE, totalSupply);
    }

    function _combinedTierAssets() internal view returns (uint256 totalAssets) {
        for (uint256 i; i < 4; i++) {
            totalAssets += tiers[i].totalAssets();
        }
    }

    function _assertCombinedGuardRevert(bytes memory reason) internal pure {
        require(reason.length >= 4, "expected combined backing/share custom error");
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        require(selector == COMBINED_BACKING_PER_SHARE_DECREASED, "unexpected revert selector");
    }
}
