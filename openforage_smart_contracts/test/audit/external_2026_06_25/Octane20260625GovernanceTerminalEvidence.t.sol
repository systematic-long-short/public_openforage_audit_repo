// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/Blocklist.sol";
import "../../../src/ForageGovernor.sol";
import "../../../src/ForageToken.sol";
import "../external_2026_06_12/fixtures/ExternalAuditLegacyUpgradeFixtures.sol";

contract Octane20260625GovernanceTerminalEvidenceTest is Test {
    function test_V2_sameTimestampSnapshotChurnDoesNotDoubleCountButCanDefineFinalSnapshotState() public {
        // PHASE15_REPRO_BINDING: V-2
        address owner = makeAddr("octane25.gov.owner");
        address treasury = makeAddr("octane25.gov.treasury");
        address proposer = makeAddr("octane25.gov.proposer");
        address voterA = makeAddr("octane25.gov.voterA");
        address voterB = makeAddr("octane25.gov.voterB");

        vm.warp(100);
        ForageToken forage = _deployForageToken(owner, treasury, owner);
        ForageGovernor governor = _deployGovernor(forage, owner, 10);

        uint256 proposerVotes = 2_000_000e18;
        uint256 mobileVotes = 5_000_000e18;
        vm.startPrank(treasury);
        forage.transfer(proposer, proposerVotes);
        forage.transfer(voterA, mobileVotes);
        vm.stopPrank();

        vm.prank(proposer);
        forage.delegate(proposer);
        vm.prank(voterA);
        forage.delegate(voterA);
        vm.prank(voterB);
        forage.delegate(voterB);
        vm.warp(block.timestamp + 1);

        uint256 proposalId = _propose(governor, proposer);
        uint256 snapshot = governor.proposalSnapshot(proposalId);

        vm.warp(snapshot);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending),
            "proposal is not active during the exact snapshot timestamp"
        );
        vm.prank(voterA);
        (bool voteAtSnapshot,) =
            address(governor).call(abi.encodeWithSignature("castVote(uint256,uint8)", proposalId, uint8(1)));
        assertFalse(voteAtSnapshot, "castVote cannot execute while proposal is still Pending");

        vm.prank(voterA);
        forage.transfer(voterB, mobileVotes);
        vm.warp(snapshot + 1);
        assertEq(forage.getPastVotes(voterA, snapshot), 0, "same-timestamp transfer overwrites voterA snapshot power");
        assertEq(
            forage.getPastVotes(voterB, snapshot),
            mobileVotes,
            "same-timestamp transfer gives voterB the final snapshot power"
        );
        assertEq(
            forage.getPastVotes(voterA, snapshot) + forage.getPastVotes(voterB, snapshot),
            mobileVotes,
            "the current implementation does not double-count the moved voting power"
        );

        vm.prank(voterB);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, mobileVotes, "voting after the churn counts only the final snapshot owner");
    }

    function test_V3_zeroBalanceDelegatesDoNotExpandPastVoteLookupGas() public {
        // CI-0067_POLICY_A_POSTFIX: V-3
        address owner = makeAddr("octane25.v3.owner");
        address treasury = makeAddr("octane25.v3.treasury");
        address source = makeAddr("octane25.v3.source");
        address delegatee = makeAddr("octane25.v3.delegatee");
        ForageToken forage = _deployForageToken(owner, treasury, owner);

        vm.prank(treasury);
        forage.transfer(source, 100e18);
        vm.prank(source);
        forage.delegate(delegatee);
        uint256 snapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        uint256 gasStart = gasleft();
        uint256 baselineVotes = forage.getPastVotes(delegatee, snapshot);
        uint256 baselineGas = gasStart - gasleft();
        assertEq(baselineVotes, 100e18, "setup: delegatee has one funded source");

        for (uint256 i; i < 96; ++i) {
            address zeroSource = address(uint160(uint256(keccak256(abi.encode("octane25-zero-source", i)))));
            vm.prank(zeroSource);
            forage.delegate(delegatee);
        }

        gasStart = gasleft();
        uint256 votesAfterZeroSources = forage.getPastVotes(delegatee, snapshot);
        uint256 gasAfterZeroSources = gasStart - gasleft();

        assertEq(votesAfterZeroSources, baselineVotes, "zero-balance delegate sources do not add votes");
        assertLe(gasAfterZeroSources, baselineGas + 5_000, "unfunded historical delegate sources are not tracked");
    }

    function test_V3_zeroBalanceDelegatesDoNotExpandPastVoteLookupAfterRemediation() public {
        // CI-0067_POLICY_A_POSTFIX: V-3
        address owner = makeAddr("octane25.v3.post.owner");
        address treasury = makeAddr("octane25.v3.post.treasury");
        address source = makeAddr("octane25.v3.post.source");
        address delegatee = makeAddr("octane25.v3.post.delegatee");
        ForageToken forage = _deployForageToken(owner, treasury, owner);

        vm.prank(treasury);
        forage.transfer(source, 100e18);
        vm.prank(source);
        forage.delegate(delegatee);
        uint256 snapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        uint256 gasStart = gasleft();
        uint256 baselineVotes = forage.getPastVotes(delegatee, snapshot);
        uint256 baselineGas = gasStart - gasleft();

        for (uint256 i; i < 96; ++i) {
            address zeroSource = address(uint160(uint256(keccak256(abi.encode("octane25-zero-source-post", i)))));
            vm.prank(zeroSource);
            forage.delegate(delegatee);
        }

        gasStart = gasleft();
        uint256 votesAfterZeroSources = forage.getPastVotes(delegatee, snapshot);
        uint256 gasAfterZeroSources = gasStart - gasleft();

        assertEq(votesAfterZeroSources, baselineVotes, "zero-balance delegates do not change votes");
        assertLe(gasAfterZeroSources, baselineGas + 5_000, "zero-balance delegate spam must not materially grow gas");
    }

    function test_V11_missingLegacyBlockedIntervalDataFallsBackToUnblocked() public {
        // PHASE15_REPRO_BINDING: V-11
        address owner = makeAddr("octane25.v11.owner");
        address treasury = makeAddr("octane25.v11.treasury");
        address guardian = makeAddr("octane25.v11.guardian");
        address legacySource = makeAddr("octane25.v11.legacySource");
        address delegatee = makeAddr("octane25.v11.delegatee");

        ForageToken forage = _deployForageToken(owner, treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));

        vm.prank(treasury);
        forage.transfer(legacySource, 100e18);
        vm.prank(legacySource);
        forage.delegate(delegatee);
        uint256 historicalSnapshot = block.timestamp;
        vm.warp(block.timestamp + 1);

        assertFalse(
            blocklist.wasEffectivelyBlockedAt(legacySource, historicalSnapshot),
            "with no checkpoint and no legacy expiry, current code treats the source as unblocked"
        );
        assertEq(
            forage.getPastVotes(delegatee, historicalSnapshot),
            100e18,
            "missing legacy interval data cannot be reconstructed and therefore votes are counted"
        );
    }

    function test_RV111_legacyExpiryOnlyFallbackOverExcludesBeforeUnknownBlockStart() public {
        // PHASE15_REPRO_BINDING: R-V-11-1
        address owner = makeAddr("octane25.rv111.owner");
        address treasury = makeAddr("octane25.rv111.treasury");
        address guardian = makeAddr("octane25.rv111.guardian");
        address source = makeAddr("octane25.rv111.source");
        address delegatee = makeAddr("octane25.rv111.delegatee");

        ForageToken forage = _deployForageToken(owner, treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));

        vm.prank(treasury);
        forage.transfer(source, 100e18);
        vm.prank(source);
        forage.delegate(delegatee);
        uint256 snapshotBeforeHypotheticalBlockStart = block.timestamp;
        vm.warp(block.timestamp + 1);

        _writeLegacyBlockedUntil(blocklist, source, snapshotBeforeHypotheticalBlockStart + 30 days);

        assertTrue(
            blocklist.wasEffectivelyBlockedAt(source, snapshotBeforeHypotheticalBlockStart),
            "expiry-only fallback treats every earlier timepoint before expiry as blocked"
        );
        assertEq(
            forage.getPastVotes(delegatee, snapshotBeforeHypotheticalBlockStart),
            0,
            "ForageToken excludes source votes for pre-start snapshots when only legacy expiry exists"
        );
    }

    function test_V11_ownerImportedLegacyIntervalExcludesOnlyInsideInterval() public {
        // CI-0067_POLICY_A_POSTFIX: V-11 / R-V-11-1
        address owner = makeAddr("octane25.v11.post.owner");
        address treasury = makeAddr("octane25.v11.post.treasury");
        address guardian = makeAddr("octane25.v11.post.guardian");
        address source = makeAddr("octane25.v11.post.source");
        address delegatee = makeAddr("octane25.v11.post.delegatee");

        ForageToken forage = _deployForageToken(owner, treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));

        vm.prank(treasury);
        forage.transfer(source, 100e18);
        vm.prank(source);
        forage.delegate(delegatee);
        uint256 beforeStart = block.timestamp;
        uint256 start = beforeStart + 10;
        uint256 inside = start + 10;
        uint256 end = start + 30;
        uint256 afterEnd = end + 2;
        vm.warp(afterEnd + 1);

        vm.prank(owner);
        blocklist.importLegacyBlockedInterval(source, start, end);

        assertFalse(blocklist.wasEffectivelyBlockedAt(source, beforeStart), "pre-start snapshot is not over-excluded");
        assertTrue(blocklist.wasEffectivelyBlockedAt(source, inside), "inside imported interval is blocked");
        assertFalse(blocklist.wasEffectivelyBlockedAt(source, afterEnd), "post-end snapshot is unblocked");
        assertEq(forage.getPastVotes(delegatee, beforeStart), 100e18, "pre-start votes count");
        assertEq(forage.getPastVotes(delegatee, inside), 0, "in-interval votes are excluded");
        assertEq(forage.getPastVotes(delegatee, afterEnd), 100e18, "post-end votes count");
    }

    function test_V12_legacyDelegateCheckpointsFailClosedUntilOwnerBackfillsSources() public {
        // PHASE15_REPRO_BINDING: V-12
        address owner = makeAddr("octane25.v12.owner");
        address treasury = makeAddr("octane25.v12.treasury");
        address holder = makeAddr("octane25.v12.holder");
        address delegatee = makeAddr("octane25.v12.delegatee");
        address guardian = makeAddr("octane25.v12.guardian");

        ForageToken forage = _deployLegacyForageTokenWithoutDelegateSourceTracking(owner, treasury, owner);
        Blocklist blocklist = _deployBlocklist(guardian, owner);
        vm.prank(owner);
        forage.setBlocklist(address(blocklist));

        vm.prank(treasury);
        forage.transfer(holder, 100e18);
        vm.prank(holder);
        forage.delegate(delegatee);
        assertEq(forage.getVotes(delegatee), 100e18, "legacy implementation records delegate votes");

        _upgradeLegacyForageTokenToCurrent(forage, owner);
        assertEq(forage.getVotes(delegatee), 0, "current implementation fails closed before source backfill");

        address[] memory sources = new address[](1);
        sources[0] = holder;
        vm.prank(owner);
        forage.syncDelegateSources(sources);

        assertEq(forage.getVotes(delegatee), 100e18, "owner backfill restores tracked delegate-source votes");
    }

    function _deployForageToken(address teamVesting, address forageTreasury, address owner)
        internal
        returns (ForageToken)
    {
        ForageToken implementation = new ForageToken();
        bytes memory initData = abi.encodeCall(ForageToken.initialize, (teamVesting, forageTreasury, owner));
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployLegacyForageTokenWithoutDelegateSourceTracking(
        address teamVesting,
        address forageTreasury,
        address owner
    ) internal returns (ForageToken) {
        LegacyForageTokenWithoutDelegateSourceTracking implementation =
            new LegacyForageTokenWithoutDelegateSourceTracking();
        bytes memory initData = abi.encodeCall(
            LegacyForageTokenWithoutDelegateSourceTracking.initialize, (teamVesting, forageTreasury, owner)
        );
        return ForageToken(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _upgradeLegacyForageTokenToCurrent(ForageToken forage, address owner) internal {
        ForageToken implementation = new ForageToken();
        vm.prank(owner);
        forage.upgradeToAndCall(address(implementation), "");
    }

    function _deployBlocklist(address guardian, address owner) internal returns (Blocklist) {
        Blocklist implementation = new Blocklist();
        bytes memory initData = abi.encodeCall(Blocklist.initialize, (guardian, owner));
        return Blocklist(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _deployGovernor(ForageToken forage, address owner, uint48 votingDelay) internal returns (ForageGovernor) {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        TimelockController timelock = new TimelockController(0, proposers, executors, owner);

        ForageGovernor implementation = new ForageGovernor();
        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (address(forage), address(timelock), votingDelay, uint32(3_600), uint256(100), uint256(400), address(0))
        );
        return ForageGovernor(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _propose(ForageGovernor governor, address proposer) internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(ForageGovernor.maxActiveProposals.selector);

        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, "OCTANE-20260625-V2");
    }

    function _writeLegacyBlockedUntil(Blocklist blocklist, address account, uint256 until) internal {
        bytes32 slot = keccak256(abi.encode(account, uint256(3)));
        vm.store(address(blocklist), slot, bytes32(until));
    }
}
