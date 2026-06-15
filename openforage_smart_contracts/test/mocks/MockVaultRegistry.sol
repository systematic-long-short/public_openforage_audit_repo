// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IVaultRegistry.sol";

/// @title MockVaultRegistry — Test mock for VaultRegistry
/// @notice Provides a writable mock that stores vault configs in memory for test setup.
///         Uses `addTestVault` (not `addVault`) to avoid name collision with the real interface.
contract MockVaultRegistry is IVaultRegistry {
    // Re-export types from IVaultRegistry.
    using {_toConfig} for VaultConfig;

    mapping(uint256 => VaultConfig) private _vaults;
    uint256[] private _allVaultIds;
    uint256 private _nextVaultId = 1;
    mapping(bytes32 => uint256) private _abbreviationToVaultId;
    address public riskusdVault;

    /// @notice Add a vault for test setup. NOT the real addVault interface.
    function addTestVault(
        string calldata name_,
        string calldata abbreviation_,
        address[4] calldata tierVaults_,
        address stakingQueue_,
        uint256 capacityCap_,
        uint256[4] calldata lockupDurations_,
        uint16[4] calldata yieldSplitsBps_,
        uint16[4] calldata fundingBps_
    ) external returns (uint256 vaultId) {
        vaultId = _nextVaultId++;
        _vaults[vaultId] = VaultConfig({
            vaultId: vaultId,
            name: name_,
            abbreviation: abbreviation_,
            tierVaults: tierVaults_,
            stakingQueue: stakingQueue_,
            capacityCap: capacityCap_,
            lockupDurations: lockupDurations_,
            yieldSplitsBps: yieldSplitsBps_,
            fundingBps: fundingBps_,
            status: VaultStatus.Active
        });
        _allVaultIds.push(vaultId);
        _abbreviationToVaultId[keccak256(bytes(abbreviation_))] = vaultId;
    }

    /// @notice Update vault status for test setup.
    function setTestVaultStatus(uint256 vaultId_, VaultStatus status_) external {
        _vaults[vaultId_].status = status_;
    }

    /// @notice Update capacity cap for test setup.
    function setTestCapacityCap(uint256 vaultId_, uint256 capacityCap_) external {
        _vaults[vaultId_].capacityCap = capacityCap_;
    }

    /// @notice Update tier vault routing for test setup.
    function setTestTierVaults(uint256 vaultId_, address[4] calldata tierVaults_) external {
        _vaults[vaultId_].tierVaults = tierVaults_;
    }

    /// @notice Update the registry's RISKUSDVault reference for test setup.
    function setTestRISKUSDVault(address riskusdVault_) external {
        riskusdVault = riskusdVault_;
    }

    // ── View functions matching VaultRegistry interface ──

    function getVault(uint256 vaultId_) external view override returns (VaultConfig memory) {
        require(_vaults[vaultId_].vaultId != 0, "MockVaultRegistry: invalid vault id");
        return _vaults[vaultId_];
    }

    function getActiveVaults() external view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 0; i < _allVaultIds.length; i++) {
            if (_vaults[_allVaultIds[i]].status == VaultStatus.Active) {
                count++;
            }
        }
        uint256[] memory result = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < _allVaultIds.length; i++) {
            if (_vaults[_allVaultIds[i]].status == VaultStatus.Active) {
                result[idx++] = _allVaultIds[i];
            }
        }
        return result;
    }

    function getAllVaults() external view override returns (uint256[] memory) {
        return _allVaultIds;
    }

    function getVaultsPage(uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory ids, uint256 nextOffset, uint256 total)
    {
        total = _allVaultIds.length;
        if (offset >= total || limit == 0) {
            return (new uint256[](0), total, total);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length;) {
            ids[i] = _allVaultIds[offset + i];
            unchecked {
                ++i;
            }
        }
        nextOffset = end;
    }

    function notifyLossResolved() external override {}

    function vaultCount() external view returns (uint256) {
        return _allVaultIds.length;
    }

    function getVaultByAbbreviation(string calldata abbreviation_) external view returns (uint256) {
        uint256 vaultId = _abbreviationToVaultId[keccak256(bytes(abbreviation_))];
        require(vaultId != 0, "MockVaultRegistry: vault not found");
        return vaultId;
    }
}

// Helper to suppress unused import warning
function _toConfig(VaultConfig memory c) pure returns (VaultConfig memory) {
    return c;
}
