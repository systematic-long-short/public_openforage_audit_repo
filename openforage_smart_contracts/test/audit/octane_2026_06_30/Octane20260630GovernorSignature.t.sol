// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

import "../../helpers/ForageGovernorTestBase.sol";
import "../../mocks/MockForageTokenVotes.sol";

contract Octane20260630ERC1271Voter is IERC1271 {
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

contract Octane20260630GovernorSignatureTest is ForageGovernorTestBase {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function test_G1_castVoteBySigAcceptsValidEoaBallotAndConsumesNonce() public {
        uint256 voterKey = 0xA11CE;
        address sigVoter = _prepareEoaSigVoter(voterKey);
        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(sigVoter);
        bytes memory signature = _signBallot(voterKey, proposalId, 1, sigVoter, nonce);

        uint256 weight = governor.castVoteBySig(proposalId, 1, sigVoter, signature);

        assertEq(weight, 5_000_000 * 1e18, "signature vote uses snapshot weight");
        assertTrue(governor.hasVoted(proposalId, sigVoter), "signature voter recorded");
        assertEq(governor.nonces(sigVoter), nonce + 1, "nonce consumed");
    }

    function test_Octane_castVoteBySigRejectsMismatchedEoaBallot() public {
        uint256 voterKey = 0xB0B;
        address sigVoter = _prepareEoaSigVoter(voterKey);
        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(sigVoter);
        bytes memory wrongSupportSignature = _signBallot(voterKey, proposalId, 0, sigVoter, nonce);

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, sigVoter));
        governor.castVoteBySig(proposalId, 1, sigVoter, wrongSupportSignature);

        assertFalse(governor.hasVoted(proposalId, sigVoter), "invalid signature must not vote");
        assertEq(governor.nonces(sigVoter), nonce, "invalid signature must not consume nonce");
    }

    function test_G3_castVoteBySigAcceptsEip1271ContractBallot() public {
        Octane20260630ERC1271Voter contractVoter = new Octane20260630ERC1271Voter();
        vm.prank(deployer);
        token.transfer(address(contractVoter), 5_000_000 * 1e18);
        contractVoter.delegate(token);
        vm.roll(block.number + 1);

        uint256 proposalId = _createActiveProposal();
        uint256 nonce = governor.nonces(address(contractVoter));
        bytes32 digest = _ballotDigest(proposalId, 1, address(contractVoter), nonce);
        contractVoter.setValidHash(digest);

        uint256 weight = governor.castVoteBySig(proposalId, 1, address(contractVoter), hex"01");

        assertEq(weight, 5_000_000 * 1e18, "1271 vote uses contract snapshot weight");
        assertTrue(governor.hasVoted(proposalId, address(contractVoter)), "1271 voter recorded");
        assertEq(governor.nonces(address(contractVoter)), nonce + 1, "1271 nonce consumed");
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

    function _signBallot(
        uint256 privateKey,
        uint256 proposalId,
        uint8 support,
        address voter,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _ballotDigest(proposalId, support, voter, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _ballotDigest(
        uint256 proposalId,
        uint8 support,
        address voter,
        uint256 nonce
    ) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            governor.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(governor.BALLOT_TYPEHASH(), proposalId, support, voter, nonce));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
