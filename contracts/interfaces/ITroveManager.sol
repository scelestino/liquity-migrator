// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

interface ITroveManager {

    function getEntireDebtAndColl(address _borrower) external view returns (
        uint debt,
        uint coll,
        uint pendingLUSDDebtReward,
        uint pendingETHReward
    );

}
