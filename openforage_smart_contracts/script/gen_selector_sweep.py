import argparse
import json
import os
import sys
from string import Template

import sha3

CONTRACTS = (
    ("atRISKUSD", "atRISKUSD.sol"),
    ("Blocklist", "Blocklist.sol"),
    ("CustodianRegistry", "CustodianRegistry.sol"),
    ("DelegatingVestingWallet", "DelegatingVestingWallet.sol"),
    ("FORAGETreasury", "FORAGETreasury.sol"),
    ("ForageGovernor", "ForageGovernor.sol"),
    ("ForageToken", "ForageToken.sol"),
    ("GuardianModule", "GuardianModule.sol"),
    ("HLTradingBridge", "hyperliquid/HLTradingBridge.sol"),
    ("RISKUSD", "RISKUSD.sol"),
    ("RISKUSDVault", "RISKUSDVault.sol"),
    ("StakingQueue", "StakingQueue.sol"),
    ("USDCTreasury", "USDCTreasury.sol"),
    ("VaultRegistry", "VaultRegistry.sol"),
)
ACCESSORS = {
    "atRISKUSD": "sweepTierVaults[0]",
    "Blocklist": "sweepBlocklist",
    "CustodianRegistry": "sweepCustodianRegistry",
    "DelegatingVestingWallet": "sweepVestingWallet",
    "FORAGETreasury": "sweepForageTreasury",
    "ForageGovernor": "sweepGovernor",
    "ForageToken": "sweepForage",
    "GuardianModule": "sweepGuardianModule",
    "HLTradingBridge": "sweepBridge",
    "RISKUSD": "sweepRiskusd",
    "RISKUSDVault": "sweepVault",
    "StakingQueue": "sweepQueue",
    "USDCTreasury": "sweepUsdcTreasury",
    "VaultRegistry": "sweepVaultRegistry",
}
EXEMPT_TOKENS = ("RISKUSD", "atRISKUSD", "ForageToken")
EXEMPT_NAMES = ("transfer", "approve", "transferFrom")
SEAM_NAMES = ("initialize", "initializeTarget", "setAllowlist", "setVaultModule", "setQueueModule")
SCALARS = {"address": "address(0)", "bool": "false", "bytes": '""', "string": '""'}
PREFIXES = ("gated", "exempt", "seam")
OUT_RELATIVE = os.path.join("test", "Gate.sweep.t.sol")


def root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def abi_file(root, contract, source):
    name = os.path.basename(source)
    return os.path.join(root, "out", name, contract + ".json")


def read_abi(path, contract):
    if not os.path.isfile(path):
        sys.stderr.write("missing ABI for %s: %s\n" % (contract, path))
        sys.exit(2)
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload.get("abi"), list):
        sys.stderr.write("missing ABI for %s: %s\n" % (contract, path))
        sys.exit(2)
    return payload["abi"]


def signature(entry):
    return "%s(%s)" % (entry["name"], ",".join(type_name(argument) for argument in entry["inputs"]))


def type_name(argument):
    if argument["type"].startswith("tuple"):
        fields = ",".join(type_name(component) for component in argument.get("components", ()))
        return "(%s)%s" % (fields, argument["type"][5:])
    return argument["type"]


def selector_of(text):
    digest = sha3.keccak_256()
    digest.update(text.encode("ascii"))
    return digest.hexdigest()[:8]


def zero_value(argument):
    return zero_expr(argument["type"], argument.get("internalType"), argument.get("components"))


def zero_expr(type_, internal=None, components=None):
    if internal:
        return zero_internal(internal, components)
    if type_ in SCALARS:
        return SCALARS[type_]
    if type_.endswith("[]"):
        return "new %s[](0)" % type_[:-2]
    if type_.endswith("]"):
        return zero_fixed(type_)
    return "%s(0)" % type_


def zero_internal(internal, components):
    base = internal.replace(" memory", "").replace(" calldata", "").replace(" storage", "")
    if base.startswith("enum "):
        return "%s(0)" % base[5:]
    if base.startswith("struct "):
        return "%s(%s)" % (base[7:], struct_fields(components))
    if base.startswith("contract "):
        return "address(0)"
    return zero_expr(base)


def struct_fields(components):
    return ", ".join(zero_value(component) for component in (components or ()))


def zero_fixed(type_):
    base, _, count = type_.rpartition("[")
    return "[%s]" % ", ".join(zero_expr(base) for _ in range(int(count[:-1])))


def is_state_changing(entry):
    return entry.get("type") == "function" and entry.get("stateMutability") in ("nonpayable", "payable")


def classify(contract, name):
    if contract in EXEMPT_TOKENS and name in EXEMPT_NAMES:
        return "exempt"
    if name in SEAM_NAMES:
        return "seam"
    return "gated"


def pair_rows(target, contract, abi):
    rows = []
    for entry in abi:
        if is_state_changing(entry):
            text = signature(entry)
            rows.append(
                {
                    "target": target,
                    "contract": contract,
                    "signature": text,
                    "selector": selector_of(text),
                    "kind": classify(contract, entry["name"]),
                    "arguments": ", ".join(zero_value(argument) for argument in entry["inputs"]),
                }
            )
    return rows


def collect(root):
    pairs = []
    for target, (contract, source) in enumerate(CONTRACTS):
        pairs.extend(pair_rows(target, contract, read_abi(abi_file(root, contract, source), contract)))
    return sorted(pairs, key=lambda pair: (pair["contract"], pair["selector"]))


def render_row(index, pair):
    arguments = "0x" + pair["selector"]
    if pair["arguments"]:
        arguments += ", " + pair["arguments"]
    row = "        pairs[%d] = SweepPair(%d, KIND_%s, 0x%s, abi.encodeWithSelector(%s));"
    rendered = row % (index, pair["target"], pair["kind"].upper(), pair["selector"], arguments)
    if len(rendered) <= 120:
        return rendered
    return (
        "        pairs[%d] = SweepPair(\n"
        "            %d, KIND_%s, 0x%s, abi.encodeWithSelector(\n"
        "                %s\n"
        "            )\n"
        "        );"
    ) % (index, pair["target"], pair["kind"].upper(), pair["selector"], arguments)


def render_rows(pairs):
    return "\n".join(render_row(index, pair) for index, pair in enumerate(pairs))


def render_targets():
    rows = ("        targets[%d] = address(%s);" % (index, ACCESSORS[contract]) for index, (contract, _) in enumerate(CONTRACTS))
    return "\n".join(rows)


def totals(pairs):
    counts = dict.fromkeys(PREFIXES, 0)
    for pair in pairs:
        counts[pair["kind"]] += 1
    return counts


def render_file(root):
    pairs = collect(root)
    counts = totals(pairs)
    return SOURCE.safe_substitute(
        contract_count=len(CONTRACTS),
        row_count=len(pairs),
        gated=counts["gated"],
        exempt=counts["exempt"],
        seam=counts["seam"],
        pairs=render_rows(pairs),
        targets=render_targets(),
    )


def check_file(path, generated):
    if not os.path.isfile(path):
        sys.stderr.write("missing generated file: %s\n" % path)
        return 1
    with open(path, encoding="utf-8") as handle:
        current = handle.read()
    if current == generated:
        sys.stdout.write("Gate.sweep.t.sol matches the generated bytes (%d lines)\n" % len(generated.splitlines()))
        return 0
    return report_drift(current.splitlines(), generated.splitlines())


def report_drift(current, generated):
    limit = min(len(current), len(generated))
    for number in range(limit):
        if current[number] != generated[number]:
            sys.stderr.write("drifted line %d:\n  checked in: %s\n  generated:  %s\n" % (number + 1, current[number], generated[number]))
            return 1
    sys.stderr.write("drifted line %d: checked in %d lines, generated %d lines\n" % (limit + 1, len(current), len(generated)))
    return 1


def print_table(pairs):
    for pair in pairs:
        sys.stdout.write("%s 0x%s %-11s %s\n" % (pair["contract"], pair["selector"], pair["kind"], pair["signature"]))


def main():
    parser = argparse.ArgumentParser(description="Generate contracts/test/Gate.sweep.t.sol from the fourteen out ABIs")
    parser.add_argument("--write", action="store_true", help="rewrite contracts/test/Gate.sweep.t.sol")
    parser.add_argument("--check", action="store_true", help="exit non-zero when the checked-in file is stale")
    options = parser.parse_args()
    root = root_dir()
    generated = render_file(root)
    target = os.path.join(root, OUT_RELATIVE)
    if options.write:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(generated)
        sys.stdout.write("wrote %s (%d lines)\n" % (OUT_RELATIVE, len(generated.splitlines())))
        return 0
    if options.check:
        return check_file(target, generated)
    print_table(collect(root))
    return 0


SOURCE = Template(
    '''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AllowlistGatedUpgradeable.sol";
import "../src/Blocklist.sol";
import "../src/CustodianRegistry.sol";
import "../src/DelegatingVestingWallet.sol";
import "../src/FORAGETreasury.sol";
import "../src/ForageGovernor.sol";
import "../src/ForageToken.sol";
import "../src/GuardianModule.sol";
import "../src/RISKUSD.sol";
import "../src/RISKUSDVault.sol";
import "../src/StakingQueue.sol";
import "../src/USDCTreasury.sol";
import "../src/VaultRegistry.sol";
import "../src/atRISKUSD.sol";
import "../src/hyperliquid/HLTradingBridge.sol";
import "../src/interfaces/IAllowlist.sol";
import "../src/modules/RISKUSDVaultModule.sol";
import "../src/modules/StakingQueueModule.sol";
import "./helpers/AllowlistHarness.sol";
import "./helpers/AllowlistTestBase.sol";
import "./mocks/MockSequencerUptimeFeed.sol";
import "./mocks/MockUSDC.sol";

/// @dev GENERATED by contracts/script/gen_selector_sweep.py --write; every non-view, non-pure function of the
/// fourteen gated contracts is called from one unverified EOA and checked against the real Allowlist registry.
contract GateSweepTest is Test, AllowlistTestBase {
    uint8 internal constant CONTRACTS = $contract_count;
    uint256 internal constant ROWS = $row_count;
    uint256 internal constant EXEMPT_PAIRS = $exempt;
    uint256 internal constant GATED_PAIRS = $gated;
    uint256 internal constant SEAM_PAIRS = $seam;
    uint8 internal constant SELECTOR_KINDS = 3;
    uint8 internal constant KIND_GATED = 0;
    uint8 internal constant KIND_EXEMPT = 1;
    uint8 internal constant KIND_SEAM = 2;

    struct SweepPair {
        uint8 target;
        uint8 kind;
        bytes4 selector;
        bytes data;
    }

    MockUSDC internal sweepUsdc;
    MockSequencerUptimeFeed internal sweepFeed;
    TimelockController internal sweepTimelock;
    RISKUSD internal sweepRiskusd;
    RISKUSDVault internal sweepVault;
    VaultRegistry internal sweepVaultRegistry;
    FORAGETreasury internal sweepForageTreasury;
    ForageToken internal sweepForage;
    StakingQueue internal sweepQueue;
    ForageGovernor internal sweepGovernor;
    GuardianModule internal sweepGuardianModule;
    Blocklist internal sweepBlocklist;
    CustodianRegistry internal sweepCustodianRegistry;
    USDCTreasury internal sweepUsdcTreasury;
    HLTradingBridge internal sweepBridge;
    DelegatingVestingWallet internal sweepVestingWallet;
    atRISKUSD[4] internal sweepTierVaults;
    address internal sweepUnverified;

    function setUp() public {
        vm.chainId(31_337);
        vm.warp(100);
        sweepUnverified = makeAddr("unverified");
        _deploySweepRegistry();
        _deploySweepStack();
        _wireSweepGate();
        _requireSweepWiring();
    }

    function _deploySweepRegistry() internal {
        address[] memory systemAccounts = new address[](1);
        systemAccounts[0] = address(this);
        address[] memory actors = new address[](0);
        deployAllowlistHarness(systemAccounts, actors);
    }

    function _deploySweepStack() internal {
        sweepUsdc = new MockUSDC();
        sweepFeed = new MockSequencerUptimeFeed();
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        sweepTimelock = new TimelockController(0, proposers, proposers, address(this));
        sweepRiskusd = RISKUSD(_proxy(address(new RISKUSD()), abi.encodeCall(RISKUSD.initialize, (address(this)))));
        sweepVault = RISKUSDVault(
            _proxy(
                address(new RISKUSDVault()),
                abi.encodeCall(RISKUSDVault.initialize, (address(sweepUsdc), address(sweepRiskusd), address(this)))
            )
        );
        sweepVault.setVaultModule(address(new RISKUSDVaultModule()));
        sweepVaultRegistry = VaultRegistry(
            _proxy(address(new VaultRegistry()), abi.encodeCall(VaultRegistry.initialize, (address(this))))
        );
        for (uint256 i; i < 4; ++i) {
            sweepTierVaults[i] = atRISKUSD(
                _proxy(
                    address(new atRISKUSD()),
                    abi.encodeCall(
                        atRISKUSD.initialize,
                        (
                            address(sweepRiskusd),
                            address(0),
                            address(0),
                            1 days,
                            1 hours,
                            uint8(i),
                            "atRISKUSD",
                            address(this)
                        )
                    )
                )
            );
        }
        uint256 nonce = vm.getNonce(address(this));
        sweepForageTreasury = FORAGETreasury(
            _proxy(
                address(new FORAGETreasury()),
                abi.encodeCall(FORAGETreasury.initialize, (vm.computeCreateAddress(address(this), nonce + 3), address(this)))
            )
        );
        sweepForage = ForageToken(
            _proxy(
                address(new ForageToken()),
                abi.encodeCall(ForageToken.initialize, (address(this), address(sweepForageTreasury), address(this)))
            )
        );
        address[4] memory tiers = [
            address(sweepTierVaults[0]),
            address(sweepTierVaults[1]),
            address(sweepTierVaults[2]),
            address(sweepTierVaults[3])
        ];
        sweepQueue = StakingQueue(
            _proxy(
                address(new StakingQueue()),
                abi.encodeCall(
                    StakingQueue.initialize,
                    (address(sweepRiskusd), address(sweepForage), tiers, address(sweepVaultRegistry), address(this))
                )
            )
        );
        sweepQueue.setQueueModule(address(new StakingQueueModule()));
        nonce = vm.getNonce(address(this));
        address[] memory guardians = new address[](0);
        uint256[] memory permissions = new uint256[](0);
        sweepGuardianModule = GuardianModule(
            _proxy(
                address(new GuardianModule()),
                abi.encodeCall(
                    GuardianModule.initialize,
                    (vm.computeCreateAddress(address(this), nonce + 3), address(sweepTimelock), guardians, permissions)
                )
            )
        );
        sweepGovernor = ForageGovernor(
            payable(
                _proxy(
                    address(new ForageGovernor()),
                    abi.encodeCall(
                        ForageGovernor.initialize,
                        (
                            address(sweepForage),
                            address(sweepTimelock),
                            uint48(0),
                            uint32(1 hours),
                            uint256(100),
                            uint256(400),
                            address(sweepGuardianModule)
                        )
                    )
                )
            )
        );
        sweepUsdcTreasury = USDCTreasury(
            _proxy(
                address(new USDCTreasury()),
                abi.encodeCall(
                    USDCTreasury.initialize,
                    (
                        address(sweepUsdc),
                        address(sweepVault),
                        address(sweepVaultRegistry),
                        address(this),
                        makeAddr("foundation primary"),
                        makeAddr("foundation backup"),
                        makeAddr("protocol primary"),
                        makeAddr("protocol backup")
                    )
                )
            )
        );
        sweepCustodianRegistry = CustodianRegistry(
            _proxy(
                address(new CustodianRegistry()),
                abi.encodeCall(
                    CustodianRegistry.initialize,
                    (address(this), address(sweepGovernor), address(sweepGuardianModule))
                )
            )
        );
        HLTradingBridge.RouteConfig memory route = HLTradingBridge.RouteConfig(
            makeAddr("cold account"),
            bytes32(uint256(uint160(makeAddr("cold account")))),
            uint64(block.chainid),
            address(sweepFeed)
        );
        sweepBridge = HLTradingBridge(
            _proxy(
                address(new HLTradingBridge()),
                abi.encodeCall(
                    HLTradingBridge.initialize,
                    (
                        address(sweepUsdc),
                        address(sweepVault),
                        address(sweepUsdcTreasury),
                        address(sweepCustodianRegistry),
                        address(this),
                        makeAddr("keeper"),
                        makeAddr("custodian executor"),
                        address(sweepGuardianModule),
                        route
                    )
                )
            )
        );
        sweepBlocklist = Blocklist(
            _proxy(address(new Blocklist()), abi.encodeCall(Blocklist.initialize, (address(this), address(this))))
        );
        sweepVestingWallet = new DelegatingVestingWallet(
            address(this), uint64(block.timestamp), uint64(4 * 365 days), uint64(365 days), address(this), address(allowlist)
        );
    }

    function _proxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }

    function _wireSweepGate() internal {
        address[CONTRACTS] memory targets = _sweepTargets();
        for (uint256 i; i < CONTRACTS; ++i) {
            allowlist.setSystemAccount(targets[i], true);
        }
        allowlist.setSystemAccount(address(sweepTimelock), true);
        for (uint256 i; i < CONTRACTS; ++i) {
            if (targets[i] != address(sweepGovernor) && targets[i] != address(sweepGuardianModule)) {
                IAllowlistSettable(targets[i]).setAllowlist(address(allowlist));
            }
        }
        _timelockSetAllowlist(address(sweepGuardianModule));
        _timelockSetAllowlist(address(sweepGovernor));
    }

    function _timelockSetAllowlist(address target) internal {
        bytes memory data = abi.encodeCall(IAllowlistSettable.setAllowlist, (address(allowlist)));
        sweepTimelock.schedule(target, 0, data, bytes32(0), bytes32(0), 0);
        sweepTimelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function _requireSweepWiring() internal view {
        address[CONTRACTS] memory targets = _sweepTargets();
        for (uint256 i; i < CONTRACTS; ++i) {
            assertGt(targets[i].code.length, 0, "SWEEP target has no code");
            assertEq(
                AllowlistGatedUpgradeable(targets[i]).allowlist(),
                address(allowlist),
                "SWEEP target is not wired to the real registry"
            );
        }
    }

    function _sweepTargets() internal view returns (address[CONTRACTS] memory targets) {
$targets
    }

    function _sweepPairs() internal pure returns (SweepPair[] memory pairs) {
        pairs = new SweepPair[](ROWS);
$pairs
    }

    function test_sweepSelectorGate() public {
        address[CONTRACTS] memory targets = _sweepTargets();
        SweepPair[] memory pairs = _sweepPairs();
        uint256 gated;
        uint256 exempt;
        uint256 seams;
        uint256 ozGuarded;
        for (uint256 i; i < pairs.length; ++i) {
            SweepPair memory pair = pairs[i];
            address target = targets[pair.target];
            assertGt(target.code.length, 0, "SWEEP target has no code");
            vm.prank(sweepUnverified);
            (bool ok, bytes memory ret) = target.call(pair.data);
            if (pair.kind == KIND_GATED) {
                assertFalse(ok, "SWEEP gated call did not revert");
                assertTrue(
                    _revertSelector(ret) == IAllowlist.CallerNotAllowed.selector,
                    string.concat("SWEEP gated call reverted with the wrong selector: ", vm.toString(bytes32(pair.selector)))
                );
                assertEq(_revertCaller(ret), sweepUnverified, "SWEEP gated call named the wrong caller");
                ++gated;
            } else if (pair.kind == KIND_EXEMPT) {
                _requireNotGated(ok, ret, "SWEEP exempt call was gated");
                ++exempt;
            } else if (pair.kind == KIND_SEAM) {
                assertFalse(ok, "SWEEP bootstrap seam call succeeded for an unverified caller");
                _requireNotGated(ok, ret, "SWEEP bootstrap seam call was gated");
                ++seams;
            } else {
                ++ozGuarded;
            }
        }
        uint256 pairCount = gated + exempt;
        assertEq(pairCount, gated + EXEMPT_PAIRS, "SWEEP pairs != gated + exempt");
        assertEq(gated, GATED_PAIRS, "SWEEP gated pair count");
        assertEq(exempt, EXEMPT_PAIRS, "SWEEP exempt pair count");
        assertEq(seams, SEAM_PAIRS, "SWEEP bootstrap seam count");
        assertEq(ozGuarded, 0, "SWEEP unrecognized selector kinds");
        console.log(
            string.concat(
                "SWEEP contracts=",
                vm.toString(uint256(CONTRACTS)),
                " pairs=",
                vm.toString(pairCount),
                " gated=",
                vm.toString(gated),
                " exempt=",
                vm.toString(exempt),
                " selectorKinds=",
                vm.toString(uint256(SELECTOR_KINDS))
            )
        );
        console.log(string.concat("SWEEP seams=", vm.toString(seams), " ozGuarded=", vm.toString(ozGuarded)));
    }

    function _requireNotGated(bool ok, bytes memory ret, string memory label) internal pure {
        assertTrue(ok || _revertSelector(ret) != IAllowlist.CallerNotAllowed.selector, label);
    }

    function _revertSelector(bytes memory ret) internal pure returns (bytes4 selector) {
        if (ret.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(ret, 32))
        }
    }

    function _revertCaller(bytes memory ret) internal pure returns (address account) {
        if (ret.length < 36) return address(0);
        assembly {
            account := mload(add(ret, 36))
        }
    }
}
'''
)

if __name__ == "__main__":
    sys.exit(main())
