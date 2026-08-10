// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {UnlockThrottled} from "../../src/Errors.sol";

/// @title UnlockCapInvariantsMultiLane — property tests for the single-cap per-period invariant.
///        Verify that total release across all lanes (shared + protected) never exceeds
///        `maxUnlockForPeriod(p)`, under adversarial and fuzzed source interactions.
contract UnlockCapInvariantsMultiLaneTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Core invariant: totalReleasedInPeriod(p) <= maxUnlockForPeriod(p)
    // The reserved-quota model keeps every lane draw within the single per-period cap.
    // -------------------------------------------------------------------------

    /// @notice Explicit single-assertion invariant: total release across all lanes never
    ///         exceeds the per-period cap, no matter how sources interact.
    function test_totalReleasedNeverExceedsCap() public {
        // Setup: protected source (claim) fully funded, shared whale fully vested.
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address whale = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            10_000_000e18,
            0,
            1 days,
            false
        );

        _aliceBuys(200_000e6);
        vm.prank(alice);
        preMTRY.approve(address(claim), 2_500_000e18);
        vm.prank(alice);
        claim.lockPreTokens(2_500_000e18);

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        vm.warp(block.timestamp + 180 days + 540 days);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);

        // Exercise both lanes maximally.
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        VestingWalletLinear(whale).claim();
        vm.prank(alice);
        claim.claim();

        // Single, explicit invariant
        assertLe(unlockController.totalReleasedInPeriod(period), unlockController.maxUnlockForPeriod(period));
        assertLe(unlockController.totalReleasedInPeriod(period), cap);
    }

    /// @notice Total released across shared and protected lanes must not exceed the single
    ///         per-period cap even when both lanes are exercised maximally.
    function test_sharedPlusIsolatedNeverExceedsSingleCap() public {
        // Create a strategic TGE vesting with 10M, zero cliff, 1-day duration
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address whale = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            10_000_000e18,
            0,
            1 days,
            false
        );

        // Also prepare a claim-bound user with 10M entitlement
        _aliceBuys(200_000e6);  // 200_000 USDC → 2.5M preMTRY → 10M MTRY entitlement
        vm.prank(alice);
        preMTRY.approve(address(claim), 2_500_000e18);
        vm.prank(alice);
        claim.lockPreTokens(2_500_000e18);

        // Set TGE on claim (MULTYR-1: must be >= saleEnd)
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        // Warp past full vesting for BOTH
        vm.warp(block.timestamp + 180 days + 540 days);

        // Period at the end:
        uint256 period = unlockController.currentPeriod();
        uint256 theoreticalMax = unlockController.maxUnlockForPeriod(period);

        // Drain shared via whale
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        VestingWalletLinear(whale).claim();

        // Drain isolated via claim
        vm.prank(alice);
        claim.claim();

        // Measure total released across both lanes in this period.
        uint256 totalReleased = unlockController.totalReleasedInPeriod(period);

        // Invariant: total across lanes <= theoretical per-period cap.
        assertLe(totalReleased, theoreticalMax, "single-cap violated: total release exceeds cap");
    }

    // -------------------------------------------------------------------------
    // Multi-source stress: vesting whale + ecosystem emitter + claim user in same period
    // -------------------------------------------------------------------------
    function test_multiSourceStressInSamePeriod() public {
        // Setup: whale vesting (10M), ecosystem whitelist (10M emissions), claim user (10M entitled)
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address whale = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            10_000_000e18,
            0,
            1 days,
            false
        );

        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);

        _aliceBuys(200_000e6);
        vm.prank(alice);
        preMTRY.approve(address(claim), 2_500_000e18);
        vm.prank(alice);
        claim.lockPreTokens(2_500_000e18);
        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        // Advance past vesting and trigger new epoch so pending local cap applies.
        vm.warp(block.timestamp + 180 days + 540 days);
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);  // rollover to pick up 10M local

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);

        // All three sources contend in the same period. Expected behavior:
        // - whale (shared) clamped to 3M (shared lane after warm-up = ~3M - 1wei)
        // - ecosystem (shared) granted=0 after whale drained shared lane → UnlockThrottled revert
        // - alice (protected) gets her 3M reserve
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        VestingWalletLinear(whale).claim();

        vm.prank(deployer);
        try ecosystem.emitTo(bob, 1_000_000e18) {} catch {}

        vm.prank(alice);
        claim.claim();

        uint256 totalReleased = unlockController.totalReleasedInPeriod(period);

        // Single-cap invariant: total release across all lanes <= per-period cap.
        assertLe(totalReleased, cap, "single-cap violated: multi-source release exceeds cap");

        // Liveness: protected source always receives at least its reserved quota.
        assertGt(mtry.balanceOf(alice), 0, "protected source received zero tokens");

        // Accounting: shared and protected counters reconcile with totalReleasedInPeriod.
        uint256 shared = unlockController.releasedInPeriod(period);
        uint256 protectedClaim = unlockController.protectedReleasedInPeriod(address(claim), period);
        assertEq(totalReleased, shared + protectedClaim, "lane counters diverge from aggregate");
    }

    // -------------------------------------------------------------------------
    // Reservation semantics
    // -------------------------------------------------------------------------

    /// @notice Shared sources cannot access the protected reserve even when protected sources
    ///         have consumed nothing. The local ecosystem cap is raised so the global reserve
    ///         is the binding constraint.
    function test_sharedCannotTouchProtectedReserveEvenIfUnused() public {
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);

        // Step 1 — advance to next epoch (pending applies from next epoch)
        vm.warp(unlockGenesis + 30 days);
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);  // trigger rollover, local cap now 10M

        // Step 2 — advance AGAIN to a new period with fresh global cap AND local cap 10M already active.
        vm.warp(block.timestamp + 30 days);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        uint256 quotaBps = unlockController.protectedQuotaBps();
        uint256 protectedReserve = (cap * quotaBps) / 10_000;

        // Ecosystem tries to drain the FULL global cap. Local cap is 10M (not binding).
        // Global shared lane should clamp to cap - protectedReserve.
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(bob, cap);
        assertEq(granted, cap - protectedReserve, "shared lane must not access protected reserve");

        // Further shared attempts revert — ecosystem surfaces UnlockThrottled when controller returns 0.
        vm.prank(deployer);
        vm.expectRevert(UnlockThrottled.selector);
        ecosystem.emitTo(bob, 1);

        // Reserve untouched by shared lane.
        assertEq(unlockController.totalReleasedInPeriod(period), cap - protectedReserve);
        assertEq(unlockController.protectedReleasedInPeriod(address(claim), period), 0);
    }

    /// @notice Unused protected capacity does NOT spill over to shared sources at end of period.
    ///         The reserve is forfeited if not used (next period resets fresh).
    function test_unusedProtectedCapacityDoesNotSpillOverToShared() public {
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);

        vm.warp(unlockGenesis + 30 days);  // new period 1, new epoch

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        uint256 quotaBps = unlockController.protectedQuotaBps();
        uint256 protectedReserve = (cap * quotaBps) / 10_000;

        // Shared drains its lane (cap - protectedReserve = 3M)
        vm.prank(deployer);
        ecosystem.emitTo(bob, cap);

        // Warp to the NEXT period boundary. Protected consumed nothing; reserve is forfeited.
        vm.warp(block.timestamp + 30 days);
        uint256 nextPeriod = unlockController.currentPeriod();
        assertEq(nextPeriod, period + 1);

        // Shared lane in next period is fresh cap - protectedReserve again (no carryover).
        vm.prank(deployer);
        uint256 grantedNext = ecosystem.emitTo(bob, cap);
        assertEq(grantedNext, cap - protectedReserve);

        // Prior period's forfeited reserve did NOT carry over.
        assertEq(unlockController.releasedInPeriod(nextPeriod), cap - protectedReserve);
    }

    function testFuzz_anyCombinationStaysUnderCap(uint256 whaleAmt, uint256 emitAmt, uint256 claimShare) public {
        whaleAmt = bound(whaleAmt, 1, 10_000_000e18);
        emitAmt = bound(emitAmt, 1, 10_000_000e18);
        claimShare = bound(claimShare, 1, 2_500_000e18);

        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address whale = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            whaleAmt,
            0,
            1 days,
            false
        );

        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);

        uint256 usdcNeeded = (claimShare * 80_000) / 1e18;
        if (usdcNeeded < 80_000) usdcNeeded = 80_000;  // min buy
        if (usdcNeeded > 800_000e6) usdcNeeded = 800_000e6;  // max hard cap
        _aliceBuys(usdcNeeded);

        uint256 actualPreMtry = preMTRY.balanceOf(alice);
        if (actualPreMtry > 0) {
            vm.prank(alice);
            preMTRY.approve(address(claim), actualPreMtry);
            vm.prank(alice);
            claim.lockPreTokens(actualPreMtry);
        }

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        vm.warp(block.timestamp + 180 days + 540 days);
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);

        vm.prank(strategicBeneficiary, strategicBeneficiary);
        try VestingWalletLinear(whale).claim() {} catch {}

        vm.prank(deployer);
        try ecosystem.emitTo(bob, emitAmt) {} catch {}

        vm.prank(alice);
        try claim.claim() {} catch {}

        uint256 totalReleased = unlockController.totalReleasedInPeriod(period);
        assertLe(totalReleased, cap, "single-cap violated: fuzz multi-source release exceeds cap");
    }
}
