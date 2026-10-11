// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./AllowlistGatedUpgradeable.sol";
import "./DelegatingVestingWallet.sol";
import "./IForageGovernorPause.sol";
import "./interfaces/IAllowlist.sol";
import "./interfaces/IAllowlistSystemRegistrar.sol";
import {ForageTokenRotationStatus} from "./modules/ForageTokenStateModule.sol";

interface IFORAGETreasuryBlocklist {
    function isBlocked(address account) external view returns (bool);
}

interface IFORAGETreasuryAllowlistState {
    function allowlist() external view returns (address);

    function blocklistRotationStatus() external view returns (ForageTokenRotationStatus memory);
}

contract FORAGETreasuryModule {
    error DelegateCallRequired();
    error Unauthorized();
    error UnauthorizedDistributor();
    error CapNotShrunk();
    error ForageTokenAllowlistStateUnavailable(address forageToken);
    error AllowlistNotForageTokenProvider(address candidate, address activeAllowlist, address pendingAllowlist);
    error PartnershipSystemRegistrarNotReady(address allowlist, address treasury);

    event DistributorAccepted(address indexed oldDistributor, address indexed newDistributor);
    event DistributorDailyCapUpdated(uint256 oldCap, uint256 newCap);

    address private immutable _self;

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == _self) revert DelegateCallRequired();
        _;
    }

    function verifyClaim(
        bytes32[] calldata proof,
        bytes32 root,
        address treasury,
        bytes32 lane,
        uint256 roundId,
        address account,
        uint256 amount
    ) external pure returns (bool) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(treasury, lane, roundId, account, amount))));
        return MerkleProof.verify(proof, root, leaf);
    }

    function requireTokenAllowlistProvider(address forageToken_, address candidate, bool allowInitialBinding)
        external
        view
    {
        if (candidate == address(0)) revert IAllowlist.AllowlistUnavailable();
        (address activeAllowlist, address pendingAllowlist) = _forageTokenAllowlistProviders(forageToken_);
        if (candidate == activeAllowlist || candidate == pendingAllowlist) return;
        if (allowInitialBinding && activeAllowlist == address(0) && pendingAllowlist == address(0)) return;
        revert AllowlistNotForageTokenProvider(candidate, activeAllowlist, pendingAllowlist);
    }

    function requireSystemRegistrarReady(address allowlist_, address treasury) external view {
        if (allowlist_.code.length == 0) revert PartnershipSystemRegistrarNotReady(allowlist_, treasury);
        bool ready;
        try IAllowlistSystemRegistrar(allowlist_).isSystemRegistrar(treasury) returns (bool registered) {
            ready = registered;
        } catch {
            revert PartnershipSystemRegistrarNotReady(allowlist_, treasury);
        }
        if (!ready) revert PartnershipSystemRegistrarNotReady(allowlist_, treasury);
    }

    function _forageTokenAllowlistProviders(address forageToken_)
        private
        view
        returns (address activeAllowlist, address pendingAllowlist)
    {
        if (forageToken_.code.length == 0) revert ForageTokenAllowlistStateUnavailable(forageToken_);
        IFORAGETreasuryAllowlistState tokenState = IFORAGETreasuryAllowlistState(forageToken_);
        try tokenState.allowlist() returns (address currentAllowlist) {
            activeAllowlist = currentAllowlist;
        } catch {
            revert ForageTokenAllowlistStateUnavailable(forageToken_);
        }
        try tokenState.blocklistRotationStatus() returns (ForageTokenRotationStatus memory status) {
            if (status.allowlistReindexActive) pendingAllowlist = status.pendingAllowlist;
        } catch {
            revert ForageTokenAllowlistStateUnavailable(forageToken_);
        }
    }

    function acceptDistributor(address allowlist_, uint256 pendingSlot, uint256 distributorSlot)
        external
        onlyDelegateCall
    {
        address pending;
        address oldDistributor;
        assembly {
            pending := sload(pendingSlot)
            oldDistributor := sload(distributorSlot)
        }
        if (msg.sender != pending) revert UnauthorizedDistributor();
        bool isSystem;
        try IAllowlist(allowlist_).isSystemAccount(msg.sender) returns (bool systemAccount) {
            isSystem = systemAccount;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!isSystem) revert UnauthorizedDistributor();
        assembly {
            sstore(distributorSlot, caller())
            sstore(pendingSlot, 0)
        }
        emit DistributorAccepted(oldDistributor, msg.sender);
    }

    function shrinkDistributorDailyCap(uint256 storageSlot, uint256 newCap, address owner_, address governor_)
        external
        onlyDelegateCall
    {
        if (msg.sender != owner_ && msg.sender != IForageGovernorPause(governor_).guardianModule()) {
            revert Unauthorized();
        }
        uint256 oldCap;
        assembly {
            oldCap := sload(storageSlot)
        }
        if (newCap >= oldCap) revert CapNotShrunk();
        assembly {
            sstore(storageSlot, newCap)
        }
        emit DistributorDailyCapUpdated(oldCap, newCap);
    }
}

/// @title FORAGETreasury
/// @notice Consolidated FORAGE distribution treasury for agent, depositor, and partnership programmes.
contract FORAGETreasury is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    AllowlistGatedUpgradeable
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRoot();
    error InvalidProof();
    error AlreadyClaimed();
    error ProgramCapExceeded();
    error ClaimCooldownActive();
    error RoundExpired();
    error RoundNotExpired();
    error Unauthorized();
    error BlockedRecipient();
    error BlocklistUnavailable(address blocklist);
    error RenounceOwnershipDisabled();
    error RoundAlreadyPublished(uint256 roundId);
    error UnauthorizedDistributor();
    error CapNotShrunk();
    error FreshTreasuryStateRequired(uint256 layoutVersion);
    error FreshInitializationOnExistingState(uint256 layoutVersion, address forageToken);
    error ForageTokenAllowlistStateUnavailable(address forageToken);
    error AllowlistNotForageTokenProvider(address candidate, address activeAllowlist, address pendingAllowlist);
    error VestingWalletNotRecorded(address wallet);
    error VestingWalletAllowlistMismatch(address wallet, address expected, address actual);
    error PartnershipSystemRegistrarNotReady(address allowlist, address treasury);

    uint256 public constant AGENT_PROGRAM_CAP = 30_000_000e18;
    uint256 public constant DEPOSITOR_PROGRAM_CAP = 10_000_000e18;
    uint256 public constant PARTNERSHIP_PROGRAM_CAP = 40_000_000e18;
    uint256 public constant AGENT_CLAIM_COOLDOWN = 1 days;
    bytes32 public constant AGENT_REWARD_LANE = keccak256("FORAGE_AGENT_REWARD");
    bytes32 public constant DEPOSITOR_REWARD_LANE = keccak256("FORAGE_DEPOSITOR_REWARD");
    uint256 private constant FRESH_LAYOUT_VERSION = 2;

    struct Round {
        bytes32 root;
        uint256 totalAmount;
        uint64 deadline;
        uint256 claimedAmount;
        bool swept;
    }

    IERC20 private _forageToken;
    address public blocklist;

    mapping(uint256 => Round) public agentRounds;
    mapping(uint256 => Round) public depositorRounds;
    mapping(uint256 => mapping(address => bool)) public agentClaimed;
    mapping(uint256 => mapping(address => bool)) public depositorClaimed;
    mapping(address => uint256) public lastAgentClaimAt;
    uint256 public totalAgentDistributed;
    uint256 public totalDepositorDistributed;
    uint256 public totalPartnershipDistributed;

    address private _distributor;
    address private _pendingDistributor;
    uint256 private _distributorDailyCap;
    uint256 private _distributorUsedToday;
    uint256 private _distributorDayStart;
    uint256 private _freshLayoutVersion;
    mapping(address => bool) public isTreasuryVestingWallet;
    address private _forageGovernor;
    FORAGETreasuryModule private immutable _capModule;

    uint256[32] private __gap;

    event AgentRootPublished(uint256 indexed roundId, bytes32 root, uint256 totalAmount, uint64 deadline);
    event DepositorRootPublished(uint256 indexed roundId, bytes32 root, uint256 totalAmount, uint64 deadline);
    event AgentClaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event DepositorClaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event PartnershipDistributed(address indexed beneficiary, address indexed wallet, uint256 amount);
    event RoundSwept(uint256 indexed roundId, address indexed recipient, uint256 amount);
    event RoundSweptV2(bytes32 indexed lane, uint256 indexed roundId, address indexed recipient, uint256 amount);
    event BlocklistSet(address indexed blocklist);
    event VestingWalletAllowlistForwarded(
        address indexed wallet, address indexed previousAllowlist, address indexed nextAllowlist
    );
    event DistributorProposed(address indexed currentDistributor, address indexed pendingDistributor);
    event DistributorAccepted(address indexed oldDistributor, address indexed newDistributor);
    event DistributorDailyCapUpdated(uint256 oldCap, uint256 newCap);

    constructor() {
        _disableInitializers();
        _capModule = new FORAGETreasuryModule();
    }

    modifier onlyDuringConstructionBeforeInitialization() {
        if (address(this).code.length != 0) revert InvalidInitialization();
        _;
    }

    modifier freshOnly() {
        if (_freshLayoutVersion != FRESH_LAYOUT_VERSION) {
            revert FreshTreasuryStateRequired(_freshLayoutVersion);
        }
        _;
    }

    function initialize(address forageToken_, address owner_, address forageGovernor_)
        external
        onlyDuringConstructionBeforeInitialization
        initializer
    {
        if (_freshLayoutVersion != 0 || address(_forageToken) != address(0)) {
            revert FreshInitializationOnExistingState(_freshLayoutVersion, address(_forageToken));
        }
        if (forageToken_ == address(0) || owner_ == address(0) || forageGovernor_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        _forageToken = IERC20(forageToken_);
        _forageGovernor = forageGovernor_;
        _distributorDailyCap = 1_000_000e18;
        _freshLayoutVersion = FRESH_LAYOUT_VERSION;
    }

    function setBlocklist(address blocklist_) external freshOnly onlyAllowedCaller onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        blocklist = blocklist_;
        emit BlocklistSet(blocklist_);
    }

    function setAllowlist(address allowlist_) external freshOnly onlyOwner {
        bool initialBinding = allowlist() == address(0);
        _requireTokenAllowlistProvider(allowlist_, initialBinding);
        _transitionAllowlist(allowlist_);
        _requireTokenAllowlistProvider(allowlist(), initialBinding);
    }

    function publishAgentRoot(uint256 roundId, bytes32 root, uint256 totalAmount, uint64 deadline)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalAmount > AGENT_PROGRAM_CAP) revert ProgramCapExceeded();
        if (agentRounds[roundId].root != bytes32(0)) revert RoundAlreadyPublished(roundId);
        agentRounds[roundId] = Round(root, totalAmount, deadline, 0, false);
        emit AgentRootPublished(roundId, root, totalAmount, deadline);
    }

    function publishDepositorRoot(uint256 roundId, bytes32 root, uint256 totalAmount, uint64 deadline)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
    {
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalAmount > DEPOSITOR_PROGRAM_CAP) revert ProgramCapExceeded();
        if (depositorRounds[roundId].root != bytes32(0)) revert RoundAlreadyPublished(roundId);
        depositorRounds[roundId] = Round(root, totalAmount, deadline, 0, false);
        emit DepositorRootPublished(roundId, root, totalAmount, deadline);
    }

    function claimAgent(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        external
        freshOnly
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != account) revert Unauthorized();
        _requireAgentBeneficiary(account);
        uint256 lastClaimAt = lastAgentClaimAt[account];
        if (lastClaimAt != 0 && block.timestamp < lastClaimAt + AGENT_CLAIM_COOLDOWN) {
            revert ClaimCooldownActive();
        }
        Round storage round = agentRounds[roundId];
        if (totalAgentDistributed + amount > AGENT_PROGRAM_CAP) revert ProgramCapExceeded();
        totalAgentDistributed += amount;
        _claim(round, agentClaimed[roundId][account], AGENT_REWARD_LANE, roundId, account, amount, proof);
        agentClaimed[roundId][account] = true;
        lastAgentClaimAt[account] = block.timestamp;
        emit AgentClaimed(roundId, account, amount);
    }

    function claimDepositor(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        external
        freshOnly
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != account) revert Unauthorized();
        if (_isBlocked(account)) revert BlockedRecipient();
        Round storage round = depositorRounds[roundId];
        if (totalDepositorDistributed + amount > DEPOSITOR_PROGRAM_CAP) revert ProgramCapExceeded();
        totalDepositorDistributed += amount;
        _claim(round, depositorClaimed[roundId][account], DEPOSITOR_REWARD_LANE, roundId, account, amount, proof);
        depositorClaimed[roundId][account] = true;
        emit DepositorClaimed(roundId, account, amount);
    }

    function claimAgentFor(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        external
        freshOnly
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != _distributor) revert Unauthorized();
        if (_isBlocked(msg.sender)) revert BlockedRecipient();
        if (_isBlocked(account)) revert BlockedRecipient();
        uint256 lastClaimAt = lastAgentClaimAt[account];
        if (lastClaimAt != 0 && block.timestamp < lastClaimAt + AGENT_CLAIM_COOLDOWN) {
            revert ClaimCooldownActive();
        }
        Round storage round = agentRounds[roundId];
        if (totalAgentDistributed + amount > AGENT_PROGRAM_CAP) revert ProgramCapExceeded();
        _consumeDistributorDailyCap(amount);
        totalAgentDistributed += amount;
        _claim(round, agentClaimed[roundId][account], AGENT_REWARD_LANE, roundId, account, amount, proof);
        agentClaimed[roundId][account] = true;
        lastAgentClaimAt[account] = block.timestamp;
        emit AgentClaimed(roundId, account, amount);
    }

    function distributePartnership(
        address beneficiary,
        address delegatee,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint64 cliff
    ) external freshOnly onlyAllowedCaller onlyOwner nonReentrant returns (address wallet) {
        if (beneficiary == address(0) || delegatee == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (totalPartnershipDistributed + amount > PARTNERSHIP_PROGRAM_CAP) revert ProgramCapExceeded();
        if (_isBlocked(beneficiary) || _isBlocked(delegatee)) revert BlockedRecipient();

        address distributionAllowlist = allowlist();
        _requireTokenAllowlistProvider(distributionAllowlist, false);
        FORAGETreasuryModule(address(_capModule)).requireSystemRegistrarReady(distributionAllowlist, address(this));
        wallet = address(
            new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this), distributionAllowlist)
        );
        isTreasuryVestingWallet[wallet] = true;
        IAllowlistSystemRegistrar(distributionAllowlist).setSystemAccount(wallet, true);
        _requireTokenAllowlistProvider(allowlist(), false);
        address registeredAllowlist = DelegatingVestingWallet(wallet).allowlist();
        if (registeredAllowlist != distributionAllowlist) {
            revert VestingWalletAllowlistMismatch(wallet, distributionAllowlist, registeredAllowlist);
        }
        DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
        DelegatingVestingWallet(wallet).setBlocklist(blocklist);
        _forageToken.safeTransfer(wallet, amount);
        DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
        DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
        totalPartnershipDistributed += amount;
        emit PartnershipDistributed(beneficiary, wallet, amount);
    }

    function setVestingWalletAllowlist(address wallet, address candidateAllowlist)
        external
        freshOnly
        onlyAllowedCaller
        onlyOwner
        nonReentrant
    {
        if (!isTreasuryVestingWallet[wallet] || wallet.code.length == 0) revert VestingWalletNotRecorded(wallet);
        _requireTokenAllowlistProvider(allowlist(), false);
        _requireTokenAllowlistProvider(candidateAllowlist, false);
        DelegatingVestingWallet vestingWallet = DelegatingVestingWallet(wallet);
        address previousAllowlist = vestingWallet.allowlist();
        if (previousAllowlist == candidateAllowlist) return;
        vestingWallet.setAllowlist(candidateAllowlist);
        _requireTokenAllowlistProvider(allowlist(), false);
        _requireTokenAllowlistProvider(candidateAllowlist, false);
        address updatedAllowlist = vestingWallet.allowlist();
        if (updatedAllowlist != candidateAllowlist) {
            revert VestingWalletAllowlistMismatch(wallet, candidateAllowlist, updatedAllowlist);
        }
        emit VestingWalletAllowlistForwarded(wallet, previousAllowlist, updatedAllowlist);
    }

    function sweepExpiredAgentRound(uint256 roundId, address recipient)
        external
        freshOnly
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != owner()) revert Unauthorized();
        Round storage round = agentRounds[roundId];
        uint256 remaining = round.totalAmount - round.claimedAmount;
        _sweep(round, roundId, recipient);
        emit RoundSweptV2(AGENT_REWARD_LANE, roundId, recipient, remaining);
    }

    function sweepExpiredDepositorRound(uint256 roundId, address recipient)
        external
        freshOnly
        onlyAllowedCaller
        nonReentrant
    {
        if (msg.sender != owner()) revert Unauthorized();
        Round storage round = depositorRounds[roundId];
        uint256 remaining = round.totalAmount - round.claimedAmount;
        _sweep(round, roundId, recipient);
        emit RoundSweptV2(DEPOSITOR_REWARD_LANE, roundId, recipient, remaining);
    }

    function setDistributor(address distributor_) external freshOnly onlyAllowedCaller onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        _pendingDistributor = distributor_;
        emit DistributorProposed(_distributor, distributor_);
    }

    function acceptDistributor() external freshOnly onlyAllowedCaller {
        uint256 pendingSlot;
        uint256 distributorSlot;
        assembly {
            pendingSlot := _pendingDistributor.slot
            distributorSlot := _distributor.slot
        }
        _delegateCapModule(
            abi.encodeCall(FORAGETreasuryModule.acceptDistributor, (allowlist(), pendingSlot, distributorSlot))
        );
    }

    function shrinkDistributorDailyCap(uint256 newCap) external freshOnly onlyAllowedCaller {
        uint256 storageSlot;
        assembly {
            storageSlot := _distributorDailyCap.slot
        }
        _delegateCapModule(
            abi.encodeCall(
                FORAGETreasuryModule.shrinkDistributorDailyCap, (storageSlot, newCap, owner(), _forageGovernor)
            )
        );
    }

    function distributor() external view returns (address) {
        return _distributor;
    }

    function pendingDistributor() external view returns (address) {
        return _pendingDistributor;
    }

    function distributorDailyCap() external view returns (uint256) {
        return _distributorDailyCap;
    }

    function forageToken() external view returns (address) {
        return address(_forageToken);
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        freshOnly
        onlyAllowedCaller
    {
        super.upgradeToAndCall(newImplementation, data);
    }

    function transferOwnership(address newOwner) public override freshOnly onlyAllowedCaller {
        super.transferOwnership(newOwner);
    }

    function acceptOwnership() public override freshOnly onlyAllowedCaller {
        super.acceptOwnership();
    }

    function _consumeDistributorDailyCap(uint256 amount) internal {
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        if (_distributorDayStart != dayStart) {
            _distributorDayStart = dayStart;
            _distributorUsedToday = 0;
        }
        if (_distributorUsedToday + amount > _distributorDailyCap) revert ProgramCapExceeded();
        _distributorUsedToday += amount;
    }

    function _delegateCapModule(bytes memory data) private {
        (bool ok, bytes memory result) = address(_capModule).delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _claim(
        Round storage round,
        bool alreadyClaimed,
        bytes32 lane,
        uint256 roundId,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        if (alreadyClaimed) revert AlreadyClaimed();
        if (round.root == bytes32(0)) revert InvalidRoot();
        if (block.timestamp > round.deadline) revert RoundExpired();
        if (
            !FORAGETreasuryModule(address(_capModule)).verifyClaim(
                proof, round.root, address(this), lane, roundId, account, amount
            )
        ) revert InvalidProof();
        if (round.claimedAmount + amount > round.totalAmount) revert ProgramCapExceeded();
        round.claimedAmount += amount;
        _forageToken.safeTransfer(account, amount);
    }

    function _sweep(Round storage round, uint256 roundId, address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        if (round.root == bytes32(0)) revert InvalidRoot();
        if (block.timestamp <= round.deadline) revert RoundNotExpired();
        if (round.swept) revert AlreadyClaimed();
        round.swept = true;
        uint256 remaining = round.totalAmount - round.claimedAmount;
        if (remaining > 0) {
            _forageToken.safeTransfer(recipient, remaining);
        }
        emit RoundSwept(roundId, recipient, remaining);
    }

    function _isBlocked(address account) internal view returns (bool) {
        address blocklist_ = blocklist;
        if (blocklist_ == address(0)) revert BlocklistUnavailable(blocklist_);
        try IFORAGETreasuryBlocklist(blocklist_).isBlocked(account) returns (bool blocked) {
            return blocked;
        } catch {
            revert BlocklistUnavailable(blocklist_);
        }
    }

    function _requireAgentBeneficiary(address account) private view {
        address allowlist_ = allowlist();
        if (allowlist_ == address(0)) revert IAllowlist.AllowlistUnavailable();
        bool allowed;
        try IAllowlist(allowlist_).isAllowed(account) returns (bool result) {
            allowed = result;
        } catch {
            revert IAllowlist.AllowlistUnavailable();
        }
        if (!allowed) revert IAllowlist.CallerNotAllowed(account);
        if (_isBlocked(account)) revert BlockedRecipient();
    }

    function _requireTokenAllowlistProvider(address candidateAllowlist, bool allowInitialBinding) private view {
        FORAGETreasuryModule(address(_capModule)).requireTokenAllowlistProvider(
            address(_forageToken), candidateAllowlist, allowInitialBinding
        );
    }

    function _authorizeUpgrade(address) internal override freshOnly onlyOwner {}
}
