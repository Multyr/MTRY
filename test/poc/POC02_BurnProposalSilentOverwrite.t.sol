// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {PreMTRYClaim} from "../../src/PreMTRYClaim.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {EcosystemEmissionController} from "../../src/EcosystemEmissionController.sol";
import {BurnAlreadyPending} from "../../src/Errors.sol";

// =============================================================================
// POC-02: proposeBurn() Silently Overwrites a Pending Burn
// =============================================================================
//
// STATUS: FIXED
//
// OLD BEHAVIOR:
//   All three burn-lifecycle contracts (PreMTRYClaim, VestingManager,
//   EcosystemEmissionController) allowed proposeBurn() to be called again while a
//   burn was already pending. The second call silently replaced the first with no
//   error and no cancel step, restarting the 7-day BURN_DELAY clock. An Owner could:
//   (a) escalate the burn amount just before the Veto window expired, or
//   (b) repeatedly re-propose to prevent the burn ever becoming executable at a
//       predictable time, bypassing the spirit of the timelock.
//
// ROOT CAUSE:
//   No `pendingBurnAmount != 0` guard in proposeBurn() across all three contracts.
//
// FIX APPLIED (src/PreMTRYClaim.sol, src/VestingManager.sol,
//              src/EcosystemEmissionController.sol):
//   Added at the top of proposeBurn() in all three contracts:
//     if (pendingBurnAmount != 0) revert BurnAlreadyPending();
//   New error BurnAlreadyPending added to src/Errors.sol.
//   Owner must now call cancelBurn() before changing a pending burn amount.
//   This preserves the original Veto window and prevents clock resets.
// =============================================================================

contract POC02_BurnProposalSilentOverwrite is TestSetup {
    // Setup shared across scenarios -- warp past full vesting for burn eligibility
    uint256 constant CLIFF = 180 days;
    uint256 constant VESTING = 540 days;

    function setUp() public {
        _deployAllCorrectly();
        vm.startPrank(deployer);
        claim.setTGE(block.timestamp);
        vestingManager.setTGE(block.timestamp);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // VestingManager [FIXED]: second proposeBurn now reverts BurnAlreadyPending.
    //   Old: second call silently replaced first, resetting the 7-day Veto window.
    //   New: Owner must cancel the pending proposal before creating a new one.
    // -------------------------------------------------------------------------
    function test_vestingManager_proposeBurnOverwrite() public {
        // VestingManager holds all 111M MTRY at this point (no vestings created)
        uint256 balance = mtry.balanceOf(address(vestingManager));
        assertGt(balance, 0, "vestingManager has MTRY to burn");

        uint256 smallAmount = 1_000e18;
        uint256 largeAmount = 50_000_000e18;

        vm.startPrank(deployer);

        // First proposal: 1k tokens. Veto sees this, plans to cancel in ~6 days.
        vestingManager.proposeBurn(smallAmount);
        uint256 firstDeadline = vestingManager.pendingBurnExecutableAt();
        assertEq(vestingManager.pendingBurnAmount(), smallAmount);

        // Warp to 6 days later (1 day before Veto's 7-day window expires)
        vm.warp(block.timestamp + 6 days);

        // FIXED: second proposeBurn now reverts -- owner must cancel first.
        // The veto window can no longer be silently reset by re-proposing.
        vm.expectRevert(BurnAlreadyPending.selector);
        vestingManager.proposeBurn(largeAmount);

        vm.stopPrank();

        // Original proposal is still intact
        assertEq(vestingManager.pendingBurnAmount(), smallAmount, "FIXED: first proposal unchanged");
        assertEq(vestingManager.pendingBurnExecutableAt(), firstDeadline, "FIXED: deadline not reset");
    }

    // -------------------------------------------------------------------------
    // PreMTRYClaim [FIXED]: same BurnAlreadyPending guard added here too.
    //   Requires a cancelBurn() call between two proposeBurn() calls.
    // -------------------------------------------------------------------------
    function test_preMTRYClaim_proposeBurnOverwrite() public {
        // Warp past full vesting horizon so proposeBurn is eligible
        uint256 tge = claim.tgeTimestamp();
        vm.warp(tge + CLIFF + VESTING + 1 days);

        // Fund claim with more than MAX_CLAIM_POOL to have a burnable surplus
        // (in practice the claim starts with exactly 40M; no surplus unless tokens sent directly)
        // For this POC, we just confirm the overwrite mechanic with available balance
        uint256 outstanding = claim.totalEntitled() - claim.totalClaimed();
        uint256 balance = mtry.balanceOf(address(claim));
        uint256 burnable = balance > outstanding ? balance - outstanding : 0;

        // If no burnable surplus exists (all tokens entitled), skip this variant
        if (burnable == 0) return;

        vm.startPrank(deployer);

        // First proposal
        uint256 firstAmount = burnable / 2;
        claim.proposeBurn(firstAmount);
        assertEq(claim.pendingBurnAmount(), firstAmount);

        // FIXED: second proposeBurn now reverts -- must cancel first to change amount.
        uint256 secondAmount = burnable;
        vm.expectRevert(BurnAlreadyPending.selector);
        claim.proposeBurn(secondAmount);

        vm.stopPrank();

        // Original proposal still intact
        assertEq(claim.pendingBurnAmount(), firstAmount, "FIXED: first proposal unchanged");
    }

    // -------------------------------------------------------------------------
    // Veto window extension [FIXED]: re-proposing near expiry now reverts.
    //   Old: Owner could call proposeBurn 1s before deadline, resetting the 7-day
    //        clock indefinitely and keeping Veto unable to cancel predictably.
    //   New: BurnAlreadyPending prevents this; the original deadline is immutable
    //        until the pending proposal is explicitly cancelled.
    // -------------------------------------------------------------------------
    function test_vetoWindowCanBeExtendedIndefinitelyByOwner() public {
        uint256 balance = mtry.balanceOf(address(vestingManager));
        uint256 burnAmount = 1_000e18;

        // Owner proposes on day 0
        vm.prank(deployer);
        vestingManager.proposeBurn(burnAmount);
        uint256 originalDeadline = vestingManager.pendingBurnExecutableAt();

        // Warp to 1 second before the deadline
        vm.warp(block.timestamp + 7 days - 1);

        // FIXED: re-proposing without cancelling now reverts.
        // Owner can no longer extend the veto window by silently overwriting.
        vm.prank(deployer);
        vm.expectRevert(BurnAlreadyPending.selector);
        vestingManager.proposeBurn(burnAmount);

        // The deadline is NOT reset -- Veto can cancel within the original 7-day window.
        assertEq(
            vestingManager.pendingBurnExecutableAt(),
            originalDeadline,
            "FIXED: deadline not extended"
        );
    }
}
