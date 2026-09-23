// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
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

    uint256[28] private __gap;

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
            uint256 depositorClaim = profit * 7_000 / 10_000;
            recognizedDepositorClaim[vaultId] += depositorClaim;
            // Tier splits are read from the canonical registry record, not restated here (P42).
            uint16[4] memory yieldSplits = IVaultRegistry(vaultRegistry).getVault(vaultId).yieldSplitsBps;
            for (uint8 i; i < 4; ++i) {
                _tierAccountingValue[vaultId][i] += profit * uint256(yieldSplits[i]) / 10_000;
            }
        } else {
            uint256 loss = SignedMath.abs(amount);
            for (uint8 i; i < 4; ++i) {
                _tierAccountingAdjustmentBps[vaultId][i] = -1_000;
            }
            retainedBufferLossAbsorbed[vaultId] += loss / 10;
        }
        emit PnLRecognized(vaultId, amount);
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
        IRISKUSDVaultLossSettlement(riskusdVault).burnForLoss(vaultId, riskusdAmount);
    }

    function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount)
        external
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
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
        uint256 vaultTopUp = claim > fundedClaim ? claim - fundedClaim : 0;
        if (vaultTopUp > amount - foundation - retained) {
            vaultTopUp = amount - foundation - retained;
        }
        uint256 agent = amount - foundation - retained - vaultTopUp;
        fundedDepositorClaim[vaultId] = fundedClaim + vaultTopUp;
        pendingVaultTopUp[vaultId] += vaultTopUp;

        earmarkBalance[EARMARK_FOUNDATION] += foundation;
        earmarkBalance[EARMARK_PROTOCOL_RETAINED] += retained;
        earmarkBalance[EARMARK_VAULT_TOP_UP] += vaultTopUp;
        earmarkBalance[EARMARK_AGENT_PAY] += agent;
        emit PnLReturned(vaultId, amount);
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
        } else if (earmark == EARMARK_VAULT_TOP_UP) {
            if (recipient != riskusdVault) revert DestinationNotAllowed();
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
