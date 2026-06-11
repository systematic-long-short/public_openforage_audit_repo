// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-01: Initialization Tests (R-01, R-02, R-03, R-04, R-05, R-39, R-40)
// ============================================================
contract AtRISKUSD_TC01_Initialization is AtRISKUSDTestBase {
    // ----- L3 Step 2: tierId() stored correctly -----
    function test_TC01_initSetsTierId() public view {
        assertEq(vault.tierId(), TIER_ID, "tierId mismatch after init");
    }

    // ----- L3 Step 3: lockupPeriod() stored correctly -----
    function test_TC01_initSetsLockupPeriod() public view {
        assertEq(vault.lockupPeriod(), LOCKUP_PERIOD, "lockupPeriod mismatch after init");
    }

    // ----- L3 Step 4: cooldownPeriod() stored correctly -----
    function test_TC01_initSetsCooldownPeriod() public view {
        assertEq(vault.cooldownPeriod(), COOLDOWN_PERIOD, "cooldownPeriod mismatch after init");
    }

    // ----- L3 Step 5: yieldSource() returns the yield source address -----
    function test_TC01_initSetsYieldSource() public view {
        assertEq(vault.yieldSource(), yieldSource, "yieldSource address mismatch after init");
    }

    // ----- L3 Step 6: stakingQueue() returns the staking queue address -----
    function test_TC01_initSetsStakingQueue() public view {
        assertEq(vault.stakingQueue(), stakingQueue, "stakingQueue address mismatch after init");
    }

    // ----- L3 Step 7: owner() == initialOwner_ -----
    function test_TC01_initSetsOwner() public view {
        assertEq(vault.owner(), owner, "owner mismatch after init");
    }

    // ----- L3 Step 8: totalYieldAccrued() == 0 -----
    function test_TC01_initSetsYieldAccruedToZero() public view {
        assertEq(vault.totalYieldAccrued(), 0, "totalYieldAccrued should be 0 after init");
    }

    // ----- L3 Step 9: totalLossAbsorbed() == 0 -----
    function test_TC01_initSetsLossAbsorbedToZero() public view {
        assertEq(vault.totalLossAbsorbed(), 0, "totalLossAbsorbed should be 0 after init");
    }

    // ----- L3 Step 10: totalSupply() == 0 -----
    function test_TC01_initSetsTotalSupplyZero() public view {
        assertEq(vault.totalSupply(), 0, "totalSupply should be 0 after init");
    }

    // ----- L3 Step 11: totalAssets() == 0 -----
    function test_TC01_initSetsTotalAssetsZero() public view {
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after init");
    }

    // ----- L3 Step 12: asset() returns the RISKUSD address -----
    function test_TC01_initSetsAsset() public view {
        assertEq(vault.asset(), address(riskusd), "asset() should return RISKUSD address");
    }

    function test_TC01_initSetsMetadata() public view {
        assertEq(vault.name(), "atRISKUSD-90D", "name mismatch after init");
        assertEq(vault.symbol(), "atRISKUSD-90D", "symbol mismatch after init");
    }

    // ----- L3 Step 13: Double-init reverts InvalidInitialization -----
    function test_TC01_doubleInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            address(riskusd),
            yieldSource,
            stakingQueue,
            LOCKUP_PERIOD,
            COOLDOWN_PERIOD,
            TIER_ID,
            TIER_ABBREVIATION,
            owner
        );
    }

    // ----- L3 Step 14: Zero address for riskusd_ reverts ZeroAddress -----
    function test_TC01_initZeroRiskusdReverts() public {
        atRISKUSD impl = new atRISKUSD();
        vm.expectRevert(atRISKUSD.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    address(0),
                    yieldSource,
                    stakingQueue,
                    LOCKUP_PERIOD,
                    COOLDOWN_PERIOD,
                    TIER_ID,
                    TIER_ABBREVIATION,
                    owner
                )
            )
        );
    }

    // ----- L3 Step 14: Zero address for yieldSource_ is allowed (circular dependency) -----
    function test_TC01_initZeroYieldSourceAllowed() public {
        atRISKUSD impl = new atRISKUSD();
        // yieldSource_ may be address(0) at deploy time; owner sets via setYieldSource() later
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    address(riskusd),
                    address(0),
                    stakingQueue,
                    LOCKUP_PERIOD,
                    COOLDOWN_PERIOD,
                    TIER_ID,
                    TIER_ABBREVIATION,
                    owner
                )
            )
        );
        atRISKUSD v = atRISKUSD(address(proxy));
        assertEq(v.yieldSource(), address(0), "yieldSource should be address(0) after init");
    }

    // ----- L3 Step 14: Zero address for stakingQueue_ is allowed (circular dependency) -----
    function test_TC01_initZeroStakingQueueAllowed() public {
        atRISKUSD impl = new atRISKUSD();
        // stakingQueue_ may be address(0) at deploy time; owner sets via setStakingQueue() later
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    address(riskusd),
                    yieldSource,
                    address(0),
                    LOCKUP_PERIOD,
                    COOLDOWN_PERIOD,
                    TIER_ID,
                    TIER_ABBREVIATION,
                    owner
                )
            )
        );
        atRISKUSD v = atRISKUSD(address(proxy));
        assertEq(v.stakingQueue(), address(0), "stakingQueue should be address(0) after init");
    }

    // ----- L3 Step 14: Zero address for initialOwner_ reverts ZeroAddress -----
    function test_TC01_initZeroOwnerReverts() public {
        atRISKUSD impl = new atRISKUSD();
        vm.expectRevert(atRISKUSD.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (
                    address(riskusd),
                    yieldSource,
                    stakingQueue,
                    LOCKUP_PERIOD,
                    COOLDOWN_PERIOD,
                    TIER_ID,
                    TIER_ABBREVIATION,
                    address(0)
                )
            )
        );
    }

    function test_TC01_initEmptyAbbreviationReverts() public {
        atRISKUSD impl = new atRISKUSD();
        vm.expectRevert(atRISKUSD.EmptyAbbreviation.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (address(riskusd), yieldSource, stakingQueue, LOCKUP_PERIOD, COOLDOWN_PERIOD, TIER_ID, "", owner)
            )
        );
    }

    // ----- L3 Step 15: Invalid tier 4 reverts InvalidTier -----
    function test_TC01_initInvalidTier4Reverts() public {
        atRISKUSD impl = new atRISKUSD();
        vm.expectRevert(atRISKUSD.InvalidTier.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (address(riskusd), yieldSource, stakingQueue, LOCKUP_PERIOD, COOLDOWN_PERIOD, 4, "4D", owner)
            )
        );
    }

    // ----- L3 Step 15: Invalid tier 255 reverts InvalidTier -----
    function test_TC01_initInvalidTier255Reverts() public {
        atRISKUSD impl = new atRISKUSD();
        vm.expectRevert(atRISKUSD.InvalidTier.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                atRISKUSD.initialize,
                (address(riskusd), yieldSource, stakingQueue, LOCKUP_PERIOD, COOLDOWN_PERIOD, 255, "255D", owner)
            )
        );
    }

    // ----- L3 Step 16: Implementation contract initializers disabled -----
    function test_TC01_implDirectInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(riskusd),
            yieldSource,
            stakingQueue,
            LOCKUP_PERIOD,
            COOLDOWN_PERIOD,
            TIER_ID,
            TIER_ABBREVIATION,
            owner
        );
    }

    // ----- L3 Step 17: Tier 0 config verified -----
    function test_TC01_initTier0Config() public {
        atRISKUSD tier0 = _deployFreshVault(0, COOLDOWN_PERIOD, 0);
        assertEq(tier0.tierId(), 0, "tier0 tierId mismatch");
        assertEq(tier0.lockupPeriod(), 0, "tier0 lockupPeriod mismatch");
        assertEq(tier0.cooldownPeriod(), COOLDOWN_PERIOD, "tier0 cooldownPeriod mismatch");
    }

    // ----- L3 Step 17: Tier 1 config verified (already tested via setUp) -----
    function test_TC01_initTier1Config() public view {
        assertEq(vault.tierId(), 1, "tier1 tierId mismatch");
        assertEq(vault.lockupPeriod(), 7_776_000, "tier1 lockupPeriod mismatch (90 days)");
    }

    // ----- L3 Step 17: Tier 2 config verified -----
    function test_TC01_initTier2Config() public {
        atRISKUSD tier2 = _deployFreshVault(15_552_000, COOLDOWN_PERIOD, 2);
        assertEq(tier2.tierId(), 2, "tier2 tierId mismatch");
        assertEq(tier2.lockupPeriod(), 15_552_000, "tier2 lockupPeriod mismatch (180 days)");
    }

    // ----- L3 Step 17: Tier 3 config verified -----
    function test_TC01_initTier3Config() public {
        atRISKUSD tier3 = _deployFreshVault(31_104_000, COOLDOWN_PERIOD, 3);
        assertEq(tier3.tierId(), 3, "tier3 tierId mismatch");
        assertEq(tier3.lockupPeriod(), 31_104_000, "tier3 lockupPeriod mismatch (360 days)");
    }

    function test_TC01_initializeV3SetsMetadataAfterV2() public {
        vm.startPrank(owner);
        vault.initializeV2();
        vault.initializeV3("360D");
        vm.stopPrank();

        assertEq(vault.name(), "atRISKUSD-360D", "name should be retagged");
        assertEq(vault.symbol(), "atRISKUSD-360D", "symbol should be retagged");
    }

    function test_TC01_initializeV3DoubleCallReverts() public {
        vm.startPrank(owner);
        vault.initializeV2();
        vault.initializeV3("360D");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initializeV3("180D");
        vm.stopPrank();
    }

    function test_TC01_initializeV3NonOwnerReverts() public {
        vm.prank(owner);
        vault.initializeV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.initializeV3("360D");
    }

    function test_TC01_initializeV3EmptyAbbreviationReverts() public {
        vm.prank(owner);
        vault.initializeV2();

        vm.prank(owner);
        vm.expectRevert(atRISKUSD.EmptyAbbreviation.selector);
        vault.initializeV3("");
    }
}
