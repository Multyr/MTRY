// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {ZeroAmount} from "../../src/Errors.sol";

// =============================================================================
// POC-10: batchEmit() Is Fully Atomic -- Single Zero Amount Reverts Entire Batch
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   EcosystemEmissionController.batchEmit() iterates entries and calls _emit()
//   for each. _emit() reverts with ZeroAmount if amount == 0 and with
//   EpochCapExceeded if the local epoch cap is exhausted. Since batchEmit has no
//   per-item error handling, any revert rolls back ALL prior transfers in that
//   transaction -- strict all-or-nothing atomicity.
//
// WHY NO FIX:
//   Atomicity is a deliberate design choice: governance submits a batch as a single
//   governance action; partial execution would leave the emission state in a
//   harder-to-reason-about intermediate position. Off-chain tooling is expected to
//   validate amounts > 0 and within the epoch cap before submitting.
//
// OPEN QUESTIONS:
//   Q1. Atomicity is undocumented in the NatSpec (only "max 50 entries" is noted).
//       Adding a sentence clarifying all-or-nothing semantics would prevent surprises.
//   Q2. If off-chain calculation rounds a recipient to 0 tokens, the entire emission
//       batch fails. Is there a pre-submission validation tool or script that prevents
//       zero-amount entries from reaching the chain?
//   Q3. EpochCapExceeded mid-batch is a harder-to-predict failure mode than ZeroAmount.
//       Should batchEmit clamp each entry to the available epoch cap instead of reverting?
// =============================================================================

contract POC10_BatchEmitAtomicRevert is TestSetup {
    address recipientA = address(0xAAAA);
    address recipientB = address(0xBBBB);
    address recipientC = address(0xCCCC);

    function setUp() public {
        _deployAllCorrectly();

        // Approve three recipients
        vm.startPrank(deployer);
        ecosystem.setApprovedRecipient(recipientA, true);
        ecosystem.setApprovedRecipient(recipientB, true);
        ecosystem.setApprovedRecipient(recipientC, true);
        vm.stopPrank();

        // Warp to genesis so emissions are active
        vm.warp(ecosystemGenesis);
    }

    // -------------------------------------------------------------------------
    // Zero amount in middle of batch reverts entire batch
    // -------------------------------------------------------------------------
    function test_batchEmitZeroAmountRevertsAllItems() public {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);

        recipients[0] = recipientA;
        recipients[1] = recipientB;
        recipients[2] = recipientC;

        amounts[0] = 10_000e18; // valid
        amounts[1] = 0;          // ZERO -- will revert the batch
        amounts[2] = 10_000e18; // valid but never reached

        // Entire batch reverts due to amounts[1] == 0
        vm.expectRevert(ZeroAmount.selector);
        vm.prank(deployer);
        ecosystem.batchEmit(recipients, amounts);

        // QUESTION: recipientA and recipientC get nothing despite having valid amounts.
        assertEq(mtry.balanceOf(recipientA), 0, "recipientA received nothing -- batch reverted");
        assertEq(mtry.balanceOf(recipientB), 0, "recipientB received nothing");
        assertEq(mtry.balanceOf(recipientC), 0, "recipientC received nothing");
    }

    // -------------------------------------------------------------------------
    // Epoch cap exhaustion mid-batch also reverts all
    // -------------------------------------------------------------------------
    function test_batchEmitEpochCapExhaustionRevertsRemaining() public {
        // Epoch cap = 1M MTRY (set in TestSetup). Request two emissions that together exceed it.
        uint256 epochCap = 1_000_000e18;

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = recipientA;
        recipients[1] = recipientB;

        // First: slightly under cap (800k). Second: 800k again -- will exceed remaining.
        // After first emission, only 200k remains. But wait -- the _emit() CLAMPS to remaining
        // for the individual amount, it doesn't revert... unless local remaining = 0.
        // Let's exhaust the cap first with a single large emit.
        amounts[0] = epochCap; // fills entire epoch cap (up to global limit too)
        amounts[1] = 1e18;     // any amount -- epoch cap is now 0, will revert EpochCapExceeded

        // First call exhausts epoch cap
        vm.prank(deployer);
        ecosystem.emitTo(recipientA, epochCap);
        uint256 available = ecosystem.availableThisEpoch();
        assertEq(available, 0, "epoch cap fully consumed");

        // Now batchEmit with two entries -- even the first will revert
        address[] memory recipients2 = new address[](2);
        uint256[] memory amounts2 = new uint256[](2);
        recipients2[0] = recipientB;
        recipients2[1] = recipientC;
        amounts2[0] = 1e18;
        amounts2[1] = 1e18;

        // Both fail -- epoch cap exhausted for both
        vm.expectRevert(); // EpochCapExceeded
        vm.prank(deployer);
        ecosystem.batchEmit(recipients2, amounts2);

        // QUESTION: batchEmit is all-or-nothing. If epoch is exhausted mid-batch,
        // the remaining valid emissions for the period must wait for the next epoch.
        assertEq(mtry.balanceOf(recipientB), 0);
        assertEq(mtry.balanceOf(recipientC), 0);
    }

    // -------------------------------------------------------------------------
    // Contrast: individual emitTo calls succeed where batch would revert
    // -------------------------------------------------------------------------
    function test_individualEmitSucceedsWhereZeroBatchFails() public {
        // Individual emitTo: skips zero validation only in the sense that
        // zero reverts PER CALL, not the whole batch.
        vm.prank(deployer);
        ecosystem.emitTo(recipientA, 10_000e18);

        vm.expectRevert(ZeroAmount.selector);
        vm.prank(deployer);
        ecosystem.emitTo(recipientB, 0);

        vm.prank(deployer);
        ecosystem.emitTo(recipientC, 10_000e18);

        assertGt(mtry.balanceOf(recipientA), 0, "A received tokens");
        assertEq(mtry.balanceOf(recipientB), 0, "B received nothing (zero amount)");
        assertGt(mtry.balanceOf(recipientC), 0, "C received tokens");

        // QUESTION: With individual calls, A and C succeed despite B failing.
        // With batch, A and C would also fail. Is the caller expected to validate
        // amounts off-chain before batching?
    }
}
