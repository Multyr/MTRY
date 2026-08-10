// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {NoBeneficiaryUpdatePending} from "../../src/Errors.sol";

// =============================================================================
// POC-04: cancelBeneficiaryUpdate() Succeeds (and Emits) When Nothing Is Pending
// =============================================================================
//
// STATUS: FIXED
//
// OLD BEHAVIOR:
//   VestingWalletLinear.cancelBeneficiaryUpdate() did not check whether
//   pendingBeneficiary != address(0) before proceeding. With no pending update,
//   it set pendingBeneficiary = address(0) (already zero), reset beneficiaryUpdateAt,
//   and emitted BeneficiaryUpdateCancelled(address(0)). This is the exact mirror
//   of POC-03 (cancelBurn no-op) in VestingWalletLinear. The revoker could generate
//   unlimited confusing on-chain history showing cancels with no matching proposals.
//
// ROOT CAUSE:
//   No `pendingBeneficiary == address(0)` guard in cancelBeneficiaryUpdate().
//
// FIX APPLIED (src/VestingWalletLinear.sol):
//   Added guard after the caller authorization check:
//     if (pendingBeneficiary == address(0)) revert NoBeneficiaryUpdatePending();
//   New error NoBeneficiaryUpdatePending added to src/Errors.sol.
//   BeneficiaryUpdateCancelled is now only emitted when an actual proposal existed.
// =============================================================================

contract POC04_CancelBeneficiaryUpdateNoOp is TestSetup {
    VestingWalletLinear wallet;

    function setUp() public {
        _deployAllCorrectly();
        // Create a revocable team vesting wallet
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000_000e18,
            180 days,
            540 days,
            true
        );
        wallet = VestingWalletLinear(w);
    }

    // -------------------------------------------------------------------------
    // [FIXED]: cancelBeneficiaryUpdate with nothing pending now reverts.
    //   Old: emitted BeneficiaryUpdateCancelled(address(0)) with no state change.
    //   New: NoBeneficiaryUpdatePending revert -- no spurious event possible.
    // -------------------------------------------------------------------------
    function test_cancelBeneficiaryUpdate_noOpWhenNothingPending() public {
        // Precondition: no pending update
        assertEq(wallet.pendingBeneficiary(), address(0), "no pending beneficiary");

        // FIXED: cancelBeneficiaryUpdate() now reverts with NoBeneficiaryUpdatePending.
        // Spurious BeneficiaryUpdateCancelled(address(0)) events are no longer possible.
        vm.expectRevert(NoBeneficiaryUpdatePending.selector);
        vm.prank(teamBeneficiary);
        wallet.cancelBeneficiaryUpdate();
    }

    // -------------------------------------------------------------------------
    // Revoker spurious events [FIXED]: revoker can no longer call cancel with nothing pending.
    //   Old: revoker could generate confusing history of cancels with no proposals.
    // -------------------------------------------------------------------------
    function test_revokerSpuriousCancelCreatesConfusingHistory() public {
        // FIXED: cancelBeneficiaryUpdate() reverts on the first call with no pending update.
        // Revoker can no longer generate spurious cancellation events.
        vm.expectRevert(NoBeneficiaryUpdatePending.selector);
        vm.prank(deployer);      // deployer == revoker (vestingManager.owner())
        wallet.cancelBeneficiaryUpdate();

        // Beneficiary is still the original
        assertEq(wallet.beneficiary(), teamBeneficiary);
    }

    // -------------------------------------------------------------------------
    // Contrast: proper propose → cancel flow
    // -------------------------------------------------------------------------
    function test_cancelAfterProposalWorks() public {
        // Propose a real update
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);

        assertEq(wallet.pendingBeneficiary(), alice, "update pending");

        // Cancel it properly
        vm.prank(teamBeneficiary);
        wallet.cancelBeneficiaryUpdate();

        assertEq(wallet.pendingBeneficiary(), address(0), "update cleared");
        assertEq(wallet.beneficiaryUpdateAt(), 0);
        // BeneficiaryUpdateCancelled(alice) emitted -- meaningful event
    }
}
