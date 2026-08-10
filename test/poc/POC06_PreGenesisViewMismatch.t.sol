// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";

// =============================================================================
// POC-06: remainingAllowance() Returns Non-Zero Before Genesis
// =============================================================================
//
// STATUS: PARTIALLY FIXED
//
// OLD BEHAVIOR:
//   GlobalUnlockController.remainingAllowance() returned the full period-0 cap
//   (e.g. 6M MTRY at 2% of 300M) before genesisTimestamp, because it used
//   currentPeriod() which returns 0 pre-genesis and period-0 had a cap set in
//   the constructor. Meanwhile consumeAllowance() correctly returned 0 pre-genesis
//   via an early return. Result: view said "6M available", consume returned 0.
//   Frontend monitoring or dashboards reading remainingAllowance() on launch day
//   would display misleading capacity figures.
//
// ROOT CAUSE:
//   consumeAllowance() had a `block.timestamp < genesisTimestamp` guard; the
//   view function remainingAllowance() did not.
//
// FIX APPLIED (src/GlobalUnlockController.sol):
//   Added genesis guard at the top of remainingAllowance():
//     if (block.timestamp < genesisTimestamp) return 0;
//   Now view and consume agree pre-genesis: both return 0.
//
// REMAINING OPEN FINDING (no fix applied):
//   remainingAllowance() returns the TOTAL pool remaining across both lanes
//   (shared + protected). For a SHARED source, the accessible amount is capped at
//   (cap - protectedReserve) = 50% of cap by default. So at genesis, the view
//   returns 6M but a shared source can only consume 3M. remainingAllowance() is
//   not "what you can get" -- it is "what the pool has left across all lanes."
//   The last test below documents this ongoing inconsistency.
//   remainingAllowanceForSource(address) is the accurate per-lane query.
// =============================================================================

contract POC06_PreGenesisViewMismatch is TestSetup {
    GlobalUnlockController freshController;

    function setUp() public {
        // Deploy a fresh controller with genesis 30 days in the future
        uint256 futureGenesis = block.timestamp + 30 days;
        freshController = new GlobalUnlockController(
            address(0x1234), // token (mock, not needed for view tests)
            address(this),
            futureGenesis,
            30 days,
            200,           // 2% cap
            300_000_000e18 // 300M reference supply
        );
    }

    // -------------------------------------------------------------------------
    // [FIXED]: remainingAllowance() now returns 0 pre-genesis.
    //   Old: returned 6M (full period-0 cap). New: returns 0 (matches consume).
    // -------------------------------------------------------------------------
    function test_preGenesis_remainingAllowanceNonZero() public view {
        // We are before genesis
        assertLt(block.timestamp, freshController.genesisTimestamp(), "pre-genesis");

        uint256 remaining = freshController.remainingAllowance();

        // FIXED: remainingAllowance() now returns 0 pre-genesis (genesis guard added).
        // Previously it returned the full period-0 cap (6M), which was misleading for
        // dashboards and monitoring systems that check remainingAllowance() on launch day.
        assertEq(remaining, 0, "FIXED: remainingAllowance correctly returns 0 pre-genesis");
    }

    // -------------------------------------------------------------------------
    // Pre-genesis: consumeAllowance() returns 0 (correct)
    // -------------------------------------------------------------------------
    function test_preGenesis_consumeAllowanceReturnsZero() public {
        // Authorize this test contract as a source
        freshController.setAuthorizedSource(address(this), true);

        // Attempt to consume -- returns 0 because of genesis guard
        uint256 granted = freshController.consumeAllowance(1_000_000e18);
        assertEq(granted, 0, "consumeAllowance returns 0 pre-genesis");
    }

    // -------------------------------------------------------------------------
    // [FIXED]: the pre-genesis view/consume gap is closed. Both now return 0.
    // -------------------------------------------------------------------------
    function test_viewConsumeMismatchPreGenesis() public {
        freshController.setAuthorizedSource(address(this), true);

        uint256 viewSays = freshController.remainingAllowance();

        // FIXED: remainingAllowance() now returns 0 pre-genesis, eliminating the
        // view/consume mismatch. A caller reading remainingAllowance() pre-genesis
        // correctly sees 0, and calling consumeAllowance(0) would revert with ZeroAmount.
        assertEq(viewSays, 0, "FIXED: view returns 0 pre-genesis -- no misleading capacity shown");

        // Consuming with a non-zero amount pre-genesis still returns 0 (genesis guard in consume).
        // Consuming 0 reverts with ZeroAmount -- there is nothing to consume.
        uint256 actuallyGranted = freshController.consumeAllowance(1_000_000e18);
        assertEq(actuallyGranted, 0, "consume still returns 0 pre-genesis");
    }

    // -------------------------------------------------------------------------
    // [OPEN]: remainingAllowance() overstates accessible cap for SHARED sources.
    //   At genesis, view returns 6M (total pool) but a shared source gets only 3M
    //   (50% reserved for protected lane). Use remainingAllowanceForSource() instead.
    // -------------------------------------------------------------------------
    function test_atGenesis_viewAndConsumeAreConsistent() public {
        // address(this) is authorized but NOT a protected source -- it is a SHARED source.
        freshController.setAuthorizedSource(address(this), true);

        // Warp to genesis
        vm.warp(freshController.genesisTimestamp());

        uint256 viewSays = freshController.remainingAllowance(); // returns total remaining = 6M
        uint256 actuallyGranted = freshController.consumeAllowance(viewSays);

        // FINDING: remainingAllowance() overstates what a SHARED source can receive.
        // Default protectedQuotaBps = 5000 (50%). Shared sources can only consume
        // up to (cap - protectedReserve) = 50% of cap = 3M, not the full 6M the view shows.
        // This inconsistency is identical pre-genesis (total vs 0) and post-genesis for
        // shared sources (total cap vs shared quota).
        assertGt(viewSays, 0, "view reports 6M available at genesis");
        uint256 protectedQuotaBps = freshController.protectedQuotaBps();
        uint256 expectedGranted = (viewSays * (10_000 - protectedQuotaBps)) / 10_000; // 3M
        assertEq(actuallyGranted, expectedGranted,
            "FINDING: shared source gets only shared quota (3M), not full cap (6M)");
        assertGt(viewSays, actuallyGranted,
            "remainingAllowance() overstates accessible allowance for shared sources");
    }
}
