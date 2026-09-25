// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Allowlist.sol";

interface IDistributorTreasury {
    function setDistributor(address distributor_) external;
    function acceptDistributor() external;
    function distributor() external view returns (address);
}

/// @title RegisterAllowlist
/// @notice Post-deploy operator checklist: finalizes the registrar, registers the system
///         accounts the deploy could not, grants the non-expiring operator approvals and
///         sets both treasuries' distributors. Every step is guarded by a current-state
///         read, printed as a checklist line, and idempotent on a second run.
contract RegisterAllowlist is Script {
    error AllowlistNotDeployed(address target);
    error RegistrarFinalizeWaiting(bytes4 selector);
    error DistributorKeyMismatch(address signer, address distributor);

    uint256 internal sendCount;
    uint256 internal skipCount;
    uint256 internal waitCount;
    uint256 internal manualCount;
    bytes4 internal waitSelector;

    function run() external {
        string memory manifestPath =
            vm.envOr("DEPLOYMENT_MANIFEST_PATH", string("deployments/arbitrum-sepolia/latest.json"));
        string memory manifest = vm.readFile(manifestPath);
        address allowlist = _deployedAddress(manifest, ".allowlist");
        address forageTreasury = _deployedAddress(manifest, ".forageTreasury");
        address usdcTreasury = _deployedAddress(manifest, ".usdcTreasury");

        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");
        address custodianExecutor = vm.envAddress("CUSTODIAN_EXECUTOR");
        address launchVotingDelegate = vm.envAddress("LAUNCH_VOTING_DELEGATE");

        vm.startBroadcast(ownerKey);
        _finalizeRegistrar(allowlist, keeper);
        _registerSystemAccount(allowlist, distributor);
        _registerSystemAccount(allowlist, launchVotingDelegate);
        for (uint256 i; i < 7; ++i) {
            _approveOperator(allowlist, vm.envAddress(string.concat("GUARDIAN_", vm.toString(i))));
        }
        _approveOperator(allowlist, custodianExecutor);
        _approveOperator(allowlist, launchVotingDelegate);
        bool acceptForageTreasury = _setDistributor(forageTreasury, distributor);
        bool acceptUSDCTreasury = _setDistributor(usdcTreasury, distributor);
        vm.stopBroadcast();

        if (acceptForageTreasury) _acceptDistributor(forageTreasury, distributor);
        if (acceptUSDCTreasury) _acceptDistributor(usdcTreasury, distributor);

        console.log(_checklistLine());
        if (waitCount != 0) revert RegistrarFinalizeWaiting(waitSelector);
    }

    function _deployedAddress(string memory manifest, string memory key) internal view returns (address target) {
        target = vm.parseJsonAddress(manifest, key);
        if (target.code.length == 0) revert AllowlistNotDeployed(target);
    }

    function _finalizeRegistrar(address allowlist, address keeper) internal {
        if (Allowlist(allowlist).registrar() == keeper) {
            console.log("SKIP finalizeRegistrar");
            ++skipCount;
            return;
        }
        try Allowlist(allowlist).finalizeRegistrar() {
            console.log("SEND finalizeRegistrar", allowlist);
            ++sendCount;
        } catch (bytes memory reason) {
            if (reason.length < 4) _rethrow(reason);
            bytes4 selector = bytes4(reason);
            if (
                selector != Allowlist.FinalizeDelayNotElapsed.selector
                    && selector != Allowlist.NoPendingProposal.selector && selector != Allowlist.ProposalExpired.selector
            ) {
                _rethrow(reason);
            }
            waitSelector = selector;
            console.log(string.concat("WAIT finalizeRegistrar ", vm.toString(abi.encodePacked(selector))));
            ++waitCount;
        }
    }

    function _registerSystemAccount(address allowlist, address account) internal {
        if (Allowlist(allowlist).isSystemAccount(account)) {
            console.log("SKIP setSystemAccount", account);
            ++skipCount;
            return;
        }
        Allowlist(allowlist).setSystemAccount(account, true);
        console.log("SEND setSystemAccount", account);
        ++sendCount;
    }

    function _approveOperator(address allowlist, address account) internal {
        if (Allowlist(allowlist).allowedUntil(account) == type(uint64).max) {
            console.log("SKIP approveOperator", account);
            ++skipCount;
            return;
        }
        Allowlist(allowlist).approveOperator(account);
        console.log("SEND approveOperator", account);
        ++sendCount;
    }

    function _setDistributor(address treasury, address distributor) internal returns (bool) {
        if (IDistributorTreasury(treasury).distributor() == distributor) {
            console.log("SKIP setDistributor", treasury);
            ++skipCount;
            return false;
        }
        IDistributorTreasury(treasury).setDistributor(distributor);
        console.log("SEND setDistributor", treasury);
        ++sendCount;
        return true;
    }

    function _acceptDistributor(address treasury, address distributor) internal {
        bytes memory callData = abi.encodeCall(IDistributorTreasury.acceptDistributor, ());
        uint256 distributorKey = vm.envOr("DISTRIBUTOR_PRIVATE_KEY", uint256(0));
        if (distributorKey == 0) {
            console.log(
                string.concat("MANUAL acceptDistributor ", vm.toString(treasury), " calldata ", vm.toString(callData))
            );
            ++manualCount;
            return;
        }
        address signer = vm.addr(distributorKey);
        if (signer != distributor) revert DistributorKeyMismatch(signer, distributor);
        vm.startBroadcast(distributorKey);
        IDistributorTreasury(treasury).acceptDistributor();
        vm.stopBroadcast();
        console.log("SEND acceptDistributor", treasury);
        ++sendCount;
    }

    function _checklistLine() internal view returns (string memory) {
        return string.concat(
            "checklist: ",
            vm.toString(sendCount),
            " send, ",
            vm.toString(skipCount),
            " skip, ",
            vm.toString(waitCount),
            " wait, ",
            vm.toString(manualCount),
            " manual"
        );
    }

    function _rethrow(bytes memory reason) internal pure {
        assembly {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
