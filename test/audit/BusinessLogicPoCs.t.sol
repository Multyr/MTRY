// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";
import {UnauthorizedSource} from "../../src/Errors.sol";

// =============================================================================
// Audit finding MULTYR-2 (Low; informally tracked as L-1 pre-response): Lazy
// rollover made GlobalUnlockController and EcosystemEmissionController
// advertise stale capacity after period/epoch boundaries.
//
// STATUS: FIXED
//
// Pending release-cap changes become effective in the next period/epoch, but
// were only promoted inside the state-changing consumption functions
// (`consumeAllowance`, `_emit`). The public capacity views
// (`maxUnlockForPeriod`, `remainingAllowance`, `remainingAllowanceForSource`,
// `availableThisEpoch`) did not simulate that due rollover, so immediately
// after a boundary they fell back to the stale pre-rollover scalar while the
// next state-changing call at the same timestamp enforced a different value.
// `maxUnlockForPeriod`'s reference-supply branch failed in the OPPOSITE
// direction from its cap branch: a same-period `setReferenceSupply` commit was
// applied to the view immediately, even though the documented commit rule
// says it only applies to strictly later periods.
//
// FIX APPLIED:
//   - GlobalUnlockController.maxUnlockForPeriod() now delegates to
//     `_projectedCapBps` / `_projectedReferenceSupply`, which simulate exactly
//     what `_rollPeriodIfNeeded` would promote for the queried period if it
//     ran right now, without writing storage.
//   - GlobalUnlockController.remainingAllowanceForSource() uses the analogous
//     `_projectedProtectedQuotaBps` instead of reading the live
//     (possibly not-yet-promoted) `protectedQuotaBps` scalar directly.
//   - EcosystemEmissionController.availableThisEpoch() now delegates to
//     `_projectedMaxEmissionPerEpoch`, mirroring `_rollEpochIfNeeded`.
//   Because `consumeAllowance`/`_emit` compute their enforced cap via these
//   same public views, the view and the very next state-changing call at the
//   same timestamp now always agree — in both directions (increase and
//   decrease) and for same-period governance commits.
//
// This also incidentally resolved the KL-2 known limitation (see
// audit/KnownLimitations.md) and test/poc/POC07_StaleCapLargeGap.t.sol, since
// consumeAllowance's cap enforcement shares the same projection logic.
// =============================================================================
contract BusinessLogicPoCs is TestSetup {
    address constant RECIPIENT = address(0xA11CE0);

    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // GlobalUnlockController: pending cap DECREASE due at a period boundary.
    // The view must already report the reduced cap before any consumeAllowance
    // call, and the first consuming call must grant exactly what the view showed.
    // -------------------------------------------------------------------------
    function test_MULTYR2_globalUnlockViewReflectsPendingCapDecrease() public {
        vm.startPrank(deployer);
        unlockController.setAuthorizedSource(address(this), true);
        unlockController.setProtectedSource(address(this), true);
        unlockController.setPendingUnlockCapBps(100); // 2% -> 1%
        vm.stopPrank();

        vm.warp(unlockGenesis + PERIOD_DURATION); // enter period 1, no consuming call yet

        uint256 expectedCap = 3_000_000e18; // 300M * 1%
        assertEq(unlockController.maxUnlockForPeriod(1), expectedCap, "view must show due cap decrease");
        assertEq(unlockController.remainingAllowance(), expectedCap, "remainingAllowance must match");

        uint256 granted = unlockController.consumeAllowance(expectedCap);
        assertEq(granted, expectedCap, "view and first write must agree");
        assertEq(unlockController.maxUnlockForPeriod(1), expectedCap, "post-roll view unchanged");
    }

    // -------------------------------------------------------------------------
    // GlobalUnlockController: pending cap INCREASE due at a period boundary.
    // The view must not understate the new, higher capacity.
    // -------------------------------------------------------------------------
    function test_MULTYR2_globalUnlockViewReflectsPendingCapIncrease() public {
        vm.startPrank(deployer);
        unlockController.setAuthorizedSource(address(this), true);
        unlockController.setProtectedSource(address(this), true);
        unlockController.setPendingUnlockCapBps(400); // 2% -> 4%
        vm.stopPrank();

        vm.warp(unlockGenesis + PERIOD_DURATION);

        uint256 expectedCap = 12_000_000e18; // 300M * 4%
        assertEq(unlockController.maxUnlockForPeriod(1), expectedCap, "view must show due cap increase");

        uint256 granted = unlockController.consumeAllowance(expectedCap);
        assertEq(granted, expectedCap, "view and first write must agree");
    }

    // -------------------------------------------------------------------------
    // GlobalUnlockController: a reference-supply change committed in the SAME
    // period it is queried for must NOT be projected as due yet -- the view
    // must keep reporting the old (pre-commit) reference supply until the
    // period in which the commit landed has actually rolled over, then must
    // switch over exactly when it becomes due.
    // -------------------------------------------------------------------------
    function test_MULTYR2_globalUnlockViewSamePeriodReferenceSupplyNotProjectedEarly() public {
        vm.warp(unlockGenesis + PERIOD_DURATION); // enter period 1 first (still uninitialized)

        vm.prank(deployer);
        unlockController.setReferenceSupply(150_000_000e18); // committed inside period 1

        // Not due for period 1 (commit period == queried period, not strictly less).
        uint256 oldCap = 6_000_000e18; // still the original 300M * 2%
        assertEq(unlockController.maxUnlockForPeriod(1), oldCap, "same-period commit must not be projected early");

        vm.startPrank(deployer);
        unlockController.setAuthorizedSource(address(this), true);
        unlockController.setProtectedSource(address(this), true);
        vm.stopPrank();

        uint256 granted = unlockController.consumeAllowance(oldCap);
        assertEq(granted, oldCap, "write enforces the same old value the view projected");

        // Now advance into period 2 -- the reference-supply commit is finally due.
        vm.warp(unlockGenesis + 2 * PERIOD_DURATION);
        uint256 newCap = 3_000_000e18; // 150M * 2%
        assertEq(unlockController.maxUnlockForPeriod(2), newCap, "due in period 2");
    }

    // -------------------------------------------------------------------------
    // GlobalUnlockController: remainingAllowanceForSource() for a protected
    // source must reflect a due protected-quota change before any consuming call.
    // -------------------------------------------------------------------------
    function test_MULTYR2_globalUnlockViewSourceAllowanceReflectsPendingProtectedQuota() public {
        vm.startPrank(deployer);
        unlockController.setAuthorizedSource(address(this), true);
        unlockController.setProtectedSource(address(this), true);
        unlockController.setPendingProtectedQuotaBps(7_500); // 50% -> 75% (max)
        vm.stopPrank();

        vm.warp(unlockGenesis + PERIOD_DURATION);

        // Protected lane view: full remaining cap regardless of quota (protected sources
        // may use cap - totalUsed), so this exercises the shared-lane branch instead.
        vm.startPrank(deployer);
        unlockController.setAuthorizedSource(bob, true);
        vm.stopPrank();

        // Shared lane remaining = cap - protectedReserve = 6M - (6M * 75%) = 1.5M,
        // using the DUE 75% quota, not the stale 50% default.
        uint256 expectedSharedRemaining = 1_500_000e18;
        assertEq(
            unlockController.remainingAllowanceForSource(bob),
            expectedSharedRemaining,
            "shared-lane view must reflect the due protected-quota increase"
        );
    }

    // -------------------------------------------------------------------------
    // EcosystemEmissionController: pending epoch-cap DECREASE due at an epoch
    // boundary. availableThisEpoch() must already reflect it.
    // -------------------------------------------------------------------------
    function test_MULTYR2_ecosystemViewReflectsPendingCapDecrease() public {
        vm.startPrank(deployer);
        ecosystem.setApprovedRecipient(RECIPIENT, true);
        ecosystem.setPendingMaxEmissionPerEpoch(500_000e18); // 1M -> 500k
        vm.stopPrank();

        vm.warp(ecosystemGenesis + EPOCH_DURATION); // enter epoch 1, no emission yet

        assertEq(ecosystem.availableThisEpoch(), 500_000e18, "view must show due epoch cap decrease");

        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(RECIPIENT, 500_000e18);
        assertEq(granted, 500_000e18, "view and first emission must agree");
    }

    // -------------------------------------------------------------------------
    // EcosystemEmissionController: pending epoch-cap INCREASE due at an epoch
    // boundary. availableThisEpoch() must not understate it.
    // -------------------------------------------------------------------------
    function test_MULTYR2_ecosystemViewReflectsPendingCapIncrease() public {
        vm.startPrank(deployer);
        ecosystem.setApprovedRecipient(RECIPIENT, true);
        ecosystem.setPendingMaxEmissionPerEpoch(2_000_000e18); // 1M -> 2M
        vm.stopPrank();

        vm.warp(ecosystemGenesis + EPOCH_DURATION);

        assertEq(ecosystem.availableThisEpoch(), 2_000_000e18, "view must show due epoch cap increase");

        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(RECIPIENT, 2_000_000e18);
        assertEq(granted, 2_000_000e18, "view and first emission must agree");
    }

    // =========================================================================
    // Audit finding MULTYR-3 (Low; informally tracked as L-2 pre-response):
    // GlobalUnlockController's source allowance view omits authorization and
    // genesis preconditions.
    //
    // STATUS: FIXED
    //
    // remainingAllowanceForSource(source) computed lane capacity without
    // mirroring two preconditions consumeAllowance() enforces before granting
    // anything: source authorization (`authorizedSource[msg.sender]`) and
    // unlock genesis (`block.timestamp >= genesisTimestamp`). An unauthorized
    // address therefore received a positive quote even though its write would
    // always revert `UnauthorizedSource`; before genesis, even an authorized
    // protected source received a full-cap quote while both the aggregate
    // `remainingAllowance()` view and `consumeAllowance()` itself returned 0.
    //
    // FIX APPLIED: remainingAllowanceForSource() now returns 0 immediately for
    // an unauthorized source or before genesis, mirroring consumeAllowance's
    // own preconditions, before computing any lane-specific quote.
    // =========================================================================

    // -------------------------------------------------------------------------
    // An unauthorized address must get a 0 view quote, matching the fact that
    // its corresponding consumeAllowance() call always reverts.
    // -------------------------------------------------------------------------
    function test_MULTYR3_unauthorizedSourceGetsZeroAllowanceView() public {
        address randomSource = address(0xBADD00D);
        assertFalse(unlockController.authorizedSource(randomSource), "not authorized by default");

        assertEq(
            unlockController.remainingAllowanceForSource(randomSource),
            0,
            "unauthorized source must get a 0 view quote, not a positive one a write would reject"
        );

        vm.prank(randomSource);
        vm.expectRevert(UnauthorizedSource.selector);
        unlockController.consumeAllowance(1_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Before genesis, an authorized protected source must get a 0 view quote,
    // matching remainingAllowance() and consumeAllowance() (both already
    // genesis-gated).
    // -------------------------------------------------------------------------
    function test_MULTYR3_preGenesisAuthorizedSourceGetsZeroAllowanceView() public {
        uint256 futureGenesis = block.timestamp + 30 days;
        GlobalUnlockController freshController = new GlobalUnlockController(
            address(mtry),
            deployer,
            futureGenesis,
            30 days,
            200,            // 2% cap
            300_000_000e18  // 300M reference supply
        );

        vm.startPrank(deployer);
        freshController.setAuthorizedSource(address(claim), true);
        freshController.setProtectedSource(address(claim), true);
        vm.stopPrank();

        assertLt(block.timestamp, freshController.genesisTimestamp(), "pre-genesis");

        // Pre-fix this returned the full period-0 cap (6M) for an authorized protected
        // source, even though nothing can actually be consumed yet.
        assertEq(
            freshController.remainingAllowanceForSource(address(claim)),
            0,
            "pre-genesis view must return 0, matching remainingAllowance() and consumeAllowance()"
        );
        assertEq(freshController.remainingAllowance(), 0, "aggregate view already correctly returns 0");

        vm.prank(address(claim));
        uint256 granted = freshController.consumeAllowance(1_000_000e18);
        assertEq(granted, 0, "consumeAllowance still returns 0 pre-genesis");
    }
}
