// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/VaultRegistryTestBase.sol";

// ============================================================
// Handler Contract for Invariant Testing
// ============================================================

/// @dev Handler that randomly calls VaultRegistry state-changing functions
/// with bounded inputs. Tracks ghost state for invariant assertions.
contract VaultRegistryHandler is Test {
    VaultRegistry public registry;
    address public owner;

    // ── Ghost state ──

    /// @dev Number of successful addVault calls.
    uint256 public ghostVaultCount;

    /// @dev Last vault ID assigned (for monotonicity check).
    uint256 public ghostLastVaultId;

    /// @dev All registered vault IDs.
    uint256[] public registeredVaultIds;

    /// @dev All registered abbreviations (as keccak hashes for uniqueness check).
    mapping(bytes32 => bool) public abbreviationHashExists;

    /// @dev Abbreviation strings for each vault ID.
    mapping(uint256 => string) public vaultAbbreviations;

    /// @dev Status snapshot for each vault ID (before an operation on another vault).
    mapping(uint256 => VaultStatus) public ghostVaultStatus;

    /// @dev Capacity cap snapshot for each vault.
    mapping(uint256 => uint256) public ghostCapacityCap;

    /// @dev Yield splits snapshot.
    mapping(uint256 => uint16[4]) internal _ghostYieldSplits;

    /// @dev Funding bps snapshot.
    mapping(uint256 => uint16[4]) internal _ghostFundingBps;

    /// @dev Abbreviation seed counter for generating unique abbreviations.
    uint256 internal _abbrCounter;

    constructor(VaultRegistry registry_, address owner_) {
        registry = registry_;
        owner = owner_;
    }

    // ── Helper: deterministic abbreviation from counter ──
    function _nextAbbr() internal returns (string memory) {
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        uint256 seed = _abbrCounter++;
        bytes memory out = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = alphabet[seed % 26];
            seed /= 26;
        }
        return string(out);
    }

    // ── Handler functions exposed to the fuzzer ──

    function addVault(uint256 capSeed) external {
        uint256 capacityCap = bound(capSeed, 1, 1e30);
        string memory abbr = _nextAbbr();
        bytes32 abbrHash = keccak256(bytes(abbr));

        // Skip if abbreviation collision (should not happen with counter-based generation)
        if (abbreviationHashExists[abbrHash]) return;

        address[4] memory tierVaults = [
            address(uint160(uint256(keccak256(abi.encodePacked(_abbrCounter, uint256(0)))))),
            address(uint160(uint256(keccak256(abi.encodePacked(_abbrCounter, uint256(1)))))),
            address(uint160(uint256(keccak256(abi.encodePacked(_abbrCounter, uint256(2)))))),
            address(uint160(uint256(keccak256(abi.encodePacked(_abbrCounter, uint256(3))))))
        ];
        // Ensure non-zero
        for (uint8 i = 0; i < 4; i++) {
            if (tierVaults[i] == address(0)) tierVaults[i] = address(uint160(i + 1));
        }
        address stakingQueue = address(uint160(uint256(keccak256(abi.encodePacked(_abbrCounter, uint256(99))))));
        if (stakingQueue == address(0)) stakingQueue = address(100);

        uint16[4] memory yieldSplitsBps = [uint16(5000), uint16(5500), uint16(6000), uint16(6500)];
        uint16[4] memory fundingBps = [uint16(2000), uint16(2000), uint16(1500), uint16(1500)];
        uint256[4] memory lockupDurations = [uint256(0), 90 days, 180 days, 365 days];

        vm.prank(owner);
        try registry.addVault(
            "FuzzVault", abbr, tierVaults, stakingQueue, capacityCap, lockupDurations, yieldSplitsBps, fundingBps
        ) returns (
            uint256 vaultId
        ) {
            ghostVaultCount++;
            ghostLastVaultId = vaultId;
            registeredVaultIds.push(vaultId);
            abbreviationHashExists[abbrHash] = true;
            vaultAbbreviations[vaultId] = abbr;
            ghostVaultStatus[vaultId] = VaultStatus.Active;
            ghostCapacityCap[vaultId] = capacityCap;
            _ghostYieldSplits[vaultId] = yieldSplitsBps;
            _ghostFundingBps[vaultId] = fundingBps;
        } catch {}
    }

    function pauseVault(uint256 idSeed) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];

        // Snapshot all other vaults before the operation
        vm.prank(owner);
        try registry.pauseVault(targetId) {
            ghostVaultStatus[targetId] = VaultStatus.Paused;
        } catch {}
    }

    function startWindDown(uint256 idSeed) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];

        vm.prank(owner);
        try registry.startWindDown(targetId) {
            ghostVaultStatus[targetId] = VaultStatus.WindingDown;
        } catch {}
    }

    function setCapacityCap(uint256 idSeed, uint256 capSeed) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];
        uint256 newCap = bound(capSeed, 1, 1e30);

        // OF-17-004: setCapacityCap only proposes — ghost NOT updated here.
        // Ghost is updated in finalizeCapacityCap after the delay elapses.
        vm.prank(owner);
        try registry.setCapacityCap(targetId, newCap) {} catch {}
    }

    function finalizeCapacityCap(uint256 idSeed) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];

        // Warp past FINALIZE_DELAY (2 days) to allow finalization
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        try registry.finalizeCapacityCap(targetId) {
            // Update ghost only on successful finalization
            VaultConfig memory cfg = registry.getVault(targetId);
            ghostCapacityCap[targetId] = cfg.capacityCap;
        } catch {}
    }

    function setYieldSplits(uint256 idSeed, uint16[4] calldata yieldBps, uint16[4] calldata fundBps) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];

        // Bound to valid ranges
        uint16[4] memory yieldSplitsBps;
        uint16[4] memory fundingBps;
        for (uint8 i = 0; i < 4; i++) {
            yieldSplitsBps[i] = uint16(bound(uint256(yieldBps[i]), 1, 10000));
            fundingBps[i] = uint16(bound(uint256(fundBps[i]), 0, 10000 - uint256(yieldSplitsBps[i])));
        }

        // OF-17: setYieldSplits only proposes — ghost NOT updated here.
        // Ghost is updated in finalizeYieldSplits after the delay elapses.
        vm.prank(owner);
        try registry.setYieldSplits(targetId, yieldSplitsBps, fundingBps) {} catch {}
    }

    function finalizeYieldSplits(uint256 idSeed) external {
        if (registeredVaultIds.length == 0) return;
        uint256 idx = idSeed % registeredVaultIds.length;
        uint256 targetId = registeredVaultIds[idx];

        // Warp past FINALIZE_DELAY (2 days) to allow finalization
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(owner);
        try registry.finalizeYieldSplits(targetId) {
            // Update ghost only on successful finalization
            VaultConfig memory cfg = registry.getVault(targetId);
            _ghostYieldSplits[targetId] = cfg.yieldSplitsBps;
            _ghostFundingBps[targetId] = cfg.fundingBps;
        } catch {}
    }

    // ── Accessors for invariant contract ──

    function registeredVaultCount() external view returns (uint256) {
        return registeredVaultIds.length;
    }

    function registeredVaultIdAt(uint256 idx) external view returns (uint256) {
        return registeredVaultIds[idx];
    }

    function ghostYieldSplits(uint256 vaultId, uint8 tier) external view returns (uint16) {
        return _ghostYieldSplits[vaultId][tier];
    }

    function ghostFundingBps(uint256 vaultId, uint8 tier) external view returns (uint16) {
        return _ghostFundingBps[vaultId][tier];
    }
}

// ============================================================
// TC-12: Invariant Tests (R-43, R-44, R-45, R-46, R-47, R-48, R-49)
// ============================================================
contract VaultRegistry_TC12_Invariant is VaultRegistryTestBase {
    VaultRegistryHandler public handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultRegistryHandler(registry, owner);
        targetContract(address(handler));
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 1: Vault ID monotonicity (R-43)
    // _nextVaultId strictly increases. Each new vault ID = previous + 1.
    // ─────────────────────────────────────────────────────────
    function invariant_vaultIdMonotonicity() external view {
        uint256 count = handler.registeredVaultCount();
        if (count == 0) return;

        uint256 prevId = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);
            assertGt(vid, prevId, "vault IDs must be strictly increasing");
            assertEq(vid, prevId + 1, "vault IDs must be sequential (increment by 1)");
            prevId = vid;
        }
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 2: Abbreviation uniqueness (R-44)
    // No two vaults share an abbreviation. Every abbreviation
    // resolves to the correct vault ID.
    // ─────────────────────────────────────────────────────────
    function invariant_abbreviationUniqueness() external view {
        uint256 count = handler.registeredVaultCount();
        if (count == 0) return;

        // For each registered vault, verify its abbreviation resolves to itself
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);
            string memory abbr = handler.vaultAbbreviations(vid);
            uint256 resolvedId = registry.getVaultByAbbreviation(abbr);
            assertEq(resolvedId, vid, "abbreviation must resolve to its own vaultId");
        }

        // Cross-check: no two vault IDs have the same abbreviation hash
        // (already enforced by handler's abbreviationHashExists mapping,
        //  but verify on-chain state independently)
        for (uint256 i = 0; i < count; i++) {
            uint256 vidI = handler.registeredVaultIdAt(i);
            string memory abbrI = handler.vaultAbbreviations(vidI);
            bytes32 hashI = keccak256(bytes(abbrI));
            for (uint256 j = i + 1; j < count; j++) {
                uint256 vidJ = handler.registeredVaultIdAt(j);
                string memory abbrJ = handler.vaultAbbreviations(vidJ);
                bytes32 hashJ = keccak256(bytes(abbrJ));
                assertTrue(hashI != hashJ, "no two vaults may share the same abbreviation");
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 3: vaultCount consistency (R-45)
    // vaultCount() == number of registered vaults.
    // ─────────────────────────────────────────────────────────
    function invariant_vaultCountConsistency() external view {
        assertEq(
            registry.vaultCount(),
            handler.ghostVaultCount(),
            "vaultCount() must equal number of successful addVault calls"
        );
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 4: Status transitions one-way (R-46)
    // Active -> Paused, Active -> WindingDown, Paused -> WindingDown only.
    // No reverse transitions.
    // ─────────────────────────────────────────────────────────
    function invariant_statusTransitionsOneWay() external view {
        uint256 count = handler.registeredVaultCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);
            VaultConfig memory cfg = registry.getVault(vid);

            // On-chain status must match the ghost status tracked by the handler
            VaultStatus ghostStatus = handler.ghostVaultStatus(vid);
            assertEq(
                uint8(cfg.status),
                uint8(ghostStatus),
                "on-chain status must match ghost-tracked status (no unauthorized transitions)"
            );

            // Additional: if ghost says WindingDown, on-chain must be WindingDown
            // (no reverse transitions from WindingDown)
            if (ghostStatus == VaultStatus.WindingDown) {
                assertEq(
                    uint8(cfg.status),
                    uint8(VaultStatus.WindingDown),
                    "WindingDown is terminal -- cannot transition back"
                );
            }

            // If ghost says Paused, on-chain must be Paused or WindingDown (not Active)
            if (ghostStatus == VaultStatus.Paused) {
                assertTrue(
                    cfg.status == VaultStatus.Paused || cfg.status == VaultStatus.WindingDown,
                    "Paused vault cannot return to Active"
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 5: Per-vault independence (R-47)
    // Pausing/winding down one vault does not affect others.
    // ─────────────────────────────────────────────────────────
    function invariant_perVaultIndependence() external view {
        uint256 count = handler.registeredVaultCount();
        if (count < 2) return;

        // For each vault, verify its config matches its ghost state
        // regardless of operations performed on other vaults
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);
            VaultConfig memory cfg = registry.getVault(vid);

            // Status must match ghost
            assertEq(
                uint8(cfg.status),
                uint8(handler.ghostVaultStatus(vid)),
                "vault status must reflect only its own transitions"
            );

            // Capacity cap must match ghost
            assertEq(
                cfg.capacityCap,
                handler.ghostCapacityCap(vid),
                "vault capacity cap must reflect only its own setCapacityCap calls"
            );

            // Yield splits and funding bps must match ghost
            for (uint8 t = 0; t < 4; t++) {
                assertEq(
                    cfg.yieldSplitsBps[t],
                    handler.ghostYieldSplits(vid, t),
                    "yieldSplitsBps must reflect only its own setYieldSplits calls"
                );
                assertEq(
                    cfg.fundingBps[t],
                    handler.ghostFundingBps(vid, t),
                    "fundingBps must reflect only its own setYieldSplits calls"
                );
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 6: View functions work regardless of status (R-48)
    // getVault, getVaultByAbbreviation, getActiveVaults, getAllVaults,
    // vaultCount -- none revert on registered vaults.
    // ─────────────────────────────────────────────────────────
    function invariant_viewFunctionsWork() external view {
        uint256 count = handler.registeredVaultCount();

        // vaultCount must not revert (implicit -- if it reverts, this call fails)
        uint256 vc = registry.vaultCount();
        assertEq(vc, handler.ghostVaultCount(), "vaultCount view must work");

        // getActiveVaults must not revert
        uint256[] memory activeIds = registry.getActiveVaults();
        // All returned IDs must be Active
        for (uint256 i = 0; i < activeIds.length; i++) {
            VaultConfig memory cfg = registry.getVault(activeIds[i]);
            assertEq(uint8(cfg.status), uint8(VaultStatus.Active), "getActiveVaults must return only Active vaults");
        }

        // getAllVaults must not revert and must include all registered IDs
        uint256[] memory allIds = registry.getAllVaults();
        assertEq(allIds.length, count, "getAllVaults must return all registered vault IDs");

        // Per-vault view functions must work regardless of status
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);

            // getVault must not revert
            VaultConfig memory cfg = registry.getVault(vid);
            assertEq(cfg.vaultId, vid, "getVault must return correct vaultId regardless of status");

            // getVaultByAbbreviation must not revert
            string memory abbr = handler.vaultAbbreviations(vid);
            uint256 resolvedId = registry.getVaultByAbbreviation(abbr);
            assertEq(resolvedId, vid, "getVaultByAbbreviation must work regardless of vault status");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Invariant 7: Yield split bounds (R-49)
    // yieldSplitsBps[i] + fundingBps[i] <= 10000 for all tiers
    // in all vaults.
    // ─────────────────────────────────────────────────────────
    function invariant_yieldSplitBounds() external view {
        uint256 count = handler.registeredVaultCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 vid = handler.registeredVaultIdAt(i);
            VaultConfig memory cfg = registry.getVault(vid);
            for (uint8 t = 0; t < 4; t++) {
                uint256 sum = uint256(cfg.yieldSplitsBps[t]) + uint256(cfg.fundingBps[t]);
                assertLe(
                    sum,
                    10000,
                    string.concat("yieldSplitsBps + fundingBps must be <= 10000 for tier ", vm.toString(uint256(t)))
                );
                // Also verify yield is non-zero (R-15)
                assertGt(
                    uint256(cfg.yieldSplitsBps[t]),
                    0,
                    string.concat("yieldSplitsBps must be > 0 for tier ", vm.toString(uint256(t)))
                );
            }
        }
    }
}
