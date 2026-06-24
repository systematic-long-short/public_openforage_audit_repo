// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FinalizeDelayProfile} from "../FinalizeDelayProfile.sol";
import {IBlocklist} from "../interfaces/IBlocklist.sol";

interface IUSDCTreasuryReturnPort {
    function recordPrincipalReturnUSDC(uint256 amount) external;
    function returnPnLUSDC(uint256 vaultId, uint256 amount) external;
}

interface IRISKUSDVaultCustodyPort {
    function deployCapital(uint256 usdcAmount) external;
    function returnCapital(uint256 usdcAmount) external;
}

interface IRISKUSDVaultNAVPort {
    function recordCustodianNAV(uint256 vaultId, uint256 nav, uint256 lossNonce) external;
    function latestLossNonce() external view returns (uint256);
}

interface ICustodianRegistryAccountingPort {
    function HYPERLIQUID_CUSTODIAN_ID() external view returns (bytes32);
    function ROLE_EXECUTOR() external view returns (bytes32);
    function guardianModule() external view returns (address);
    function hasCustodianRole(bytes32 id, bytes32 role, address account) external view returns (bool);
    function paused() external view returns (bool);
    function recordDeployment(bytes32 id, uint256 amount) external;
    function recordReturn(bytes32 id, uint256 amount) external;
    function recordEmergencyReturn(bytes32 id, uint256 amount) external;
}

/// @title HLTradingBridge
/// @notice Slim Arbitrum-side HyperLiquid custodian for the target stack.
contract HLTradingBridge is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidBps();
    error UnauthorizedExecutor();
    error UnauthorizedKeeper();
    error UnauthorizedPause();
    error PerBlockDeployCapExceeded(uint256 provided, uint256 cap);
    error PerDayDeployCapExceeded(uint256 provided, uint256 cap);
    error ReturnPerCallCapExceeded(uint256 provided, uint256 cap);
    error ReturnPerDayCapExceeded(uint256 provided, uint256 cap);
    error NoPendingKeeper();
    error FinalizeDelayNotElapsed();
    error ProposalExpired();
    error StaleNAV();
    error ArrivalAmountMismatch();
    error RequestMismatch();
    error InvalidWithdrawalRecipient(address recipient);
    error WithdrawalIntentSourceMismatch(bytes32 provided, bytes32 expected);
    error WithdrawalIntentChainMismatch(uint64 provided, uint64 expected);
    error WithdrawalIntentAmountExceeded(uint256 provided, uint256 cap);
    error InsufficientReconciledLiquidity(uint256 requested, uint256 available);
    error WithdrawalIntentPending(bytes32 intentId);
    error DirectionFrozen();
    error BlockedAddress(address account);
    error BlocklistUnavailable(address blocklist);
    error RenounceOwnershipDisabled();
    error GuardianCannotLoosen();
    error UnauthorizedVault(address caller);

    uint256 public constant DAY_SECONDS = 1 days;
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public usdc;
    address public riskusdVault;
    address public usdcTreasury;
    address public custodianRegistry;
    address public guardianModule;

    uint256 internal _deployedPrincipal;
    uint256 internal _pendingDeployPrincipal;
    uint256 internal _appliedNAV;
    uint256 internal _lastNAVBookValue;
    uint256 internal _lastNAVRawValue;
    uint256 internal _lastNAVObservedAt;

    uint256 internal _perBlockDeployCap;
    uint256 internal _perDayDeployCap;
    uint256 internal _deployUsedThisBlock;
    uint256 internal _deployUsedBlockNum;
    uint256 internal _deployUsedThisDay;
    uint256 internal _deployUsedDayStart;

    uint16 internal _returnPerCallCapBps;
    uint16 internal _returnPerDayCapBps;
    uint256 internal _returnUsedThisDay;
    uint256 internal _returnUsedDayStart;

    address internal _keeper;
    address internal _pendingKeeper;
    uint256 internal _pendingKeeperProposedAt;
    address internal _custodianExecutor;
    address internal _blocklist;
    bool internal _directionalFreeze;

    struct WithdrawalIntent {
        uint256 amount;
        address recipient;
        bytes32 sourceAccount;
        uint64 chainSelector;
        bool consumed;
        bool exists;
        uint256 balanceCheckpoint;
    }

    struct RouteConfig {
        address coldAccount;
        bytes32 hyperliquidSourceAccount;
        uint64 withdrawalChainSelector;
    }

    mapping(bytes32 => WithdrawalIntent) internal _withdrawalIntents;
    address public coldAccount;
    bytes32 public hyperliquidSourceAccount;
    uint64 public withdrawalChainSelector;
    uint256 internal _withdrawalIntentUsedThisDay;
    uint256 internal _withdrawalIntentUsedDayStart;
    uint256 internal _reconciledReturnLiquidity;
    bytes32 internal _openWithdrawalIntentId;

    event DeployedToHyperLiquid(uint256 usdcE6, uint256 deployedPrincipal);
    event NAVPosted(uint256 indexed vaultId, uint256 bookValue, uint256 rawNav, uint256 appliedNav, uint256 observedAt);
    event PrincipalReturned(uint256 usdcE6, uint256 deployedPrincipal);
    event PnLReturned(uint256 indexed vaultId, uint256 usdcE6);
    event WithdrawalIntentRequested(
        bytes32 indexed intentId, uint256 amount, address indexed recipient, bytes32 sourceAccount, uint64 chainSelector
    );
    event WithdrawalArrivalReconciled(bytes32 indexed intentId, uint256 amount);
    event DirectionalFreezeSet(bool frozen);
    event KeeperProposed(address indexed currentKeeper, address indexed pendingKeeper);
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);
    event PendingKeeperCancelled(address indexed pendingKeeper);
    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);
    event PerBlockDeployCapSet(uint256 oldCap, uint256 newCap);
    event PerDayDeployCapSet(uint256 oldCap, uint256 newCap);
    event ReturnCapitalCapsSet(uint16 oldPerCallBps, uint16 newPerCallBps, uint16 oldPerDayBps, uint16 newPerDayBps);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address usdc_,
        address riskusdVault_,
        address usdcTreasury_,
        address custodianRegistry_,
        address initialOwner_,
        address keeper_,
        address executor_,
        address guardianModule_,
        RouteConfig calldata route
    ) external initializer {
        if (
            usdc_ == address(0) || riskusdVault_ == address(0) || usdcTreasury_ == address(0)
                || custodianRegistry_ == address(0) || initialOwner_ == address(0) || keeper_ == address(0)
                || executor_ == address(0) || guardianModule_ == address(0) || route.coldAccount == address(0)
                || route.hyperliquidSourceAccount == bytes32(0) || route.withdrawalChainSelector == 0
        ) revert ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        usdc = usdc_;
        riskusdVault = riskusdVault_;
        usdcTreasury = usdcTreasury_;
        custodianRegistry = custodianRegistry_;
        guardianModule = guardianModule_;
        coldAccount = route.coldAccount;
        hyperliquidSourceAccount = route.hyperliquidSourceAccount;
        withdrawalChainSelector = route.withdrawalChainSelector;
        _keeper = keeper_;
        _custodianExecutor = executor_;
        _perBlockDeployCap = 1_000_000e6;
        _perDayDeployCap = 5_000_000e6;
        _deployUsedDayStart = block.timestamp;
        _returnPerCallCapBps = 1_000;
        _returnPerDayCapBps = 1_000;
        _returnUsedDayStart = block.timestamp;
        _withdrawalIntentUsedDayStart = block.timestamp;
    }

    function deployToHyperLiquid(uint256 usdcE6) external whenNotPaused nonReentrant {
        _requireExecutor();
        if (_directionalFreeze) revert DirectionFrozen();
        if (usdcE6 == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(coldAccount);
        _enforceDeployCaps(usdcE6);
        _recordCustodianDeployment(usdcE6);

        IERC20 token = IERC20(usdc);
        uint256 balanceBefore = token.balanceOf(address(this));
        IRISKUSDVaultCustodyPort(riskusdVault).deployCapital(usdcE6);
        if (token.balanceOf(address(this)) - balanceBefore != usdcE6) revert ArrivalAmountMismatch();
        token.safeTransfer(coldAccount, usdcE6);

        _deployedPrincipal += usdcE6;
        _pendingDeployPrincipal += usdcE6;

        emit DeployedToHyperLiquid(usdcE6, _deployedPrincipal);
    }

    function postNAV(uint256 vaultId, uint256 bookValue, uint256 rawNav, uint256 observedAt)
        external
        whenNotPaused
        nonReentrant
    {
        _requireKeeper();
        _requireNotBlocked(msg.sender);

        uint256 applied = _normalizeCustodianNAV(bookValue, rawNav, observedAt, _appliedNAV, true);
        _lastNAVBookValue = bookValue;
        _lastNAVRawValue = rawNav;
        _lastNAVObservedAt = observedAt;
        _appliedNAV = applied;
        if (_pendingDeployPrincipal != 0 && applied >= _deployedPrincipal) {
            _pendingDeployPrincipal = 0;
        }
        uint256 lossNonce = 0;
        if (applied < bookValue) {
            lossNonce = IRISKUSDVaultNAVPort(riskusdVault).latestLossNonce() + 1;
        }
        IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, lossNonce);

        emit NAVPosted(vaultId, bookValue, rawNav, applied, observedAt);
    }

    function returnPrincipalUSDC(uint256 amount) external nonReentrant {
        _requireExecutor();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(riskusdVault);
        _enforceReturnCaps(amount);

        if (amount >= _deployedPrincipal) {
            _deployedPrincipal = 0;
        } else {
            _deployedPrincipal -= amount;
        }
        if (amount >= _pendingDeployPrincipal) {
            _pendingDeployPrincipal = 0;
        } else {
            _pendingDeployPrincipal -= amount;
        }

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        _recordCustodianReturn(amount);
        token.forceApprove(riskusdVault, amount);
        IRISKUSDVaultCustodyPort(riskusdVault).returnCapital(amount);
        token.forceApprove(riskusdVault, 0);
        IUSDCTreasuryReturnPort(usdcTreasury).recordPrincipalReturnUSDC(amount);
        emit PrincipalReturned(amount, _deployedPrincipal);
    }

    function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant {
        _requireExecutor();
        if (amount == 0) revert ZeroAmount();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(address(this));
        _requireNotBlocked(usdcTreasury);
        _enforceReturnCaps(amount);

        IERC20 token = IERC20(usdc);
        _consumeReconciledLiquidity(token, amount);
        token.forceApprove(usdcTreasury, amount);
        IUSDCTreasuryReturnPort(usdcTreasury).returnPnLUSDC(vaultId, amount);
        token.forceApprove(usdcTreasury, 0);
        emit PnLReturned(vaultId, amount);
    }

    function requestWithdrawalIntent(uint256 amount, address recipient, bytes32 sourceAccount, uint64 chainSelector)
        external
        nonReentrant
        returns (bytes32 intentId)
    {
        _requireExecutor();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _requireNotBlocked(msg.sender);
        _requireNotBlocked(recipient);
        if (recipient != address(this)) revert InvalidWithdrawalRecipient(recipient);
        if (sourceAccount != hyperliquidSourceAccount) {
            revert WithdrawalIntentSourceMismatch(sourceAccount, hyperliquidSourceAccount);
        }
        if (chainSelector != withdrawalChainSelector) {
            revert WithdrawalIntentChainMismatch(chainSelector, withdrawalChainSelector);
        }
        _enforceWithdrawalIntentCaps(amount);

        intentId = keccak256(
            abi.encode(address(this), msg.sender, amount, recipient, sourceAccount, chainSelector, block.number)
        );
        bytes32 openIntentId = _openWithdrawalIntentId;
        if (openIntentId != bytes32(0)) revert WithdrawalIntentPending(openIntentId);
        uint256 balanceCheckpoint = _unreconciledBalance(IERC20(usdc).balanceOf(address(this)));
        _withdrawalIntents[intentId] = WithdrawalIntent({
            amount: amount,
            recipient: recipient,
            sourceAccount: sourceAccount,
            chainSelector: chainSelector,
            consumed: false,
            exists: true,
            balanceCheckpoint: balanceCheckpoint
        });
        _openWithdrawalIntentId = intentId;

        emit WithdrawalIntentRequested(intentId, amount, recipient, sourceAccount, chainSelector);
    }

    function reconcileWithdrawalArrival(bytes32 intentId, uint256 arrivedAmount) external nonReentrant {
        _requireKeeper();
        _requireNotBlocked(msg.sender);
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        if (!intent.exists || intent.consumed) revert RequestMismatch();
        if (intentId != _openWithdrawalIntentId) revert RequestMismatch();
        if (arrivedAmount != intent.amount) revert ArrivalAmountMismatch();

        uint256 currentBalance = IERC20(usdc).balanceOf(address(this));
        uint256 unreconciledBalance = _unreconciledBalance(currentBalance);
        if (unreconciledBalance < intent.balanceCheckpoint + arrivedAmount) revert ArrivalAmountMismatch();

        _reconciledReturnLiquidity += arrivedAmount;
        intent.consumed = true;
        _openWithdrawalIntentId = bytes32(0);
        emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
    }

    function setDirectionalFreeze(bool frozen) external {
        _requireGuardianModuleOrOwner();
        if (msg.sender == _liveGuardianModule() && !frozen) revert GuardianCannotLoosen();
        _setDirectionalFreeze(frozen);
    }

    function freezeAttestations() external {
        _requireGuardianModuleOrOwner();
        _setDirectionalFreeze(true);
    }

    function pause() external {
        if (msg.sender != _liveGuardianModule() && msg.sender != owner()) revert UnauthorizedPause();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function proposeKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        _pendingKeeper = newKeeper;
        _pendingKeeperProposedAt = block.timestamp;
        emit KeeperProposed(_keeper, newKeeper);
    }

    function finalizeKeeper() external onlyOwner {
        address newKeeper = _pendingKeeper;
        if (newKeeper == address(0)) revert NoPendingKeeper();
        if (block.timestamp < _pendingKeeperProposedAt + _finalizeDelay()) revert FinalizeDelayNotElapsed();
        if (block.timestamp > _pendingKeeperProposedAt + PROPOSAL_EXPIRY) revert ProposalExpired();

        address oldKeeper = _keeper;
        _keeper = newKeeper;
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
        emit KeeperSet(oldKeeper, newKeeper);
    }

    function cancelPendingKeeper() external onlyOwner {
        address pending = _pendingKeeper;
        if (pending == address(0)) revert NoPendingKeeper();
        _pendingKeeper = address(0);
        _pendingKeeperProposedAt = 0;
        emit PendingKeeperCancelled(pending);
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address old = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(old, blocklist_);
    }

    function setPerBlockDeployCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerBlockDeployCap(newCap);
    }

    function setPerDayDeployCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert ZeroAmount();
        _setPerDayDeployCap(newCap);
    }

    function setReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) external onlyOwner {
        _validateReturnCapitalCaps(perCallBps, perDayBps);
        _setReturnCapitalCaps(perCallBps, perDayBps);
    }

    function shrinkPerBlockDeployCap(uint256 newCap) external {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perBlockDeployCap) revert GuardianCannotLoosen();
        _setPerBlockDeployCap(newCap);
    }

    function shrinkPerDayDeployCap(uint256 newCap) external {
        _requireGuardianModuleOrOwner();
        if (newCap == 0) revert ZeroAmount();
        if (newCap > _perDayDeployCap) revert GuardianCannotLoosen();
        _setPerDayDeployCap(newCap);
    }

    function tightenReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) external {
        _requireGuardianModuleOrOwner();
        _validateReturnCapitalCaps(perCallBps, perDayBps);
        if (perCallBps > _returnPerCallCapBps || perDayBps > _returnPerDayCapBps) revert GuardianCannotLoosen();
        _setReturnCapitalCaps(perCallBps, perDayBps);
    }

    function _validateReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) internal pure {
        if (perCallBps == 0 || perDayBps == 0 || perCallBps > BPS_DENOMINATOR || perDayBps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
    }

    function _setDirectionalFreeze(bool frozen) internal {
        _directionalFreeze = frozen;
        emit DirectionalFreezeSet(frozen);
    }

    function _setPerBlockDeployCap(uint256 newCap) internal {
        uint256 old = _perBlockDeployCap;
        _perBlockDeployCap = newCap;
        emit PerBlockDeployCapSet(old, newCap);
    }

    function _setPerDayDeployCap(uint256 newCap) internal {
        uint256 old = _perDayDeployCap;
        _perDayDeployCap = newCap;
        emit PerDayDeployCapSet(old, newCap);
    }

    function _setReturnCapitalCaps(uint16 perCallBps, uint16 perDayBps) internal {
        uint16 oldPerCall = _returnPerCallCapBps;
        uint16 oldPerDay = _returnPerDayCapBps;
        _returnPerCallCapBps = perCallBps;
        _returnPerDayCapBps = perDayBps;
        emit ReturnCapitalCapsSet(oldPerCall, perCallBps, oldPerDay, perDayBps);
    }

    function _requireGuardianModuleOrOwner() internal view {
        if (msg.sender != _liveGuardianModule() && msg.sender != owner()) revert UnauthorizedPause();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function appliedNAV() external view returns (uint256) {
        return _appliedNAV;
    }

    function lastNAVBookValue() external view returns (uint256) {
        return _lastNAVBookValue;
    }

    function lastNAVRawValue() external view returns (uint256) {
        return _lastNAVRawValue;
    }

    function lastNAVObservedAt() external view returns (uint256) {
        return _lastNAVObservedAt;
    }

    function deployedPrincipal() external view returns (uint256) {
        return _deployedPrincipal;
    }

    function pendingDeployPrincipal() external view returns (uint256) {
        return _pendingDeployPrincipal;
    }

    function perBlockDeployCap() external view returns (uint256) {
        return _perBlockDeployCap;
    }

    function perDayDeployCap() external view returns (uint256) {
        return _perDayDeployCap;
    }

    function returnPerCallCapBps() public view returns (uint16) {
        return _returnPerCallCapBps;
    }

    function returnPerDayCapBps() public view returns (uint16) {
        return _returnPerDayCapBps;
    }

    function registryReturnPerCallCapBps() external view returns (uint16) {
        return _returnPerCallCapBps;
    }

    function registryReturnPerDayCapBps() external view returns (uint16) {
        return _returnPerDayCapBps;
    }

    function keeper() external view returns (address) {
        return _keeper;
    }

    function pendingKeeper() external view returns (address) {
        return _pendingKeeper;
    }

    function pendingKeeperProposedAt() external view returns (uint256) {
        return _pendingKeeperProposedAt;
    }

    function custodianExecutor() external view returns (address) {
        return _custodianExecutor;
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function directionalFreeze() external view returns (bool) {
        return _directionalFreeze;
    }

    function tierShareActionsPaused() external view returns (bool) {
        return _directionalFreeze;
    }

    function wiringChangeDelay() external view returns (uint256) {
        return _finalizeDelay();
    }

    function withdrawalIntentConsumed(bytes32 intentId) external view returns (bool) {
        return _withdrawalIntents[intentId].consumed;
    }

    function openWithdrawalIntentId() external view returns (bytes32) {
        return _openWithdrawalIntentId;
    }

    function withdrawalIntent(bytes32 intentId)
        external
        view
        returns (
            uint256 amount,
            address recipient,
            bytes32 sourceAccount,
            uint64 chainSelector,
            bool consumed,
            bool exists
        )
    {
        WithdrawalIntent storage intent = _withdrawalIntents[intentId];
        return
            (
                intent.amount,
                intent.recipient,
                intent.sourceAccount,
                intent.chainSelector,
                intent.consumed,
                intent.exists
            );
    }

    function reconciledReturnLiquidity() external view returns (uint256) {
        return _reconciledReturnLiquidity;
    }

    function normalizeManualCustodianNAV(uint256, uint256 nav, uint256 lossNonce)
        external
        view
        returns (bool, uint256)
    {
        if (msg.sender != riskusdVault) revert UnauthorizedVault(msg.sender);
        if (lossNonce != 0) {
            if (_directionalFreeze && nav > _appliedNAV) revert DirectionFrozen();
            return (true, nav);
        }

        uint256 observedAt = _lastNAVObservedAt;
        uint256 bookValue = _lastNAVBookValue;

        uint256 normalizedNav = _normalizeCustodianNAV(bookValue, nav, observedAt, _appliedNAV, false);
        return (true, normalizedNav);
    }

    function _normalizeCustodianNAV(
        uint256 bookValue,
        uint256 rawNav,
        uint256 observedAt,
        uint256 currentAppliedNAV,
        bool allowZeroBaseline
    ) internal view returns (uint256) {
        if (!allowZeroBaseline && (observedAt == 0 || bookValue == 0)) revert StaleNAV();
        if (block.timestamp > observedAt + DAY_SECONDS) revert StaleNAV();
        if (_directionalFreeze && rawNav > currentAppliedNAV) revert DirectionFrozen();

        uint256 maxUp = bookValue + (bookValue * 1_000 / BPS_DENOMINATOR);
        return rawNav > maxUp ? maxUp : rawNav;
    }

    function _enforceDeployCaps(uint256 usdcE6) internal {
        if (block.number != _deployUsedBlockNum) {
            _deployUsedBlockNum = block.number;
            _deployUsedThisBlock = 0;
        }
        uint256 remainingBlock =
            _perBlockDeployCap > _deployUsedThisBlock ? _perBlockDeployCap - _deployUsedThisBlock : 0;
        if (usdcE6 > remainingBlock) revert PerBlockDeployCapExceeded(usdcE6, remainingBlock);
        _deployUsedThisBlock += usdcE6;

        if (block.timestamp >= _deployUsedDayStart + DAY_SECONDS) {
            _deployUsedDayStart = block.timestamp;
            _deployUsedThisDay = 0;
        }
        uint256 remainingDay = _perDayDeployCap > _deployUsedThisDay ? _perDayDeployCap - _deployUsedThisDay : 0;
        if (usdcE6 > remainingDay) revert PerDayDeployCapExceeded(usdcE6, remainingDay);
        _deployUsedThisDay += usdcE6;
    }

    function _recordCustodianDeployment(uint256 usdcE6) internal {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        registry.recordDeployment(registry.HYPERLIQUID_CUSTODIAN_ID(), usdcE6);
    }

    function _recordCustodianReturn(uint256 usdcE6) internal {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        bytes32 id = registry.HYPERLIQUID_CUSTODIAN_ID();
        if (registry.paused()) {
            registry.recordEmergencyReturn(id, usdcE6);
        } else {
            registry.recordReturn(id, usdcE6);
        }
    }

    function _enforceReturnCaps(uint256 amount) internal {
        uint256 principalBase = _deployedPrincipal;
        uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
        if (amount > perCallCap) revert ReturnPerCallCapExceeded(amount, perCallCap);

        if (block.timestamp >= _returnUsedDayStart + DAY_SECONDS) {
            _returnUsedDayStart = block.timestamp;
            _returnUsedThisDay = 0;
        }
        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
        uint256 remainingDay = perDayCap > _returnUsedThisDay ? perDayCap - _returnUsedThisDay : 0;
        if (amount > remainingDay) revert ReturnPerDayCapExceeded(amount, remainingDay);
        _returnUsedThisDay += amount;
    }

    function _enforceWithdrawalIntentCaps(uint256 amount) internal {
        uint256 principalBase = _deployedPrincipal;
        uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
        if (amount > perCallCap) revert WithdrawalIntentAmountExceeded(amount, perCallCap);

        if (block.timestamp >= _withdrawalIntentUsedDayStart + DAY_SECONDS) {
            _withdrawalIntentUsedDayStart = block.timestamp;
            _withdrawalIntentUsedThisDay = 0;
        }
        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
        uint256 remainingDay = perDayCap > _withdrawalIntentUsedThisDay ? perDayCap - _withdrawalIntentUsedThisDay : 0;
        if (amount > remainingDay) revert WithdrawalIntentAmountExceeded(amount, remainingDay);
        _withdrawalIntentUsedThisDay += amount;
    }

    function _consumeReconciledLiquidity(IERC20 token, uint256 amount) internal {
        uint256 available = _reconciledReturnLiquidity;
        if (amount > available) revert InsufficientReconciledLiquidity(amount, available);
        uint256 currentBalance = token.balanceOf(address(this));
        if (amount > currentBalance) revert InsufficientReconciledLiquidity(amount, currentBalance);
        _reconciledReturnLiquidity = available - amount;
    }

    function _unreconciledBalance(uint256 currentBalance) internal view returns (uint256) {
        uint256 reconciled = _reconciledReturnLiquidity;
        return currentBalance > reconciled ? currentBalance - reconciled : 0;
    }

    function _requireExecutor() internal view {
        ICustodianRegistryAccountingPort registry = ICustodianRegistryAccountingPort(custodianRegistry);
        if (!registry.hasCustodianRole(registry.HYPERLIQUID_CUSTODIAN_ID(), registry.ROLE_EXECUTOR(), msg.sender)) {
            revert UnauthorizedExecutor();
        }
    }

    function _requireKeeper() internal view {
        if (msg.sender != _keeper) revert UnauthorizedKeeper();
    }

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        try IBlocklist(blocklist_).isBlocked(account) returns (bool blocked) {
            if (blocked) revert BlockedAddress(account);
        } catch {
            revert BlocklistUnavailable(blocklist_);
        }
    }

    function _liveGuardianModule() internal view returns (address) {
        address liveGuardianModule = ICustodianRegistryAccountingPort(custodianRegistry).guardianModule();
        if (liveGuardianModule == address(0)) revert UnauthorizedPause();
        return liveGuardianModule;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
