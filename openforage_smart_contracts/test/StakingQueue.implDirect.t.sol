// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-16: Implementation Direct Call Tests (R-02)
// Verify the implementation contract cannot be initialized or
// used directly. Constructor _disableInitializers ensures the
// implementation is completely inert.
// ============================================================
contract StakingQueue_TC16_ImplDirect is StakingQueueTestBase {
    /// @dev Step 1-2: Deploy implementation directly (not behind proxy).
    /// Call initialize() on implementation -- MUST revert with
    /// InvalidInitialization().
    function test_TC16_implDirectInitReverts() public {
        // `implementation` is deployed in StakingQueueTestBase.setUp()
        // without going through a proxy.
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }

    /// @dev Step 3: Call joinQueue() on implementation directly.
    /// MUST revert (not initialized, disabled initializers prevent state).
    function test_TC16_implDirectJoinQueueReverts() public {
        riskusd.mint(alice, STANDARD_DEPOSIT);
        vm.prank(alice);
        riskusd.approve(address(implementation), STANDARD_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert();
        implementation.joinQueue(STANDARD_DEPOSIT, 0);
    }

    /// @dev Step 4a: Call cancelQueue() on implementation directly.
    /// MUST revert (not initialized).
    function test_TC16_implDirectCancelQueueReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        implementation.cancelQueue(1);
    }

    /// @dev Step 4b: Call processQueue() on implementation directly.
    /// MUST revert (not initialized).
    function test_TC16_implDirectProcessQueueReverts() public {
        vm.prank(keeper);
        vm.expectRevert();
        implementation.processQueue(0, 10);
    }

    /// @dev Step 5: Verify constructor called _disableInitializers() by
    /// confirming the implementation's initialization state is locked.
    /// A second call to initialize() after construction MUST revert
    /// InvalidInitialization, proving _disableInitializers() ran.
    function test_TC16_constructorDisabledInitializers() public {
        // Deploy a fresh implementation contract
        StakingQueue freshImpl = new StakingQueue();

        // Attempt to initialize -- must revert because constructor
        // called _disableInitializers()
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        freshImpl.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }
}
