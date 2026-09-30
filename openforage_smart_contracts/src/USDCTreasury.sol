// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./AllowlistGatedUpgradeable.sol";
import "./FinalizeDelayProfile.sol";
import "./interfaces/IAtRiskUSDProfitClaims.sol";
import {IUSDCTreasuryLossSettlement, IUSDCTreasuryYieldClaims} from "./interfaces/IUSDCTreasuryYieldClaims.sol";
import "./interfaces/IVaultRegistry.sol";
import {USDCTreasuryAccountingModule} from "./modules/USDCTreasuryAccountingModule.sol";

interface IUSDCTreasuryBlocklist {
    function isBlocked(address account) external view returns (bool);
}

interface IRISKUSDVaultLossSettlement {
    function burnForLoss(uint256 vaultId, uint256 riskusdAmount) external;
    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) external;
    function replenish(uint256 usdcAmount) external;
    function deposit(uint256 usdcAmount) external;
    function riskusd() external view returns (address);
    function latestLossNonce() external view returns (uint256);
    function settledLossNonce() external view returns (uint256);
    function lossPendingVaultId() external view returns (uint256);
    function latestLossAmount() external view returns (uint256);
    function lossPending() external view returns (bool);
    function forageGovernor() external view returns (address);
}

interface IUSDCTreasuryTierVault is IAtRiskUSDProfitClaims {
    function legitimateAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function accrueYield(uint256 riskusdAmount) external;
    function absorbLoss(uint256 riskusdAmount) external;
}

interface IUSDCTreasuryGuardianQuery {
    function guardianModule() external view returns (address);
}

/// @title USDCTreasury
/// @notice Single protocol-USDC router for target accounting and returned-cash earmarks.
contract USDCTreasury is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    FinalizeDelayProfile,
    AllowlistGatedUpgradeable,
    IUSDCTreasuryYieldClaims,
    IUSDCTreasuryLossSettlement
{
    using SafeERC20 for IERC20;

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

    struct PnLReturnState {
        uint256 outstandingClaim;
        uint256 existingPending;
    }

    struct AccountingModuleSlot {
        address module;
    }

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedAttestor();
    error UnauthorizedBridge();
    error UnauthorizedDistributor();
    error PurposeCapExceeded();
    error InsufficientEarmark();
    error DestinationNotAllowed();
    error FinalizeDelayNotElapsed();
    error NoPendingWallet();
    error BlockedRecipient(address account);
    error BlocklistUnavailable(address blocklist);
    error InvalidBatch();
    error BatchLimitExceeded();
    error RenounceOwnershipDisabled();
    error PrincipalReturnsUseVault();
    error USDCAmountMismatch(uint256 expected, uint256 actual);
    error PnLNotRecognized(uint256 vaultId);
    error PnLReturnAccountingUninitialized();
    error PnLReturnExceedsUnpaidProfit(uint256 vaultId, uint256 requested, uint256 unpaid);
    error ProposalExpired();
    error InvalidLossRateCap(uint256 capBps);
    error LossRateCapWideningNotAllowed(uint256 requested, uint256 current);
    error LossRateCapExceeded(uint256 requested, uint256 remaining);
    error LossNonceMismatch(uint256 provided, uint256 expected);
    error LossVaultMismatch(uint256 provided, uint256 expected);
    error NoPendingLoss();
    error AttestedLossPending();
    error UnauthorizedLossCapShrinker(address caller);
    error VaultTopUpAmountMismatch(uint256 provided, uint256 pending);
    error SettlementValueMismatch(address account, uint256 expected, uint256 actual);
    error TierVaultUnavailable(address tierVault);
    error ZeroSupplyTier(address tierVault, uint256 amount);
    error TierYieldClaimMismatch(uint256 vaultId, address tierVault, uint256 expected, uint256 actual);
    error YieldClaimInvariant(uint256 vaultId, uint256 aggregateClaim, uint256 tierClaim);
    error LegacyTreasuryStateUnsupported();
    error SettlementVersionRequired(uint64 observedVersion);
    error LossSettlementBasisUnavailable(uint256 lossNonce);
    error AccountingModuleUnavailable(address module);

    bytes32 public constant EARMARK_VAULT_TOP_UP = keccak256("VAULT_TOP_UP");
    bytes32 public constant EARMARK_AGENT_PAY = keccak256("AGENT_PAY");
    bytes32 public constant EARMARK_PROTOCOL_RETAINED = keccak256("PROTOCOL_RETAINED");
    bytes32 public constant EARMARK_FOUNDATION = keccak256("FOUNDATION");

    uint256 public constant DAY_SECONDS = 1 days;
    uint16 public constant DEFAULT_FOUNDATION_ALLOCATION_BPS = 5_000;
    uint16 public constant MAX_FOUNDATION_ALLOCATION_BPS = 5_000;
    uint16 public constant FOUNDATION_DAILY_CAP_BPS = 1_000;
    uint16 public constant PROTOCOL_SHARE_BPS = 3_000;
    uint256 public constant PROTOCOL_RETAINED_DAILY_CAP = 1_000_000e6;
    uint16 public constant AGENT_PAY_CAP_BPS = 1_000;
    uint256 public constant MAX_AGENT_PAY_BATCH = 100;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint256 public constant LOSS_RATE_WINDOW = 1 days;
    uint256 public constant DEFAULT_LOSS_RATE_CAP_BPS = 1_000;
    uint256 public constant MAX_LOSS_RATE_CAP_BPS = type(uint16).max;
    uint64 private constant LOSS_SETTLEMENT_VERSION = 1;

    IERC20 private _usdc;
    address public override riskusdVault;
    address public override vaultRegistry;
    address public override pnlAttestor;
    address public override hlTradingBridge;
    address public foundationPrimary;
    address public foundationBackup;
    address public protocolPrimary;
    address public protocolBackup;
    address public blocklist;
    address public pendingFoundationPrimary;
    uint256 public pendingFoundationPrimaryAt;
    uint256 public totalPrincipalReturned;
    uint16 private _foundationAllocationBps;

    mapping(uint256 => uint256) public recognizedProfit;
    mapping(uint256 => uint256) public recognizedDepositorClaim;
    mapping(uint256 => uint256) public retainedBufferLossAbsorbed;
    mapping(uint256 => mapping(uint8 => int256)) private _tierAccountingAdjustmentBps;
    mapping(uint256 => mapping(uint8 => uint256)) private _tierAccountingValue;
    mapping(bytes32 => uint256) public earmarkBalance;
    mapping(bytes32 => uint256) private _earmarkWindowStart;
    mapping(bytes32 => uint256) private _earmarkWindowUsed;
    mapping(uint256 => uint256) public fundedDepositorClaim;
    mapping(uint256 => uint256) public pendingVaultTopUp;

    address private _distributor;
    address private _pendingDistributor;

    uint256 public lossRateCapBps;
    uint256 private _lossRateWindowStart;
    uint256 private _lossRateWindowUsed;
    uint256 private _lossRateWindowTierAssets;
    mapping(uint256 => mapping(uint8 => uint256)) private _fundedTierYield;
    mapping(address => uint256) private _unfundedTierYieldClaim;
    bool private _yieldClaimsReady;
    mapping(uint256 => VaultFeeCarry) private _vaultFeeCarry;
    mapping(uint256 => LossRateWindow) private _lossRateWindows;
    mapping(uint256 => uint256) public unreturnedRecognizedProfit;
    bool private _profitReturnAccountingInitialized;
    PendingLossSettlement private _pendingLossSettlement;
    uint64 private _lossSettlementVersion;
    AccountingModuleSlot private _accountingModule;

    uint256[6] private __gap;

    event PnLRecognized(uint256 indexed vaultId, int256 amount);
    event PrincipalReturned(uint256 amount);
    event PnLReturned(uint256 indexed vaultId, uint256 amount);
    event EarmarkDisbursed(bytes32 indexed earmark, address indexed recipient, uint256 amount);
    event PnLAttestorSet(address indexed attestor);
    event HLTradingBridgeSet(address indexed bridge);
    event BlocklistSet(address indexed blocklist);
    event FoundationPrimaryProposed(address indexed wallet, uint256 proposedAt);
    event FoundationPrimaryFinalized(address indexed wallet);
    event FoundationPrimaryCancelled(address indexed wallet);
    event VaultTopUpDelivered(uint256 indexed vaultId, uint256 amount);
    event LossRateCapUpdated(uint256 oldCapBps, uint256 newCapBps);
    event AttestedLossSettled(uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount);
    event LossSettlementProgressed(
        uint256 indexed vaultId, uint256 indexed lossNonce, uint256 amount, uint256 remaining
    );

    constructor() {
        _disableInitializers();
    }

    modifier onlyOwnerOrDistributor() {
        if (msg.sender != owner() && msg.sender != _distributor) revert UnauthorizedDistributor();
        _;
    }

    modifier freshOnly() {
        _requireAccountingModuleReady();
        _;
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0 || _getInitializedVersion() != 0) revert InvalidInitialization();
        _;
    }

    modifier settlementVersionRequired() {
        uint64 version = _lossSettlementVersion;
        if (version != LOSS_SETTLEMENT_VERSION) revert SettlementVersionRequired(version);
        PendingLossSettlement storage pending = _pendingLossSettlement;
        if (pending.nonce != 0 && pending.reportTimeTierAssetsTotal == 0) {
            revert LossSettlementBasisUnavailable(pending.nonce);
        }
        _;
    }

    function initialize(
        address usdc_,
        address riskusdVault_,
        address vaultRegistry_,
        address owner_,
        address foundationPrimary_,
        address foundationBackup_,
        address protocolPrimary_,
        address protocolBackup_,
        address accountingModule_
    ) external onlyDuringConstructionBeforeInitialization initializer {
        if (
            usdc_ == address(0) || riskusdVault_ == address(0) || vaultRegistry_ == address(0) || owner_ == address(0)
                || foundationPrimary_ == address(0) || foundationBackup_ == address(0) || protocolPrimary_ == address(0)
                || protocolBackup_ == address(0)
        ) revert ZeroAddress();
        if (accountingModule_ == address(0)) revert ZeroAddress();
        if (accountingModule_.code.length == 0) revert AccountingModuleUnavailable(accountingModule_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        _usdc = IERC20(usdc_);
        riskusdVault = riskusdVault_;
        vaultRegistry = vaultRegistry_;
        foundationPrimary = foundationPrimary_;
        foundationBackup = foundationBackup_;
        protocolPrimary = protocolPrimary_;
        protocolBackup = protocolBackup_;
        _foundationAllocationBps = DEFAULT_FOUNDATION_ALLOCATION_BPS;
        _earmarkWindowStart[EARMARK_FOUNDATION] = block.timestamp;
        lossRateCapBps = DEFAULT_LOSS_RATE_CAP_BPS;
        _yieldClaimsReady = true;
        _profitReturnAccountingInitialized = true;
        _lossSettlementVersion = LOSS_SETTLEMENT_VERSION;
        _accountingModule.module = accountingModule_;
    }

    function yieldClaimsReady() external view override returns (bool) {
        return _yieldClaimsReady;
    }

    function unfundedYieldClaim(address tierVault) external view override returns (uint256) {
        return _unfundedTierYieldClaim[tierVault];
    }

    function setPnLAttestor(address attestor) external onlyAllowedCaller onlyOwner {
        if (attestor == address(0)) revert ZeroAddress();
        pnlAttestor = attestor;
        emit PnLAttestorSet(attestor);
    }

    function setHLTradingBridge(address bridge) external onlyAllowedCaller onlyOwner {
        if (bridge == address(0)) revert ZeroAddress();
        hlTradingBridge = bridge;
        emit HLTradingBridgeSet(bridge);
    }

    function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        blocklist = blocklist_;
        emit BlocklistSet(blocklist_);
    }

    function setAllowlist(address allowlist_) external onlyOwner {
        _transitionAllowlist(allowlist_);
    }

    function setDistributor(address distributor_) external onlyAllowedCaller onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        _pendingDistributor = distributor_;
    }

    function acceptDistributor() external freshOnly onlyAllowedCaller {
        if (msg.sender != _pendingDistributor) revert UnauthorizedDistributor();
        _distributor = msg.sender;
        _pendingDistributor = address(0);
    }

    function distributor() external view returns (address) {
        return _distributor;
    }

    function pendingDistributor() external view returns (address) {
        return _pendingDistributor;
    }

    function recognizePnL(uint256 vaultId, int256 amount) external freshOnly onlyAllowedCaller nonReentrant {
        if (msg.sender != pnlAttestor) revert UnauthorizedAttestor();
        if (!_profitReturnAccountingInitialized) revert PnLReturnAccountingUninitialized();
        if (amount >= 0) {
            uint256 profit = SignedMath.abs(amount);
            VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
            _validateYieldClaimProjection(vaultId, config);
            recognizedProfit[vaultId] += profit;
            unreturnedRecognizedProfit[vaultId] += profit;
            uint256 depositorYield = _recognizeTierYield(vaultId, profit, config);
            recognizedDepositorClaim[vaultId] += depositorYield;
            _validateYieldClaimProjection(vaultId, config);
        } else {
            uint256 loss = SignedMath.abs(amount);
            if (_hasOpenAttestedLoss()) revert AttestedLossPending();
            VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
            uint256 writtenDown = _writeDownUnpaidClaims(vaultId, loss, config);
            _reduceUnreturnedRecognizedProfit(vaultId, loss);
            for (uint8 i; i < 4; ++i) {
                _tierAccountingAdjustmentBps[vaultId][i] = -1_000;
            }
            retainedBufferLossAbsorbed[vaultId] += (loss - writtenDown) / 10;
        }
        emit PnLRecognized(vaultId, amount);
    }

    function setLossRateCapBps(uint256 newCapBps) external onlyAllowedCaller onlyOwner {
        _setLossRateCapBps(newCapBps);
    }

    function shrinkLossRateCapBps(uint256 newCapBps) external freshOnly onlyAllowedCaller {
        _requireGuardianModule();
        if (newCapBps > lossRateCapBps) revert LossRateCapWideningNotAllowed(newCapBps, lossRateCapBps);
        _setLossRateCapBps(newCapBps);
    }

    function returnPrincipalUSDC(uint256) external pure {
        revert PrincipalReturnsUseVault();
    }

    function recordPrincipalReturnUSDC(uint256 amount) external freshOnly onlyAllowedCaller nonReentrant {
        if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
        if (amount == 0) revert ZeroAmount();
        totalPrincipalReturned += amount;
        emit PrincipalReturned(amount);
    }

    function burnForLoss(uint256 vaultId, uint256 riskusdAmount) external onlyAllowedCaller onlyOwner nonReentrant {
        if (_hasOpenAttestedLoss()) revert AttestedLossPending();
        IRISKUSDVaultLossSettlement(riskusdVault).burnForLoss(vaultId, riskusdAmount);
    }

    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount)
        external
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        if (_hasOpenAttestedLoss()) revert AttestedLossPending();
        if (coverUsdcAmount != 0) {
            _usdc.safeTransferFrom(msg.sender, address(this), coverUsdcAmount);
            _usdc.forceApprove(riskusdVault, coverUsdcAmount);
        }
        IRISKUSDVaultLossSettlement(riskusdVault).coverAndBurnForLoss(vaultId, riskusdAmount, coverUsdcAmount);
        if (coverUsdcAmount != 0) {
            _usdc.forceApprove(riskusdVault, 0);
        }
    }

    function replenish(uint256 usdcAmount) external onlyAllowedCaller onlyOwner nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        _usdc.forceApprove(riskusdVault, usdcAmount);
        IRISKUSDVaultLossSettlement(riskusdVault).replenish(usdcAmount);
        _usdc.forceApprove(riskusdVault, 0);
    }

    function returnPnLUSDC(uint256 vaultId, uint256 amount) external freshOnly onlyAllowedCaller nonReentrant {
        if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
        if (amount == 0) revert ZeroAmount();
        if (!_profitReturnAccountingInitialized) revert PnLReturnAccountingUninitialized();
        if (recognizedProfit[vaultId] == 0) revert PnLNotRecognized(vaultId);
        uint256 unpaid = unreturnedRecognizedProfit[vaultId];
        if (amount > unpaid) revert PnLReturnExceedsUnpaidProfit(vaultId, amount, unpaid);
        PnLReturnState memory state = _preflightPnLReturn(vaultId);
        unreturnedRecognizedProfit[vaultId] = unpaid - amount;
        _collectPnLReturn(amount);
        USDCTreasuryAccountingModule.PnLReturnAllocation memory allocation =
            _calculatePnLReturnAllocation(vaultId, amount, state.outstandingClaim, state.existingPending);
        _commitPnLReturn(vaultId, amount, allocation);
    }

    function _preflightPnLReturn(uint256 vaultId) private view returns (PnLReturnState memory state) {
        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        state.outstandingClaim = _validateYieldClaimProjection(vaultId, config);
        state.existingPending = pendingVaultTopUp[vaultId];
        if (state.existingPending > state.outstandingClaim) {
            revert SettlementValueMismatch(address(this), state.outstandingClaim, state.existingPending);
        }
    }

    function _collectPnLReturn(uint256 amount) private {
        IERC20 token = _usdc;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert USDCAmountMismatch(amount, received);
    }

    function _calculatePnLReturnAllocation(
        uint256 vaultId,
        uint256 amount,
        uint256 outstandingClaim,
        uint256 existingPending
    ) private view returns (USDCTreasuryAccountingModule.PnLReturnAllocation memory allocation) {
        VaultFeeCarry storage carry = _vaultFeeCarry[vaultId];
        return USDCTreasuryAccountingModule(_accountingModule.module).calculatePnLReturnAllocation(
            amount,
            outstandingClaim,
            existingPending,
            _foundationAllocationBps,
            carry.protocolRemainder,
            carry.foundationRemainder
        );
    }

    function _commitPnLReturn(
        uint256 vaultId,
        uint256 amount,
        USDCTreasuryAccountingModule.PnLReturnAllocation memory allocation
    ) private {
        pendingVaultTopUp[vaultId] += allocation.vaultTopUp;
        earmarkBalance[EARMARK_FOUNDATION] += allocation.foundation;
        earmarkBalance[EARMARK_PROTOCOL_RETAINED] += allocation.retained;
        earmarkBalance[EARMARK_VAULT_TOP_UP] += allocation.vaultTopUp;
        earmarkBalance[EARMARK_AGENT_PAY] += allocation.agent;
        VaultFeeCarry storage carry = _vaultFeeCarry[vaultId];
        carry.protocolRemainder = allocation.protocolRemainder;
        carry.foundationRemainder = allocation.foundationRemainder;
        emit PnLReturned(vaultId, amount);
    }

    function deliverVaultTopUp(uint256 vaultId, uint256 amount) external onlyAllowedCaller onlyOwner nonReentrant {
        if (_hasOpenAttestedLoss()) revert AttestedLossPending();
        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        uint256[4] memory allocations = _prepareVaultTopUp(vaultId, amount, config);
        IERC20 riskusd = _mintTopUpRISKUSD(amount);
        _accrueTierYield(vaultId, config, riskusd, allocations);
        emit VaultTopUpDelivered(vaultId, amount);
    }

    function _prepareVaultTopUp(uint256 vaultId, uint256 amount, VaultConfig memory config)
        private
        view
        returns (uint256[4] memory allocations)
    {
        uint256 pending = pendingVaultTopUp[vaultId];
        if (amount == 0) revert ZeroAmount();
        if (amount != pending) revert VaultTopUpAmountMismatch(amount, pending);
        if (_isBlocked(riskusdVault)) revert BlockedRecipient(riskusdVault);
        uint256 earmark = earmarkBalance[EARMARK_VAULT_TOP_UP];
        if (amount > earmark) revert InsufficientEarmark();

        (uint256 outstandingClaim, uint256[4] memory outstanding) = _projectYieldClaims(vaultId, config);
        if (amount > outstandingClaim) {
            revert SettlementValueMismatch(address(this), outstandingClaim, amount);
        }

        allocations = _allocateCapped(amount, outstanding, outstandingClaim);
    }

    function _mintTopUpRISKUSD(uint256 amount) private returns (IERC20 riskusd) {
        address centralVault = riskusdVault;
        riskusd = IERC20(IRISKUSDVaultLossSettlement(centralVault).riskusd());
        uint256 treasuryUsdcBefore = _usdc.balanceOf(address(this));
        uint256 vaultUsdcBefore = _usdc.balanceOf(centralVault);
        uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
        _usdc.forceApprove(centralVault, amount);
        IRISKUSDVaultLossSettlement(centralVault).deposit(amount);
        _usdc.forceApprove(centralVault, 0);
        _requireBalanceDecrease(_usdc, address(this), treasuryUsdcBefore, amount);
        _requireBalanceIncrease(_usdc, centralVault, vaultUsdcBefore, amount);
        _requireBalanceIncrease(riskusd, address(this), treasuryRiskusdBefore, amount);
    }

    function _accrueTierYield(uint256 vaultId, VaultConfig memory config, IERC20 riskusd, uint256[4] memory allocations)
        private
    {
        uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
        uint256 totalYield;
        for (uint8 i; i < 4; ++i) {
            uint256 yieldAmount = allocations[i];
            if (yieldAmount == 0) continue;
            totalYield += yieldAmount;
            address tierVault = config.tierVaults[i];
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            IUSDCTreasuryTierVault tier = IUSDCTreasuryTierVault(tierVault);
            uint256 tierBalanceBefore = riskusd.balanceOf(tierVault);
            riskusd.forceApprove(tierVault, yieldAmount);
            tier.accrueYield(yieldAmount);
            _commitTierFunding(vaultId, i, tierVault, yieldAmount);
            riskusd.forceApprove(tierVault, 0);
            _requireValueIncrease(tierVault, tierBalanceBefore, riskusd.balanceOf(tierVault), yieldAmount);
        }
        _requireBalanceDecrease(riskusd, address(this), treasuryRiskusdBefore, totalYield);
    }

    function settleLoss(uint256 vaultId, uint256 lossNonce)
        external
        override
        settlementVersionRequired
        freshOnly
        onlyAllowedCaller
        nonReentrant
        returns (bool complete, uint256 originalLoss)
    {
        if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
        IRISKUSDVaultLossSettlement centralVault = IRISKUSDVaultLossSettlement(riskusdVault);
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

    function disburse(bytes32 earmark, address recipient, uint256 amount)
        external
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        _disburse(earmark, recipient, amount);
    }

    function disburseAgentPayBatch(address[] calldata recipients, uint256[] calldata amounts)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwnerOrDistributor
        nonReentrant
    {
        uint256 count = recipients.length;
        if (count == 0 || count != amounts.length) revert InvalidBatch();
        if (count > MAX_AGENT_PAY_BATCH) revert BatchLimitExceeded();
        for (uint256 i; i < count; ++i) {
            _disburse(EARMARK_AGENT_PAY, recipients[i], amounts[i]);
        }
    }

    function disburseFoundation(uint256 amount) external onlyAllowedCaller onlyOwner nonReentrant {
        address recipient = _isBlocked(foundationPrimary) ? foundationBackup : foundationPrimary;
        _disburse(EARMARK_FOUNDATION, recipient, amount);
    }

    function disburseProtocolRetained(uint256 amount) external onlyAllowedCaller onlyOwner nonReentrant {
        address recipient = _isBlocked(protocolPrimary) ? protocolBackup : protocolPrimary;
        _disburse(EARMARK_PROTOCOL_RETAINED, recipient, amount);
    }

    function proposeFoundationPrimary(address wallet) external onlyAllowedCaller onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        pendingFoundationPrimary = wallet;
        pendingFoundationPrimaryAt = block.timestamp;
        emit FoundationPrimaryProposed(wallet, block.timestamp);
    }

    function finalizeFoundationPrimary() external onlyAllowedCaller onlyOwner {
        address wallet = pendingFoundationPrimary;
        if (wallet == address(0)) revert NoPendingWallet();
        if (block.timestamp < pendingFoundationPrimaryAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > pendingFoundationPrimaryAt + PROPOSAL_EXPIRY) revert ProposalExpired();
        foundationPrimary = wallet;
        pendingFoundationPrimary = address(0);
        pendingFoundationPrimaryAt = 0;
        emit FoundationPrimaryFinalized(wallet);
    }

    function cancelPendingFoundationPrimary() external onlyAllowedCaller onlyOwner {
        address wallet = pendingFoundationPrimary;
        if (wallet == address(0)) revert NoPendingWallet();
        pendingFoundationPrimary = address(0);
        pendingFoundationPrimaryAt = 0;
        emit FoundationPrimaryCancelled(wallet);
    }

    function tierAccountingAdjustmentBps(uint256 vaultId, uint8 tier) external view returns (int256) {
        return _tierAccountingAdjustmentBps[vaultId][tier];
    }

    function tierAccountingValue(uint256 vaultId, uint8 tier) external view returns (uint256) {
        return _tierAccountingValue[vaultId][tier];
    }

    function foundationAllocationBps() external view returns (uint16) {
        return _foundationAllocationBps;
    }

    function walletRotationDelay() external view returns (uint256) {
        return _finalizeDelay();
    }

    function usdc() external view returns (address) {
        return address(_usdc);
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override onlyAllowedCaller {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshOnly onlyAllowedCaller {
        super.acceptOwnership();
    }

    function _disburse(bytes32 earmark, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_isBlocked(recipient)) revert BlockedRecipient(recipient);
        uint256 earmarkAvailable = earmarkBalance[earmark];
        if (earmarkAvailable < amount) revert InsufficientEarmark();
        if (earmark == EARMARK_PROTOCOL_RETAINED) {
            uint256 reservedCover = _pendingLossSettlement.remainingRetainedCover;
            if (reservedCover > earmarkAvailable || amount > earmarkAvailable - reservedCover) {
                revert InsufficientEarmark();
            }
        }
        if (earmark == EARMARK_FOUNDATION) {
            _enforceEarmarkWindowCap(earmark, amount, earmarkBalance[earmark], FOUNDATION_DAILY_CAP_BPS);
            if (recipient != foundationPrimary && recipient != foundationBackup) revert DestinationNotAllowed();
        } else if (earmark == EARMARK_PROTOCOL_RETAINED) {
            _enforceFixedWindowCap(earmark, amount, PROTOCOL_RETAINED_DAILY_CAP);
            if (recipient != protocolPrimary && recipient != protocolBackup) revert DestinationNotAllowed();
        } else if (earmark == EARMARK_AGENT_PAY) {
            _enforceEarmarkWindowCap(earmark, amount, earmarkBalance[earmark], AGENT_PAY_CAP_BPS);
            uint256 paymentCap = earmarkBalance[earmark] * AGENT_PAY_CAP_BPS / 10_000;
            if (amount > paymentCap) revert PurposeCapExceeded();
        } else {
            revert DestinationNotAllowed();
        }
        earmarkBalance[earmark] -= amount;
        _usdc.safeTransfer(recipient, amount);
        emit EarmarkDisbursed(earmark, recipient, amount);
    }

    function _recognizeTierYield(uint256 vaultId, uint256 profit, VaultConfig memory config)
        private
        returns (uint256 totalYield)
    {
        uint256[4] memory tierAssets;
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault == address(0)) {
                if (config.status != VaultStatus.WindingDown) revert TierVaultUnavailable(tierVault);
                continue;
            }
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            tierAssets[i] = IUSDCTreasuryTierVault(tierVault).legitimateAssets();
        }
        USDCTreasuryAccountingModule.YieldSplitInput memory input;
        input.profit = profit;
        input.tierAssets = tierAssets;
        input.yieldSplitsBps = config.yieldSplitsBps;
        input.fundingBps = config.fundingBps;
        USDCTreasuryAccountingModule.YieldSplitResult memory result =
            USDCTreasuryAccountingModule(_accountingModule.module).calculateTierYield(input);
        totalYield = result.totalYield;
        uint256[4] memory tierYield = result.tierYield;
        for (uint8 i; i < 4; ++i) {
            if (tierYield[i] != 0) _requireTierHasSupply(config.tierVaults[i], tierYield[i]);
        }
        for (uint8 i; i < 4; ++i) {
            uint256 yieldAmount = tierYield[i];
            if (yieldAmount == 0) continue;
            address tierVault = config.tierVaults[i];
            IUSDCTreasuryTierVault(tierVault).recognizeUnpaidProfit(yieldAmount);
            uint256 recorded = _tierAccountingValue[vaultId][i];
            uint256 projected = _unfundedTierYieldClaim[tierVault];
            if (yieldAmount > type(uint256).max - recorded || yieldAmount > type(uint256).max - projected) {
                revert TierYieldClaimMismatch(vaultId, tierVault, recorded, projected);
            }
            _tierAccountingValue[vaultId][i] = recorded + yieldAmount;
            _unfundedTierYieldClaim[tierVault] = projected + yieldAmount;
        }
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
            uint256 assets = IUSDCTreasuryTierVault(tierVault).legitimateAssets();
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

    function _validateYieldClaimProjection(uint256 vaultId, VaultConfig memory config)
        private
        view
        returns (uint256 aggregateOutstanding)
    {
        (aggregateOutstanding,) = _projectYieldClaims(vaultId, config);
    }

    function _projectYieldClaims(uint256 vaultId, VaultConfig memory config)
        private
        view
        returns (uint256 aggregateOutstanding, uint256[4] memory tierOutstanding)
    {
        return USDCTreasuryAccountingModule(_accountingModule.module).validateYieldClaimProjection(
            _yieldProjectionInput(vaultId, config)
        );
    }

    function _yieldProjectionInput(uint256 vaultId, VaultConfig memory config)
        private
        view
        returns (USDCTreasuryAccountingModule.YieldProjectionInput memory input)
    {
        input.vaultId = vaultId;
        input.treasury = address(this);
        input.tierVaults = config.tierVaults;
        input.windingDown = config.status == VaultStatus.WindingDown;
        input.recognizedClaim = recognizedDepositorClaim[vaultId];
        input.fundedClaim = fundedDepositorClaim[vaultId];
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            input.recognizedTier[i] = _tierAccountingValue[vaultId][i];
            input.fundedTier[i] = _fundedTierYield[vaultId][i];
            if (tierVault != address(0)) input.unfundedTier[i] = _unfundedTierYieldClaim[tierVault];
        }
    }

    function _writeDownUnpaidClaims(uint256 vaultId, uint256 amount, VaultConfig memory config)
        private
        returns (uint256 writtenDown)
    {
        (uint256 outstanding, uint256[4] memory tierOutstanding) = _projectYieldClaims(vaultId, config);
        writtenDown = amount < outstanding ? amount : outstanding;
        if (writtenDown == 0) return 0;
        uint256[4] memory allocations = _allocateCapped(writtenDown, tierOutstanding, outstanding);
        recognizedDepositorClaim[vaultId] -= writtenDown;
        for (uint8 i; i < 4; ++i) {
            uint256 allocation = allocations[i];
            if (allocation == 0) continue;
            address tierVault = config.tierVaults[i];
            IUSDCTreasuryTierVault(tierVault).writeDownUnpaidProfit(allocation);
            _tierAccountingValue[vaultId][i] -= allocation;
            _unfundedTierYieldClaim[tierVault] -= allocation;
        }
        _reconcilePendingVaultTopUp(vaultId, outstanding - writtenDown);
    }

    function _reconcilePendingVaultTopUp(uint256 vaultId, uint256 outstanding) private {
        uint256 pending = pendingVaultTopUp[vaultId];
        if (pending <= outstanding) return;
        uint256 excess = pending - outstanding;
        uint256 earmark = earmarkBalance[EARMARK_VAULT_TOP_UP];
        if (earmark < excess) revert InsufficientEarmark();
        pendingVaultTopUp[vaultId] = outstanding;
        earmarkBalance[EARMARK_VAULT_TOP_UP] = earmark - excess;
    }

    function _reduceUnreturnedRecognizedProfit(uint256 vaultId, uint256 loss) private {
        uint256 unreturned = unreturnedRecognizedProfit[vaultId];
        unreturnedRecognizedProfit[vaultId] = unreturned - Math.min(loss, unreturned);
    }

    function _requireTierHasSupply(address tierVault, uint256 amount) private view {
        if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
        (bool ok, bytes memory data) =
            tierVault.staticcall(abi.encodeWithSelector(IUSDCTreasuryTierVault.totalSupply.selector));
        if (!ok || data.length != 32) revert TierVaultUnavailable(tierVault);
        uint256 supply = abi.decode(data, (uint256));
        if (supply == 0) revert ZeroSupplyTier(tierVault, amount);
    }

    function _commitTierFunding(uint256 vaultId, uint8 tierIndex, address tierVault, uint256 amount) private {
        uint256 claim = _unfundedTierYieldClaim[tierVault];
        uint256 pending = pendingVaultTopUp[vaultId];
        uint256 earmark = earmarkBalance[EARMARK_VAULT_TOP_UP];
        if (claim < amount) revert TierYieldClaimMismatch(vaultId, tierVault, amount, claim);
        if (pending < amount) revert SettlementValueMismatch(address(this), amount, pending);
        if (earmark < amount) revert InsufficientEarmark();
        _unfundedTierYieldClaim[tierVault] = claim - amount;
        _fundedTierYield[vaultId][tierIndex] += amount;
        fundedDepositorClaim[vaultId] += amount;
        pendingVaultTopUp[vaultId] = pending - amount;
        earmarkBalance[EARMARK_VAULT_TOP_UP] = earmark - amount;
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
        uint256 nextWindowStart;
        uint256 nextWindowUsed;
        (chargedLoss, nextWindowStart, nextWindowUsed) = USDCTreasuryAccountingModule(_accountingModule.module)
            .consumeLossRateBudget(requestedLoss, tierAssets, lossRateCapBps, window.start, window.used, block.timestamp);
        window.start = nextWindowStart;
        window.tierAssets = tierAssets;
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
        IRISKUSDVaultLossSettlement centralVault,
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
            IUSDCTreasuryTierVault tier = IUSDCTreasuryTierVault(tierVault);
            uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
            tier.absorbLoss(amount);
            _requireValueDecrease(tierVault, plan.tierAssets[i], tier.legitimateAssets(), amount);
            _requireValueIncrease(tierVault, treasuryRiskusdBefore, riskusd.balanceOf(address(this)), amount);
        }
    }

    function _coverAndBurnLoss(
        uint256 vaultId,
        LossSettlementPlan memory plan,
        IRISKUSDVaultLossSettlement centralVault
    ) private {
        if (plan.retainedCover != 0) {
            uint256 retained = earmarkBalance[EARMARK_PROTOCOL_RETAINED];
            earmarkBalance[EARMARK_PROTOCOL_RETAINED] = retained - plan.retainedCover;
            _usdc.forceApprove(riskusdVault, plan.retainedCover);
        }
        centralVault.coverAndBurnForLoss(vaultId, plan.tierLoss, plan.retainedCover);
        if (plan.retainedCover != 0) _usdc.forceApprove(riskusdVault, 0);
    }

    function _setLossRateCapBps(uint256 newCapBps) private {
        if (newCapBps == 0 || newCapBps > MAX_LOSS_RATE_CAP_BPS) revert InvalidLossRateCap(newCapBps);
        uint256 oldCapBps = lossRateCapBps;
        lossRateCapBps = newCapBps;
        emit LossRateCapUpdated(oldCapBps, newCapBps);
    }

    function _requireAccountingModuleReady() private view {
        if (!_yieldClaimsReady) revert LegacyTreasuryStateUnsupported();
        address module = _accountingModule.module;
        if (module == address(0) || module.code.length == 0) revert AccountingModuleUnavailable(module);
    }

    function _requireGuardianModule() private view {
        address governor = IRISKUSDVaultLossSettlement(riskusdVault).forageGovernor();
        if (governor.code.length == 0) revert UnauthorizedLossCapShrinker(msg.sender);
        address guardianModule;
        try IUSDCTreasuryGuardianQuery(governor).guardianModule() returns (address module) {
            guardianModule = module;
        } catch {
            revert UnauthorizedLossCapShrinker(msg.sender);
        }
        if (guardianModule == address(0) || msg.sender != guardianModule) {
            revert UnauthorizedLossCapShrinker(msg.sender);
        }
    }

    function _hasOpenAttestedLoss() private view returns (bool) {
        IRISKUSDVaultLossSettlement centralVault = IRISKUSDVaultLossSettlement(riskusdVault);
        uint256 latestNonce = centralVault.latestLossNonce();
        return latestNonce != 0 && latestNonce > centralVault.settledLossNonce()
            && centralVault.lossPendingVaultId() != 0 && centralVault.latestLossAmount() != 0;
    }

    function _requireBalanceIncrease(IERC20 token, address account, uint256 beforeBalance, uint256 expected)
        private
        view
    {
        uint256 afterBalance = token.balanceOf(account);
        uint256 actual = afterBalance >= beforeBalance ? afterBalance - beforeBalance : type(uint256).max;
        if (actual != expected) revert SettlementValueMismatch(account, expected, actual);
    }

    function _requireBalanceDecrease(IERC20 token, address account, uint256 beforeBalance, uint256 expected)
        private
        view
    {
        uint256 afterBalance = token.balanceOf(account);
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : type(uint256).max;
        if (actual != expected) revert SettlementValueMismatch(account, expected, actual);
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

    function _enforceEarmarkWindowCap(bytes32 earmark, uint256 amount, uint256 currentBalance, uint16 capBps)
        internal
    {
        _resetEarmarkWindowIfExpired(earmark);
        uint256 basis = currentBalance + _earmarkWindowUsed[earmark];
        uint256 cap = basis * capBps / 10_000;
        if (_earmarkWindowUsed[earmark] + amount > cap) revert PurposeCapExceeded();
        _earmarkWindowUsed[earmark] += amount;
    }

    function _enforceFixedWindowCap(bytes32 earmark, uint256 amount, uint256 cap) internal {
        _resetEarmarkWindowIfExpired(earmark);
        if (_earmarkWindowUsed[earmark] + amount > cap) revert PurposeCapExceeded();
        _earmarkWindowUsed[earmark] += amount;
    }

    function _resetEarmarkWindowIfExpired(bytes32 earmark) internal {
        uint256 start = _earmarkWindowStart[earmark];
        if (start == 0 || block.timestamp >= start + DAY_SECONDS) {
            _earmarkWindowStart[earmark] = block.timestamp;
            _earmarkWindowUsed[earmark] = 0;
        }
    }

    function _isBlocked(address account) internal view returns (bool) {
        address blocklist_ = blocklist;
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        try IUSDCTreasuryBlocklist(blocklist_).isBlocked(account) returns (bool blocked) {
            return blocked;
        } catch {
            revert BlocklistUnavailable(blocklist_);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {
        // Match the codebase's upgrade-wipes-pending-proposals norm (OF-L06).
        pendingFoundationPrimary = address(0);
        pendingFoundationPrimaryAt = 0;
    }

    function _checkOwner() internal view override {
        if (!_yieldClaimsReady) revert LegacyTreasuryStateUnsupported();
        super._checkOwner();
    }
}
