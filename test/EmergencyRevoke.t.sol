// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";

contract EmergencyRevokeTest is TestSetup {
    VestingWalletLinear internal wallet;
    uint64 constant CLIFF = 180 days;
    uint64 constant DURATION = 540 days;
    uint256 constant ALLOCATION = 1_000_000e18;

    event EmergencyRevoked(address indexed revoker, uint256 unvestedRecovered, uint256 timestamp);

    function setUp() public {
        _deployAllCorrectly();
        wallet = VestingWalletLinear(
            _createGrantVesting(
                VestingManager.BucketType.Team,
                teamBeneficiary,
                ALLOCATION,
                CLIFF,
                DURATION,
                true
            )
        );
    }

    function test_pauseBlocksClaim() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);
        vm.prank(deployer);
        wallet.pause();
        vm.prank(teamBeneficiary);
        vm.expectRevert();  // Pausable: paused
        wallet.claim();
    }

    function test_pauseBlocksNormalRevoke() public {
        vm.prank(deployer);
        wallet.pause();
        vm.prank(deployer);
        vm.expectRevert();  // Pausable: paused
        wallet.revokeUnvested();
    }

    function test_emergencyRevokeStillWorksWhenPaused() public {
        vm.prank(deployer);
        wallet.pause();

        vm.prank(deployer);
        wallet.emergencyRevokeUnvested();

        assertTrue(wallet.revoked());
        // Full allocation returned to treasury (no time elapsed, nothing vested).
        assertEq(mtry.balanceOf(treasurySafe), 75_000_000e18 + ALLOCATION);
    }

    function test_emergencyRevokeEmitsDistinctEvent() public {
        vm.prank(deployer);
        wallet.pause();

        vm.expectEmit(true, false, false, false, address(wallet));
        emit EmergencyRevoked(deployer, ALLOCATION, block.timestamp);

        vm.prank(deployer);
        wallet.emergencyRevokeUnvested();
    }

    function test_afterEmergencyRevokeBeneficiaryCanStillClaimPreviouslyVested() public {
        // Vest to 50%, pause, emergency-revoke, unpause, beneficiary claims 50%.
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION / 2);

        vm.prank(deployer);
        wallet.pause();

        vm.prank(deployer);
        wallet.emergencyRevokeUnvested();
        assertTrue(wallet.revoked());

        // Unpause so the beneficiary can claim the frozen 500k.
        vm.prank(deployer);
        wallet.unpause();

        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertEq(mtry.balanceOf(teamBeneficiary), ALLOCATION / 2);
    }
}
