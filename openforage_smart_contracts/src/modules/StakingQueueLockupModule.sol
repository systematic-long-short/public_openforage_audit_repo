// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./StakingQueueModule.sol";

/// @title StakingQueueLockupModule -- Delegatecall-only tier upgrade, reversion and expired-lockup cluster
/// @dev StakingQueueModule forwards these selectors here by delegatecall, so they run in StakingQueue's storage like
///      the core module's own functions. Every function runs only under delegatecall; a direct call reverts
///      DirectCallForbidden().
contract StakingQueueLockupModule is StakingQueueModuleStorage {
    using SafeERC20 for IERC20;

    function syncTierVaults() external onlyDelegateCall {
        VaultConfig memory config = _currentVaultConfig();
        bool differs;
        for (uint256 i; i < 4;) {
            if (_tierVaults[i] != config.tierVaults[i]) {
                differs = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        _syncTierVaultsFromRegistry();
        if (!differs) emit TierVaultsSynced(config.tierVaults);
    }

    function upgradeTier(uint8 fromTier, uint8 toTier, uint256 atriskusdAmount) external onlyDelegateCall {
        if (atriskusdAmount == 0) revert ZeroAmount();
        if (fromTier >= 4 || toTier >= 4) revert InvalidTier();
        if (toTier <= fromTier) revert InvalidTierUpgrade();
        _requireNotBlocked(msg.sender);
        uint256 riskusdAmount;
        uint256 newShares;
        {
            VaultConfig memory config = _syncTierVaultsFromRegistry();
            if (config.status != VaultStatus.Active) revert VaultNotActive();
            address sourceVault = config.tierVaults[fromTier];
            address destVault = config.tierVaults[toTier];
            _requireLiveTierVault(sourceVault, fromTier);
            _requireLiveTierVault(destVault, toTier);
            uint256 combinedAssetsBefore = _combinedTotalAssets();
            (bool successRedeem, bytes memory redeemData) =
                sourceVault.call(abi.encodeWithSelector(_SEL_REDEEM_UPGRADE, msg.sender, atriskusdAmount));
            if (!successRedeem) {
                assembly {
                    revert(add(redeemData, 32), mload(redeemData))
                }
            }
            if (redeemData.length < 32) revert InvalidQueueEntry();
            riskusdAmount = abi.decode(redeemData, (uint256));
            if (riskusdAmount == 0) revert ZeroAmount();
            uint256 tierAvailable = _availableTierDepositCapacityForCap(toTier, config.capacityCap);
            if (riskusdAmount > tierAvailable) {
                revert TierDepositCapExceeded(toTier, riskusdAmount, tierAvailable);
            }
            _requireRecognitionWindowClosed(destVault);
            _riskusd.forceApprove(destVault, riskusdAmount);
            (bool successDeposit, bytes memory depositData) =
                destVault.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, msg.sender));
            if (!successDeposit) {
                assembly {
                    revert(add(depositData, 32), mload(depositData))
                }
            }
            if (depositData.length < 32) revert InvalidQueueEntry();
            newShares = abi.decode(depositData, (uint256));
            if (newShares == 0) revert ZeroAmount();
            _riskusd.forceApprove(destVault, 0);
            _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
        }
        emit TierUpgraded(msg.sender, fromTier, toTier, atriskusdAmount, riskusdAmount, newShares);
    }

    function selfRevert(uint8 tier) external onlyDelegateCall {
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireNotBlocked(msg.sender);
        SelfReversion memory state = _prepareSelfReversion(tier, msg.sender);
        _depositSelfReversion(msg.sender, state);
        emit LockupReverted(msg.sender, tier, state.riskusdAmount);
    }

    function _prepareSelfReversion(uint8 tier, address depositor) private returns (SelfReversion memory state) {
        VaultConfig memory config = _syncTierVaultsFromRegistry();
        address tierVault = config.tierVaults[tier];
        state.vaultZero = config.tierVaults[0];
        _requireLiveTierVault(state.vaultZero, 0);
        uint256 shares = _expiredLockupShares(tierVault, tier, depositor);
        state.combinedAssetsBefore = _combinedTotalAssets();
        state.riskusdAmount = _redeemForReversion(tierVault, depositor, shares);
        uint256 tierZeroCapacity = _availableTierDepositCapacityForCap(0, config.capacityCap);
        if (state.riskusdAmount > tierZeroCapacity) {
            revert TierDepositCapExceeded(0, state.riskusdAmount, tierZeroCapacity);
        }
    }

    function _expiredLockupShares(address tierVault, uint8 tier, address depositor) private view returns (uint256) {
        (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
            _getLockupInfo(tierVault, tier, depositor);
        if (!hasLockup || !isExpired || hasPendingWithdrawal || autoRenew) revert InvalidQueueEntry();
        return shares;
    }

    function _redeemForReversion(address tierVault, address depositor, uint256 shares)
        private
        returns (uint256 riskusdAmount)
    {
        (bool success, bytes memory data) =
            tierVault.call(abi.encodeWithSelector(_SEL_REDEEM_REVERSION, depositor, shares));
        if (!success) revert RedeemForReversionFailed();
        if (data.length < 32) revert InvalidQueueEntry();
        riskusdAmount = abi.decode(data, (uint256));
        if (riskusdAmount == 0) revert ZeroAmount();
    }

    function _depositSelfReversion(address depositor, SelfReversion memory state) private {
        _depositTierZeroReversion(state.vaultZero, depositor, state.riskusdAmount);
        _assertCombinedAssetsNotDecreased(state.combinedAssetsBefore);
    }

    function _depositTierZeroReversion(address vaultZeroAddr, address depositor, uint256 riskusdAmount) private {
        _requireRecognitionWindowClosed(vaultZeroAddr);
        _riskusd.forceApprove(vaultZeroAddr, riskusdAmount);
        (bool success, bytes memory data) =
            vaultZeroAddr.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, address(this)));
        _riskusd.forceApprove(vaultZeroAddr, 0);
        if (!success) revert Tier0DepositFailed();
        if (data.length < 32) revert InvalidQueueEntry();
        uint256 sharesMinted = abi.decode(data, (uint256));
        if (sharesMinted == 0) revert ZeroAmount();
        IERC20(vaultZeroAddr).safeTransfer(depositor, sharesMinted);
    }

    /// @notice OF-G03: Batch size is implicitly controlled by the depositors array length.
    /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
    /// batches into multiple transactions as needed.
    function processExpiredLockups(address[] calldata depositors, uint8 tier) external onlyDelegateCall {
        if (depositors.length == 0) revert ZeroAmount();
        if (tier == 0 || tier >= 4) revert InvalidTier();
        _requireAuthorizedExpiredLockupProcessor(msg.sender, depositors);
        if (_blocklist == address(0)) revert BlocklistUnavailable(_blocklist);
        _syncTierVaultsFromRegistry();

        address tierVaultAddr = _tierVaults[tier];
        address vault0Addr = _tierVaults[0];

        for (uint256 i; i < depositors.length;) {
            try this._processOneExpiredLockup(depositors[i], tier, tierVaultAddr, vault0Addr) {}
            catch (bytes memory reason) {
                emit ExpiredLockupProcessingFailed(depositors[i], tier, reason);
            }
            unchecked {
                ++i;
            }
        }
    }

    function setExpiredLockupProcessor(address processor, bool authorized) external onlyDelegateCall {
        if (processor == address(0)) revert ZeroAddress();
        _expiredLockupProcessors[processor] = authorized;
        emit ExpiredLockupProcessorSet(processor, authorized);
    }

    /// @dev Process one depositor's expired lockup. External so it can be called via try/catch.
    /// OF-010: The try/catch in processExpiredLockups() wraps this external call. If any
    /// individual lockup processing reverts (e.g., tier vault paused, insufficient liquidity),
    /// the failure is caught, an ExpiredLockupProcessingFailed event is emitted, and remaining
    /// depositors continue processing. This prevents one bad lockup from blocking the entire batch.
    function _processOneExpiredLockup(address depositor, uint8 tier, address tierVaultAddr, address vault0Addr)
        external
        onlyDelegateCall
    {
        if (msg.sender != address(this)) revert InternalOnly();
        _requireNotBlocked(depositor);

        (bool hasLockup, bool isExpired, bool autoRenew, bool hasPendingWithdrawal, uint256 shares) =
            _getLockupInfo(tierVaultAddr, tier, depositor);

        if (!hasLockup || !isExpired || (autoRenew && hasPendingWithdrawal)) return;

        if (autoRenew) {
            (bool success, bytes memory data) = tierVaultAddr.call(abi.encodeWithSelector(_SEL_RENEW_LOCKUP, depositor));
            if (!success) revert RenewLockupFailed();
            if (data.length < 32) revert InvalidQueueEntry();
            uint256 newExpiry = abi.decode(data, (uint256));

            emit LockupRenewed(depositor, tier, newExpiry);
        } else {
            _requireLiveTierVault(vault0Addr, 0);
            uint256 combinedAssetsBefore = _combinedTotalAssets();
            uint256 riskusdAmount;
            {
                (bool success, bytes memory data) =
                    tierVaultAddr.call(abi.encodeWithSelector(_SEL_REDEEM_REVERSION, depositor, shares));
                if (!success) revert RedeemForReversionFailed();
                if (data.length < 32) revert InvalidQueueEntry();
                riskusdAmount = abi.decode(data, (uint256));
            }
            if (riskusdAmount == 0) revert ZeroAmount();
            _depositTierZeroReversion(vault0Addr, depositor, riskusdAmount);
            _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
            emit LockupReverted(depositor, tier, riskusdAmount);
        }
    }

    /// @notice Retry a processed or cancelled entry's failed FORAGE unlock.
    /// @dev Any Allowlist-eligible caller may retry; the unlock remains credited to the depositor.
    function retryForageUnlock(uint256 queueId) external onlyDelegateCall {
        QueueEntry storage entry = _queueEntries[queueId];
        if (entry.depositor == address(0)) revert InvalidQueueEntry();
        uint256 forageToUnlock = _forageLockedPerEntry[queueId];
        uint256 pendingWeight = _forageUnlockPendingWeightPerEntry[queueId];
        uint256 requirement = _forageLockRequirementPerEntry[queueId];
        bool demoted = !entry.priority && !entry.processed && !entry.cancelled
            && (forageToUnlock != 0 || pendingWeight != 0 || requirement != 0);
        if (!entry.processed && !entry.cancelled && !demoted) revert InvalidQueueEntry();
        if (forageToUnlock == 0 && pendingWeight == 0 && requirement == 0) revert ZeroAmount();
        if (!demoted && _priorityRiskusdQueued[entry.depositor] != 0) revert InvalidQueueEntry();
        _requireNotBlocked(entry.depositor);
        _releaseForageLock(queueId, entry.depositor);
    }
}
