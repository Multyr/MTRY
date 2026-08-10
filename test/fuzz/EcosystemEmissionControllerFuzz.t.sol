// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {EcosystemEmissionController} from "../../src/EcosystemEmissionController.sol";

contract EcosystemEmissionControllerFuzzTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(alice, true);
    }

    function testFuzz_emissionCapped(uint256 amount) public {
        amount = bound(amount, 1, 5_000_000e18);
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(alice, amount);
        // Granted ≤ per-epoch local cap AND ≤ global period cap
        assertLe(granted, ecosystem.maxEmissionByEpoch(ecosystem.currentEpoch()) == 0
            ? ecosystem.currentMaxEmissionPerEpoch()
            : ecosystem.maxEmissionByEpoch(ecosystem.currentEpoch()));
    }

    function testFuzz_totalEmittedConsistent(uint256 a, uint256 b) public {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);
        vm.prank(deployer);
        uint256 g1 = ecosystem.emitTo(alice, a);
        vm.prank(deployer);
        uint256 g2 = ecosystem.emitTo(alice, b);
        assertEq(ecosystem.totalEmitted(), g1 + g2);
        assertEq(ecosystem.totalEmittedToRecipient(alice), g1 + g2);
    }
}
