// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../../../../src/FinalizeDelayProfile.sol";
import "../../../../src/interfaces/IBlocklist.sol";
import "../../../../src/interfaces/IVaultRegistry.sol";

contract LegacyStakingQueueWithoutEntryBounds is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    FinalizeDelayProfile
{
    using SafeERC20 for IERC20;

    struct LegacyQueueEntry {
        address depositor;
        uint256 riskusdAmount;
        uint8 tier;
        uint256 entryTimestamp;
        bool processed;
        bool cancelled;
        bool priority;
    }

    struct TierDepositCap {
        uint256 baseCap;
        uint256 proposedCap;
        uint256 proposedAt;
        bool configured;
    }

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTier();
    error VaultIdAlreadySet();
    error VaultIdNotSet();
    error VaultNotActive();

    IERC20 private _riskusd;
    address private _forage;
    address[4] private _tierVaults;
    address private _vaultRegistry;
    uint256 private _vaultId;
    address private _forageGovernor;
    uint256 private _nextQueueId;
    uint256 private _totalQueuedRiskusd;
    uint256 private _foragePriceUsd;

    mapping(uint256 => LegacyQueueEntry) private _queueEntries;
    mapping(uint8 => uint256[]) private _tierPriorityQueue;
    mapping(uint8 => uint256[]) private _tierStandardQueue;
    mapping(uint8 => uint256) private _tierPriorityHead;
    mapping(uint8 => uint256) private _tierStandardHead;

    uint256 private _priorityMultiplier;
    mapping(address => uint256) private _priorityRiskusdQueued;

    mapping(uint256 => uint256) private _forageLockedPerEntry;

    uint256 private _lastPriceUpdate;

    address internal _pendingForageGovernor;
    uint256 internal _pendingForageGovernorProposedAt;

    uint8 private _priceMode;
    address private _foragePriceOracle;
    uint8 private _foragePriceOracleDecimals;
    uint256 private _oraclePriceMaxStaleness;
    uint256 private _pendingForagePriceUsd;
    uint256 private _pendingForagePriceUsdProposedAt;
    bool private _pendingForagePriceUsdExists;
    uint8 private _pendingForagePriceMode;
    uint256 private _pendingForagePriceModeProposedAt;
    bool private _pendingForagePriceModeExists;
    address private _pendingForagePriceOracle;
    uint256 private _pendingOraclePriceMaxStaleness;
    uint8 private _pendingForagePriceOracleDecimals;
    uint256 private _pendingForagePriceOracleProposedAt;
    mapping(uint8 => TierDepositCap) private _tierDepositCaps;
    address internal _blocklist;

    uint256[33] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address riskusd_,
        address forage_,
        address[4] calldata tierVaults_,
        address vaultRegistry_,
        address initialOwner_
    ) external initializer {
        if (riskusd_ == address(0)) revert ZeroAddress();
        if (forage_ == address(0)) revert ZeroAddress();
        if (vaultRegistry_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();
        for (uint256 i; i < 4;) {
            if (tierVaults_[i] == address(0)) revert ZeroAddress();
            unchecked {
                ++i;
            }
        }

        __Ownable_init(initialOwner_);
        __Pausable_init();

        _riskusd = IERC20(riskusd_);
        _forage = forage_;
        _vaultRegistry = vaultRegistry_;
        for (uint256 i; i < 4;) {
            _tierVaults[i] = tierVaults_[i];
            unchecked {
                ++i;
            }
        }
        _nextQueueId = 1;
    }

    function setVaultId(uint256 vaultId_) external onlyOwner {
        if (_vaultId != 0) revert VaultIdAlreadySet();
        if (vaultId_ == 0) revert ZeroAmount();
        _vaultId = vaultId_;
    }

    function joinQueue(uint256 riskusdAmount, uint8 tier) external whenNotPaused nonReentrant {
        if (riskusdAmount == 0) revert ZeroAmount();
        if (tier >= 4) revert InvalidTier();
        if (_vaultId == 0) revert VaultIdNotSet();

        VaultConfig memory config = IVaultRegistry(_vaultRegistry).getVault(_vaultId);
        if (config.status != VaultStatus.Active) revert VaultNotActive();

        _riskusd.safeTransferFrom(msg.sender, address(this), riskusdAmount);

        uint256 queueId = _nextQueueId;
        unchecked {
            _nextQueueId = queueId + 1;
        }

        _queueEntries[queueId] = LegacyQueueEntry({
            depositor: msg.sender,
            riskusdAmount: riskusdAmount,
            tier: tier,
            entryTimestamp: block.timestamp,
            processed: false,
            cancelled: false,
            priority: false
        });
        _tierStandardQueue[tier].push(queueId);
        _totalQueuedRiskusd += riskusdAmount;
    }

    function nextQueueId() external view returns (uint256) {
        return _nextQueueId;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

contract LegacyForageTokenWithoutDelegateSourceTracking is
    Initializable,
    ERC20Upgradeable,
    Ownable2StepUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    error ZeroAddress();
    error BlockedAddress(address account);

    event BlocklistSet(address indexed oldBlocklist, address indexed newBlocklist);

    uint256 public constant TEAM_VESTING_ALLOCATION = 20_000_000 * 10 ** 18;
    uint256 public constant AGENT_ALLOCATION = 30_000_000 * 10 ** 18;
    uint256 public constant DEPOSITOR_ALLOCATION = 10_000_000 * 10 ** 18;
    uint256 public constant PARTNERSHIP_ALLOCATION = 40_000_000 * 10 ** 18;
    uint256 public constant FORAGE_TREASURY_ALLOCATION =
        AGENT_ALLOCATION + DEPOSITOR_ALLOCATION + PARTNERSHIP_ALLOCATION;

    mapping(address => bool) internal _authorizedBurners;
    mapping(address => bool) internal _authorizedLockers;
    mapping(address => uint256) internal _lockedBalances;
    mapping(address => bool) private _lockExempt;
    mapping(address => mapping(address => uint256)) internal _lockerBalances;
    mapping(address => EnumerableSet.AddressSet) private _accountLockers;
    address internal _blocklist;

    uint256[47] private __gap;

    constructor() {
        _disableInitializers();
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function initialize(address teamVestingAddress_, address forageTreasuryAddress_, address initialOwner_)
        external
        initializer
    {
        if (teamVestingAddress_ == address(0)) revert ZeroAddress();
        if (forageTreasuryAddress_ == address(0)) revert ZeroAddress();
        if (initialOwner_ == address(0)) revert ZeroAddress();

        __ERC20_init("Forage Token", "FORAGE");
        __EIP712_init("Forage Token", "1");
        __ERC20Votes_init();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        _mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);
        _mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);
    }

    function delegate(address delegatee) public override {
        address account = _msgSender();
        _requireNotBlocked(account);
        if (delegatee != address(0)) {
            _requireNotBlocked(delegatee);
        }
        super.delegate(delegatee);
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        address oldBlocklist = _blocklist;
        _blocklist = blocklist_;
        emit BlocklistSet(oldBlocklist, blocklist_);
    }

    function blocklist() external view returns (address) {
        return _blocklist;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (from != address(0)) {
            _requireNotBlocked(from);
        }
        if (to != address(0)) {
            _requireNotBlocked(to);
        }
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _requireNotBlocked(address account) internal view {
        address blocklist_ = _blocklist;
        if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
            revert BlockedAddress(account);
        }
    }
}
