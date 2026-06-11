// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/FORAGETreasury.sol";
import "../src/Blocklist.sol";
import "../src/ForageToken.sol";
import "../src/DelegatingVestingWallet.sol";
import "./helpers/MerkleTreeHelper.sol";
import "./mocks/MockForageTokenSimple.sol";

contract RevertingFORAGETreasuryBlocklist {
    function isBlocked(address) external pure returns (bool) {
        revert("blocklist unavailable");
    }
}

contract FORAGETreasury_TargetPrograms is Test {
    using MerkleTreeHelper for address[];

    uint256 internal constant TOTAL_SUPPLY = 100_000_000e18;
    uint256 internal constant TREASURY_ALLOCATION = 80_000_000e18;
    uint256 internal constant TEAM_ALLOCATION = 20_000_000e18;

    address internal owner = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal teamVesting = makeAddr("team-vesting");
    address internal agent = makeAddr("agent");
    address internal secondAgent = makeAddr("second-agent");
    address internal depositor = makeAddr("depositor");
    address internal secondDepositor = makeAddr("second-depositor");
    address internal partner = makeAddr("partner");
    address internal partnerDelegate = makeAddr("partner-delegate");

    MockForageTokenSimple internal forage;
    FORAGETreasury internal treasury;
    Blocklist internal blocklist;

    function setUp() public {
        forage = new MockForageTokenSimple();
        Blocklist blocklistImplementation = new Blocklist();
        bytes memory blocklistInit = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        blocklist = Blocklist(address(new ERC1967Proxy(address(blocklistImplementation), blocklistInit)));

        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        treasury = FORAGETreasury(address(proxy));

        forage.mint(address(treasury), TREASURY_ALLOCATION);

        vm.prank(owner);
        treasury.setBlocklist(address(blocklist));
    }

    function test_TSCGB_A12_launchMintTargetsOnlyForageTreasuryAndTeam() public {
        address forageTreasury = makeAddr("forage-treasury");
        ForageToken implementation = new ForageToken();

        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address,address)", teamVesting, forageTreasury, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        ForageToken token = ForageToken(address(proxy));

        assertEq(token.totalSupply(), TOTAL_SUPPLY, "launch mint must remain 100M");
        assertEq(token.balanceOf(forageTreasury), TREASURY_ALLOCATION, "80M must fund FORAGETreasury");
        assertEq(token.balanceOf(teamVesting), TEAM_ALLOCATION, "20M must fund team vesting");
    }

    function test_TSCGB_A11_agentAndDepositorMerklesUseSeparateProgramBudgets() public {
        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory agentAmounts = new uint256[](1);
        agentAmounts[0] = 30e18;
        bytes32 agentRoot = MerkleTreeHelper.computeRoot(address(treasury), 1, agents, agentAmounts);
        bytes32[] memory agentProof =
            MerkleTreeHelper.getProof(address(treasury), 1, agents, agentAmounts, agent, 30e18);

        address[] memory depositors = new address[](1);
        depositors[0] = depositor;
        uint256[] memory depositorAmounts = new uint256[](1);
        depositorAmounts[0] = 10e18;
        bytes32 depositorRoot = MerkleTreeHelper.computeRoot(address(treasury), 2, depositors, depositorAmounts);
        bytes32[] memory depositorProof =
            MerkleTreeHelper.getProof(address(treasury), 2, depositors, depositorAmounts, depositor, 10e18);

        vm.startPrank(owner);
        treasury.publishAgentRoot(1, agentRoot, 30e18, uint64(block.timestamp + 30 days));
        treasury.publishDepositorRoot(2, depositorRoot, 10e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(agent);
        treasury.claimAgent(1, agent, 30e18, agentProof);
        vm.prank(depositor);
        treasury.claimDepositor(2, depositor, 10e18, depositorProof);

        assertEq(forage.balanceOf(agent), 30e18, "agent Merkle claim must pay from agent budget");
        assertEq(forage.balanceOf(depositor), 10e18, "depositor Merkle claim must pay from depositor budget");
        assertTrue(treasury.agentClaimed(1, agent), "agent claim flag must be program-specific");
        assertTrue(treasury.depositorClaimed(2, depositor), "depositor claim flag must be program-specific");
    }

    function test_TSCGB_A11_partnershipDistributionCreatesDelegatingVestingWallet() public {
        vm.prank(owner);
        address wallet = treasury.distributePartnership(
            partner,
            partnerDelegate,
            40e18,
            uint64(block.timestamp + 1 days),
            uint64(4 * 365 days),
            uint64(365 days)
        );

        assertEq(forage.balanceOf(wallet), 40e18, "partnership allocation must fund vesting wallet");
        assertEq(DelegatingVestingWallet(wallet).beneficiary(), partner, "vesting wallet beneficiary mismatch");
        assertEq(forage.delegates(wallet), partnerDelegate, "vesting wallet must delegate voting power");
    }

    function test_TSCGB_A11_agentBudgetCapAndCooldownAreEnforced() public {
        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 30_000_001e18;
        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), 3, agents, amounts);

        vm.prank(owner);
        vm.expectRevert(FORAGETreasury.ProgramCapExceeded.selector);
        treasury.publishAgentRoot(3, root, 30_000_001e18, uint64(block.timestamp + 30 days));

        amounts[0] = 1e18;
        root = MerkleTreeHelper.computeRoot(address(treasury), 4, agents, amounts);
        vm.prank(owner);
        treasury.publishAgentRoot(4, root, 1e18, uint64(block.timestamp + 30 days));

        bytes32[] memory proof = MerkleTreeHelper.getProof(address(treasury), 4, agents, amounts, agent, 1e18);
        vm.prank(agent);
        treasury.claimAgent(4, agent, 1e18, proof);

        vm.prank(owner);
        treasury.publishAgentRoot(5, root, 1e18, uint64(block.timestamp + 30 days));

        vm.prank(agent);
        vm.expectRevert(FORAGETreasury.ClaimCooldownActive.selector);
        treasury.claimAgent(5, agent, 1e18, proof);
    }

    function test_TSCGB_A11_agentAndDepositorClaimsCannotExceedRoundTotals() public {
        address[] memory agents = new address[](2);
        agents[0] = agent;
        agents[1] = secondAgent;
        uint256[] memory agentAmounts = new uint256[](2);
        agentAmounts[0] = 1e18;
        agentAmounts[1] = 1e18;
        bytes32 agentRoot = MerkleTreeHelper.computeRoot(address(treasury), 11, agents, agentAmounts);

        vm.prank(owner);
        treasury.publishAgentRoot(11, agentRoot, 1e18, uint64(block.timestamp + 30 days));

        bytes32[] memory agentProof =
            MerkleTreeHelper.getProof(address(treasury), 11, agents, agentAmounts, agent, 1e18);
        vm.prank(agent);
        treasury.claimAgent(11, agent, 1e18, agentProof);

        bytes32[] memory secondAgentProof =
            MerkleTreeHelper.getProof(address(treasury), 11, agents, agentAmounts, secondAgent, 1e18);
        vm.prank(secondAgent);
        vm.expectRevert(FORAGETreasury.ProgramCapExceeded.selector);
        treasury.claimAgent(11, secondAgent, 1e18, secondAgentProof);

        address[] memory depositors = new address[](2);
        depositors[0] = depositor;
        depositors[1] = secondDepositor;
        uint256[] memory depositorAmounts = new uint256[](2);
        depositorAmounts[0] = 1e18;
        depositorAmounts[1] = 1e18;
        bytes32 depositorRoot = MerkleTreeHelper.computeRoot(address(treasury), 12, depositors, depositorAmounts);

        vm.prank(owner);
        treasury.publishDepositorRoot(12, depositorRoot, 1e18, uint64(block.timestamp + 30 days));

        bytes32[] memory depositorProof =
            MerkleTreeHelper.getProof(address(treasury), 12, depositors, depositorAmounts, depositor, 1e18);
        vm.prank(depositor);
        treasury.claimDepositor(12, depositor, 1e18, depositorProof);

        bytes32[] memory secondDepositorProof =
            MerkleTreeHelper.getProof(address(treasury), 12, depositors, depositorAmounts, secondDepositor, 1e18);
        vm.prank(secondDepositor);
        vm.expectRevert(FORAGETreasury.ProgramCapExceeded.selector);
        treasury.claimDepositor(12, secondDepositor, 1e18, secondDepositorProof);
    }

    function test_TSCGB_A11_cumulativeAgentProgramCapIsEnforced() public {
        uint256 agentProgramCap = treasury.AGENT_PROGRAM_CAP();

        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory agentAmounts = new uint256[](1);
        agentAmounts[0] = agentProgramCap;
        bytes32 agentRoot = MerkleTreeHelper.computeRoot(address(treasury), 13, agents, agentAmounts);
        bytes32[] memory agentProof =
            MerkleTreeHelper.getProof(address(treasury), 13, agents, agentAmounts, agent, agentProgramCap);

        address[] memory secondAgents = new address[](1);
        secondAgents[0] = secondAgent;
        uint256[] memory secondAgentAmounts = new uint256[](1);
        secondAgentAmounts[0] = 1e18;
        bytes32 secondAgentRoot = MerkleTreeHelper.computeRoot(address(treasury), 14, secondAgents, secondAgentAmounts);
        bytes32[] memory secondAgentProof =
            MerkleTreeHelper.getProof(address(treasury), 14, secondAgents, secondAgentAmounts, secondAgent, 1e18);

        vm.startPrank(owner);
        treasury.publishAgentRoot(13, agentRoot, agentProgramCap, uint64(block.timestamp + 30 days));
        treasury.publishAgentRoot(14, secondAgentRoot, 1e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(agent);
        treasury.claimAgent(13, agent, agentProgramCap, agentProof);
        vm.prank(secondAgent);
        vm.expectRevert(FORAGETreasury.ProgramCapExceeded.selector);
        treasury.claimAgent(14, secondAgent, 1e18, secondAgentProof);
    }

    function test_TSCGB_A11_cumulativeDepositorProgramCapIsEnforced() public {
        uint256 depositorProgramCap = treasury.DEPOSITOR_PROGRAM_CAP();

        address[] memory depositors = new address[](1);
        depositors[0] = depositor;
        uint256[] memory depositorAmounts = new uint256[](1);
        depositorAmounts[0] = depositorProgramCap;
        bytes32 depositorRoot = MerkleTreeHelper.computeRoot(address(treasury), 15, depositors, depositorAmounts);
        bytes32[] memory depositorProof = MerkleTreeHelper.getProof(
            address(treasury), 15, depositors, depositorAmounts, depositor, depositorProgramCap
        );

        address[] memory secondDepositors = new address[](1);
        secondDepositors[0] = secondDepositor;
        uint256[] memory secondDepositorAmounts = new uint256[](1);
        secondDepositorAmounts[0] = 1e18;
        bytes32 secondDepositorRoot =
            MerkleTreeHelper.computeRoot(address(treasury), 16, secondDepositors, secondDepositorAmounts);
        bytes32[] memory secondDepositorProof = MerkleTreeHelper.getProof(
            address(treasury), 16, secondDepositors, secondDepositorAmounts, secondDepositor, 1e18
        );

        vm.startPrank(owner);
        treasury.publishDepositorRoot(15, depositorRoot, depositorProgramCap, uint64(block.timestamp + 30 days));
        treasury.publishDepositorRoot(16, secondDepositorRoot, 1e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(depositor);
        treasury.claimDepositor(15, depositor, depositorProgramCap, depositorProof);
        vm.prank(secondDepositor);
        vm.expectRevert(FORAGETreasury.ProgramCapExceeded.selector);
        treasury.claimDepositor(16, secondDepositor, 1e18, secondDepositorProof);
    }

    function test_TSCGB_A11_blockedClaimantDoesNotBlockOtherProgramClaims() public {
        address[] memory agents = new address[](2);
        agents[0] = agent;
        agents[1] = secondAgent;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18;
        amounts[1] = 20e18;
        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), 6, agents, amounts);

        vm.prank(owner);
        treasury.publishAgentRoot(6, root, 30e18, uint64(block.timestamp + 30 days));

        vm.prank(guardian);
        blocklist.blockAddress(agent);

        bytes32[] memory blockedProof = MerkleTreeHelper.getProof(address(treasury), 6, agents, amounts, agent, 10e18);
        vm.prank(agent);
        vm.expectRevert(FORAGETreasury.BlockedRecipient.selector);
        treasury.claimAgent(6, agent, 10e18, blockedProof);

        bytes32[] memory liveProof =
            MerkleTreeHelper.getProof(address(treasury), 6, agents, amounts, secondAgent, 20e18);
        vm.prank(secondAgent);
        treasury.claimAgent(6, secondAgent, 20e18, liveProof);

        assertEq(forage.balanceOf(secondAgent), 20e18, "unblocked claim must continue");
    }

    function test_TSCGB_A11_revertingBlocklistFailsLoudForAgentDepositorAndPartnership() public {
        RevertingFORAGETreasuryBlocklist revertingBlocklist = new RevertingFORAGETreasuryBlocklist();
        vm.prank(owner);
        treasury.setBlocklist(address(revertingBlocklist));

        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory agentAmounts = new uint256[](1);
        agentAmounts[0] = 1e18;
        bytes32 agentRoot = MerkleTreeHelper.computeRoot(address(treasury), 8, agents, agentAmounts);
        bytes32[] memory agentProof =
            MerkleTreeHelper.getProof(address(treasury), 8, agents, agentAmounts, agent, 1e18);

        address[] memory depositors = new address[](1);
        depositors[0] = depositor;
        uint256[] memory depositorAmounts = new uint256[](1);
        depositorAmounts[0] = 2e18;
        bytes32 depositorRoot = MerkleTreeHelper.computeRoot(address(treasury), 9, depositors, depositorAmounts);
        bytes32[] memory depositorProof =
            MerkleTreeHelper.getProof(address(treasury), 9, depositors, depositorAmounts, depositor, 2e18);

        vm.startPrank(owner);
        treasury.publishAgentRoot(8, agentRoot, 1e18, uint64(block.timestamp + 30 days));
        treasury.publishDepositorRoot(9, depositorRoot, 2e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(FORAGETreasury.BlocklistUnavailable.selector, address(revertingBlocklist))
        );
        treasury.claimAgent(8, agent, 1e18, agentProof);

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(FORAGETreasury.BlocklistUnavailable.selector, address(revertingBlocklist))
        );
        treasury.claimDepositor(9, depositor, 2e18, depositorProof);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(FORAGETreasury.BlocklistUnavailable.selector, address(revertingBlocklist))
        );
        treasury.distributePartnership(
            partner,
            partnerDelegate,
            1e18,
            uint64(block.timestamp + 1 days),
            uint64(365 days),
            uint64(30 days)
        );
    }

    function test_TSCGB_A11_missingBlocklistFailsLoudBeforeClaims() public {
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        FORAGETreasury unwiredTreasury =
            FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));
        forage.mint(address(unwiredTreasury), 10e18);

        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        bytes32 root = MerkleTreeHelper.computeRoot(address(unwiredTreasury), 10, agents, amounts);
        bytes32[] memory proof = MerkleTreeHelper.getProof(address(unwiredTreasury), 10, agents, amounts, agent, 1e18);

        vm.startPrank(owner);
        vm.expectRevert(FORAGETreasury.ZeroAddress.selector);
        unwiredTreasury.setBlocklist(address(0));
        unwiredTreasury.publishAgentRoot(10, root, 1e18, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FORAGETreasury.BlocklistUnavailable.selector, address(0)));
        unwiredTreasury.claimAgent(10, agent, 1e18, proof);
    }

    function test_TSCGB_A11_sweepExpiredRoundsAreAdminOnlyAndPreserveUnclaimedAccounting() public {
        address[] memory agents = new address[](1);
        agents[0] = agent;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 25e18;
        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), 7, agents, amounts);

        vm.prank(owner);
        treasury.publishAgentRoot(7, root, 25e18, uint64(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(agent);
        vm.expectRevert(FORAGETreasury.Unauthorized.selector);
        treasury.sweepExpiredAgentRound(7, owner);

        vm.prank(owner);
        treasury.sweepExpiredAgentRound(7, owner);

        assertEq(forage.balanceOf(owner), 25e18, "admin sweep must recover only unclaimed expired funds");

        address[] memory depositors = new address[](1);
        depositors[0] = depositor;
        uint256[] memory depositorAmounts = new uint256[](1);
        depositorAmounts[0] = 15e18;
        bytes32 depositorRoot = MerkleTreeHelper.computeRoot(address(treasury), 8, depositors, depositorAmounts);

        vm.prank(owner);
        treasury.publishDepositorRoot(8, depositorRoot, 15e18, uint64(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(depositor);
        vm.expectRevert(FORAGETreasury.Unauthorized.selector);
        treasury.sweepExpiredDepositorRound(8, owner);

        vm.prank(owner);
        treasury.sweepExpiredDepositorRound(8, owner);

        assertEq(forage.balanceOf(owner), 40e18, "depositor sweep must use consolidated treasury accounting");
    }
}
