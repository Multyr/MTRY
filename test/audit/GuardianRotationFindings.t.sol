// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {NotRevocable, NotAuthorized} from "../../src/Errors.sol";

// =============================================================================
// Audit finding MULTYR-6 (Low; informally tracked as L-3 pre-response):
// Immutable guardian in VestingWalletLinear let stale guardians indefinitely
// freeze non-revocable grants.
//
// STATUS: FIXED
//
// Each VestingWalletLinear stored its guardian as an immutable constructor
// value, set once by VestingManager at deploy time from its own immutable
// `vestingGuardian`. VestingManager.setGuardian() rotates the manager's
// separate, mutable GovernanceRoles guardian, but that rotation never reached
// already-deployed wallets: a rotated-out (e.g. compromised) guardian retained
// permanent pause authority over every wallet it was originally assigned to,
// while the newly rotated-in guardian could not pause those wallets at all.
// For non-revocable grants, emergencyRevokeUnvested() is unavailable, so
// governance had no path to migrate the locked position.
//
// FIX APPLIED:
//   - VestingWalletLinear no longer stores an immutable `guardian`. It exposes
//     a `guardian()` view that resolves dynamically via
//     `IVestingManager(vestingManager).guardian()` -- the manager's own
//     mutable GovernanceRoles guardian -- mirroring the existing `revoker()`
//     pattern (which already resolves dynamically via `owner()`).
//   - VestingManager's separate `vestingGuardian` immutable (and the
//     constructor parameter that fed it) were removed entirely, since the
//     manager's own `guardian` state (from GovernanceRoles) is now the single
//     source of truth propagated to every wallet.
//   A `VestingManager.setGuardian()` rotation now takes effect immediately for
//   every already-deployed wallet, exactly like an `owner()` (revoker)
//   rotation already did.
// =============================================================================
contract GuardianRotationFindings is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Reproduces the report's exact scenario: a non-revocable wallet, a
    // manager-level guardian rotation, and confirmation that the rotation now
    // actually takes effect for the already-deployed wallet -- the rotated-out
    // guardian loses pause authority and the rotated-in guardian gains it,
    // instead of the wallet staying pinned to the stale guardian forever.
    // -------------------------------------------------------------------------
    function test_MULTYR6_GuardianRotationPropagatesToNonRevocableWallet() public {
        address compromisedGuardian = safeGuardian;
        address rotatedInGuardian = address(0xA11A);

        VestingWalletLinear wallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, teamBeneficiary, 1_000_000e18, 0, 365 days, false)
        );
        vm.warp(block.timestamp + 183 days);

        // Prove the wallet is functional pre-rotation.
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertGt(wallet.claimedAmount(), 0);

        vm.prank(deployer);
        vestingManager.setGuardian(rotatedInGuardian);

        // FIXED: the wallet's guardian now follows the manager rotation immediately.
        assertEq(wallet.guardian(), rotatedInGuardian, "wallet guardian must follow manager rotation");
        assertEq(vestingManager.guardian(), rotatedInGuardian);

        // Rotated-in guardian can now pause -- previously this reverted.
        vm.prank(rotatedInGuardian);
        wallet.pause();
        assertTrue(wallet.paused());

        vm.prank(teamBeneficiary);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.claim();

        vm.prank(deployer);
        wallet.unpause();

        // The rotated-out (compromised) guardian has permanently lost pause authority.
        vm.prank(compromisedGuardian);
        vm.expectRevert(NotAuthorized.selector);
        wallet.pause();

        // The wallet is not stuck: the rotated-in guardian remains in full control,
        // and normal claim flow resumes once unpaused.
        assertFalse(wallet.paused());
        vm.warp(block.timestamp + 1);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertGt(wallet.claimedAmount(), 0);

        // Non-revocable emergency recovery is still unavailable by design (unrelated to
        // the guardian bug) -- included to show the fix didn't need that escape hatch.
        vm.prank(deployer);
        vm.expectRevert(NotRevocable.selector);
        wallet.emergencyRevokeUnvested();
    }

    // -------------------------------------------------------------------------
    // A revocable grant is unaffected by (and doesn't need) this fix in a
    // different way -- but confirms the dynamic guardian resolution also works
    // correctly for the revocable path, consistent with `revoker()`.
    // -------------------------------------------------------------------------
    function test_MULTYR6_GuardianRotationPropagatesToRevocableWallet() public {
        address rotatedInGuardian = address(0xB0B1);

        VestingWalletLinear wallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, teamBeneficiary, 1_000_000e18, 0, 365 days, true)
        );

        vm.prank(deployer);
        vestingManager.setGuardian(rotatedInGuardian);

        vm.prank(safeGuardian);
        vm.expectRevert(NotAuthorized.selector);
        wallet.pause();

        vm.prank(rotatedInGuardian);
        wallet.pause();
        assertTrue(wallet.paused());
    }
}
