// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/StakingQueue.sol";
import "../mocks/MockRISKUSD.sol";
import "../mocks/MockForageTokenLocked.sol";
import "../mocks/MockAtRISKUSD.sol";
import "../mocks/MockVaultRegistry.sol";

/// @dev Abstract base for StakingQueue tests.
/// Deploys StakingQueue behind an ERC1967 proxy with MockRISKUSD, MockForageTokenLocked,
/// and 4 MockAtRISKUSD tier vaults.
/// setUp() will revert against the stub (initialize reverts "STUB: not implemented"),
/// causing all tests to FAIL -- correct behavior before implementation.
abstract contract StakingQueueTestBase is Test {
    StakingQueue public queue;
    StakingQueue public implementation;
    MockRISKUSD public riskusd;
    MockForageTokenLocked public forage;
    MockAtRISKUSD public vault0;
    MockAtRISKUSD public vault1;
    MockAtRISKUSD public vault2;
    MockAtRISKUSD public vault3;
    MockVaultRegistry public mockVaultRegistry;
    uint256 public registeredVaultId;

    address public owner;
    address public governor;
    address public attacker;
    address public alice;
    address public bob;
    address public charlie;
    address public dave;
    address public keeper;

    uint256 public constant DEFAULT_COMBINED_CAPACITY = 10_000_000e6;
    uint256 public constant STANDARD_DEPOSIT = 1_000e6;

    function setUp() public virtual {
        owner = makeAddr("timelock");
        governor = makeAddr("governor");
        attacker = makeAddr("attacker");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");
        keeper = makeAddr("keeper");

        // Deploy mocks
        riskusd = new MockRISKUSD();
        forage = new MockForageTokenLocked();

        // Deploy tier vaults
        vault0 = new MockAtRISKUSD(address(riskusd));
        vault1 = new MockAtRISKUSD(address(riskusd));
        vault2 = new MockAtRISKUSD(address(riskusd));
        vault3 = new MockAtRISKUSD(address(riskusd));

        // Deploy VaultRegistry mock and register a vault
        mockVaultRegistry = new MockVaultRegistry();
        address[4] memory tierVaults = [address(vault0), address(vault1), address(vault2), address(vault3)];
        uint256[4] memory lockups = [uint256(0), 7776000, 15552000, 31104000];
        uint16[4] memory yieldBps = [uint16(5000), 5500, 6000, 6500];
        uint16[4] memory fundingBps = [uint16(2000), 2000, 1500, 1500];
        registeredVaultId = mockVaultRegistry.addTestVault(
            "Test Vault", "TV", tierVaults, address(0), DEFAULT_COMBINED_CAPACITY, lockups, yieldBps, fundingBps
        );

        // Deploy implementation
        implementation = new StakingQueue();

        // Deploy proxy with initialize call
        bytes memory initData = abi.encodeCall(
            StakingQueue.initialize, (address(riskusd), address(forage), tierVaults, address(mockVaultRegistry), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        queue = StakingQueue(address(proxy));

        // Link queue to its vault in the registry
        vm.prank(owner);
        queue.setVaultId(registeredVaultId);
    }

    /// @dev Mint RISKUSD to a user and approve StakingQueue.
    function _fundUser(address user, uint256 amount) internal {
        riskusd.mint(user, amount);
        vm.prank(user);
        riskusd.approve(address(queue), amount);
    }

    /// @dev Mint and approve max RISKUSD for a user.
    function _fundUserMax(address user) internal {
        uint256 amount = 100_000_000e6;
        riskusd.mint(user, amount);
        vm.prank(user);
        riskusd.approve(address(queue), type(uint256).max);
    }

    /// @dev Have a user join the queue for a given tier and amount.
    function _joinQueue(address user, uint256 amount, uint8 tier) internal returns (uint256 queueId) {
        _fundUser(user, amount);
        queueId = queue.nextQueueId();
        vm.prank(user);
        queue.joinQueue(amount, tier);
    }

    /// @dev Set the ForageGovernor on the queue (propose + warp + finalize).
    function _setGovernor() internal {
        vm.startPrank(owner);
        queue.setForageGovernor(governor);
        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForageGovernor();
        vm.stopPrank();
    }

    /// @dev Set the FORAGE price for priority cap calculation.
    function _setForagePriceUsd(uint256 price) internal {
        vm.startPrank(owner);
        queue.setForagePriceUsd(price);
        vm.warp(block.timestamp + 2 days + 1);
        queue.finalizeForagePriceUsd();
        vm.stopPrank();
    }

    /// @dev Set the priority multiplier for cap calculation.
    function _setPriorityMultiplier(uint256 multiplier) internal {
        vm.prank(owner);
        queue.setPriorityMultiplier(multiplier);
    }

    /// @dev Activate priority lane with given price and multiplier.
    function _activatePriority(uint256 price, uint256 multiplier) internal {
        _setForagePriceUsd(price);
        _setPriorityMultiplier(multiplier);
    }

    /// @dev Deploy a fresh proxy with given parameters.
    function _deployFreshProxy(
        address riskusd_,
        address forage_,
        address[4] memory tierVaults_,
        address vaultRegistry_,
        address owner_
    ) internal returns (StakingQueue) {
        StakingQueue impl = new StakingQueue();
        bytes memory initData =
            abi.encodeCall(StakingQueue.initialize, (riskusd_, forage_, tierVaults_, vaultRegistry_, owner_));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return StakingQueue(address(proxy));
    }

    /// @dev Approve StakingQueue to spend RISKUSD on behalf of the queue
    /// (needed for vault deposits during processQueue).
    function _approveQueueForVaults() internal {
        // The StakingQueue contract itself needs to approve vaults
        // This is handled internally by the contract in the real implementation
    }
}
