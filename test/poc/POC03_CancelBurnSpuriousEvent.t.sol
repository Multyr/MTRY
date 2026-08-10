// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {NoBurnPending} from "../../src/Errors.sol";

// =============================================================================
// POC-03: cancelBurn() Emits BurnCancelled Even When Nothing Is Pending
// =============================================================================
//
// STATUS: FIXED
//
// OLD BEHAVIOR:
//   cancelBurn() in all three burn-lifecycle contracts (PreMTRYClaim, VestingManager,
//   EcosystemEmissionController) did not check pendingBurnAmount before proceeding.
//   Calling with no pending burn silently zeroed the already-zero fields and emitted
//   BurnCancelled(), producing a misleading on-chain event with no state effect.
//   A Veto holder could generate unlimited spurious BurnCancelled events at will.
//
// ROOT CAUSE:
//   No `pendingBurnAmount == 0` guard in cancelBurn() across all three contracts.
//   The complementary function executeBurn() already had the NoBurnPending guard;
//   cancelBurn() was simply missing it.
//
// FIX APPLIED (src/PreMTRYClaim.sol, src/VestingManager.sol,
//              src/EcosystemEmissionController.sol):
//   Added at the top of cancelBurn() in all three contracts:
//     if (pendingBurnAmount == 0) revert NoBurnPending();
//   The error NoBurnPending already existed in src/Errors.sol (used by executeBurn).
//   BurnCancelled is now only ever emitted when a real pending proposal existed.
// =============================================================================

contract POC03_CancelBurnSpuriousEvent is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // VestingManager [FIXED]: cancelBurn with nothing pending now reverts.
    //   Old: silent no-op emitting BurnCancelled(). New: NoBurnPending revert.
    // -------------------------------------------------------------------------
    function test_vestingManager_cancelBurnNopEmitsEvent() public {
        // Precondition: no pending burn
        assertEq(vestingManager.pendingBurnAmount(), 0, "no pending burn");

        // FIXED: cancelBurn() now reverts with NoBurnPending when nothing is pending.
        // Spurious events and no-op state changes are no longer possible.
        vm.expectRevert(NoBurnPending.selector);
        vm.prank(safeVeto);
        vestingManager.cancelBurn();
    }

    // -------------------------------------------------------------------------
    // EcosystemEmissionController [FIXED]: same NoBurnPending guard added.
    // -------------------------------------------------------------------------
    function test_ecosystem_cancelBurnNopEmitsEvent() public {
        assertEq(ecosystem.pendingBurnAmount(), 0, "no pending burn in ecosystem");

        // FIXED: ecosystem cancelBurn also now reverts with NoBurnPending.
        vm.expectRevert(NoBurnPending.selector);
        vm.prank(safeVeto);
        ecosystem.cancelBurn();
    }

    // -------------------------------------------------------------------------
    // Spam resistance [FIXED]: first call with no pending burn now reverts.
    //   Old: loop of cancelBurn() calls generated unlimited spurious events.
    // -------------------------------------------------------------------------
    function test_vetoCanSpamCancelBurnWithNoPendingBurn() public {
        // FIXED: cancelBurn() now reverts on the first call -- spam is no longer possible.
        vm.expectRevert(NoBurnPending.selector);
        vm.prank(safeVeto);
        vestingManager.cancelBurn();

        assertEq(vestingManager.pendingBurnAmount(), 0, "state still clean");
    }

    // -------------------------------------------------------------------------
    // Contrast: cancelBurn after an actual proposal works as expected
    // -------------------------------------------------------------------------
    function test_cancelBurnAfterProposalWorks() public {
        uint256 burnAmount = 1_000e18;

        vm.prank(deployer);
        vestingManager.proposeBurn(burnAmount);
        assertEq(vestingManager.pendingBurnAmount(), burnAmount, "burn proposed");

        vm.prank(safeVeto);
        vestingManager.cancelBurn();

        assertEq(vestingManager.pendingBurnAmount(), 0, "burn cancelled correctly");
        assertEq(vestingManager.pendingBurnExecutableAt(), 0);
    }
}
