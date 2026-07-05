// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/FORAGETreasury.sol";
import "../../helpers/ForageGovernorTestBase.sol";
import "../../helpers/MerkleTreeHelper.sol";
import "../../mocks/MockForageTokenSimple.sol";
import "../../mocks/MockForageTokenVotes.sol";

contract PublicAuditOpenBlocklist {
    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}

contract PublicAuditERC1271Voter is IERC1271 {
    bytes4 internal constant MAGICVALUE = IERC1271.isValidSignature.selector;
    bytes32 internal validHash;

    function delegate(MockForageTokenVotes token) external {
        token.delegate(address(this));
    }

    function setValidHash(bytes32 hash) external {
        validHash = hash;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return hash == validHash ? MAGICVALUE : bytes4(0);
    }
}

contract Octane20260630SignatureDomainPublicAudit001TreasuryTest is Test {
    address internal owner = makeAddr("treasury-owner");
    address internal claimant = makeAddr("lane-claimant");
    address internal depositor = makeAddr("depositor");
    address internal secondDepositor = makeAddr("second-depositor");

    MockForageTokenSimple internal forage;
    FORAGETreasury internal treasury;

    function setUp() public {
        vm.warp(1_000);

        forage = new MockForageTokenSimple();
        FORAGETreasury implementation = new FORAGETreasury();
        bytes memory initData = abi.encodeCall(FORAGETreasury.initialize, (address(forage), owner));
        treasury = FORAGETreasury(address(new ERC1967Proxy(address(implementation), initData)));

        forage.mint(address(treasury), 80_000_000e18);

        PublicAuditOpenBlocklist openBlocklist = new PublicAuditOpenBlocklist();
        vm.prank(owner);
        treasury.setBlocklist(address(openBlocklist));
    }

    function test_PUBLIC_AUDIT_T1_sameMerkleProofClaimsAgentAndDepositorWhenRootsMatch() public {
        uint256 roundId = 9_001;
        uint256 amount = 3e18;
        address[] memory accounts = new address[](1);
        accounts[0] = claimant;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), roundId, accounts, amounts);
        bytes32[] memory proof =
            MerkleTreeHelper.getProof(address(treasury), roundId, accounts, amounts, claimant, amount);

        vm.startPrank(owner);
        treasury.publishAgentRoot(roundId, root, amount, uint64(block.timestamp + 30 days));
        treasury.publishDepositorRoot(roundId, root, amount, uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.prank(claimant);
        treasury.claimAgent(roundId, claimant, amount, proof);
        vm.prank(claimant);
        treasury.claimDepositor(roundId, claimant, amount, proof);

        assertEq(forage.balanceOf(claimant), amount * 2, "same proof paid in both lanes");
        assertTrue(treasury.agentClaimed(roundId, claimant), "agent lane marked claimed");
        assertTrue(treasury.depositorClaimed(roundId, claimant), "depositor lane marked claimed");
    }

    function test_PUBLIC_AUDIT_T2_depositorRoundRepublishResetsAccountingAndAllowsOversweep() public {
        uint256 roundId = 9_002;
        uint256 depositorAmount = 10e18;
        uint256 secondDepositorAmount = 20e18;
        uint256 totalAmount = depositorAmount + secondDepositorAmount;

        address[] memory accounts = new address[](2);
        accounts[0] = depositor;
        accounts[1] = secondDepositor;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositorAmount;
        amounts[1] = secondDepositorAmount;

        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), roundId, accounts, amounts);
        bytes32[] memory proof =
            MerkleTreeHelper.getProof(address(treasury), roundId, accounts, amounts, depositor, depositorAmount);

        vm.prank(owner);
        treasury.publishDepositorRoot(roundId, root, totalAmount, uint64(block.timestamp + 30 days));

        vm.prank(depositor);
        treasury.claimDepositor(roundId, depositor, depositorAmount, proof);
        assertEq(forage.balanceOf(depositor), depositorAmount, "first claim paid");

        vm.prank(owner);
        treasury.publishDepositorRoot(roundId, root, totalAmount, uint64(block.timestamp + 30 days));
        (, uint256 republishedTotal,, uint256 republishedClaimedAmount,) = treasury.depositorRounds(roundId);
        assertEq(republishedTotal, totalAmount, "republished round kept total");
        assertEq(republishedClaimedAmount, 0, "republish reset claimed accounting");

        vm.prank(depositor);
        vm.expectRevert(FORAGETreasury.AlreadyClaimed.selector);
        treasury.claimDepositor(roundId, depositor, depositorAmount, proof);

        vm.prank(owner);
        treasury.publishDepositorRoot(roundId, root, totalAmount, uint64(block.timestamp - 1));
        vm.prank(owner);
        treasury.sweepExpiredDepositorRound(roundId, owner);

        assertEq(forage.balanceOf(owner), totalAmount, "sweep used reset claimed amount");
        assertEq(
            forage.balanceOf(depositor) + forage.balanceOf(owner),
            totalAmount + depositorAmount,
            "paid exceeds current round total"
        );
    }

    function test_PUBLIC_AUDIT_T3_expiredAgentRoundCanBeSweptImmediatelyAndRepublishedAfterSweep() public {
        uint256 roundId = 9_003;
        uint256 amount = 7e18;
        address[] memory accounts = new address[](1);
        accounts[0] = claimant;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        bytes32 root = MerkleTreeHelper.computeRoot(address(treasury), roundId, accounts, amounts);
        bytes32[] memory proof =
            MerkleTreeHelper.getProof(address(treasury), roundId, accounts, amounts, claimant, amount);
        uint64 expiredDeadline = uint64(block.timestamp - 1);

        vm.prank(owner);
        treasury.publishAgentRoot(roundId, root, amount, expiredDeadline);

        vm.prank(claimant);
        vm.expectRevert(FORAGETreasury.RoundExpired.selector);
        treasury.claimAgent(roundId, claimant, amount, proof);

        vm.prank(owner);
        treasury.sweepExpiredAgentRound(roundId, owner);
        assertEq(forage.balanceOf(owner), amount, "first expired sweep paid");

        vm.prank(owner);
        treasury.publishAgentRoot(roundId, root, amount, expiredDeadline);
        vm.prank(owner);
        treasury.sweepExpiredAgentRound(roundId, owner);

        assertEq(forage.balanceOf(owner), amount * 2, "republish reset swept flag");
    }
}

contract Octane20260630SignatureDomainPublicAudit001GovernorTest is ForageGovernorTestBase {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function test_PUBLIC_AUDIT_G1_eoaBallotIsBoundToCurrentChainIdDomain() public {
        uint256 voterKey = 0xA11CE;
        address sigVoter = _prepareEoaSigVoter(voterKey);
        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(sigVoter);
        bytes memory signature = _signBallot(voterKey, proposalId, 1, sigVoter, nonce);
        uint256 originalChainId = block.chainid;

        vm.chainId(originalChainId + 1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        governor.castVoteBySig(proposalId, 1, sigVoter, signature);
        vm.chainId(originalChainId);

        assertFalse(governor.hasVoted(proposalId, sigVoter), "wrong-domain vote rejected");
        assertEq(governor.nonces(sigVoter), nonce, "wrong-domain signature did not consume nonce");
    }

    function test_PUBLIC_AUDIT_Octane_eoaBallotReplayDoesNotCastOrConsumeSecondNonce() public {
        uint256 voterKey = 0xB0B;
        address sigVoter = _prepareEoaSigVoter(voterKey);
        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(sigVoter);
        bytes memory signature = _signBallot(voterKey, proposalId, 1, sigVoter, nonce);

        governor.castVoteBySig(proposalId, 1, sigVoter, signature);
        assertTrue(governor.hasVoted(proposalId, sigVoter), "first signed vote recorded");
        assertEq(governor.nonces(sigVoter), nonce + 1, "first signed vote consumed nonce");

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        governor.castVoteBySig(proposalId, 1, sigVoter, signature);
        assertEq(governor.nonces(sigVoter), nonce + 1, "replay did not consume another nonce");
    }

    function test_PUBLIC_AUDIT_G3_eoaHighSVariantIsRejectedWithoutConsumingNonce() public {
        uint256 voterKey = 0xCAFE;
        address sigVoter = _prepareEoaSigVoter(voterKey);
        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(sigVoter);
        bytes32 digest = _ballotDigest(proposalId, 1, sigVoter, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(voterKey, digest);

        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleatedSignature = abi.encodePacked(r, highS, flippedV);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        governor.castVoteBySig(proposalId, 1, sigVoter, malleatedSignature);

        assertFalse(governor.hasVoted(proposalId, sigVoter), "high-s signature rejected");
        assertEq(governor.nonces(sigVoter), nonce, "high-s signature did not consume nonce");
    }

    function test_PUBLIC_AUDIT_G4_eip1271ContractSignerRejectionKeepsNonceUnchanged() public {
        PublicAuditERC1271Voter contractVoter = new PublicAuditERC1271Voter();
        vm.prank(deployer);
        token.transfer(address(contractVoter), 5_000_000 * 1e18);
        contractVoter.delegate(token);
        vm.roll(block.number + 1);

        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(address(contractVoter));
        bytes32 digest = _ballotDigest(proposalId, 1, address(contractVoter), nonce);
        contractVoter.setValidHash(bytes32(uint256(digest) ^ uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, address(contractVoter)));
        governor.castVoteBySig(proposalId, 1, address(contractVoter), hex"01");

        assertFalse(governor.hasVoted(proposalId, address(contractVoter)), "invalid 1271 vote rejected");
        assertEq(governor.nonces(address(contractVoter)), nonce, "invalid 1271 signature did not consume nonce");
    }

    function _prepareEoaSigVoter(uint256 privateKey) internal returns (address sigVoter) {
        sigVoter = vm.addr(privateKey);
        vm.prank(deployer);
        token.transfer(sigVoter, 5_000_000 * 1e18);
        vm.prank(sigVoter);
        token.delegate(sigVoter);
        vm.roll(block.number + 1);
    }

    function _createActiveProposal() internal returns (uint256 proposalId) {
        proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);
    }

    function _signBallot(uint256 privateKey, uint256 proposalId, uint8 support, address voter, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _ballotDigest(proposalId, support, voter, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _ballotDigest(uint256 proposalId, uint8 support, address voter, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
        bytes32 structHash = keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, nonce));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
