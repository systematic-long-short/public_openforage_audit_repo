pragma solidity ^0.8.20;

import "./interfaces/IAllowlist.sol";

interface IGuardianModuleEmergencyPrincipalLane {
    function allowlist() external view returns (address);
    function isGuardian(address account) external view returns (bool);
    function getGuardianPermissions(address account) external view returns (uint256);
    function getGuardians() external view returns (address[] memory);
}

contract GuardianEmergencyPrincipalLane {
    error InvalidGuardianModule(address module);
    error InvalidAllowlist(address allowlist);
    error CallerNotAllowed(address caller);
    error NotPauseGuardian(address guardian);
    error LaneAlreadyOpen(uint256 laneOpenUntil);

    event LaneVoteCast(address indexed guardian, uint256 expiresAt);
    event PrincipalLaneOpened(uint256 laneOpenUntil);

    uint256 private constant _PAUSE_PERMISSION = 1;
    uint256 private constant _QUORUM = 4;
    uint256 private constant _VOTE_LIFETIME = 24 hours;
    uint256 private constant _LANE_LIFETIME = 7 days;

    address private immutable _guardianModule;
    mapping(address => uint256) private _voteExpiresAt;
    uint256 private _laneOpenUntil;

    constructor(address guardianModule_, address allowlist_) {
        if (guardianModule_ == address(0) || guardianModule_.code.length == 0) {
            revert InvalidGuardianModule(guardianModule_);
        }
        if (allowlist_ == address(0) || allowlist_.code.length == 0) revert InvalidAllowlist(allowlist_);
        _guardianModule = guardianModule_;
    }

    function castLaneVote() external {
        if (!_currentAllowlist().isAllowed(msg.sender)) revert CallerNotAllowed(msg.sender);
        if (!isLaneGuardian(msg.sender)) revert NotPauseGuardian(msg.sender);
        if (_laneOpenUntil > block.timestamp) revert LaneAlreadyOpen(_laneOpenUntil);
        uint256 expiresAt = block.timestamp + _VOTE_LIFETIME;
        _voteExpiresAt[msg.sender] = expiresAt;
        emit LaneVoteCast(msg.sender, expiresAt);
        if (block.timestamp >= _laneOpenUntil && _activeVoteCount() >= _QUORUM) {
            _laneOpenUntil = block.timestamp + _LANE_LIFETIME;
            emit PrincipalLaneOpened(_laneOpenUntil);
        }
    }

    function principalLaneOpen() external view returns (bool) {
        return _laneOpenUntil > block.timestamp;
    }

    function laneOpenUntil() external view returns (uint256) {
        return _laneOpenUntil;
    }

    function isLaneGuardian(address account) public view returns (bool) {
        IGuardianModuleEmergencyPrincipalLane module = IGuardianModuleEmergencyPrincipalLane(_guardianModule);
        if (!_currentAllowlist().isAllowed(account)) return false;
        if (!module.isGuardian(account) || module.getGuardianPermissions(account) & _PAUSE_PERMISSION == 0) {
            return false;
        }
        return _contains(module.getGuardians(), account);
    }

    function _activeVoteCount() private view returns (uint256 count) {
        IGuardianModuleEmergencyPrincipalLane module = IGuardianModuleEmergencyPrincipalLane(_guardianModule);
        IAllowlist currentAllowlist = _currentAllowlist();
        address[] memory guardians = module.getGuardians();
        for (uint256 i; i < guardians.length;) {
            address guardian = guardians[i];
            if (
                !_appearedEarlier(guardians, i, guardian) && _voteExpiresAt[guardian] > block.timestamp
                    && _hasPausePermission(module, guardian) && currentAllowlist.isAllowed(guardian)
            ) ++count;
            unchecked {
                ++i;
            }
        }
    }

    function _currentAllowlist() private view returns (IAllowlist) {
        address currentAllowlist = IGuardianModuleEmergencyPrincipalLane(_guardianModule).allowlist();
        if (currentAllowlist == address(0) || currentAllowlist.code.length == 0) {
            revert InvalidAllowlist(currentAllowlist);
        }
        return IAllowlist(currentAllowlist);
    }

    function _hasPausePermission(IGuardianModuleEmergencyPrincipalLane module, address guardian)
        private
        view
        returns (bool)
    {
        return module.isGuardian(guardian) && module.getGuardianPermissions(guardian) & _PAUSE_PERMISSION != 0;
    }

    function _appearedEarlier(address[] memory guardians, uint256 index, address guardian)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < index;) {
            if (guardians[i] == guardian) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _contains(address[] memory guardians, address account) private pure returns (bool) {
        for (uint256 i; i < guardians.length;) {
            if (guardians[i] == account) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
