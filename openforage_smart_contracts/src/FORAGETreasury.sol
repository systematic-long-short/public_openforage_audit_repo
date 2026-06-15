// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./DelegatingVestingWallet.sol";

interface IFORAGETreasuryBlocklist {
    function isBlocked(address account) external view returns (bool);
}

/// @title FORAGETreasury
/// @notice Consolidated FORAGE distribution treasury for agent, depositor, and partnership programmes.
contract FORAGETreasury is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard {
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

    uint256 public constant AGENT_PROGRAM_CAP = 30_000_000e18;
    uint256 public constant DEPOSITOR_PROGRAM_CAP = 10_000_000e18;
    uint256 public constant PARTNERSHIP_PROGRAM_CAP = 40_000_000e18;
    uint256 public constant AGENT_CLAIM_COOLDOWN = 1 days;

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

    uint256[40] private __gap;

    event AgentRootPublished(uint256 indexed roundId, bytes32 root, uint256 totalAmount, uint64 deadline);
    event DepositorRootPublished(uint256 indexed roundId, bytes32 root, uint256 totalAmount, uint64 deadline);
    event AgentClaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event DepositorClaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event PartnershipDistributed(address indexed beneficiary, address indexed wallet, uint256 amount);
    event RoundSwept(uint256 indexed roundId, address indexed recipient, uint256 amount);
    event BlocklistSet(address indexed blocklist);

    constructor() {
        _disableInitializers();
    }

    function initialize(address forageToken_, address owner_) external initializer {
        if (forageToken_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        _forageToken = IERC20(forageToken_);
    }

    function setBlocklist(address blocklist_) external onlyOwner {
        if (blocklist_ == address(0)) revert ZeroAddress();
        blocklist = blocklist_;
        emit BlocklistSet(blocklist_);
    }

    function publishAgentRoot(uint256 roundId, bytes32 root, uint256 totalAmount, uint64 deadline) external onlyOwner {
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalAmount > AGENT_PROGRAM_CAP) revert ProgramCapExceeded();
        agentRounds[roundId] = Round(root, totalAmount, deadline, 0, false);
        emit AgentRootPublished(roundId, root, totalAmount, deadline);
    }

    function publishDepositorRoot(uint256 roundId, bytes32 root, uint256 totalAmount, uint64 deadline)
        external
        onlyOwner
    {
        if (root == bytes32(0)) revert InvalidRoot();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalAmount > DEPOSITOR_PROGRAM_CAP) revert ProgramCapExceeded();
        depositorRounds[roundId] = Round(root, totalAmount, deadline, 0, false);
        emit DepositorRootPublished(roundId, root, totalAmount, deadline);
    }

    function claimAgent(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (msg.sender != account) revert Unauthorized();
        if (_isBlocked(account)) revert BlockedRecipient();
        uint256 lastClaimAt = lastAgentClaimAt[account];
        if (lastClaimAt != 0 && block.timestamp < lastClaimAt + AGENT_CLAIM_COOLDOWN) {
            revert ClaimCooldownActive();
        }
        Round storage round = agentRounds[roundId];
        if (totalAgentDistributed + amount > AGENT_PROGRAM_CAP) revert ProgramCapExceeded();
        totalAgentDistributed += amount;
        _claim(round, agentClaimed[roundId][account], roundId, account, amount, proof);
        agentClaimed[roundId][account] = true;
        lastAgentClaimAt[account] = block.timestamp;
        emit AgentClaimed(roundId, account, amount);
    }

    function claimDepositor(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (msg.sender != account) revert Unauthorized();
        if (_isBlocked(account)) revert BlockedRecipient();
        Round storage round = depositorRounds[roundId];
        if (totalDepositorDistributed + amount > DEPOSITOR_PROGRAM_CAP) revert ProgramCapExceeded();
        totalDepositorDistributed += amount;
        _claim(round, depositorClaimed[roundId][account], roundId, account, amount, proof);
        depositorClaimed[roundId][account] = true;
        emit DepositorClaimed(roundId, account, amount);
    }

    function distributePartnership(
        address beneficiary,
        address delegatee,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint64 cliff
    ) external onlyOwner nonReentrant returns (address wallet) {
        if (beneficiary == address(0) || delegatee == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (totalPartnershipDistributed + amount > PARTNERSHIP_PROGRAM_CAP) revert ProgramCapExceeded();
        if (_isBlocked(beneficiary) || _isBlocked(delegatee)) revert BlockedRecipient();

        wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
        DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
        DelegatingVestingWallet(wallet).setBlocklist(blocklist);
        _forageToken.safeTransfer(wallet, amount);
        DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
        DelegatingVestingWallet(wallet).setForageToken(address(_forageToken));
        totalPartnershipDistributed += amount;
        emit PartnershipDistributed(beneficiary, wallet, amount);
    }

    function sweepExpiredAgentRound(uint256 roundId, address recipient) external nonReentrant {
        if (msg.sender != owner()) revert Unauthorized();
        _sweep(agentRounds[roundId], roundId, recipient);
    }

    function sweepExpiredDepositorRound(uint256 roundId, address recipient) external nonReentrant {
        if (msg.sender != owner()) revert Unauthorized();
        _sweep(depositorRounds[roundId], roundId, recipient);
    }

    function forageToken() external view returns (address) {
        return address(_forageToken);
    }

    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _claim(
        Round storage round,
        bool alreadyClaimed,
        uint256 roundId,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        if (alreadyClaimed) revert AlreadyClaimed();
        if (round.root == bytes32(0)) revert InvalidRoot();
        if (block.timestamp > round.deadline) revert RoundExpired();
        if (!MerkleProof.verify(proof, round.root, _leaf(roundId, account, amount))) revert InvalidProof();
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

    function _leaf(uint256 roundId, address account, uint256 amount) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(address(this), roundId, account, amount))));
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

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
