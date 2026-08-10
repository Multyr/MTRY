// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";

contract GlobalUnlockControllerFuzzTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function testFuzz_consumeNeverExceedsCap(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000e18);
        vm.prank(address(ecosystem));
        uint256 granted = unlockController.consumeAllowance(amount);
        // Granted ≤ amount AND ≤ period cap
        assertLe(granted, amount);
        assertLe(granted, unlockController.maxUnlockForPeriod(0));
        assertLe(unlockController.releasedInPeriod(0), unlockController.maxUnlockForPeriod(0));
    }

    function testFuzz_multipleConsumptionsStayUnderCap(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 10_000_000e18);
        b = bound(b, 1, 10_000_000e18);
        c = bound(c, 1, 10_000_000e18);

        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(a);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(b);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(c);

        assertLe(unlockController.releasedInPeriod(0), unlockController.maxUnlockForPeriod(0));
    }

    function testFuzz_periodIndexIsDeterministic(uint256 warpSec) public {
        warpSec = bound(warpSec, 0, 100 * 30 days);
        vm.warp(unlockGenesis + warpSec);
        uint256 expected = warpSec / PERIOD_DURATION;
        assertEq(unlockController.currentPeriod(), expected);
    }

    function testFuzz_capChangeNeverAffectsActivePeriod(uint16 newCap) public {
        uint256 capBps = bound(uint256(newCap), 1, 2_000);
        // Consume in current period
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1_000_000e18);
        uint256 maxBefore = unlockController.maxUnlockForPeriod(0);

        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(capBps);

        // Active period cap unchanged
        assertEq(unlockController.maxUnlockForPeriod(0), maxBefore);
    }
}
