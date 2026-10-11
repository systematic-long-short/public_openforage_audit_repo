// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

library AtRiskUSDWeeklyExitModule {
    error WeeklyExitAccountingInvariant(uint256 expected, uint256 actual);

    function directRoom(uint256 weeklyRoom, uint256 queuedReserve) internal pure returns (uint256) {
        return queuedReserve >= weeklyRoom ? 0 : weeklyRoom - queuedReserve;
    }

    function entitlement(uint256 requestShares, uint256 roomShares, uint256 demandShares)
        internal
        pure
        returns (uint256)
    {
        if (demandShares == 0) {
            if (roomShares != 0) revert WeeklyExitAccountingInvariant(demandShares, roomShares);
            return 0;
        }
        uint256 fillableRoom = roomShares < demandShares ? roomShares : demandShares;
        return Math.mulDiv(requestShares, fillableRoom, demandShares);
    }
}
