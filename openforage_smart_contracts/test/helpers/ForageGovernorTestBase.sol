// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "../../src/ForageGovernor.sol";
import "../../src/GuardianModule.sol";
import "../mocks/MockForageTokenVotes.sol";
import "./MockPausable.sol";
import "./RevertTarget.sol";

/// @title ForageGovernorTestBase - Shared setup for all ForageGovernor tests
/// @dev Deploys MockForageTokenVotes, TimelockController, ForageGovernor via UUPS proxy,
///      and GuardianModule via proxy. Sets up test accounts with varying token balances
///      and guardian permissions.
abstract contract ForageGovernorTestBase is Test {
    ForageGovernor public governor;
    ForageGovernor public implementation;
    GuardianModule public guardianModuleContract;
    GuardianModule public guardianModuleImpl;
    MockForageTokenVotes public token;
    TimelockController public timelock;
    MockPausable public mockPausable;
    RevertTarget public revertTarget;

    // ── Test accounts ─────────────────────────────────────────────────
    address public deployer;
    address public proposer; // 1% = 1M tokens, delegated to self
    address public voter1;
    address public voter2;
    address public voter3;
    address public voter4;
    address public voter5;
    address public guardian1; // permissions = 14 (CANCEL+EMERGENCY+PROPOSE, OF-19-001: no PAUSE+CANCEL)
    address public guardian2; // permissions = 1 (PAUSE only)
    address public guardian3; // permissions = 2 (CANCEL only)
    address public guardian4; // permissions = 4 (EMERGENCY only)
    address public nonGuardian;
    address public attacker;

    // ── Constants ─────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 100_000_000 * 1e18;
    // OF-001: Two-phase governance parameters. Launch: votingDelay=0, votingPeriod=3600 (1h), timelockDelay=0.
    // Production (June 2026): votingDelay=86400 (1d), votingPeriod=432000 (5d), timelockDelay=691200 (8d).
    // Tests use launch-phase values; votingPeriod keeps the one-hour launch minimum.
    uint48 public constant DEFAULT_VOTING_DELAY = 0; // Launch phase: 0 seconds (OF-001)
    uint32 public constant DEFAULT_VOTING_PERIOD = 3_600; // Launch phase: 1 hour (OF-001)
    uint256 public constant DEFAULT_QUORUM_BPS = 400; // 4%
    uint256 public constant DEFAULT_THRESHOLD_BPS = 100; // 1%
    uint256 public constant DEFAULT_MAX_ACTIVE = 10;
    uint256 public constant TIMELOCK_MIN_DELAY = 0; // Launch phase: 0 seconds
    // Production-phase constants for transition tests
    uint48 public constant PRODUCTION_VOTING_DELAY = 86_400; // 1 day
    uint32 public constant PRODUCTION_VOTING_PERIOD = 432_000; // 5 days
    uint256 public constant PRODUCTION_TIMELOCK_DELAY = 691_200; // 8 days

    // Derived constants
    uint256 public constant PROPOSER_TOKENS = TOTAL_SUPPLY * DEFAULT_THRESHOLD_BPS / 10_000; // 1M tokens
    uint256 public constant QUORUM_TOKENS = TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10_000; // 4M tokens

    function setUp() public virtual {
        // OF-001: Warp past timestamp 1 — OZ TimelockController uses timestamp=1
        // as the _DONE_TIMESTAMP sentinel. With delay=0 (launch phase), scheduling
        // at block.timestamp=1 would collide with the sentinel, making the operation
        // appear "Done" before execution. Warping to t=100 avoids this edge case.
        vm.warp(100);

        // ── Create accounts ───────────────────────────────────────────
        deployer = makeAddr("deployer");
        proposer = makeAddr("proposer");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        voter3 = makeAddr("voter3");
        voter4 = makeAddr("voter4");
        voter5 = makeAddr("voter5");
        guardian1 = makeAddr("guardian1");
        guardian2 = makeAddr("guardian2");
        guardian3 = makeAddr("guardian3");
        guardian4 = makeAddr("guardian4");
        nonGuardian = makeAddr("nonGuardian");
        attacker = makeAddr("attacker");

        vm.startPrank(deployer);

        // ── Deploy MockForageTokenVotes ────────────────────────────────
        token = new MockForageTokenVotes();

        // ── Mint and distribute tokens (100M total) ───────────────────
        // proposer: 1M (1% = proposal threshold)
        token.mint(proposer, PROPOSER_TOKENS);
        // voter1: 5M (enough for quorum by itself + margin)
        token.mint(voter1, 5_000_000 * 1e18);
        // voter2: 3M
        token.mint(voter2, 3_000_000 * 1e18);
        // voter3: 2M
        token.mint(voter3, 2_000_000 * 1e18);
        // voter4: 1M
        token.mint(voter4, 1_000_000 * 1e18);
        // voter5: 500K
        token.mint(voter5, 500_000 * 1e18);
        // deployer keeps the rest for supply (to make totalSupply = 100M)
        uint256 distributed = PROPOSER_TOKENS + 5_000_000 * 1e18 + 3_000_000 * 1e18 + 2_000_000 * 1e18 + 1_000_000
            * 1e18 + 500_000 * 1e18;
        token.mint(deployer, TOTAL_SUPPLY - distributed);

        vm.stopPrank();

        // ── Delegate to self (activate voting power) ──────────────────
        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);
        vm.prank(voter4);
        token.delegate(voter4);
        vm.prank(voter5);
        token.delegate(voter5);

        // ── Deploy TimelockController ─────────────────────────────────
        // ForageGovernor will be added as sole proposer after governor deployment.
        // For now, deployer is temp proposer. Executor = address(0) (open execution).
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution

        vm.prank(deployer);
        timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));

        // ── Deploy ForageGovernor impl + proxy (no guardian module yet) ──
        implementation = new ForageGovernor();

        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(timelock),
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0) // guardian module set after deployment
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        governor = ForageGovernor(payable(address(proxy)));

        // ── Deploy GuardianModule impl + proxy ──────────────────────────
        guardianModuleImpl = new GuardianModule();

        address[] memory guardians = new address[](4);
        uint256[] memory permissions = new uint256[](4);
        guardians[0] = guardian1;
        permissions[0] = 14; // CANCEL | EMERGENCY | CAN_PROPOSE (OF-19-001: PAUSE+CANCEL forbidden)
        guardians[1] = guardian2;
        permissions[1] = 1; // PAUSE only
        guardians[2] = guardian3;
        permissions[2] = 2; // CANCEL only
        guardians[3] = guardian4;
        permissions[3] = 4; // EMERGENCY only

        bytes memory moduleInitData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), address(timelock), guardians, permissions));
        ERC1967Proxy moduleProxy = new ERC1967Proxy(address(guardianModuleImpl), moduleInitData);
        guardianModuleContract = GuardianModule(address(moduleProxy));

        // ── Configure TimelockController: grant governor PROPOSER_ROLE ──
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
        bytes32 CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

        // Grant governor PROPOSER_ROLE
        vm.prank(deployer);
        timelock.schedule(
            address(timelock),
            0,
            abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(governor))),
            bytes32(0),
            keccak256("grant_proposer"),
            TIMELOCK_MIN_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
        timelock.execute(
            address(timelock),
            0,
            abi.encodeCall(timelock.grantRole, (PROPOSER_ROLE, address(governor))),
            bytes32(0),
            keccak256("grant_proposer")
        );

        // Grant governor CANCELLER_ROLE
        vm.prank(deployer);
        timelock.schedule(
            address(timelock),
            0,
            abi.encodeCall(timelock.grantRole, (CANCELLER_ROLE, address(governor))),
            bytes32(0),
            keccak256("grant_canceller"),
            TIMELOCK_MIN_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
        timelock.execute(
            address(timelock),
            0,
            abi.encodeCall(timelock.grantRole, (CANCELLER_ROLE, address(governor))),
            bytes32(0),
            keccak256("grant_canceller")
        );

        // Revoke deployer's PROPOSER_ROLE
        vm.prank(deployer);
        timelock.schedule(
            address(timelock),
            0,
            abi.encodeCall(timelock.revokeRole, (PROPOSER_ROLE, deployer)),
            bytes32(0),
            keccak256("revoke_proposer"),
            TIMELOCK_MIN_DELAY
        );
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
        timelock.execute(
            address(timelock),
            0,
            abi.encodeCall(timelock.revokeRole, (PROPOSER_ROLE, deployer)),
            bytes32(0),
            keccak256("revoke_proposer")
        );

        // ── Set guardian module on governor (via timelock) ──────────────
        {
            bytes memory setModuleData =
                abi.encodeCall(ForageGovernor.setGuardianModule, (address(guardianModuleContract)));
            bytes32 setModuleSalt = keccak256(setModuleData);
            vm.prank(address(governor));
            timelock.schedule(address(governor), 0, setModuleData, bytes32(0), setModuleSalt, TIMELOCK_MIN_DELAY);
            vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
            timelock.execute(address(governor), 0, setModuleData, bytes32(0), setModuleSalt);
        }

        // ── Deploy mock contracts for guardian tests ──────────────────
        mockPausable = new MockPausable(address(timelock), address(governor));
        mockPausable.setGuardianModule(address(guardianModuleContract));
        revertTarget = new RevertTarget();

        // ── OF-M01: Whitelist mockPausable as a valid guardian pause target ──
        // Now done on GuardianModule via timelock
        {
            bytes memory whitelistData =
                abi.encodeWithSignature("setPausableTarget(address,bool)", address(mockPausable), true);
            bytes32 whitelistSalt = keccak256(whitelistData);
            vm.prank(address(timelock));
            // Direct call since timelock is the authorized caller on GuardianModule
            guardianModuleContract.setPausableTarget(address(mockPausable), true);
        }

        // ── Roll forward one block so voting power checkpoints are queryable ──
        vm.roll(block.number + 1);
    }

    // ── Helper: create a simple proposal ──────────────────────────────
    /// @dev Creates a proposal targeting governor.setMaxActiveProposals(10).
    ///      Returns the proposalId.
    function _createProposal() internal returns (uint256) {
        return _createProposalFrom(proposer);
    }

    /// @dev Creates a proposal from a specific account.
    function _createProposalFrom(address from) internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        string memory description = string(abi.encodePacked("Proposal #", vm.toString(block.number)));

        vm.prank(from);
        return governor.propose(targets, values, calldatas, description);
    }

    /// @dev Creates a proposal with specific parameters.
    function _createProposalWithParams(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256) {
        vm.prank(proposer);
        return governor.propose(targets, values, calldatas, description);
    }

    // ── Helper: pass a proposal through voting ────────────────────────
    /// @dev Advances past votingDelay, casts enough For votes to pass quorum,
    ///      and advances past votingPeriod. Proposal ends in Succeeded state.
    function _passProposal(uint256 proposalId) internal {
        // Advance past voting delay
        vm.roll(block.number + governor.votingDelay() + 1);

        // Cast For votes from voter1 (5M > 4M quorum)
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For

        // Advance past voting period
        vm.roll(block.number + governor.votingPeriod() + 1);
    }

    // ── Helper: queue and execute a proposal ──────────────────────────
    /// @dev Queues a Succeeded proposal and advances past the timelock delay,
    ///      then executes it.
    function _queueAndExecute(uint256 proposalId) internal {
        // Get proposal details for queue/execute
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        bytes32 descriptionHash = keccak256(bytes(string(abi.encodePacked("Proposal #", vm.toString(block.number)))));

        // Queue
        governor.queue(targets, values, calldatas, descriptionHash);

        // Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    /// @dev Queue and execute with specific parameters
    function _queueAndExecuteWithParams(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal {
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    // ── Helper: build proposal params ─────────────────────────────────
    /// @dev Returns standard proposal parameters (target=governor, setMaxActiveProposals(10))
    function _standardProposalParams()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
    }
}
