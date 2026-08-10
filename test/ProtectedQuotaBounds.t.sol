// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {InvalidUnlockCap} from "../src/Errors.sol";

contract ProtectedQuotaBoundsTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function test_setProtectedQuotaRejectsAboveMax() public {
        uint256 denom = unlockController.CAP_DENOMINATOR();
        uint256 minShared = unlockController.MIN_SHARED_QUOTA_BPS();

        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setPendingProtectedQuotaBps(denom - minShared + 1);  // 7501

        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setPendingProtectedQuotaBps(denom);  // 10000 (100%)
    }

    function test_minSharedQuotaAlwaysPreserved() public {
        uint256 denom = unlockController.CAP_DENOMINATOR();
        uint256 minShared = unlockController.MIN_SHARED_QUOTA_BPS();

        // Set pending max quota (75%); it is stored as pending, not yet promoted.
        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(denom - minShared);
        assertEq(unlockController.pendingProtectedQuotaBps(), denom - minShared);

        // Advance to the next period so the pending value is promoted.
        vm.warp(unlockGenesis + PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);  // triggers _rollPeriodIfNeeded
        assertEq(unlockController.protectedQuotaBps(), denom - minShared);
    }

    function test_sharedSourceCannotBeFullyStarvedByQuota() public {
        // With max protected quota (75%), shared lane still has 25% = 1.5M of 6M cap.
        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(7_500);

        // Warp to next period — triggers pending→current promotion on first consumeAllowance.
        vm.warp(unlockGenesis + PERIOD_DURATION);

        vm.prank(address(ecosystem));
        uint256 granted = unlockController.consumeAllowance(10_000_000e18);
        // Shared quota floor preserved: shared lane at least (cap * 2500 / 10000) = 1.5M.
        assertGe(granted, 1_500_000e18);
    }

    function test_protectedAndSharedStillRespectSingleCapInvariant() public {
        // Ecosystem (shared) + claim (protected) combined cannot exceed cap.
        // Default protectedQuotaBps is already 5000; pending change to the same value is a no-op.
        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(5_000);

        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(2_000_000e18);

        vm.prank(address(claim));
        unlockController.consumeAllowance(5_000_000e18);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        assertLe(unlockController.totalReleasedInPeriod(period), cap);
    }

    function test_unusedProtectedReserveDoesNotSpillToShared() public {
        // Fresh period 1 with higher local ecosystem cap so local is not binding.
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);
        vm.warp(unlockGenesis + 30 days);
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);  // trigger rollover

        vm.warp(block.timestamp + 30 days);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        uint256 quotaBps = unlockController.protectedQuotaBps();
        uint256 protectedReserve = (cap * quotaBps) / 10_000;

        // Shared alone: bounded at cap - protectedReserve.
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(bob, cap);
        assertEq(granted, cap - protectedReserve);
    }
}
