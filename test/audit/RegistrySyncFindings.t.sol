// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";

// =============================================================================
// Audit finding MULTYR-4 (Low; informally tracked as L-4 pre-response):
// VestingManager registry returns the former beneficiary after a supported
// reassignment (and the former "active" status after a completed revocation).
//
// STATUS: FIXED
//
// VestingWalletLinear supports a delayed 2-phase beneficiary reassignment, but
// confirmation only updated the child wallet's own `beneficiary` storage --
// the corresponding VestingManager.VestingRecord.beneficiary was never
// synchronized, so the manager's registry permanently returned the grant's
// creation-time beneficiary instead of the current one. The same
// synchronization gap affected VestingRecord.active: revokeUnvested()
// notifies the manager for bucket-cap accounting via recordRevocation(), but
// that callback never flipped the record's `active` flag, so a fully revoked
// grant stayed reported as active forever.
//
// FIX APPLIED:
//   - VestingManager gained an authenticated `recordBeneficiaryUpdate(wallet,
//     newBeneficiary)` callback (mirroring the existing `recordRevocation`
//     authentication pattern: only the registered wallet itself may call).
//     VestingWalletLinear.confirmBeneficiaryUpdate() now calls it after
//     updating its own beneficiary.
//   - VestingManager.recordRevocation() now also sets `record.active = false`
//     alongside its existing bucket-accounting update.
//   The registry (`vestings` mapping getter and `getVestingsByBucketPaginated`)
//   is now kept live-accurate without needing to change its read-side shape.
// =============================================================================
contract RegistrySyncFindings is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Reproduces the report's exact scenario: Alice's grant is reassigned to
    // Bob via the supported 2-phase flow. The manager registry must reflect
    // Bob immediately after confirmation, matching the wallet's own
    // authoritative beneficiary().
    // -------------------------------------------------------------------------
    function test_MULTYR4_BeneficiaryReassignmentSyncsToManagerRegistry() public {
        VestingWalletLinear wallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, alice, 1_000_000e18, 0, 365 days, false)
        );

        (VestingManager.VestingRecord[] memory before, ) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 10);
        assertEq(before[0].beneficiary, alice, "registry initially matches creation beneficiary");

        vm.prank(alice);
        wallet.proposeBeneficiaryUpdate(bob);
        vm.warp(block.timestamp + wallet.BENEFICIARY_UPDATE_DELAY());
        vm.prank(bob, bob);
        wallet.confirmBeneficiaryUpdate();

        assertEq(wallet.beneficiary(), bob, "wallet is authoritative and already correct");

        (VestingManager.VestingRecord[] memory afterUpdate, ) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 10);
        assertEq(afterUpdate[0].beneficiary, bob, "FIXED: registry now reflects the current beneficiary");
        assertEq(afterUpdate[0].vestingWallet, address(wallet), "same record, wallet identity unchanged");
    }

    // -------------------------------------------------------------------------
    // Reproduces the report's revocation scenario: a revocable grant is fully
    // revoked. The manager registry's `active` flag must flip to false,
    // matching wallet.revoked() and walletRevocationRecorded().
    // -------------------------------------------------------------------------
    function test_MULTYR4_RevocationSyncsActiveFlagInManagerRegistry() public {
        VestingWalletLinear wallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, alice, 1_000_000e18, 0, 365 days, true)
        );

        (VestingManager.VestingRecord[] memory before, ) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 10);
        assertTrue(before[0].active, "registry initially active");

        vm.prank(deployer);
        wallet.revokeUnvested();

        assertTrue(wallet.revoked(), "wallet is authoritative and already correct");
        assertTrue(vestingManager.walletRevocationRecorded(address(wallet)));

        (VestingManager.VestingRecord[] memory afterRevoke, ) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 10);
        assertFalse(afterRevoke[0].active, "FIXED: registry now reflects the completed revocation");
    }

    // -------------------------------------------------------------------------
    // recordBeneficiaryUpdate / recordRevocation must remain wallet-only calls --
    // an arbitrary caller (not the registered wallet) cannot forge a registry sync.
    // -------------------------------------------------------------------------
    function test_MULTYR4_RecordBeneficiaryUpdateRejectsNonWalletCaller() public {
        VestingWalletLinear wallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, alice, 1_000_000e18, 0, 365 days, false)
        );

        vm.prank(alice);
        vm.expectRevert();
        vestingManager.recordBeneficiaryUpdate(address(wallet), bob);
    }
}
