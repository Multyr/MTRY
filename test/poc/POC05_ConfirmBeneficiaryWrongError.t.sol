// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {BeneficiaryUpdatePending, NoBeneficiaryUpdatePending} from "../../src/Errors.sol";

// =============================================================================
// POC-05: confirmBeneficiaryUpdate() Threw the Wrong Error
// =============================================================================
//
// STATUS: FIXED
//
// OLD BEHAVIOR:
//   When confirmBeneficiaryUpdate() was called with NO pending update
//   (pendingBeneficiary == address(0)), it reverted with BeneficiaryUpdatePending.
//   The NatSpec for that error says "Reverted when a beneficiary update IS already
//   pending" -- but the trigger condition was the exact opposite (no update pending).
//   A client catching BeneficiaryUpdatePending would display "another update is
//   already blocking yours" when in fact nothing was pending at all. The same error
//   was used in opposite conditions: proposeBeneficiaryUpdate() (correctly: IS pending)
//   and confirmBeneficiaryUpdate() (incorrectly: IS NOT pending).
//
// ROOT CAUSE:
//   VestingWalletLinear.sol reused BeneficiaryUpdatePending for the "no update" case
//   because no complementary "not pending" error existed in Errors.sol.
//
// FIX APPLIED (src/VestingWalletLinear.sol, src/Errors.sol):
//   - Added new error NoBeneficiaryUpdatePending to Errors.sol with correct NatSpec.
//   - Changed confirmBeneficiaryUpdate() line from:
//       if (pendingBeneficiary == address(0)) revert BeneficiaryUpdatePending();
//     to:
//       if (pendingBeneficiary == address(0)) revert NoBeneficiaryUpdatePending();
//   - The two call sites now use distinct, semantically correct errors:
//       proposeBeneficiaryUpdate()  → BeneficiaryUpdatePending    (update IS pending)
//       confirmBeneficiaryUpdate()  → NoBeneficiaryUpdatePending  (update IS NOT pending)
//       cancelBeneficiaryUpdate()   → NoBeneficiaryUpdatePending  (update IS NOT pending)
// =============================================================================

contract POC05_ConfirmBeneficiaryWrongError is TestSetup {
    VestingWalletLinear wallet;

    function setUp() public {
        _deployAllCorrectly();
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000_000e18,
            180 days,
            540 days,
            false
        );
        wallet = VestingWalletLinear(w);
    }

    // -------------------------------------------------------------------------
    // [FIXED]: confirm with no pending now throws the correct NoBeneficiaryUpdatePending.
    //   Old: threw BeneficiaryUpdatePending ("update IS pending") when nothing was pending.
    //   New: throws NoBeneficiaryUpdatePending -- semantically accurate for callers.
    // -------------------------------------------------------------------------
    function test_confirmWithNoPending_throwsBeneficiaryUpdatePending() public {
        // Precondition: no pending update
        assertEq(wallet.pendingBeneficiary(), address(0));

        // FIXED: confirmBeneficiaryUpdate() now throws NoBeneficiaryUpdatePending (new error)
        // when there is no pending update. Previously it threw BeneficiaryUpdatePending,
        // which was semantically inverted ("update IS pending" when there is NO update).
        vm.expectRevert(NoBeneficiaryUpdatePending.selector);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.confirmBeneficiaryUpdate();
    }

    // -------------------------------------------------------------------------
    // Contrast: propose then confirm -- BeneficiaryUpdatePending thrown correctly
    //           in propose when one already exists
    // -------------------------------------------------------------------------
    function test_proposeTwice_throwsBeneficiaryUpdatePending_correctly() public {
        // First proposal -- succeeds
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        assertEq(wallet.pendingBeneficiary(), alice);

        // Second proposal while one is pending -- BeneficiaryUpdatePending thrown
        // Here the error IS semantically correct: an update IS pending.
        vm.expectRevert(BeneficiaryUpdatePending.selector);
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(bob);
    }

    // -------------------------------------------------------------------------
    // [FIXED]: both call sites now use distinct, semantically correct errors.
    //   propose → BeneficiaryUpdatePending    (IS pending -- blocks duplicate)
    //   confirm → NoBeneficiaryUpdatePending  (IS NOT pending -- nothing to confirm)
    // -------------------------------------------------------------------------
    function test_errorReuseOppositeConditions() public {
        // Site 1 (proposeBeneficiaryUpdate): reverts when pendingBeneficiary != address(0)
        //   → semantically correct: "there IS already a pending update"
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice); // first call ok

        vm.expectRevert(BeneficiaryUpdatePending.selector);
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(bob);  // errors: update IS pending ✓

        // Cancel so we can test the other site
        vm.prank(teamBeneficiary);
        wallet.cancelBeneficiaryUpdate();
        assertEq(wallet.pendingBeneficiary(), address(0));

        // Site 2 (confirmBeneficiaryUpdate): reverts when pendingBeneficiary == address(0)
        //   FIXED: now throws NoBeneficiaryUpdatePending -- semantically correct.
        //   Callers can now distinguish the two cases without reading state.
        vm.expectRevert(NoBeneficiaryUpdatePending.selector);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.confirmBeneficiaryUpdate(); // errors: update is NOT pending -- correct error now
    }
}
