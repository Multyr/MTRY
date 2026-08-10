// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";

/// @title Token-stack property tests verifying allocation and bucket invariants.
contract TokenStackInvariantsTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function test_allocationsSumIs300M() public view {
        uint256 sum = mtry.balanceOf(treasurySafe)
            + mtry.balanceOf(liquiditySafe)
            + mtry.balanceOf(address(claim))
            + mtry.balanceOf(address(vestingManager))
            + mtry.balanceOf(address(ecosystem));
        assertEq(sum, 300_000_000e18);
    }

    function test_bucketCapSumIs111M() public view {
        uint256 sum = TEAM_CAP + STRATEGIC_STANDARD_CAP + STRATEGIC_EXTENDED_CAP
            + ADVISORS_STANDARD_CAP + ADVISORS_SHORT_CAP;
        assertEq(sum, 111_000_000e18);
    }

    function test_totalBurnedStartsAtZero() public view {
        assertEq(mtry.totalBurned(), 0);
    }

    function test_totalSupplyMinusBurnedIsAllocation() public view {
        assertEq(mtry.totalSupply(), 300_000_000e18 - mtry.totalBurned());
    }
}
