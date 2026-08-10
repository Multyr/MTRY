// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {EcosystemEmissionController} from "../src/EcosystemEmissionController.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidTimestamp,
    RecipientNotApproved,
    EpochCapExceeded,
    EmissionHorizonExceeded,
    NotStarted,
    UnlockThrottled,
    InvalidBatchSize,
    ArrayLengthMismatch,
    BurnBeforeHorizon,
    BurnAmountZero,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady
} from "../src/Errors.sol";

contract EcosystemEmissionControllerTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(alice, true);
    }

    // -------------------------------------------------------------------------
    // Epoch math
    // -------------------------------------------------------------------------
    function test_currentEpochAtGenesisIsZero() public view {
        assertEq(ecosystem.currentEpoch(), 0);
    }

    function test_currentEpochIncrements() public {
        vm.warp(ecosystemGenesis + 30 days);
        assertEq(ecosystem.currentEpoch(), 1);
    }

    // -------------------------------------------------------------------------
    // Basic emission
    // -------------------------------------------------------------------------
    function test_emitToSucceeds() public {
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(alice, 500_000e18);
        assertEq(granted, 500_000e18);
        assertEq(mtry.balanceOf(alice), 500_000e18);
        assertEq(ecosystem.totalEmitted(), 500_000e18);
    }

    function test_emitToNotApprovedRecipientReverts() public {
        vm.prank(deployer);
        vm.expectRevert(RecipientNotApproved.selector);
        ecosystem.emitTo(bob, 1e18);
    }

    function test_emitToZeroAmountReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAmount.selector);
        ecosystem.emitTo(alice, 0);
    }

    function test_emitToOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ecosystem.emitTo(alice, 1e18);
    }

    // -------------------------------------------------------------------------
    // Local epoch cap
    // -------------------------------------------------------------------------
    function test_localEpochCapEnforced() public {
        vm.prank(deployer);
        ecosystem.emitTo(alice, 1_000_000e18); // full cap for first epoch

        vm.prank(deployer);
        vm.expectRevert(EpochCapExceeded.selector);
        ecosystem.emitTo(alice, 1);
    }

    function test_localCapPartialEmissionOnly() public {
        // Local cap = 1M, global cap = 6M. Emission of 1.5M should be clamped to 1M by local cap.
        // But wantLocal = min(amount, localRemaining) = 1M, then global allows 1M -> granted = 1M.
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(alice, 1_500_000e18);
        assertEq(granted, 1_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Pending cap changes
    // -------------------------------------------------------------------------
    function test_pendingMaxEmissionAppliesNextEpoch() public {
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(2_000_000e18);

        // Current epoch: still 1M cap
        assertEq(ecosystem.currentMaxEmissionPerEpoch(), 1_000_000e18);

        vm.warp(ecosystemGenesis + 30 days);
        vm.prank(deployer);
        ecosystem.emitTo(alice, 1);
        assertEq(ecosystem.maxEmissionByEpoch(1), 2_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Horizon
    // -------------------------------------------------------------------------
    function test_emitBeyondHorizonReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days); // epoch 60, == MAX_EPOCHS
        vm.prank(deployer);
        vm.expectRevert(EmissionHorizonExceeded.selector);
        ecosystem.emitTo(alice, 1);
    }

    function test_emitInLastValidEpoch() public {
        vm.warp(ecosystemGenesis + 59 * 30 days); // epoch 59, last valid
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(alice, 500e18);
        assertEq(granted, 500e18);
    }

    // -------------------------------------------------------------------------
    // Batch
    // -------------------------------------------------------------------------
    function test_batchEmitSucceeds() public {
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 100e18;
        amounts[1] = 200e18;
        vm.prank(deployer);
        uint256[] memory granted = ecosystem.batchEmit(recipients, amounts);
        assertEq(granted[0], 100e18);
        assertEq(granted[1], 200e18);
    }

    function test_batchEmitLengthMismatchReverts() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](3);
        vm.prank(deployer);
        vm.expectRevert(ArrayLengthMismatch.selector);
        ecosystem.batchEmit(recipients, amounts);
    }

    function test_batchEmitExceedingMaxSizeReverts() public {
        address[] memory recipients = new address[](51);
        uint256[] memory amounts = new uint256[](51);
        vm.prank(deployer);
        vm.expectRevert(InvalidBatchSize.selector);
        ecosystem.batchEmit(recipients, amounts);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------
    function test_pauseBlocksEmit() public {
        vm.prank(deployer);
        ecosystem.pause();
        vm.prank(deployer);
        vm.expectRevert();
        ecosystem.emitTo(alice, 1e18);
    }

    // -------------------------------------------------------------------------
    // Burn (post-horizon, timelocked)
    // -------------------------------------------------------------------------
    function test_proposeBurnRevertsBeforeHorizon() public {
        vm.prank(deployer);
        vm.expectRevert(BurnBeforeHorizon.selector);
        ecosystem.proposeBurn(1_000e18);
    }

    function test_burnAfterHorizonFlow() public {
        vm.warp(ecosystemGenesis + 60 * 30 days); // >= MAX_EPOCHS
        uint256 balance = mtry.balanceOf(address(ecosystem));

        vm.prank(deployer);
        ecosystem.proposeBurn(balance);
        vm.warp(block.timestamp + 7 days);

        uint256 supplyBefore = mtry.totalSupply();
        vm.prank(deployer);
        ecosystem.executeBurn();
        assertEq(mtry.balanceOf(address(ecosystem)), 0);
        assertEq(mtry.totalSupply(), supplyBefore - balance);
    }

    // -- Coverage gap: availableThisEpoch view --------------------------------

    function test_availableThisEpoch_atGenesis_fullCap() public view {
        assertEq(ecosystem.availableThisEpoch(), 1_000_000e18);
    }

    function test_availableThisEpoch_decreasesAfterEmit() public {
        vm.prank(deployer);
        ecosystem.emitTo(alice, 400_000e18);
        assertEq(ecosystem.availableThisEpoch(), 600_000e18);
    }

    function test_availableThisEpoch_zeroAfterEpochExhausted() public {
        vm.prank(deployer);
        ecosystem.emitTo(alice, 1_000_000e18);
        assertEq(ecosystem.availableThisEpoch(), 0);
    }

    function test_availableThisEpoch_zeroAtMaxEpochs() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        assertEq(ecosystem.availableThisEpoch(), 0);
    }

    // -- Coverage gap: cancelBurn ---------------------------------------------

    function test_cancelBurn_clearsProposal() public {
        vm.warp(ecosystemGenesis + 60 * 30 days + 1);
        vm.prank(deployer);
        ecosystem.proposeBurn(1e18);
        assertGt(ecosystem.pendingBurnAmount(), 0);

        vm.prank(deployer);
        ecosystem.cancelBurn();
        assertEq(ecosystem.pendingBurnAmount(), 0);
    }

    // -- Coverage gap: unpause ------------------------------------------------

    function test_unpause_restoresEmit() public {
        vm.prank(deployer);
        ecosystem.pause();
        vm.prank(deployer);
        ecosystem.unpause();
        uint256 before = mtry.balanceOf(alice);
        vm.prank(deployer);
        ecosystem.emitTo(alice, 1e18);
        assertEq(mtry.balanceOf(alice) - before, 1e18);
    }

    // -------------------------------------------------------------------------
    // Constructor revert guards
    // -------------------------------------------------------------------------
    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(ZeroAddress.selector);
        new EcosystemEmissionController(
            address(0), address(unlockController), deployer,
            block.timestamp, 30 days, 1_000_000e18
        );
    }

    function test_constructorRevertsOnZeroUnlockController() public {
        vm.expectRevert(ZeroAddress.selector);
        new EcosystemEmissionController(
            address(mtry), address(0), deployer,
            block.timestamp, 30 days, 1_000_000e18
        );
    }

    function test_constructorRevertsOnZeroEpochDuration() public {
        vm.expectRevert(ZeroAmount.selector);
        new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp, 0, 1_000_000e18
        );
    }

    function test_constructorRevertsOnZeroMaxEmission() public {
        vm.expectRevert(ZeroAmount.selector);
        new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp, 30 days, 0
        );
    }

    // -------------------------------------------------------------------------
    // setApprovedRecipient zero address guard
    // -------------------------------------------------------------------------
    function test_setApprovedRecipientZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        ecosystem.setApprovedRecipient(address(0), true);
    }

    // -------------------------------------------------------------------------
    // setPendingMaxEmissionPerEpoch zero guard
    // -------------------------------------------------------------------------
    function test_setPendingMaxEmissionZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAmount.selector);
        ecosystem.setPendingMaxEmissionPerEpoch(0);
    }

    // -------------------------------------------------------------------------
    // availableThisEpoch — pre-genesis returns 0
    // -------------------------------------------------------------------------
    function test_availableThisEpoch_preGenesis_returnsZero() public {
        EcosystemEmissionController fresh = new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp + 365 days,  // future genesis
            30 days, 1_000_000e18
        );
        assertEq(fresh.availableThisEpoch(), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: currentEpoch() pre-genesis returns 0
    // -------------------------------------------------------------------------
    function test_currentEpoch_preGenesis_returnsZero() public {
        EcosystemEmissionController fresh = new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp + 365 days,  // future genesis
            30 days, 1_000_000e18
        );
        assertEq(fresh.currentEpoch(), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: availableThisEpoch() cap-already-set branch
    // -------------------------------------------------------------------------
    function test_availableThisEpoch_capAlreadySetBranch() public {
        // Emit in a later epoch so _rollEpochIfNeeded snapshots maxEmissionByEpoch[epoch] != 0.
        // Then availableThisEpoch reads cap directly (skips the `if (cap == 0)` default).
        vm.warp(ecosystemGenesis + 30 days); // epoch 1
        vm.prank(deployer);
        ecosystem.emitTo(alice, 100e18); // rolls epoch 1, snapshots cap
        assertEq(ecosystem.maxEmissionByEpoch(1), 1_000_000e18);
        assertEq(ecosystem.availableThisEpoch(), 1_000_000e18 - 100e18);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _emit() horizon exceeded revert
    // -------------------------------------------------------------------------
    function test_emit_horizonExceededReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days); // epoch 60 == MAX_EPOCHS
        vm.prank(deployer);
        vm.expectRevert(EmissionHorizonExceeded.selector);
        ecosystem.emitTo(alice, 1e18);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: proposeBurn guards
    // -------------------------------------------------------------------------
    function test_proposeBurn_alreadyPendingReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        vm.startPrank(deployer);
        ecosystem.proposeBurn(1e18);
        vm.expectRevert(BurnAlreadyPending.selector);
        ecosystem.proposeBurn(1e18);
        vm.stopPrank();
    }

    function test_proposeBurn_zeroAmountReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        vm.prank(deployer);
        vm.expectRevert(BurnAmountZero.selector);
        ecosystem.proposeBurn(0);
    }

    function test_proposeBurn_exceedsBalanceReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        uint256 balance = mtry.balanceOf(address(ecosystem));
        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        ecosystem.proposeBurn(balance + 1);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: cancelBurn / executeBurn guards
    // -------------------------------------------------------------------------
    function test_cancelBurn_noPendingReverts() public {
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        ecosystem.cancelBurn();
    }

    function test_executeBurn_noPendingReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        ecosystem.executeBurn();
    }

    function test_executeBurn_notReadyReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        vm.startPrank(deployer);
        ecosystem.proposeBurn(1e18);
        vm.expectRevert(BurnNotReady.selector);
        ecosystem.executeBurn();
        vm.stopPrank();
    }

    function test_executeBurn_exceedsBalanceReverts() public {
        vm.warp(ecosystemGenesis + 60 * 30 days);
        uint256 balance = mtry.balanceOf(address(ecosystem));
        vm.prank(deployer);
        ecosystem.proposeBurn(balance);
        vm.warp(block.timestamp + 7 days);

        // Drain balance so the pending amount now exceeds the balance.
        vm.prank(address(ecosystem));
        mtry.transfer(bob, 1);

        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        ecosystem.executeBurn();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _emit() before genesis → NotStarted
    // -------------------------------------------------------------------------
    function test_emit_beforeGenesis_reverts() public {
        EcosystemEmissionController fresh = new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp + 365 days,
            30 days, 1_000_000e18
        );
        vm.prank(deployer);
        fresh.setApprovedRecipient(alice, true);
        vm.prank(deployer);
        vm.expectRevert(NotStarted.selector);
        fresh.emitTo(alice, 1e18);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: availableThisEpoch() cap==0 → uses currentMaxEmissionPerEpoch
    // -------------------------------------------------------------------------
    function test_availableThisEpoch_uninitializedEpochUsesDefault() public {
        // Epoch 0 cap is set in constructor. Epoch 1 is uninitialized (cap==0)
        // until _rollEpochIfNeeded fires. Calling availableThisEpoch() before
        // any emit in epoch 1 exercises the cap==0 → default assignment branch.
        vm.warp(ecosystemGenesis + 30 days); // enter epoch 1
        uint256 available = ecosystem.availableThisEpoch();
        // cap == 0 for epoch 1 → uses currentMaxEmissionPerEpoch = 1_000_000e18
        assertEq(available, 1_000_000e18);
    }

    // -------------------------------------------------------------------------
    // M-5: Constructor rejects genesis unreasonably far in the future
    // -------------------------------------------------------------------------

    function test_constructor_rejectsGenesisInFarFuture() public {
        vm.expectRevert(InvalidTimestamp.selector);
        new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp + 3651 days,  // just past the 3650-day ceiling
            30 days, 1_000_000e18
        );
    }

    function test_constructor_acceptsGenesisTenYearsOut() public {
        // Exactly at the boundary is valid.
        new EcosystemEmissionController(
            address(mtry), address(unlockController), deployer,
            block.timestamp + 3650 days,
            30 days, 1_000_000e18
        );
    }
}
