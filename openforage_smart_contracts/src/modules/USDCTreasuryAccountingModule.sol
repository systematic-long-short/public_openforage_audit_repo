// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultRegistry, VaultConfig, VaultStatus} from "../interfaces/IVaultRegistry.sol";

interface IRISKUSDVaultNAV {
    function lastAttestedNAV() external view returns (uint256);
    function adjustedCustodianNAV() external view returns (uint256);
    function lastAttestationTimestamp() external view returns (uint256);
    function attestationIntervalSeconds() external view returns (uint256);
    function totalDeployed() external view returns (uint256);
}

interface IUSDCTreasuryAccountingGuardianVault {
    function forageGovernor() external view returns (address);
}

interface IUSDCTreasuryAccountingGuardianQuery {
    function guardianModule() external view returns (address);
}

interface IUSDCTreasuryRoleState {
    function pnlAttestor() external view returns (address);
    function hlTradingBridge() external view returns (address);
}

interface IUSDCTreasuryRoleBridge {
    function keeper() external view returns (address);
    function pendingKeeper() external view returns (address);
    function custodianRegistry() external view returns (address);
    function usdcTreasury() external view returns (address);
}

interface IUSDCTreasuryRoleRegistry {
    function hasActiveExecutor(address account) external view returns (bool);
}

interface IUSDCTreasuryLossSettlementVault {
    function latestLossNonce() external view returns (uint256);
    function settledLossNonce() external view returns (uint256);
    function lossPendingVaultId() external view returns (uint256);
    function latestLossAmount() external view returns (uint256);
    function lossPending() external view returns (bool);
    function riskusd() external view returns (address);
    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) external;
}

interface IUSDCTreasuryTierLossVault {
    function legitimateAssets() external view returns (uint256);
    function absorbLoss(uint256 riskusdAmount) external;
}

contract USDCTreasuryAccountingModule {
    using SafeERC20 for IERC20;

    error DelegateCallRequired();
    error InvalidLossRateCap(uint256 capBps);
    error LossRateCapWideningNotAllowed(uint256 requested, uint256 current);
    error UnauthorizedLossCapShrinker(address caller);
    error LossRateCapExceeded(uint256 requested, uint256 remaining);
    error SettlementValueMismatch(address account, uint256 expected, uint256 actual);
    error TierVaultUnavailable(address tierVault);
    error TierYieldClaimMismatch(uint256 vaultId, address tierVault, uint256 expected, uint256 actual);
    error YieldClaimInvariant(uint256 vaultId, uint256 aggregateClaim, uint256 tierClaim);
    error ZeroAddress();
    error TreasuryRoleCollision(address account, address conflictingAccount);
    error RoleSourceUnavailable(address source);
    error UnauthorizedBridge();
    error InsufficientEarmark();
    error LossNonceMismatch(uint256 provided, uint256 expected);
    error LossVaultMismatch(uint256 provided, uint256 expected);
    error NoPendingLoss();

    uint256 private constant LOSS_RATE_WINDOW = 1 days;
    bytes32 private constant EARMARK_PROTOCOL_RETAINED = keccak256("PROTOCOL_RETAINED");
    uint8 private constant PNL_POLICY_SET_ATTESTOR = 3;
    uint8 private constant PNL_POLICY_SET_BRIDGE = 4;
    uint256 private constant PROTOCOL_SHARE_BPS = 3_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    address private immutable _self;

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

    struct VaultFeeCarry {
        uint16 protocolRemainder;
        uint16 foundationRemainder;
    }

    struct LossRateWindow {
        uint256 start;
        uint256 tierAssets;
        uint256 used;
    }

    struct PendingLossSettlement {
        uint256 nonce;
        uint256 vaultId;
        uint256 originalLoss;
        uint256 remainingRetainedCover;
        uint256[4] remainingTierAllocations;
        uint256 reportTimeTierAssetsTotal;
    }

    struct LossSettlementPlan {
        uint256 tierLoss;
        uint256 retainedCover;
        uint256[4] tierAssets;
        uint256[4] tierLosses;
        address[4] tierVaults;
    }

    struct AccountingModuleSlot {
        address module;
    }

    IERC20 private _usdc;
    address private _mirrorRiskusdVault;
    address private vaultRegistry;
    address private pnlAttestor;
    address private hlTradingBridge;
    address private foundationPrimary;
    address private foundationBackup;
    address private protocolPrimary;
    address private protocolBackup;
    address private blocklist;
    address private pendingFoundationPrimary;
    uint256 private pendingFoundationPrimaryAt;
    uint256 private totalPrincipalReturned;
    uint16 private _foundationAllocationBps;
    mapping(uint256 => uint256) private recognizedProfit;
    mapping(uint256 => uint256) private recognizedDepositorClaim;
    mapping(uint256 => uint256) private retainedBufferLossAbsorbed;
    mapping(uint256 => mapping(uint8 => int256)) private _tierAccountingAdjustmentBps;
    mapping(uint256 => mapping(uint8 => uint256)) private _tierAccountingValue;
    mapping(bytes32 => uint256) private earmarkBalance;
    mapping(bytes32 => uint256) private _earmarkWindowStart;
    mapping(bytes32 => uint256) private _earmarkWindowUsed;
    mapping(uint256 => uint256) private fundedDepositorClaim;
    mapping(uint256 => uint256) private pendingVaultTopUp;
    address private _distributor;
    address private _pendingDistributor;
    uint256 private _mirrorLossRateCapBps;
    uint256 private _lossRateWindowStart;
    uint256 private _lossRateWindowUsed;
    uint256 private _lossRateWindowTierAssets;
    mapping(uint256 => mapping(uint8 => uint256)) private _fundedTierYield;
    mapping(address => uint256) private _unfundedTierYieldClaim;
    bool private _yieldClaimsReady;
    mapping(uint256 => VaultFeeCarry) private _vaultFeeCarry;
    mapping(uint256 => LossRateWindow) private _lossRateWindows;
    mapping(uint256 => uint256) private unreturnedRecognizedProfit;
    bool private _profitReturnAccountingInitialized;
    PendingLossSettlement private _pendingLossSettlement;
    uint64 private _lossSettlementVersion;
    AccountingModuleSlot private _accountingModule;
    uint16 private AGENT_PAY_CAP_BPS;
    uint256 private _agentPayCreditedTotal;
    uint256 private _agentPayDisbursedTotal;
    uint256 private _aggregateUnreturnedRecognizedProfit;
    uint256 private _pnlCashOutReportTimestamp;
    uint256 private _pnlCashOutAgainstReport;

    event AttestedLossSettled(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount);
    event LossSettlementProgressed(
        uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount, uint256 remaining
    );

    event LossRateCapUpdated(uint256 oldCapBps, uint256 newCapBps);
    event BlocklistSet(address indexed blocklist);
    event PnLAttestorSet(address indexed attestor);
    event HLTradingBridgeSet(address indexed bridge);

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert DelegateCallRequired();
        _;
    }

    function shrinkLossRateCapBps(address riskusdVault, uint256 storageSlot, uint256 newCapBps)
        external
        onlyDelegateCall
    {
        _requireGuardianModule(riskusdVault);
        uint256 currentCapBps;
        assembly {
            currentCapBps := sload(storageSlot)
        }
        if (newCapBps > currentCapBps) {
            revert LossRateCapWideningNotAllowed(newCapBps, currentCapBps);
        }
        if (newCapBps == 0 || newCapBps > type(uint16).max) revert InvalidLossRateCap(newCapBps);
        assembly {
            sstore(storageSlot, newCapBps)
        }
        emit LossRateCapUpdated(currentCapBps, newCapBps);
    }

    function setLossRateCapBps(address, uint256 storageSlot, uint256 newCapBps) external onlyDelegateCall {
        if (newCapBps == 0 || newCapBps > type(uint16).max) revert InvalidLossRateCap(newCapBps);
        uint256 oldCapBps;
        assembly {
            oldCapBps := sload(storageSlot)
            sstore(storageSlot, newCapBps)
        }
        emit LossRateCapUpdated(oldCapBps, newCapBps);
    }

    function setBlocklist(address, uint256 storageSlot, uint256 candidate) external onlyDelegateCall {
        if (candidate == 0) revert ZeroAddress();
        assembly {
            sstore(storageSlot, candidate)
        }
        emit BlocklistSet(address(uint160(candidate)));
    }

    function setPnLAttestor(address, uint256 storageSlot, uint256 candidate) external onlyDelegateCall {
        if (candidate == 0) revert ZeroAddress();
        address attestor = address(uint160(candidate));
        _requireRoleSeparation(candidate, PNL_POLICY_SET_ATTESTOR);
        assembly {
            sstore(storageSlot, candidate)
        }
        emit PnLAttestorSet(attestor);
    }

    function setHLTradingBridge(address, uint256 storageSlot, uint256 candidate) external onlyDelegateCall {
        if (candidate == 0) revert ZeroAddress();
        address bridge = address(uint160(candidate));
        _requireRoleSeparation(candidate, PNL_POLICY_SET_BRIDGE);
        assembly {
            sstore(storageSlot, candidate)
        }
        emit HLTradingBridgeSet(bridge);
    }

    function _requireRoleSeparation(uint256 candidate, uint8 mode) private view {
        IUSDCTreasuryRoleState treasury = IUSDCTreasuryRoleState(address(this));
        address attestor = treasury.pnlAttestor();
        address currentBridge = treasury.hlTradingBridge();
        address bridge = mode == PNL_POLICY_SET_BRIDGE ? address(uint160(candidate)) : currentBridge;
        if (bridge.code.length == 0) revert RoleSourceUnavailable(bridge);
        IUSDCTreasuryRoleBridge bridgeRole = IUSDCTreasuryRoleBridge(bridge);
        address bridgeTreasury = bridgeRole.usdcTreasury();
        if (bridgeTreasury != address(this)) revert RoleSourceUnavailable(bridgeTreasury);
        address registry = bridgeRole.custodianRegistry();
        if (registry.code.length == 0) revert RoleSourceUnavailable(registry);
        if (mode == PNL_POLICY_SET_BRIDGE && currentBridge != address(0)) {
            if (currentBridge.code.length == 0) revert RoleSourceUnavailable(currentBridge);
            IUSDCTreasuryRoleBridge currentRole = IUSDCTreasuryRoleBridge(currentBridge);
            if (currentRole.usdcTreasury() != address(this)) revert RoleSourceUnavailable(currentBridge);
            address currentRegistry = currentRole.custodianRegistry();
            if (currentRegistry != registry) revert RoleSourceUnavailable(currentRegistry);
        }
        if (mode == PNL_POLICY_SET_ATTESTOR) attestor = address(uint160(candidate));
        address keeper = bridgeRole.keeper();
        address pendingKeeper = bridgeRole.pendingKeeper();
        _requireDistinct(attestor, keeper);
        _requireDistinct(attestor, pendingKeeper);
        _requireNotExecutor(registry, attestor);
        _requireNotExecutor(registry, keeper);
        _requireNotExecutor(registry, pendingKeeper);
    }

    function _requireDistinct(address attestor, address keeper) private pure {
        if (attestor != address(0) && attestor == keeper) {
            revert TreasuryRoleCollision(attestor, keeper);
        }
    }

    function _requireNotExecutor(address registry, address account) private view {
        if (account == address(0)) return;
        if (IUSDCTreasuryRoleRegistry(registry).hasActiveExecutor(account)) {
            revert TreasuryRoleCollision(account, registry);
        }
    }

    function _requireGuardianModule(address riskusdVault) private view {
        address governor = IUSDCTreasuryAccountingGuardianVault(riskusdVault).forageGovernor();
        if (governor.code.length == 0) revert UnauthorizedLossCapShrinker(msg.sender);
        address guardianModule;
        try IUSDCTreasuryAccountingGuardianQuery(governor).guardianModule() returns (address module) {
            guardianModule = module;
        } catch {
            revert UnauthorizedLossCapShrinker(msg.sender);
        }
        if (guardianModule == address(0) || msg.sender != guardianModule) {
            revert UnauthorizedLossCapShrinker(msg.sender);
        }
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

    function settleLoss(uint256 vaultId, uint256 lossNonce)
        external
        onlyDelegateCall
        returns (bool complete, uint256 originalLoss)
    {
        if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
        IUSDCTreasuryLossSettlementVault centralVault = IUSDCTreasuryLossSettlementVault(_mirrorRiskusdVault);
        uint256 latestNonce = centralVault.latestLossNonce();
        if (lossNonce == 0 || lossNonce != latestNonce || lossNonce <= centralVault.settledLossNonce()) {
            revert LossNonceMismatch(lossNonce, latestNonce);
        }
        uint256 pendingVaultId = centralVault.lossPendingVaultId();
        if (pendingVaultId == 0 || vaultId != pendingVaultId) revert LossVaultMismatch(vaultId, pendingVaultId);
        uint256 loss = centralVault.latestLossAmount();
        if (loss == 0 || !centralVault.lossPending()) revert NoPendingLoss();
        LossSettlementPlan memory plan = _prepareLossSettlement(vaultId, lossNonce, loss);
        originalLoss = _pendingLossSettlement.originalLoss;
        complete = _applyLossSettlement(vaultId, lossNonce, centralVault, plan);
    }

    function _tierAssetSnapshot(VaultConfig memory config)
        private
        view
        returns (uint256[4] memory tierAssets, uint256 totalAssets)
    {
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault == address(0)) {
                if (config.status != VaultStatus.WindingDown) revert TierVaultUnavailable(tierVault);
                continue;
            }
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            uint256 assets = IUSDCTreasuryTierLossVault(tierVault).legitimateAssets();
            tierAssets[i] = assets;
            totalAssets += assets;
        }
    }

    function _allocateCapped(uint256 amount, uint256[4] memory weights, uint256 totalWeight)
        private
        view
        returns (uint256[4] memory allocations)
    {
        return USDCTreasuryAccountingModule(_accountingModule.module).allocateCapped(amount, weights, totalWeight);
    }

    function _sum(uint256[4] memory values) private pure returns (uint256 total) {
        for (uint8 i; i < 4; ++i) {
            total += values[i];
        }
    }

    function _consumeLossRateBudget(uint256 vaultId, uint256 requestedLoss, uint256 tierAssets)
        private
        returns (uint256 chargedLoss)
    {
        if (requestedLoss == 0) return 0;
        LossRateWindow storage window = _lossRateWindows[vaultId];
        if (window.start == 0 || block.timestamp >= window.start + LOSS_RATE_WINDOW) {
            window.tierAssets = tierAssets;
        }
        uint256 nextWindowStart;
        uint256 nextWindowUsed;
        (chargedLoss, nextWindowStart, nextWindowUsed) = USDCTreasuryAccountingModule(_accountingModule.module)
            .consumeLossRateBudget(
            requestedLoss, window.tierAssets, _mirrorLossRateCapBps, window.start, window.used, block.timestamp
        );
        window.start = nextWindowStart;
        window.used = nextWindowUsed;
    }

    function _startLossSettlement(uint256 vaultId, uint256 lossNonce, uint256 loss) private {
        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        (uint256[4] memory tierAssets, uint256 totalTierAssets) = _tierAssetSnapshot(config);
        uint256 tierLoss = loss < totalTierAssets ? loss : totalTierAssets;
        uint256 retainedCover = loss - tierLoss;
        if (retainedCover > earmarkBalance[EARMARK_PROTOCOL_RETAINED]) revert InsufficientEarmark();
        uint256[4] memory allocations = _allocateCapped(tierLoss, tierAssets, totalTierAssets);
        PendingLossSettlement storage pending = _pendingLossSettlement;
        pending.nonce = lossNonce;
        pending.vaultId = vaultId;
        pending.originalLoss = loss;
        pending.remainingRetainedCover = retainedCover;
        pending.reportTimeTierAssetsTotal = totalTierAssets;
        for (uint8 i; i < 4; ++i) {
            pending.remainingTierAllocations[i] = allocations[i];
        }
    }

    function _prepareLossSettlement(uint256 vaultId, uint256 lossNonce, uint256 loss)
        private
        returns (LossSettlementPlan memory plan)
    {
        PendingLossSettlement storage pending = _pendingLossSettlement;
        if (pending.nonce == 0) _startLossSettlement(vaultId, lossNonce, loss);
        if (pending.nonce != lossNonce) revert LossNonceMismatch(lossNonce, pending.nonce);
        if (pending.vaultId != vaultId) revert LossVaultMismatch(vaultId, pending.vaultId);
        uint256 tierLossRemaining = _sum(pending.remainingTierAllocations);
        uint256 expectedLoss = tierLossRemaining + pending.remainingRetainedCover;
        if (expectedLoss != loss) revert SettlementValueMismatch(address(this), expectedLoss, loss);
        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        (uint256[4] memory tierAssets,) = _tierAssetSnapshot(config);
        plan.tierAssets = tierAssets;
        plan.tierVaults = config.tierVaults;
        plan.tierLoss = _consumeLossRateBudget(vaultId, tierLossRemaining, pending.reportTimeTierAssetsTotal);
        if (plan.tierLoss != 0) {
            plan.tierLosses = _allocateCapped(plan.tierLoss, pending.remainingTierAllocations, tierLossRemaining);
        }
        plan.retainedCover = tierLossRemaining == plan.tierLoss ? pending.remainingRetainedCover : 0;
    }

    function _applyLossSettlement(
        uint256 vaultId,
        uint256 lossNonce,
        IUSDCTreasuryLossSettlementVault centralVault,
        LossSettlementPlan memory plan
    ) private returns (bool complete) {
        PendingLossSettlement storage pending = _pendingLossSettlement;
        pending.remainingRetainedCover -= plan.retainedCover;
        IERC20 riskusd = IERC20(centralVault.riskusd());
        _absorbTierLosses(pending, plan, riskusd);
        uint256 expectedRemaining = _sum(pending.remainingTierAllocations) + pending.remainingRetainedCover;
        _coverAndBurnLoss(vaultId, plan, centralVault);
        uint256 actualRemaining = centralVault.latestLossAmount();
        if (centralVault.latestLossNonce() != lossNonce || actualRemaining != expectedRemaining) {
            revert LossNonceMismatch(actualRemaining, expectedRemaining);
        }
        complete = expectedRemaining == 0;
        uint256 settledNonce = centralVault.settledLossNonce();
        if (complete) {
            if (settledNonce != lossNonce || actualRemaining != 0) revert LossNonceMismatch(settledNonce, lossNonce);
            uint256 settledOriginalLoss = pending.originalLoss;
            delete _pendingLossSettlement;
            emit AttestedLossSettled(vaultId, lossNonce, settledOriginalLoss);
        } else {
            if (settledNonce >= lossNonce) revert LossNonceMismatch(settledNonce, lossNonce);
            emit LossSettlementProgressed(vaultId, lossNonce, plan.tierLoss, actualRemaining);
        }
    }

    function _absorbTierLosses(PendingLossSettlement storage pending, LossSettlementPlan memory plan, IERC20 riskusd)
        private
    {
        for (uint8 i; i < 4; ++i) {
            uint256 amount = plan.tierLosses[i];
            pending.remainingTierAllocations[i] -= amount;
            if (amount == 0) continue;
            address tierVault = plan.tierVaults[i];
            IUSDCTreasuryTierLossVault tier = IUSDCTreasuryTierLossVault(tierVault);
            uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
            tier.absorbLoss(amount);
            _requireValueDecrease(tierVault, plan.tierAssets[i], tier.legitimateAssets(), amount);
            _requireValueIncrease(tierVault, treasuryRiskusdBefore, riskusd.balanceOf(address(this)), amount);
        }
    }

    function _coverAndBurnLoss(
        uint256 vaultId,
        LossSettlementPlan memory plan,
        IUSDCTreasuryLossSettlementVault centralVault
    ) private {
        if (plan.retainedCover != 0) {
            uint256 retained = earmarkBalance[EARMARK_PROTOCOL_RETAINED];
            earmarkBalance[EARMARK_PROTOCOL_RETAINED] = retained - plan.retainedCover;
            _usdc.forceApprove(_mirrorRiskusdVault, plan.retainedCover);
        }
        centralVault.coverAndBurnForLoss(vaultId, plan.tierLoss, plan.retainedCover);
        if (plan.retainedCover != 0) _usdc.forceApprove(_mirrorRiskusdVault, 0);
    }

    function _requireValueIncrease(address account, uint256 beforeValue, uint256 afterValue, uint256 expected)
        private
        pure
    {
        uint256 actual = afterValue >= beforeValue ? afterValue - beforeValue : type(uint256).max;
        if (actual != expected) revert SettlementValueMismatch(account, expected, actual);
    }

    function _requireValueDecrease(address account, uint256 beforeValue, uint256 afterValue, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeValue >= afterValue ? beforeValue - afterValue : type(uint256).max;
        if (actual != expected) revert SettlementValueMismatch(account, expected, actual);
    }
}
