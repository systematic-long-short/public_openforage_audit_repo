// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract USDCTreasuryAccountingModule {
    error LossRateCapExceeded(uint256 requested, uint256 remaining);
    error SettlementValueMismatch(address account, uint256 expected, uint256 actual);
    error TierVaultUnavailable(address tierVault);
    error TierYieldClaimMismatch(uint256 vaultId, address tierVault, uint256 expected, uint256 actual);
    error YieldClaimInvariant(uint256 vaultId, uint256 aggregateClaim, uint256 tierClaim);

    uint256 private constant LOSS_RATE_WINDOW = 1 days;
    uint256 private constant PROTOCOL_SHARE_BPS = 3_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    struct PnLReturnAllocation {
        uint256 protocol;
        uint256 foundation;
        uint256 retained;
        uint256 vaultTopUp;
        uint256 agent;
        uint16 protocolRemainder;
        uint16 foundationRemainder;
    }

    struct YieldProjectionInput {
        uint256 vaultId;
        address treasury;
        address[4] tierVaults;
        bool windingDown;
        uint256 recognizedClaim;
        uint256 fundedClaim;
        uint256[4] recognizedTier;
        uint256[4] fundedTier;
        uint256[4] unfundedTier;
    }

    struct YieldSplitInput {
        uint256 profit;
        uint256[4] tierAssets;
        uint16[4] yieldSplitsBps;
        uint16[4] fundingBps;
    }

    struct YieldSplitResult {
        uint256 totalYield;
        uint256[4] tierYield;
    }

    function validateYieldClaimProjection(YieldProjectionInput calldata input)
        external
        pure
        returns (uint256 aggregateOutstanding, uint256[4] memory tierOutstanding)
    {
        uint256 fundedClaim = input.fundedClaim;
        uint256 recognizedClaim = input.recognizedClaim;
        if (fundedClaim > recognizedClaim) {
            revert SettlementValueMismatch(input.treasury, recognizedClaim, fundedClaim);
        }
        aggregateOutstanding = recognizedClaim - fundedClaim;
        uint256 projected;
        for (uint8 i; i < 4; ++i) {
            uint256 recognized = input.recognizedTier[i];
            uint256 funded = input.fundedTier[i];
            if (funded > recognized) revert SettlementValueMismatch(input.treasury, recognized, funded);
            tierOutstanding[i] = recognized - funded;
            address tierVault = input.tierVaults[i];
            if (tierVault == address(0)) {
                if (!input.windingDown) revert TierVaultUnavailable(tierVault);
                if (tierOutstanding[i] != 0) {
                    revert TierYieldClaimMismatch(input.vaultId, tierVault, 0, tierOutstanding[i]);
                }
            } else if (input.unfundedTier[i] != tierOutstanding[i]) {
                revert TierYieldClaimMismatch(input.vaultId, tierVault, tierOutstanding[i], input.unfundedTier[i]);
            }
            projected += tierOutstanding[i];
        }
        if (projected != aggregateOutstanding) {
            revert YieldClaimInvariant(input.vaultId, aggregateOutstanding, projected);
        }
    }

    function calculatePnLReturnAllocation(
        uint256 amount,
        uint256 outstandingClaim,
        uint256 existingPending,
        uint16 foundationAllocationBps,
        uint16 protocolRemainder,
        uint16 foundationRemainder
    ) external pure returns (PnLReturnAllocation memory allocation) {
        uint256 protocolCarry = mulmod(amount, PROTOCOL_SHARE_BPS, BPS_DENOMINATOR) + protocolRemainder;
        allocation.protocol = Math.mulDiv(amount, PROTOCOL_SHARE_BPS, BPS_DENOMINATOR) + protocolCarry / BPS_DENOMINATOR;
        uint256 foundationCarry =
            mulmod(allocation.protocol, foundationAllocationBps, BPS_DENOMINATOR) + foundationRemainder;
        allocation.foundation = Math.mulDiv(allocation.protocol, foundationAllocationBps, BPS_DENOMINATOR)
            + foundationCarry / BPS_DENOMINATOR;
        allocation.retained = allocation.protocol - allocation.foundation;
        allocation.protocolRemainder = uint16(protocolCarry % BPS_DENOMINATOR);
        allocation.foundationRemainder = uint16(foundationCarry % BPS_DENOMINATOR);
        uint256 availableTopUp = amount - allocation.protocol;
        allocation.vaultTopUp = outstandingClaim - existingPending;
        if (allocation.vaultTopUp > availableTopUp) allocation.vaultTopUp = availableTopUp;
        allocation.agent = availableTopUp - allocation.vaultTopUp;
    }

    function calculateTierYield(YieldSplitInput calldata input)
        external
        pure
        returns (YieldSplitResult memory result)
    {
        if (input.profit == 0) return result;
        uint256 totalAssets;
        for (uint8 i; i < 4; ++i) {
            totalAssets += input.tierAssets[i];
        }
        if (totalAssets == 0) return result;
        uint256[4] memory tierProfit = _allocateUncapped(input.profit, input.tierAssets, totalAssets);
        for (uint8 i; i < 4; ++i) {
            uint256 splitTotal = uint256(input.yieldSplitsBps[i]) + uint256(input.fundingBps[i]);
            if (splitTotal != 0) {
                uint256 weightedBps = 7_000 * uint256(input.yieldSplitsBps[i]);
                result.tierYield[i] = Math.mulDiv(tierProfit[i], weightedBps, 10_000 * splitTotal);
            }
            result.totalYield += result.tierYield[i];
        }
    }

    function _allocateUncapped(uint256 amount, uint256[4] calldata weights, uint256 totalWeight)
        private
        pure
        returns (uint256[4] memory allocations)
    {
        uint256 allocated;
        uint8 firstWeightedTier = type(uint8).max;
        for (uint8 i; i < 4; ++i) {
            if (weights[i] != 0 && firstWeightedTier == type(uint8).max) firstWeightedTier = i;
            allocations[i] = Math.mulDiv(amount, weights[i], totalWeight);
            allocated += allocations[i];
        }
        if (firstWeightedTier != type(uint8).max) allocations[firstWeightedTier] += amount - allocated;
    }

    function allocateCapped(uint256 amount, uint256[4] calldata weights, uint256 totalWeight)
        external
        pure
        returns (uint256[4] memory allocations)
    {
        if (amount == 0) return allocations;
        if (totalWeight == 0 || amount > totalWeight) {
            revert SettlementValueMismatch(address(0), totalWeight, amount);
        }
        uint256 allocated;
        for (uint8 i; i < 4; ++i) {
            allocations[i] = Math.mulDiv(amount, weights[i], totalWeight);
            allocated += allocations[i];
        }
        uint256 remainder = amount - allocated;
        for (uint8 i; i < 4 && remainder != 0; ++i) {
            uint256 room = weights[i] - allocations[i];
            uint256 addition = room < remainder ? room : remainder;
            allocations[i] += addition;
            remainder -= addition;
        }
        if (remainder != 0) revert SettlementValueMismatch(address(0), amount, amount - remainder);
    }

    function consumeLossRateBudget(
        uint256 requestedLoss,
        uint256 tierAssets,
        uint256 lossRateCapBps,
        uint256 windowStart,
        uint256 windowUsed,
        uint256 currentTimestamp
    ) external pure returns (uint256 chargedLoss, uint256 nextWindowStart, uint256 nextWindowUsed) {
        nextWindowStart = windowStart;
        nextWindowUsed = windowUsed;
        if (windowStart == 0 || currentTimestamp >= windowStart + LOSS_RATE_WINDOW) {
            nextWindowStart = currentTimestamp;
            nextWindowUsed = 0;
        }
        uint256 cap = Math.mulDiv(tierAssets, lossRateCapBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        uint256 remaining = cap > nextWindowUsed ? cap - nextWindowUsed : 0;
        if (remaining == 0) revert LossRateCapExceeded(requestedLoss, remaining);
        chargedLoss = requestedLoss < remaining ? requestedLoss : remaining;
        nextWindowUsed += chargedLoss;
    }
}
