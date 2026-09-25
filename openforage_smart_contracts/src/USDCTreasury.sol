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
import "./interfaces/IVaultRegistry.sol";

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

interface IUSDCTreasuryTierVault {
    function legitimateAssets() external view returns (uint256);
    function accrueYield(uint256 riskusdAmount) external;
    function absorbLoss(uint256 riskusdAmount) external;
    function totalYieldAccrued() external view returns (uint256);
    function totalLossAbsorbed() external view returns (uint256);
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
    AllowlistGatedUpgradeable
{
    using SafeERC20 for IERC20;

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

    IERC20 private _usdc;
    address public riskusdVault;
    address public vaultRegistry;
    address public pnlAttestor;
    address public hlTradingBridge;
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

    uint256[23] private __gap;

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

    constructor() {
        _disableInitializers();
    }

    modifier onlyOwnerOrDistributor() {
        if (msg.sender != owner() && msg.sender != _distributor) revert UnauthorizedDistributor();
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
        address protocolBackup_
    ) external initializer {
        if (
            usdc_ == address(0) || riskusdVault_ == address(0) || vaultRegistry_ == address(0) || owner_ == address(0)
                || foundationPrimary_ == address(0) || foundationBackup_ == address(0) || protocolPrimary_ == address(0)
                || protocolBackup_ == address(0)
        ) revert ZeroAddress();
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
        _setAllowlist(allowlist_);
    }

    function setDistributor(address distributor_) external onlyAllowedCaller onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        _pendingDistributor = distributor_;
    }

    function acceptDistributor() external onlyAllowedCaller {
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

    function recognizePnL(uint256 vaultId, int256 amount) external onlyAllowedCaller {
        if (msg.sender != pnlAttestor) revert UnauthorizedAttestor();
        if (amount >= 0) {
            uint256 profit = SignedMath.abs(amount);
            recognizedProfit[vaultId] += profit;
            VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
            uint256 depositorYield = _recognizeTierYield(vaultId, profit, config);
            recognizedDepositorClaim[vaultId] += depositorYield;
        } else {
            uint256 loss = SignedMath.abs(amount);
            if (_hasOpenAttestedLoss()) revert AttestedLossPending();
            for (uint8 i; i < 4; ++i) {
                _tierAccountingAdjustmentBps[vaultId][i] = -1_000;
            }
            retainedBufferLossAbsorbed[vaultId] += loss / 10;
        }
        emit PnLRecognized(vaultId, amount);
    }

    function initializeV2LossRate() external onlyAllowedCaller onlyOwner reinitializer(2) {
        lossRateCapBps = DEFAULT_LOSS_RATE_CAP_BPS;
    }

    function setLossRateCapBps(uint256 newCapBps) external onlyAllowedCaller onlyOwner {
        _setLossRateCapBps(newCapBps);
    }

    function shrinkLossRateCapBps(uint256 newCapBps) external onlyAllowedCaller {
        _requireGuardianModule();
        if (newCapBps > lossRateCapBps) revert LossRateCapWideningNotAllowed(newCapBps, lossRateCapBps);
        _setLossRateCapBps(newCapBps);
    }

    function returnPrincipalUSDC(uint256) external pure {
        revert PrincipalReturnsUseVault();
    }

    function recordPrincipalReturnUSDC(uint256 amount) external onlyAllowedCaller nonReentrant {
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

    function returnPnLUSDC(uint256 vaultId, uint256 amount) external onlyAllowedCaller nonReentrant {
        if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
        if (amount == 0) revert ZeroAmount();
        if (recognizedProfit[vaultId] == 0) revert PnLNotRecognized(vaultId);
        uint256 balanceBefore = _usdc.balanceOf(address(this));
        _usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = _usdc.balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert USDCAmountMismatch(amount, received);

        uint256 foundation = amount * PROTOCOL_SHARE_BPS / 10_000 * _foundationAllocationBps / 10_000;
        uint256 retained = amount * PROTOCOL_SHARE_BPS / 10_000 - foundation;
        uint256 claim = recognizedDepositorClaim[vaultId];
        uint256 fundedClaim = fundedDepositorClaim[vaultId];
        uint256 pendingClaim = pendingVaultTopUp[vaultId];
        if (fundedClaim > claim || pendingClaim > claim - fundedClaim) {
            revert SettlementValueMismatch(address(this), claim, fundedClaim + pendingClaim);
        }
        uint256 vaultTopUp = claim - fundedClaim - pendingClaim;
        if (vaultTopUp > amount - foundation - retained) {
            vaultTopUp = amount - foundation - retained;
        }
        uint256 agent = amount - foundation - retained - vaultTopUp;
        pendingVaultTopUp[vaultId] += vaultTopUp;

        earmarkBalance[EARMARK_FOUNDATION] += foundation;
        earmarkBalance[EARMARK_PROTOCOL_RETAINED] += retained;
        earmarkBalance[EARMARK_VAULT_TOP_UP] += vaultTopUp;
        earmarkBalance[EARMARK_AGENT_PAY] += agent;
        emit PnLReturned(vaultId, amount);
    }

    function deliverVaultTopUp(uint256 vaultId, uint256 amount) external onlyAllowedCaller onlyOwner nonReentrant {
        uint256[4] memory allocations = _prepareVaultTopUp(vaultId, amount);
        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        IERC20 riskusd = _mintTopUpRISKUSD(amount);
        _accrueTierYield(config, riskusd, allocations);
        emit VaultTopUpDelivered(vaultId, amount);
    }

    function _prepareVaultTopUp(uint256 vaultId, uint256 amount) private returns (uint256[4] memory allocations) {
        uint256 pending = pendingVaultTopUp[vaultId];
        if (amount == 0) revert ZeroAmount();
        if (amount != pending) revert VaultTopUpAmountMismatch(amount, pending);
        if (_isBlocked(riskusdVault)) revert BlockedRecipient(riskusdVault);
        uint256 earmark = earmarkBalance[EARMARK_VAULT_TOP_UP];
        if (amount > earmark) revert InsufficientEarmark();

        uint256 claim = recognizedDepositorClaim[vaultId];
        uint256 funded = fundedDepositorClaim[vaultId];
        if (funded > claim || amount > claim - funded) {
            revert SettlementValueMismatch(address(this), claim, funded + amount);
        }

        uint256[4] memory outstanding = _outstandingTierYield(vaultId);
        uint256 totalOutstanding = _sum(outstanding);
        uint256 unfundedClaim = claim - funded;
        if (totalOutstanding != unfundedClaim || amount > totalOutstanding) {
            revert SettlementValueMismatch(address(0), unfundedClaim, totalOutstanding);
        }
        allocations = _allocateCapped(amount, outstanding, totalOutstanding);

        earmarkBalance[EARMARK_VAULT_TOP_UP] = earmark - amount;
        pendingVaultTopUp[vaultId] = 0;
        fundedDepositorClaim[vaultId] = funded + amount;
        for (uint8 i; i < 4; ++i) {
            _fundedTierYield[vaultId][i] += allocations[i];
        }
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

    function _accrueTierYield(VaultConfig memory config, IERC20 riskusd, uint256[4] memory allocations) private {
        uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
        uint256 totalYield;
        for (uint8 i; i < 4; ++i) {
            uint256 yieldAmount = allocations[i];
            if (yieldAmount == 0) continue;
            totalYield += yieldAmount;
            address tierVault = config.tierVaults[i];
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            IUSDCTreasuryTierVault tier = IUSDCTreasuryTierVault(tierVault);
            uint256 assetsBefore = tier.legitimateAssets();
            uint256 tierBalanceBefore = riskusd.balanceOf(tierVault);
            uint256 yieldTotalBefore = tier.totalYieldAccrued();
            riskusd.forceApprove(tierVault, yieldAmount);
            tier.accrueYield(yieldAmount);
            riskusd.forceApprove(tierVault, 0);
            _requireValueIncrease(tierVault, assetsBefore, tier.legitimateAssets(), yieldAmount);
            _requireValueIncrease(tierVault, tierBalanceBefore, riskusd.balanceOf(tierVault), yieldAmount);
            _requireValueIncrease(tierVault, yieldTotalBefore, tier.totalYieldAccrued(), yieldAmount);
        }
        _requireBalanceDecrease(riskusd, address(this), treasuryRiskusdBefore, totalYield);
    }

    function settleLoss(uint256 vaultId, uint256 lossNonce) external onlyAllowedCaller nonReentrant {
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

        VaultConfig memory config = IVaultRegistry(vaultRegistry).getVault(vaultId);
        (uint256[4] memory tierAssets, uint256 totalTierAssets) = _tierAssetSnapshot(config);
        _consumeLossRateBudget(loss, totalTierAssets);

        uint256 tierLoss = loss < totalTierAssets ? loss : totalTierAssets;
        uint256 retainedCover = loss - tierLoss;
        uint256 retained = earmarkBalance[EARMARK_PROTOCOL_RETAINED];
        if (retainedCover > retained) revert InsufficientEarmark();
        uint256[4] memory tierLosses = _allocateCapped(tierLoss, tierAssets, totalTierAssets);
        IERC20 riskusd = IERC20(centralVault.riskusd());

        for (uint8 i; i < 4; ++i) {
            uint256 amount = tierLosses[i];
            if (amount == 0) continue;
            address tierVault = config.tierVaults[i];
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            IUSDCTreasuryTierVault tier = IUSDCTreasuryTierVault(tierVault);
            uint256 assetsBefore = tier.legitimateAssets();
            uint256 treasuryRiskusdBefore = riskusd.balanceOf(address(this));
            uint256 tierBalanceBefore = riskusd.balanceOf(tierVault);
            uint256 absorbedBefore = tier.totalLossAbsorbed();
            tier.absorbLoss(amount);
            _requireValueDecrease(tierVault, assetsBefore, tier.legitimateAssets(), amount);
            _requireValueDecrease(tierVault, tierBalanceBefore, riskusd.balanceOf(tierVault), amount);
            _requireValueIncrease(tierVault, treasuryRiskusdBefore, riskusd.balanceOf(address(this)), amount);
            _requireValueIncrease(tierVault, absorbedBefore, tier.totalLossAbsorbed(), amount);
        }

        if (retainedCover != 0) {
            earmarkBalance[EARMARK_PROTOCOL_RETAINED] = retained - retainedCover;
            _usdc.forceApprove(riskusdVault, retainedCover);
        }
        centralVault.coverAndBurnForLoss(vaultId, tierLoss, retainedCover);
        if (retainedCover != 0) _usdc.forceApprove(riskusdVault, 0);

        uint256 settledNonce = centralVault.settledLossNonce();
        if (settledNonce != lossNonce || centralVault.latestLossAmount() != 0 || centralVault.lossPending()) {
            revert LossNonceMismatch(settledNonce, lossNonce);
        }
        emit AttestedLossSettled(vaultId, lossNonce, loss);
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

    function acceptOwnership() public override onlyAllowedCaller {
        super.acceptOwnership();
    }

    function _disburse(bytes32 earmark, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_isBlocked(recipient)) revert BlockedRecipient(recipient);
        if (earmarkBalance[earmark] < amount) revert InsufficientEarmark();
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
        uint256 totalAssets;
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault == address(0)) continue;
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            tierAssets[i] = IUSDCTreasuryTierVault(tierVault).legitimateAssets();
            totalAssets += tierAssets[i];
        }
        if (totalAssets == 0 || profit == 0) return 0;

        uint256[4] memory tierProfit = _allocateUncapped(profit, tierAssets, totalAssets);
        for (uint8 i; i < 4; ++i) {
            uint256 splitTotal = uint256(config.yieldSplitsBps[i]) + uint256(config.fundingBps[i]);
            uint256 yieldAmount;
            if (splitTotal != 0) {
                uint256 weightedBps = 7_000 * uint256(config.yieldSplitsBps[i]);
                yieldAmount = Math.mulDiv(tierProfit[i], weightedBps, 10_000 * splitTotal);
            }
            _tierAccountingValue[vaultId][i] += yieldAmount;
            totalYield += yieldAmount;
        }
    }

    function _tierAssetSnapshot(VaultConfig memory config)
        private
        view
        returns (uint256[4] memory tierAssets, uint256 totalAssets)
    {
        for (uint8 i; i < 4; ++i) {
            address tierVault = config.tierVaults[i];
            if (tierVault.code.length == 0) revert TierVaultUnavailable(tierVault);
            uint256 assets = IUSDCTreasuryTierVault(tierVault).legitimateAssets();
            tierAssets[i] = assets;
            totalAssets += assets;
        }
    }

    function _allocateUncapped(uint256 amount, uint256[4] memory weights, uint256 totalWeight)
        private
        pure
        returns (uint256[4] memory allocations)
    {
        if (amount == 0 || totalWeight == 0) return allocations;
        uint256 allocated;
        uint8 firstWeightedTier = type(uint8).max;
        for (uint8 i; i < 4; ++i) {
            if (weights[i] != 0 && firstWeightedTier == type(uint8).max) firstWeightedTier = i;
            allocations[i] = Math.mulDiv(amount, weights[i], totalWeight);
            allocated += allocations[i];
        }
        if (firstWeightedTier != type(uint8).max) allocations[firstWeightedTier] += amount - allocated;
    }

    function _allocateCapped(uint256 amount, uint256[4] memory weights, uint256 totalWeight)
        private
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

    function _outstandingTierYield(uint256 vaultId) private view returns (uint256[4] memory outstanding) {
        for (uint8 i; i < 4; ++i) {
            uint256 recognized = _tierAccountingValue[vaultId][i];
            uint256 funded = _fundedTierYield[vaultId][i];
            if (funded > recognized) revert SettlementValueMismatch(address(this), recognized, funded);
            outstanding[i] = recognized - funded;
        }
    }

    function _sum(uint256[4] memory values) private pure returns (uint256 total) {
        for (uint8 i; i < 4; ++i) {
            total += values[i];
        }
    }

    function _consumeLossRateBudget(uint256 loss, uint256 tierAssets) private {
        uint256 windowStart = _lossRateWindowStart;
        if (windowStart == 0 || block.timestamp >= windowStart + LOSS_RATE_WINDOW) {
            _lossRateWindowStart = block.timestamp;
            _lossRateWindowTierAssets = tierAssets;
            _lossRateWindowUsed = 0;
        }
        uint256 cap = Math.mulDiv(_lossRateWindowTierAssets, lossRateCapBps, 10_000);
        uint256 used = _lossRateWindowUsed;
        uint256 remaining = cap > used ? cap - used : 0;
        if (loss > remaining) revert LossRateCapExceeded(loss, remaining);
        _lossRateWindowUsed = used + loss;
    }

    function _setLossRateCapBps(uint256 newCapBps) private {
        if (newCapBps > MAX_LOSS_RATE_CAP_BPS) revert InvalidLossRateCap(newCapBps);
        uint256 oldCapBps = lossRateCapBps;
        lossRateCapBps = newCapBps;
        emit LossRateCapUpdated(oldCapBps, newCapBps);
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

    function _enforceEarmarkWindowCap(bytes32 earmark, uint256 amount, uint256 basis, uint16 capBps) internal {
        _resetEarmarkWindowIfExpired(earmark);
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
}
