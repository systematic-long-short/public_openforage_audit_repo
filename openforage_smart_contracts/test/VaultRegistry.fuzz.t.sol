// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";

// ============================================================
// TC-14: Fuzz Tests (R-05, R-08, R-09, R-10, R-11, R-13, R-14,
//        R-15, R-18, R-22, R-27, R-29, R-31, R-33, R-34,
//        R-43, R-44, R-46, R-49)
// ============================================================
contract VaultRegistry_TC14_Fuzz is VaultRegistryTestBase {
    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

    /// @dev Build a deterministic non-zero address from a uint256 seed.
    function _nonZeroAddr(uint256 seed) internal pure returns (address) {
        address a = address(uint160(uint256(keccak256(abi.encodePacked(seed)))));
        if (a == address(0)) a = address(1);
        return a;
    }

    /// @dev Convert a uint256 to a short string for use as abbreviation.
    function _uintToAbbr(uint256 seed) internal pure returns (string memory) {
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        bytes memory out = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = alphabet[seed % 26];
            seed /= 26;
        }
        return string(out);
    }

    /// @dev Helper struct to reduce stack depth in fuzz test 1
    struct FuzzVaultParams {
        uint256 capacityCap;
        uint16[4] yieldSplitsBps;
        uint16[4] fundingBps;
        address[4] tierVaults;
        address stakingQueue;
        string abbreviation;
    }

    /// @dev Build fuzz vault params from raw seeds
    function _buildFuzzParams(
        uint256 capSeed,
        uint16[4] calldata yieldBps,
        uint16[4] calldata fundBps,
        uint256[4] calldata addrSeeds,
        uint256 sqSeed,
        uint256 abbrSeed
    ) internal pure returns (FuzzVaultParams memory p) {
        p.capacityCap = bound(capSeed, 1, type(uint256).max);
        for (uint8 i = 0; i < 4; i++) {
            p.yieldSplitsBps[i] = uint16(bound(uint256(yieldBps[i]), 1, 10000));
            p.fundingBps[i] = uint16(bound(uint256(fundBps[i]), 0, 10000 - uint256(p.yieldSplitsBps[i])));
            p.tierVaults[i] = _nonZeroAddr(uint256(keccak256(abi.encode(addrSeeds[i], i))));
        }
        p.stakingQueue = _nonZeroAddr(uint256(keccak256(abi.encode(sqSeed, uint256(999)))));
        p.abbreviation = _uintToAbbr(abbrSeed);
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 1: addVault with random valid inputs
    // Requirements: R-05, R-43 (monotonic IDs), R-44 (abbreviation stored)
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_addVault_validInputs(
        uint256 capSeed,
        uint16[4] calldata yieldBps,
        uint16[4] calldata fundBps,
        uint256[4] calldata addrSeeds,
        uint256 sqSeed,
        uint256 abbrSeed
    ) public {
        FuzzVaultParams memory p = _buildFuzzParams(capSeed, yieldBps, fundBps, addrSeeds, sqSeed, abbrSeed);
        uint256[4] memory lockupDurations = [uint256(0), 90 days, 180 days, 365 days];

        uint256 countBefore = registry.vaultCount();

        vm.prank(owner);
        uint256 vaultId = registry.addVault(
            "FuzzVault",
            p.abbreviation,
            p.tierVaults,
            p.stakingQueue,
            p.capacityCap,
            lockupDurations,
            p.yieldSplitsBps,
            p.fundingBps
        );

        // Vault ID must be monotonically increasing (countBefore + 1)
        assertEq(vaultId, countBefore + 1, "vaultId must equal previous count + 1");

        // vaultCount must increment
        assertEq(registry.vaultCount(), countBefore + 1, "vaultCount must increment by 1");

        // getVault must return matching config
        VaultConfig memory cfg = registry.getVault(vaultId);
        assertEq(cfg.vaultId, vaultId, "stored vaultId must match");
        assertEq(cfg.capacityCap, p.capacityCap, "stored capacityCap must match");
        assertEq(uint8(cfg.status), uint8(VaultStatus.Active), "new vault must be Active");
        for (uint8 i = 0; i < 4; i++) {
            assertEq(cfg.yieldSplitsBps[i], p.yieldSplitsBps[i], "yieldSplitsBps must match");
            assertEq(cfg.fundingBps[i], p.fundingBps[i], "fundingBps must match");
            assertEq(cfg.tierVaults[i], p.tierVaults[i], "tierVaults must match");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 2: addVault with random invalid splits
    // Requirements: R-14 (InvalidSplitTotal), R-15 (ZeroYieldSplit)
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_addVault_invalidSplits(uint16[4] calldata yieldBps, uint16[4] calldata fundBps) public {
        // Determine if there is at least one tier where yield + funding > 10000
        // or yield == 0
        bool hasInvalid = false;
        for (uint8 i = 0; i < 4; i++) {
            if (yieldBps[i] == 0) {
                hasInvalid = true;
                break;
            }
            if (uint256(yieldBps[i]) + uint256(fundBps[i]) > 10000) {
                hasInvalid = true;
                break;
            }
        }

        // If no invalid tier, force one: make tier 0 overflow
        uint16[4] memory yieldSplitsBps;
        uint16[4] memory fundingBps;
        if (!hasInvalid) {
            yieldSplitsBps = [uint16(8000), yieldBps[1], yieldBps[2], yieldBps[3]];
            fundingBps = [uint16(3000), fundBps[1], fundBps[2], fundBps[3]]; // 8000 + 3000 = 11000 > 10000
        } else {
            yieldSplitsBps = [yieldBps[0], yieldBps[1], yieldBps[2], yieldBps[3]];
            fundingBps = [fundBps[0], fundBps[1], fundBps[2], fundBps[3]];
        }

        // Build valid params for everything else
        (
            string memory name,
            string memory abbreviation,
            address[4] memory tierVaults,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,,
        ) = _createDefaultVaultParams();

        // Must revert -- either InvalidSplitTotal or ZeroYieldSplit
        vm.prank(owner);
        vm.expectRevert();
        registry.addVault(
            name, abbreviation, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 3: Status transitions with random vault IDs
    // Requirements: R-18, R-22, R-46 (valid transitions only)
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_statusTransitions(uint256 vaultSeed, uint8 actionSeed) public {
        // Register 3 vaults
        uint256 id1 = _addVaultWithAbbreviation("AAA");
        uint256 id2 = _addVaultWithAbbreviation("BBB");
        uint256 id3 = _addVaultWithAbbreviation("CCC");

        // Pick a vault based on seed
        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;
        uint256 targetId = ids[vaultSeed % 3];

        // Determine action: 0 = pause, 1 = wind-down
        uint8 action = actionSeed % 2;

        if (action == 0) {
            // Pause: must succeed because vault is Active
            vm.prank(owner);
            registry.pauseVault(targetId);

            VaultConfig memory cfg = registry.getVault(targetId);
            assertEq(uint8(cfg.status), uint8(VaultStatus.Paused), "vault must be Paused after pauseVault");

            // Verify other vaults remain Active
            for (uint256 i = 0; i < 3; i++) {
                if (ids[i] != targetId) {
                    VaultConfig memory other = registry.getVault(ids[i]);
                    assertEq(uint8(other.status), uint8(VaultStatus.Active), "other vaults must remain Active");
                }
            }

            // Attempting to pause again must revert
            vm.prank(owner);
            vm.expectRevert(VaultRegistry.VaultNotActive.selector);
            registry.pauseVault(targetId);
        } else {
            // Wind down: must succeed because vault is Active
            vm.prank(owner);
            registry.startWindDown(targetId);

            VaultConfig memory cfg = registry.getVault(targetId);
            assertEq(uint8(cfg.status), uint8(VaultStatus.WindingDown), "vault must be WindingDown");

            // Attempting to wind down again must revert
            vm.prank(owner);
            vm.expectRevert(VaultRegistry.VaultAlreadyWindingDown.selector);
            registry.startWindDown(targetId);

            // Attempting to pause a WindingDown vault must also revert
            vm.prank(owner);
            vm.expectRevert(VaultRegistry.VaultNotActive.selector);
            registry.pauseVault(targetId);
        }
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 4: setCapacityCap with random values
    // Requirements: R-27, R-29
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_setCapacityCap(uint256 newCap) public {
        uint256 vaultId = _addDefaultVault();

        if (newCap == 0) {
            // Zero capacity must revert
            vm.prank(owner);
            vm.expectRevert(VaultRegistry.ZeroCapacity.selector);
            registry.setCapacityCap(vaultId, newCap);
        } else {
            // Non-zero capacity must succeed: propose + finalize
            vm.startPrank(owner);
            vm.expectEmit(true, false, false, true, address(registry));
            emit VaultRegistry.CapacityCapProposed(vaultId, newCap);
            registry.setCapacityCap(vaultId, newCap);

            vm.warp(block.timestamp + 2 days + 1);
            registry.finalizeCapacityCap(vaultId);
            vm.stopPrank();

            VaultConfig memory cfg = registry.getVault(vaultId);
            assertEq(cfg.capacityCap, newCap, "capacityCap must be updated");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 5: setYieldSplits with random bps values
    // Requirements: R-31, R-33, R-34, R-49
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_setYieldSplits(uint16[4] calldata yieldBps, uint16[4] calldata fundBps) public {
        uint256 vaultId = _addDefaultVault();

        // Determine validity of inputs
        bool isValid = true;
        uint8 firstInvalidTier = 0;
        bool isZeroYield = false;

        for (uint8 i = 0; i < 4; i++) {
            if (yieldBps[i] == 0) {
                isValid = false;
                firstInvalidTier = i;
                isZeroYield = true;
                break;
            }
            if (uint256(yieldBps[i]) + uint256(fundBps[i]) > 10000) {
                isValid = false;
                firstInvalidTier = i;
                break;
            }
        }

        uint16[4] memory yieldSplitsBps = [yieldBps[0], yieldBps[1], yieldBps[2], yieldBps[3]];
        uint16[4] memory fundingBps = [fundBps[0], fundBps[1], fundBps[2], fundBps[3]];

        if (!isValid) {
            if (isZeroYield) {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ZeroYieldSplit.selector, firstInvalidTier));
                registry.setYieldSplits(vaultId, yieldSplitsBps, fundingBps);
            } else {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(VaultRegistry.InvalidSplitTotal.selector, firstInvalidTier));
                registry.setYieldSplits(vaultId, yieldSplitsBps, fundingBps);
            }
        } else {
            vm.startPrank(owner);
            registry.setYieldSplits(vaultId, yieldSplitsBps, fundingBps);
            vm.warp(block.timestamp + 2 days + 1);
            registry.finalizeYieldSplits(vaultId);
            vm.stopPrank();

            VaultConfig memory cfg = registry.getVault(vaultId);
            for (uint8 i = 0; i < 4; i++) {
                assertEq(cfg.yieldSplitsBps[i], yieldSplitsBps[i], "yieldSplitsBps must be updated");
                assertEq(cfg.fundingBps[i], fundingBps[i], "fundingBps must be updated");
                // Invariant: yield + funding <= 10000
                assertLe(
                    uint256(cfg.yieldSplitsBps[i]) + uint256(cfg.fundingBps[i]),
                    10000,
                    "yield + funding must be <= 10000 after update"
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 6: Multi-vault registration sequences
    // Requirements: R-05, R-43 (monotonic IDs), R-44 (abbreviation uniqueness)
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_multiVaultRegistration(uint8 countRaw) public {
        uint256 count = bound(uint256(countRaw), 1, 20);

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        uint256 previousId = 0;

        for (uint256 i = 0; i < count; i++) {
            string memory abbr = _uintToAbbr(i + 100); // offset to avoid collisions
            // OF-003: Generate unique tier vault addresses per vault
            string memory idx = vm.toString(i);
            address[4] memory tierVaults = [
                makeAddr(string(abi.encodePacked("fz_t0_", idx))),
                makeAddr(string(abi.encodePacked("fz_t1_", idx))),
                makeAddr(string(abi.encodePacked("fz_t2_", idx))),
                makeAddr(string(abi.encodePacked("fz_t3_", idx)))
            ];

            vm.prank(owner);
            uint256 vid = registry.addVault(
                name, abbr, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
            );

            // Monotonic: each ID strictly greater than previous
            assertGt(vid, previousId, "vault IDs must be strictly increasing");
            assertEq(vid, previousId + 1, "vault IDs must be sequential");
            previousId = vid;

            // Abbreviation resolves correctly
            assertEq(registry.getVaultByAbbreviation(abbr), vid, "abbreviation must resolve to correct vaultId");
        }

        // Final count must match
        assertEq(registry.vaultCount(), count, "vaultCount must equal number of registrations");

        // getAllVaults length must match
        uint256[] memory allVaults = registry.getAllVaults();
        assertEq(allVaults.length, count, "getAllVaults length must equal count");

        // All vaults must be active
        uint256[] memory activeVaults = registry.getActiveVaults();
        assertEq(activeVaults.length, count, "all vaults must be active");
    }

    // ─────────────────────────────────────────────────────────
    // Fuzz 7: Abbreviation uniqueness with random strings
    // Requirements: R-12 (DuplicateAbbreviation), R-44 (uniqueness invariant)
    // ─────────────────────────────────────────────────────────
    function testFuzz_TC14_abbreviationUniqueness(uint256 seed1, uint256 seed2) public {
        string memory abbrev1 = _uintToAbbr(seed1);
        string memory abbrev2 = _uintToAbbr(seed2);

        (
            string memory name,,,
            address stakingQueue,
            uint256 capacityCap,
            uint256[4] memory lockupDurations,
            uint16[4] memory yieldSplitsBps,
            uint16[4] memory fundingBps
        ) = _createDefaultVaultParams();

        // OF-003: Unique tier vault addresses per vault
        address[4] memory tiers1 = [makeAddr("fu_t0_1"), makeAddr("fu_t1_1"), makeAddr("fu_t2_1"), makeAddr("fu_t3_1")];
        address[4] memory tiers2 = [makeAddr("fu_t0_2"), makeAddr("fu_t1_2"), makeAddr("fu_t2_2"), makeAddr("fu_t3_2")];

        // Register first vault with abbrev1
        vm.prank(owner);
        uint256 id1 = registry.addVault(
            name, abbrev1, tiers1, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        );

        bool sameAbbreviation = keccak256(bytes(abbrev1)) == keccak256(bytes(abbrev2));

        if (sameAbbreviation) {
            // Duplicate abbreviation must revert
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(VaultRegistry.DuplicateAbbreviation.selector, abbrev2));
            registry.addVault(
                name, abbrev2, tiers2, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
            );
        } else {
            // Different abbreviation must succeed
            vm.prank(owner);
            uint256 id2 = registry.addVault(
                name, abbrev2, tiers2, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
            );

            // Both abbreviations resolve to correct vault IDs
            assertEq(registry.getVaultByAbbreviation(abbrev1), id1, "abbrev1 must resolve to id1");
            assertEq(registry.getVaultByAbbreviation(abbrev2), id2, "abbrev2 must resolve to id2");

            // They must be different vaults
            assertTrue(id1 != id2, "vault IDs must be different");
        }
    }
}
