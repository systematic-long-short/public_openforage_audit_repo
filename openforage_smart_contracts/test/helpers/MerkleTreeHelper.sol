// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MerkleTreeHelper
/// @notice Pure Solidity Merkle tree builder for tests. Produces roots and proofs
///         compatible with OpenZeppelin's MerkleProof library (sorted-pair / commutative hashing).
/// @dev OF-047: Leaf encoding includes pool address and roundId for domain separation:
///      keccak256(bytes.concat(keccak256(abi.encode(pool, roundId, account, amount))))
///      Internal nodes: commutativeHash(left, right) where the smaller value comes first.
library MerkleTreeHelper {
    // ----------------------------------------------------------------
    // Public API
    // ----------------------------------------------------------------

    /// @notice Build a Merkle root from a set of (account, amount) pairs for a specific pool and round.
    /// @param pool     The pool contract address (domain separation).
    /// @param roundId  The airdrop round ID (domain separation).
    /// @param accounts Array of addresses (one per leaf).
    /// @param amounts  Array of amounts (one per leaf, same length as accounts).
    /// @return root The Merkle root.
    function computeRoot(address pool, uint256 roundId, address[] memory accounts, uint256[] memory amounts)
        internal
        pure
        returns (bytes32 root)
    {
        require(accounts.length == amounts.length, "MerkleTreeHelper: length mismatch");
        require(accounts.length > 0, "MerkleTreeHelper: empty tree");

        bytes32[] memory leaves = _hashLeaves(pool, roundId, accounts, amounts);
        leaves = _sortLeaves(leaves);
        root = _buildTree(leaves);
    }

    /// @notice Build a Merkle proof for a specific (account, amount) pair.
    /// @param pool     The pool contract address (domain separation).
    /// @param roundId  The airdrop round ID (domain separation).
    /// @param accounts Array of addresses (one per leaf).
    /// @param amounts  Array of amounts (one per leaf).
    /// @param account  The account to generate the proof for.
    /// @param amount   The amount to generate the proof for.
    /// @return proof   The sibling hashes needed to reconstruct the root.
    function getProof(
        address pool,
        uint256 roundId,
        address[] memory accounts,
        uint256[] memory amounts,
        address account,
        uint256 amount
    ) internal pure returns (bytes32[] memory proof) {
        require(accounts.length == amounts.length, "MerkleTreeHelper: length mismatch");
        require(accounts.length > 0, "MerkleTreeHelper: empty tree");

        bytes32[] memory leaves = _hashLeaves(pool, roundId, accounts, amounts);
        leaves = _sortLeaves(leaves);

        bytes32 targetLeaf = _doubleHash(pool, roundId, account, amount);

        // Find index of target leaf in sorted array
        uint256 targetIndex = type(uint256).max;
        for (uint256 i = 0; i < leaves.length; i++) {
            if (leaves[i] == targetLeaf) {
                targetIndex = i;
                break;
            }
        }
        require(targetIndex != type(uint256).max, "MerkleTreeHelper: leaf not found");

        proof = _buildProof(leaves, targetIndex);
    }

    /// @notice Compute the double-hashed leaf value for (pool, roundId, account, amount).
    /// @dev OF-047: Matches the expected on-chain encoding:
    ///      keccak256(bytes.concat(keccak256(abi.encode(pool, roundId, account, amount))))
    function hashLeaf(address pool, uint256 roundId, address account, uint256 amount) internal pure returns (bytes32) {
        return _doubleHash(pool, roundId, account, amount);
    }

    // ----------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------

    function _doubleHash(address pool, uint256 roundId, address account, uint256 amount)
        private
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(pool, roundId, account, amount))));
    }

    /// @dev Hash all (account, amount) pairs into double-hashed leaves with domain separation.
    function _hashLeaves(address pool, uint256 roundId, address[] memory accounts, uint256[] memory amounts)
        private
        pure
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            leaves[i] = _doubleHash(pool, roundId, accounts[i], amounts[i]);
        }
    }

    /// @dev Sort leaves ascending (insertion sort -- fine for test-size arrays).
    function _sortLeaves(bytes32[] memory leaves) private pure returns (bytes32[] memory) {
        uint256 n = leaves.length;
        for (uint256 i = 1; i < n; i++) {
            bytes32 key = leaves[i];
            uint256 j = i;
            while (j > 0 && leaves[j - 1] > key) {
                leaves[j] = leaves[j - 1];
                j--;
            }
            leaves[j] = key;
        }
        return leaves;
    }

    /// @dev Commutative hash matching OpenZeppelin Hashes.commutativeKeccak256.
    function _commutativeHash(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Build the full binary tree array from sorted leaves and return the root.
    ///      Pads the layer with the last element if odd (standard OZ behavior).
    function _buildTree(bytes32[] memory leaves) private pure returns (bytes32) {
        if (leaves.length == 1) return leaves[0];

        // Build layers bottom-up
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 parentLen = (layer.length + 1) / 2;
            bytes32[] memory nextLayer = new bytes32[](parentLen);
            for (uint256 i = 0; i < parentLen; i++) {
                uint256 left = 2 * i;
                uint256 right = 2 * i + 1;
                if (right < layer.length) {
                    nextLayer[i] = _commutativeHash(layer[left], layer[right]);
                } else {
                    // Odd node: promote without hashing (OZ standard tree behavior)
                    nextLayer[i] = layer[left];
                }
            }
            layer = nextLayer;
        }
        return layer[0];
    }

    /// @dev Build a proof for the leaf at `targetIndex` in the sorted leaves array.
    function _buildProof(bytes32[] memory leaves, uint256 targetIndex) private pure returns (bytes32[] memory proof) {
        if (leaves.length == 1) {
            proof = new bytes32[](0);
            return proof;
        }

        // Count tree depth for proof allocation
        uint256 depth = 0;
        {
            uint256 n = leaves.length;
            while (n > 1) {
                n = (n + 1) / 2;
                depth++;
            }
        }

        proof = new bytes32[](depth);
        uint256 proofIdx = 0;
        bytes32[] memory layer = leaves;
        uint256 idx = targetIndex;

        while (layer.length > 1) {
            uint256 parentLen = (layer.length + 1) / 2;
            bytes32[] memory nextLayer = new bytes32[](parentLen);

            // Determine sibling for current index
            if (idx % 2 == 0) {
                // Left child -- sibling is right
                if (idx + 1 < layer.length) {
                    proof[proofIdx] = layer[idx + 1];
                    proofIdx++;
                }
                // If idx+1 >= layer.length, this is an odd-node promotion (no sibling, no proof entry)
            } else {
                // Right child -- sibling is left
                proof[proofIdx] = layer[idx - 1];
                proofIdx++;
            }

            // Build the next layer (needed to continue tracking index)
            for (uint256 i = 0; i < parentLen; i++) {
                uint256 left = 2 * i;
                uint256 right = 2 * i + 1;
                if (right < layer.length) {
                    nextLayer[i] = _commutativeHash(layer[left], layer[right]);
                } else {
                    nextLayer[i] = layer[left];
                }
            }

            idx = idx / 2;
            layer = nextLayer;
        }

        // Trim proof to actual length (in case of odd-node promotions)
        if (proofIdx < depth) {
            bytes32[] memory trimmed = new bytes32[](proofIdx);
            for (uint256 i = 0; i < proofIdx; i++) {
                trimmed[i] = proof[i];
            }
            proof = trimmed;
        }
    }
}
