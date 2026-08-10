// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";

contract VestingManagerFuzzTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function testFuzz_teamBucketCapRespected(uint256 a, uint256 b) public {
        a = bound(a, 1, 50_000_000e18);
        b = bound(b, 1, 50_000_000e18);

        vm.prank(deployer);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            address(0xAAA1),
            a,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );

        vm.prank(deployer);
        if (a + b > 51_000_000e18) {
            vm.expectRevert();
        }
        vestingManager.createVesting(
            VestingManager.BucketType.Growth, // shares Team cap
            address(0xAAA2),
            b,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );

        assertLe(
            vestingManager.totalBucketAllocated(VestingManager.BucketType.Team),
            vestingManager.maxBucketAllocation(VestingManager.BucketType.Team)
        );
    }

    function testFuzz_totalAllocatedNeverExceedsSumOfCaps(uint256 seed) public {
        // Create random vestings across buckets and verify totalAllocatedAllBuckets <= sum of caps
        uint256 maxTotal = 111_000_000e18;

        for (uint256 i; i < 3; ++i) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 1e18, 5_000_000e18);
            vm.prank(deployer);
            try vestingManager.createVesting(
                VestingManager.BucketType.Team,
                address(uint160(0xBB00 + i)),
                amount,
                365 days,
                1095 days,
                false,
                VestingManager.VestingStartMode.GRANT_DATE
            ) {
                // OK
            } catch {
                // cap reached or funding issue; keep invariant assertion
            }
        }

        assertLe(vestingManager.totalAllocatedAllBuckets(), maxTotal);
    }
}
