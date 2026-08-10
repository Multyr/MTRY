// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";

/// @title Cross-flow fuzz — mixed vesting claims + ecosystem emissions stay within global cap.
contract TokenStackCrossFlowFuzzTest is TestSetup {
    VestingWalletLinear wallet;

    function setUp() public {
        _deployAllCorrectly();
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);

        wallet = VestingWalletLinear(
            _createTgeVesting(
                VestingManager.BucketType.StrategicStandard,
                strategicBeneficiary,
                3_000_000e18,
                0,
                1 days,
                false
            )
        );

        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);
    }

    function testFuzz_mixedClaimsAndEmissionsRespectGlobalCap(uint256 claimTime, uint256 emitAmount) public {
        claimTime = bound(claimTime, 1 days + 1, 1 days + 29 days); // stays in period 0
        emitAmount = bound(emitAmount, 1, 5_000_000e18);

        vm.warp(claimTime);

        uint256 releasedBefore = unlockController.releasedInPeriod(unlockController.currentPeriod());

        // Vesting claim
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        try wallet.claim() {} catch {}

        // Ecosystem emit
        vm.prank(deployer);
        try ecosystem.emitTo(bob, emitAmount) {} catch {}

        uint256 releasedAfter = unlockController.releasedInPeriod(unlockController.currentPeriod());
        uint256 cap = unlockController.maxUnlockForPeriod(unlockController.currentPeriod());

        assertLe(releasedAfter, cap);
        assertGe(releasedAfter, releasedBefore);
    }
}
