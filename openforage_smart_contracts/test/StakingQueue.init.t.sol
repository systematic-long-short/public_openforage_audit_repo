// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/StakingQueueTestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-01: Initialization Tests (R-01, R-02, R-03, R-04, R-05,
//        R-06, R-07, R-08, R-09, R-42)
// ============================================================
contract StakingQueue_TC01_Initialization is StakingQueueTestBase {
    // ----- Step 2: riskusd() returns the RISKUSD address -----
    function test_TC01_initSetsRiskusd() public view {
        assertEq(queue.riskusd(), address(riskusd), "riskusd address mismatch after init");
    }

    // ----- Step 3: forage() returns the ForageToken address -----
    function test_TC01_initSetsForage() public view {
        assertEq(queue.forage(), address(forage), "forage address mismatch after init");
    }

    // ----- Step 4: tierVault(0..3) return the 4 tier vault addresses -----
    function test_TC01_initSetsTierVaults() public view {
        assertEq(queue.tierVault(0), address(vault0), "tierVault(0) mismatch");
        assertEq(queue.tierVault(1), address(vault1), "tierVault(1) mismatch");
        assertEq(queue.tierVault(2), address(vault2), "tierVault(2) mismatch");
        assertEq(queue.tierVault(3), address(vault3), "tierVault(3) mismatch");
    }

    // ----- Step 5: owner() == initialOwner_ -----
    function test_TC01_initSetsOwner() public view {
        assertEq(queue.owner(), owner, "owner mismatch after init");
    }

    // ----- Step 6: nextQueueId() == 1 -----
    function test_TC01_initSetsNextQueueIdToOne() public view {
        assertEq(queue.nextQueueId(), 1, "nextQueueId should be 1 after init");
    }

    // ----- Step 7: combinedCapacity() == 10_000_000e6 (read from VaultRegistry) -----
    function test_TC01_initSetsCombinedCapacity() public view {
        assertEq(queue.combinedCapacity(), 10_000_000e6, "combinedCapacity should be 10M after init");
    }

    // ----- Step 7b: vaultRegistry() returns the VaultRegistry address -----
    function test_TC01_initSetsVaultRegistry() public view {
        assertEq(queue.vaultRegistry(), address(mockVaultRegistry), "vaultRegistry address mismatch after init");
    }

    // ----- Step 7c: vaultId() returns the registered vault ID -----
    function test_TC01_initSetsVaultId() public view {
        assertEq(queue.vaultId(), registeredVaultId, "vaultId mismatch after init");
    }

    // ----- Step 8: foragePriceUsd() == 0 and priorityMultiplier() == 0 -----
    function test_TC01_initSetsPriorityParamsToZero() public view {
        assertEq(queue.foragePriceUsd(), 0, "foragePriceUsd should be 0 after init");
        assertEq(queue.priorityMultiplier(), 0, "priorityMultiplier should be 0 after init");
    }

    // ----- Step 9: forageGovernor() == address(0) -----
    function test_TC01_initSetsForageGovernorToZero() public view {
        assertEq(queue.forageGovernor(), address(0), "forageGovernor should be address(0) after init");
    }

    // ----- Step 10: totalQueuedRiskusd() == 0 -----
    function test_TC01_initSetsTotalQueuedRiskusdToZero() public view {
        assertEq(queue.totalQueuedRiskusd(), 0, "totalQueuedRiskusd should be 0 after init");
    }

    // ----- Step 11: tierPriorityHead(0..3) == 0 -----
    function test_TC01_initSetsTierPriorityHeadsToZero() public view {
        for (uint8 t = 0; t < 4; t++) {
            assertEq(queue.tierPriorityHead(t), 0, "tierPriorityHead should be 0 after init");
        }
    }

    // ----- Step 12: tierStandardHead(0..3) == 0 -----
    function test_TC01_initSetsTierStandardHeadsToZero() public view {
        for (uint8 t = 0; t < 4; t++) {
            assertEq(queue.tierStandardHead(t), 0, "tierStandardHead should be 0 after init");
        }
    }

    // ----- Step 13: tierPriorityQueueLength(0..3) == 0 -----
    function test_TC01_initSetsTierPriorityQueueLengthsToZero() public view {
        for (uint8 t = 0; t < 4; t++) {
            assertEq(queue.tierPriorityQueueLength(t), 0, "tierPriorityQueueLength should be 0 after init");
        }
    }

    // ----- Step 14: tierStandardQueueLength(0..3) == 0 -----
    function test_TC01_initSetsTierStandardQueueLengthsToZero() public view {
        for (uint8 t = 0; t < 4; t++) {
            assertEq(queue.tierStandardQueueLength(t), 0, "tierStandardQueueLength should be 0 after init");
        }
    }

    // ----- Step 15: paused() == false -----
    function test_TC01_initSetsUnpaused() public view {
        assertFalse(queue.paused(), "contract should be unpaused after init");
    }

    // ----- Step 16: Double initialization reverts InvalidInitialization -----
    function test_TC01_doubleInitReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        queue.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }

    // ----- Step 17: Zero address for riskusd_ reverts ZeroAddress -----
    function test_TC01_initZeroRiskusdReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize, (address(0), address(forage), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 17: Zero address for forage_ reverts ZeroAddress -----
    function test_TC01_initZeroForageReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize, (address(riskusd), address(0), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 17: Zero address for vaultRegistry_ reverts ZeroAddress -----
    function test_TC01_initZeroVaultRegistryReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(0), owner))
        );
    }

    // ----- Step 17: Zero address for initialOwner_ reverts ZeroAddress -----
    function test_TC01_initZeroOwnerReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), address(0))
            )
        );
    }

    // ----- Step 18: Zero address for tierVaults_[0] reverts ZeroAddress -----
    function test_TC01_initZeroTierVault0Reverts() public {
        address[4] memory tierVaults = [address(0), address(vault1), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 18: Zero address for tierVaults_[1] reverts ZeroAddress -----
    function test_TC01_initZeroTierVault1Reverts() public {
        address[4] memory tierVaults = [address(vault0), address(0), address(vault2), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 18: Zero address for tierVaults_[2] reverts ZeroAddress -----
    function test_TC01_initZeroTierVault2Reverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(0), address(vault3)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 18: Zero address for tierVaults_[3] reverts ZeroAddress -----
    function test_TC01_initZeroTierVault3Reverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(0)];
        StakingQueue impl = new StakingQueue();
        vm.expectRevert(StakingQueue.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                StakingQueue.initialize,
                (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
            )
        );
    }

    // ----- Step 19: Implementation direct init blocked -----
    function test_TC01_implDirectInitReverts() public {
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner);
    }
}
