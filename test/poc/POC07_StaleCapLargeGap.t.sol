// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";

// =============================================================================
// POC-07: Stale Cap Applied When Period Gap Exceeds MAX_CATCHUP_PERIODS
// =============================================================================
//
// STATUS: FIXED (as a consequence of the MULTYR-2 fix)
//
// OLD BEHAVIOR:
//   _rollPeriodIfNeeded() initializes at most MAX_CATCHUP_PERIODS (120) storage
//   slots per call. At the exact boundary where a cap change is committed at
//   period (lastInitializedPeriod + 120) or later, the catch-up loop could reach
//   that period without the strict-less-than promotion condition
//   (`pendingCapCommitPeriod < p`) ever firing inside the loop, so the new cap
//   was NOT promoted. consumeAllowance() then read the stale, not-yet-promoted
//   `currentUnlockCapBps` for the actual current period, causing a one-time
//   over-grant at the old (higher) cap on the first call after the gap.
//
// ROOT CAUSE (shared with audit finding MULTYR-2):
//   consumeAllowance() computed its cap via `maxUnlockForPeriod(period)`, which
//   for any not-yet-initialized period simply fell back to the live
//   `currentUnlockCapBps` scalar -- the same scalar `_rollPeriodIfNeeded` had not
//   yet promoted, rather than projecting the cap the period is actually due to
//   receive once physical catch-up completes.
//
// FIX APPLIED (src/GlobalUnlockController.sol):
//   `maxUnlockForPeriod()` now delegates to `_projectedCapBps` /
//   `_projectedReferenceSupply`, which simulate the promotion `_rollPeriodIfNeeded`
//   would apply if it ran right now -- independent of how far the *physical*
//   per-call catch-up (bounded by MAX_CATCHUP_PERIODS for gas reasons) has
//   actually progressed. Because `consumeAllowance()` reuses this same public
//   view for its own cap enforcement, the very first call after an arbitrarily
//   large dormancy gap already enforces the correct, fully-caught-up cap -- no
//   over-grant, and the invariant `releasedInPeriod[p] <= maxUnlockForPeriod(p)`
//   now holds even across a >120-period catch-up boundary.
//   See also: test/GlobalUnlockController.t.sol:test_catchupBoundary_projectedCapPreventsOverRelease
//   and audit/KnownLimitations.md (former KL-2, now resolved).
// =============================================================================

contract POC07_StaleCapLargeGap is TestSetup {
    // Period = 30 days, MAX_CATCHUP_PERIODS = 120
    uint256 constant PERIOD = 30 days;
    uint256 constant MAX_CATCHUP = 120;

    function setUp() public {
        _deployAllCorrectly();
        // unlockController deployed with genesis = T0, initCap = 200 bps (2%)
        // lastInitializedPeriod = 0, currentUnlockCapBps = 200
    }

    // -------------------------------------------------------------------------
    // Core POC: the projected cap prevents over-release on the first
    // consumeAllowance after a large gap, even though physical rollover storage
    // hasn't caught up to the current period yet.
    // -------------------------------------------------------------------------
    function test_noStaleCapOverReleaseAfterLargeGap() public {
        uint256 genesis = unlockController.genesisTimestamp();

        // Warp to exactly period 120 (= lastInit + MAX_CATCHUP)
        vm.warp(genesis + 120 * PERIOD);
        assertEq(unlockController.currentPeriod(), 120);

        // Governance reduces unlock cap from 200 bps to 100 bps AT period 120.
        // This means the new cap should apply from period 121 onward.
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(100);
        assertEq(unlockController.pendingCapCommitPeriod(), 120);
        assertEq(unlockController.pendingUnlockCapBps(), 100);
        assertEq(unlockController.currentUnlockCapBps(), 200, "old cap still active pre-rollover");

        // Warp to period 121 -- one period past the cap change
        vm.warp(genesis + 121 * PERIOD);
        assertEq(unlockController.currentPeriod(), 121);

        // Reference supply = 300M. New cap (100 bps) → 3M per period.
        // Old cap (200 bps) → 6M per period. We request 4M.
        uint256 requestAmount = 4_000_000e18;
        uint256 expectedWithNewCap = 3_000_000e18; // clamped by the correct, projected 100 bps cap

        // Prank as the claim contract (an authorized + protected source)
        vm.prank(address(claim));
        uint256 granted = unlockController.consumeAllowance(requestAmount);

        // FIXED: granted is clamped to the correct 3M cap on the very first call,
        // even though capBpsByPeriod[121] had not yet been physically written.
        assertEq(
            granted,
            expectedWithNewCap,
            "projected cap correctly clamps the first call after the gap to 3M"
        );

        // remainingAllowance() now also reflects the correct post-consumption state:
        // cap (3M, projected) - granted (3M) = 0 remaining.
        uint256 remainingAfterFirst = unlockController.remainingAllowance();
        assertEq(remainingAfterFirst, 0,
            "view and write agree: correct 3M cap was reached, 0 remaining");
    }

    // -------------------------------------------------------------------------
    // Compare: correct behavior when gap is <= MAX_CATCHUP_PERIODS
    // -------------------------------------------------------------------------
    function test_noStaleCapWhenGapWithinCatchup() public {
        uint256 genesis = unlockController.genesisTimestamp();

        // Warp to period 50 (< MAX_CATCHUP = 120) and reduce cap
        vm.warp(genesis + 50 * PERIOD);
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(100);

        // Warp to period 51
        vm.warp(genesis + 51 * PERIOD);

        uint256 requestAmount = 4_000_000e18;
        vm.prank(address(claim));
        uint256 granted = unlockController.consumeAllowance(requestAmount);

        // No stale cap: catch-up loop reached period 50 (commit) and promoted the change.
        // Period 51 gets the correct new cap = 3M. Request = 4M → clamped to 3M.
        assertEq(granted, 3_000_000e18, "correct cap applied: 3M granted");
    }

    // -------------------------------------------------------------------------
    // Show the exact boundary condition is also fixed: even when the commit
    // period lands exactly at lastInitializedPeriod + MAX_CATCHUP_PERIODS (so the
    // strict promotion loop never reaches it), the projected cap still applies.
    // -------------------------------------------------------------------------
    function test_boundaryCondition_lastInitPlusMaxCatchup() public {
        uint256 genesis = unlockController.genesisTimestamp();

        // Scenario: interact at period 50 to set lastInitializedPeriod = 50
        vm.warp(genesis + 50 * PERIOD);
        vm.prank(address(claim));
        unlockController.consumeAllowance(1); // sets lastInit ≈ 50

        assertEq(unlockController.lastInitializedPeriod(), 50);

        // Now commit cap reduction at period 50 + MAX_CATCHUP = 170
        vm.warp(genesis + 170 * PERIOD);
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(100);
        assertEq(unlockController.pendingCapCommitPeriod(), 170);

        // First consumeAllowance at period 171 (= lastInit + MAX_CATCHUP + 1)
        vm.warp(genesis + 171 * PERIOD);
        vm.prank(address(claim));
        uint256 granted = unlockController.consumeAllowance(4_000_000e18);

        // FIXED: 3M granted (correct, projected 100 bps), not the stale 4M/200bps.
        assertEq(granted, 3_000_000e18, "projected cap applied at the exact boundary");
    }
}
