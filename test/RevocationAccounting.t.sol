// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {
    BucketCapExceeded,
    NotAuthorized,
    UnregisteredWallet,
    RevocationAlreadyRecorded
} from "../src/Errors.sol";

contract RevocationAccountingTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function test_revokedVestingFreesBucketCapacity() public {
        // Fill Team cap completely (51M via a single revocable grant).
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            51_000_000e18,
            365 days,
            1095 days,
            true
        );

        // New grant would exceed cap.
        vm.prank(deployer);
        vm.expectRevert(BucketCapExceeded.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            address(0xAAAA),
            1,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );

        // Revoke frees the allocation.
        vm.prank(deployer);
        VestingWalletLinear(w).revokeUnvested();

        // Now a new grant of up to 51M fits again.
        _createGrantVesting(
            VestingManager.BucketType.Team,
            address(0xBBBB),
            51_000_000e18,
            365 days,
            1095 days,
            false
        );

        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), 51_000_000e18);
    }

    function test_recordRevocationOnlyCallableByRegisteredWallet() public {
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000e18,
            365 days,
            1095 days,
            true
        );

        // Random EOA cannot record.
        vm.prank(alice);
        vm.expectRevert(UnregisteredWallet.selector);
        vestingManager.recordRevocation(address(0xDEAD), 0);

        // Registered wallet but wrong caller reverts NotAuthorized.
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        vestingManager.recordRevocation(w, 0);
    }

    function test_recordRevocationCannotBeCalledTwice() public {
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000e18,
            365 days,
            1095 days,
            true
        );

        vm.prank(deployer);
        VestingWalletLinear(w).revokeUnvested();

        // Wallet-internal double-revoke reverts AlreadyRevoked before it reaches recordRevocation,
        // so we simulate a direct recordRevocation from the wallet address.
        vm.prank(w);
        vm.expectRevert(RevocationAlreadyRecorded.selector);
        vestingManager.recordRevocation(w, 0);
    }

    function test_teamSharedCapUsesAllocatedMinusRevoked() public {
        // Team cap shared with Growth/BDCore/BDPerformance.
        // Consume 30M via Team + 20M via Growth → activeAllocated == 50M.
        address tw = _createGrantVesting(
            VestingManager.BucketType.Team,
            address(0xA111),
            30_000_000e18,
            365 days,
            1095 days,
            true
        );
        _createGrantVesting(
            VestingManager.BucketType.Growth,
            address(0xA222),
            20_000_000e18,
            180 days,
            540 days,
            false
        );

        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), 50_000_000e18);

        // Revoke the Team 30M → active goes back to 20M (Growth only).
        vm.prank(deployer);
        VestingWalletLinear(tw).revokeUnvested();
        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), 20_000_000e18);

        // Remaining is 51M - 20M = 31M.
        assertEq(vestingManager.getBucketRemaining(VestingManager.BucketType.Team), 31_000_000e18);
    }

    function test_revocationAccountingWorksForSharedTeamBucket() public {
        // Create on BDCore (shares Team cap), revoke it, verify Team activeAllocated goes to 0.
        address w = _createGrantVesting(
            VestingManager.BucketType.BDCore,
            address(0xB1B1),
            5_000_000e18,
            180 days,
            540 days,
            true
        );
        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), 5_000_000e18);

        vm.prank(deployer);
        VestingWalletLinear(w).revokeUnvested();
        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), 0);
    }

    // -------------------------------------------------------------------------
    // Mid-vest revoke frees only unvested; vested remainder stays in bucket.
    // (Pre-audit internal review item; unrelated to any HackenProof MULTYR-N finding.)
    // -------------------------------------------------------------------------

    function test_midVestRevoke_freesOnlyUnvestedInBucket() public {
        uint256 allocation   = 1_000e18;
        uint64  vestDuration = 1_000 days;

        // Grant: no cliff, 1000-day linear vest (1 MTRY/day from grant date)
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            allocation,
            0,
            vestDuration,
            true
        );

        assertEq(vestingManager.activeBucketAllocated(VestingManager.BucketType.Team), allocation);

        // Advance to 60% vested
        vm.warp(block.timestamp + 600 days);
        uint256 vested   = VestingWalletLinear(w).vestedAmount(block.timestamp);
        uint256 unvested = allocation - vested;

        // Revoke mid-vest
        vm.prank(deployer);
        VestingWalletLinear(w).revokeUnvested();

        // After fix: bucket only freed `unvested`, not the full allocation.
        // activeBucketAllocated now equals the vested-claimable remainder still owed to the beneficiary.
        assertEq(
            vestingManager.activeBucketAllocated(VestingManager.BucketType.Team),
            vested,
            "active should equal vested-claimable remainder, not zero"
        );
        // New grants can use at most cap - vested (not cap - 0 as the bug allowed)
        assertEq(
            vestingManager.getBucketRemaining(VestingManager.BucketType.Team),
            TEAM_CAP - vested
        );
    }

    function test_midVestRevokeThenRegrant_cannotExceedCapMinusClaimable() public {
        uint256 allocation   = 1_000e18;
        uint64  vestDuration = 1_000 days;

        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            allocation,
            0,
            vestDuration,
            true
        );

        vm.warp(block.timestamp + 600 days);
        uint256 vested = VestingWalletLinear(w).vestedAmount(block.timestamp);

        vm.prank(deployer);
        VestingWalletLinear(w).revokeUnvested();

        // Regrant exactly the remaining headroom — must succeed.
        uint256 headroom = vestingManager.getBucketRemaining(VestingManager.BucketType.Team);
        _createGrantVesting(
            VestingManager.BucketType.Team,
            address(0xBEEF),
            headroom,
            0,
            365 days,
            false
        );

        // activeBucketAllocated = vested (alice claimable) + headroom (bob) = TEAM_CAP
        assertEq(
            vestingManager.activeBucketAllocated(VestingManager.BucketType.Team),
            vested + headroom
        );
        assertLe(
            vestingManager.activeBucketAllocated(VestingManager.BucketType.Team),
            TEAM_CAP
        );
    }
}
