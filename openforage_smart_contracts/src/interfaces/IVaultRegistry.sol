// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice OF-006: Shared VaultConfig struct and IVaultRegistry interface.
/// Imported by VaultRegistry (canonical definition) and retained consumers to
/// eliminate inline struct duplication.

/// @dev Vault status enum matching VaultRegistry.VaultStatus.
enum VaultStatus {
    Active,
    Paused,
    WindingDown
}

/// @dev VaultConfig struct — single source of truth for vault configuration layout.
struct VaultConfig {
    uint256 vaultId;
    string name;
    string abbreviation;
    address[4] tierVaults;
    address stakingQueue;
    uint256 capacityCap;
    uint256[4] lockupDurations;
    uint16[4] yieldSplitsBps;
    uint16[4] fundingBps;
    VaultStatus status;
}

/// @dev Minimal read-only interface for VaultRegistry consumers.
interface IVaultRegistry {
    function getVault(uint256 vaultId) external view returns (VaultConfig memory);
    function getAllVaults() external view returns (uint256[] memory);
    /// @dev OF-16-002: Notify VaultRegistry that a loss has been resolved for cooldown tracking.
    function notifyLossResolved() external;
}
