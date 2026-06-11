// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AtRISKUSDTestBase.sol";
import "./helpers/AtRISKUSDV2.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-21: Attack Vector -- Implementation Direct Call Tests (R-02, R-37)
// ============================================================
contract AtRISKUSD_TC21_AttackImpl is AtRISKUSDTestBase {
    // ----- L3 Step 1: Implementation initialize — MUST revert InvalidInitialization -----
    // Constructor calls _disableInitializers(), so initialize on implementation is blocked.
    function test_TC21_implementationInitializeReverts() public {
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

    // ----- L3 Step 1 variant: Attacker tries to initialize implementation -----
    function test_TC21_attackerCannotInitializeImplementation() public {
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(riskusd),
            attacker, // attacker as yieldSource
            attacker, // attacker as stakingQueue
            LOCKUP_PERIOD,
            COOLDOWN_PERIOD,
            TIER_ID,
            TIER_ABBREVIATION,
            attacker // attacker as owner
        );
    }

    // ----- L3 Step 2: Unauthorized upgradeToAndCall on proxy — MUST revert -----
    function test_TC21_unauthorizedUpgradeOnProxyReverts() public {
        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();

        // Attacker tries to upgrade
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    // ----- L3 Step 2 variant: Alice (regular depositor) cannot upgrade -----
    function test_TC21_depositorCannotUpgrade() public {
        _depositViaQueue(alice, 1000e6);

        AtRISKUSDV2 v2Impl = new AtRISKUSDV2();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    // ----- L3 Step 3: Implementation state isolation -----
    // Any state on the implementation contract does not affect the proxy.
    function test_TC21_implementationStateIsolation() public {
        // Verify the implementation's view functions return default/uninitialized state
        // since _disableInitializers was called but no actual initialization happened

        // The implementation should have tierId = 0 (default, uninitialized)
        assertEq(implementation.tierId(), 0, "Implementation tierId should be 0 (uninitialized)");

        // The proxy should have the initialized values
        assertEq(vault.tierId(), TIER_ID, "Proxy tierId should be initialized value");

        // Verify they are independent
        assertTrue(address(implementation) != address(vault), "Implementation and proxy must be different addresses");

        // Implementation's owner should be address(0) (not initialized)
        assertEq(implementation.owner(), address(0), "Implementation owner should be address(0) (uninitialized)");

        // Proxy's owner should be the initialized owner
        assertEq(vault.owner(), owner, "Proxy owner should be the initialized owner");
    }

    // ----- Additional: Implementation has no depositor funds -----
    function test_TC21_implementationHasNoFunds() public {
        // Deposit into the proxy
        _depositViaQueue(alice, 1000e6);

        // Implementation should have zero RISKUSD balance
        assertEq(riskusd.balanceOf(address(implementation)), 0, "Implementation should have no RISKUSD balance");

        // Proxy should have the deposited funds
        assertEq(riskusd.balanceOf(address(vault)), 1000e6, "Proxy should hold the deposited RISKUSD");
    }

    // ----- Additional: Implementation totalSupply is zero -----
    function test_TC21_implementationTotalSupplyZero() public {
        _depositViaQueue(alice, 1000e6);

        // Implementation totalSupply should be 0
        assertEq(implementation.totalSupply(), 0, "Implementation totalSupply should be 0 (no real shares minted)");

        // Proxy totalSupply should reflect deposits
        assertTrue(vault.totalSupply() > 0, "Proxy totalSupply should be > 0 after deposit");
    }

    // ----- Additional: Cannot call deposit on implementation -----
    function test_TC21_cannotDepositOnImplementation() public {
        riskusd.mint(stakingQueue, 1000e6);
        vm.startPrank(stakingQueue);
        riskusd.approve(address(implementation), 1000e6);
        // Should revert -- implementation is not initialized, stakingQueue check will fail
        vm.expectRevert();
        implementation.deposit(1000e6, alice);
        vm.stopPrank();
    }
}
