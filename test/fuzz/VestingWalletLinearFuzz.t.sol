// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";

contract VestingWalletLinearFuzzTest is TestSetup {
    VestingWalletLinear wallet;
    uint64 constant CLIFF = 180 days;
    uint64 constant DURATION = 540 days;
    uint256 constant ALLOCATION = 1_000_000e18;

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

    function testFuzz_vestedAmountMonotonic(uint256 t1, uint256 dt) public {
        uint256 start = wallet.startTimestamp();
        t1 = bound(t1, start, start + CLIFF + DURATION);
        dt = bound(dt, 0, 365 days);

        uint256 vAtT1 = wallet.vestedAmount(t1);
        uint256 vAtT1PlusDt = wallet.vestedAmount(t1 + dt);
        assertGe(vAtT1PlusDt, vAtT1);
    }

    function testFuzz_vestedNeverExceedsAllocation(uint256 t) public {
        t = bound(t, wallet.startTimestamp(), wallet.startTimestamp() + 5 * (CLIFF + DURATION));
        assertLe(wallet.vestedAmount(t), ALLOCATION);
    }

    function testFuzz_revokeNeverIncreasesClaimable(uint256 tAtRevoke) public {
        tAtRevoke = bound(tAtRevoke, wallet.startTimestamp(), wallet.startTimestamp() + CLIFF + DURATION);
        vm.warp(tAtRevoke);
        uint256 vestedPre = wallet.vestedAmount(tAtRevoke);

        vm.prank(deployer);
        wallet.revokeUnvested();

        // After revoke at time T, future vested cannot exceed vested(T).
        vm.warp(tAtRevoke + 365 days);
        assertLe(wallet.vestedAmount(block.timestamp), vestedPre);
    }
}
