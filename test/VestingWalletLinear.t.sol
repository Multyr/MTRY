// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {
    ZeroAddress,
    ZeroAmount,
    NothingToRelease,
    AlreadyRevoked,
    NotRevocable,
    NotRevoker,
    NotBeneficiary,
    NotAuthorized,
    BeneficiaryUpdatePending,
    BeneficiaryUpdateNotReady,
    UnlockThrottled,
    InvalidBeneficiaryContract
} from "../src/Errors.sol";

contract VestingWalletLinearTest is TestSetup {
    VestingWalletLinear wallet;
    uint64 constant CLIFF = 180 days;
    uint64 constant DURATION = 540 days;
    uint256 constant ALLOCATION = 1_000_000e18;

    function setUp() public {
        _deployAllCorrectly();
        // GRANT_DATE mode wallet for Team bucket (1M), revocable = true
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            ALLOCATION,
            CLIFF,
            DURATION,
            true
        );
        wallet = VestingWalletLinear(w);
    }

    // -------------------------------------------------------------------------
    // Construction invariants
    // -------------------------------------------------------------------------
    function test_walletStorageIsCorrect() public view {
        assertEq(address(wallet.token()), address(mtry));
        assertEq(wallet.beneficiary(), teamBeneficiary);
        assertEq(wallet.cliffDuration(), CLIFF);
        assertEq(wallet.vestingDuration(), DURATION);
        assertEq(wallet.totalAllocation(), ALLOCATION);
        assertTrue(wallet.revocable());
        assertEq(wallet.vestingManager(), address(vestingManager));
        assertEq(wallet.revoker(), deployer);
        assertEq(wallet.treasury(), treasurySafe);
        assertEq(wallet.unlockController(), address(unlockController));
    }

    // -------------------------------------------------------------------------
    // Dynamic authority — follows VestingManager governance migration
    // -------------------------------------------------------------------------
    function test_revokerFollowsVestingManagerOwnershipMigration() public {
        // Initial authority = deployer
        assertEq(wallet.revoker(), deployer);

        // Migrate governance on VestingManager: deployer → safeGov (2-step)
        vm.prank(deployer);
        vestingManager.transferOwnership(safeGov);
        vm.prank(safeGov);
        vestingManager.acceptOwnership();

        // Wallet authority automatically follows
        assertEq(wallet.revoker(), safeGov);

        // New authority can revoke
        vm.prank(safeGov);
        wallet.revokeUnvested();
        assertTrue(wallet.revoked());
    }

    function test_oldRevokerCannotRevokeAfterMigration() public {
        // Migrate governance
        vm.prank(deployer);
        vestingManager.transferOwnership(safeGov);
        vm.prank(safeGov);
        vestingManager.acceptOwnership();

        // Old owner loses authority
        vm.prank(deployer);
        vm.expectRevert(NotRevoker.selector);
        wallet.revokeUnvested();
    }

    function test_pauseAuthorityFollowsMigration() public {
        vm.prank(deployer);
        vestingManager.transferOwnership(safeGov);
        vm.prank(safeGov);
        vestingManager.acceptOwnership();

        // Old authority can no longer pause (not guardian, not revoker after migration)
        vm.prank(deployer);
        vm.expectRevert(NotAuthorized.selector);
        wallet.pause();

        // New authority can
        vm.prank(safeGov);
        wallet.pause();
        assertTrue(wallet.paused());
    }

    function test_walletIsFundedAtCreation() public view {
        assertEq(mtry.balanceOf(address(wallet)), ALLOCATION);
    }

    // -------------------------------------------------------------------------
    // Claim — cliff, vesting, clamp
    // -------------------------------------------------------------------------
    function test_claimRevertsBeforeCliff() public {
        vm.warp(block.timestamp + CLIFF - 1);
        vm.prank(teamBeneficiary, teamBeneficiary);
        vm.expectRevert(NothingToRelease.selector);
        wallet.claim();
    }

    function test_claimAtCliffBoundaryZero() public {
        // At t == start + cliff exactly, vested = 0 (linear starts AFTER cliff end)
        vm.warp(wallet.startTimestamp() + CLIFF);
        vm.prank(teamBeneficiary, teamBeneficiary);
        vm.expectRevert(NothingToRelease.selector);
        wallet.claim();
    }

    function test_claimMidpoint() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION / 2);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertEq(mtry.balanceOf(teamBeneficiary), ALLOCATION / 2);
    }

    function test_claimFullVesting() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertEq(mtry.balanceOf(teamBeneficiary), ALLOCATION);
    }

    function test_claimRevertsForNonBeneficiary() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);
        vm.prank(alice);
        vm.expectRevert(NotBeneficiary.selector);
        wallet.claim();
    }

    function test_claimToRedirects() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claimTo(alice);
        assertEq(mtry.balanceOf(alice), ALLOCATION);
    }

    function test_claimThrottledWhenCapExhausted() public {
        // Raise local ecosystem cap so it can drain the full shared lane.
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);

        // Advance to next epoch to activate pending local cap.
        vm.warp(block.timestamp + 30 days);
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);

        // Warp to full vesting for the wallet (new period, fresh 6M cap with 3M protected + 3M shared).
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);

        // Trigger new-epoch rollover.
        vm.prank(deployer);
        ecosystem.emitTo(bob, 1);

        // Exhaust the shared lane (3M available, minus the 1-wei warm-up).
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(bob, 3_000_000e18);
        granted; // suppress warning

        // Shared lane exhausted — the wallet (shared source) now reverts with UnlockThrottled.
        uint256 period = unlockController.currentPeriod();
        // Shared lane remaining = 0 (or at most 1 wei from warm-up)
        assertLe(unlockController.remainingAllowanceForSource(address(wallet)), 1);

        vm.prank(teamBeneficiary, teamBeneficiary);
        vm.expectRevert(UnlockThrottled.selector);
        wallet.claim();
        period; // suppress warning
    }

    // -------------------------------------------------------------------------
    // Revocation
    // -------------------------------------------------------------------------
    function test_revokeSendsUnvestedToTreasury() public {
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION / 4); // 25% vested

        uint256 treasuryBefore = mtry.balanceOf(treasurySafe);
        vm.prank(deployer);
        wallet.revokeUnvested();

        // vested = 25% = 250k, unvested = 750k → to treasury
        assertEq(mtry.balanceOf(treasurySafe), treasuryBefore + 750_000e18);
        assertTrue(wallet.revoked());
    }

    function test_revokeOnlyRevoker() public {
        vm.prank(alice);
        vm.expectRevert(NotRevoker.selector);
        wallet.revokeUnvested();
    }

    function test_revokeDoubleFails() public {
        vm.prank(deployer);
        wallet.revokeUnvested();
        vm.prank(deployer);
        vm.expectRevert(AlreadyRevoked.selector);
        wallet.revokeUnvested();
    }

    function test_nonRevocableCannotRevoke() public {
        address w2 = _createGrantVesting(
            VestingManager.BucketType.Team,
            alice,
            1_000e18,
            CLIFF,
            DURATION,
            false
        );
        vm.prank(deployer);
        vm.expectRevert(NotRevocable.selector);
        VestingWalletLinear(w2).revokeUnvested();
    }

    function test_revokeBeforeCliffSendsAllToTreasury() public {
        // revoke before cliff → unvested = full allocation
        uint256 treasuryBefore = mtry.balanceOf(treasurySafe);
        vm.prank(deployer);
        wallet.revokeUnvested();
        assertEq(mtry.balanceOf(treasurySafe), treasuryBefore + ALLOCATION);
    }

    function test_afterRevokeClaimTakesOnlyVestedAtRevoke() public {
        // Warp to 50% vested, revoke → unvested (50%) goes to treasury, vested at revoke (50%) stays.
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION / 2);
        vm.prank(deployer);
        wallet.revokeUnvested();

        // Beneficiary can still claim the vested 500k
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();
        assertEq(mtry.balanceOf(teamBeneficiary), 500_000e18);
    }

    // -------------------------------------------------------------------------
    // 2-phase beneficiary update
    // -------------------------------------------------------------------------
    function test_beneficiaryUpdate2PhaseFlow() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        assertEq(wallet.pendingBeneficiary(), alice);
        assertGt(wallet.beneficiaryUpdateAt(), block.timestamp);

        // Cannot confirm before delay
        vm.prank(teamBeneficiary);
        vm.expectRevert(BeneficiaryUpdateNotReady.selector);
        wallet.confirmBeneficiaryUpdate();

        // Wait delay
        vm.warp(wallet.beneficiaryUpdateAt());
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.confirmBeneficiaryUpdate();

        assertEq(wallet.beneficiary(), alice);
        assertEq(wallet.pendingBeneficiary(), address(0));
    }

    function test_beneficiaryUpdateUnauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        wallet.proposeBeneficiaryUpdate(bob);
    }

    // Revoker must not be able to drive beneficiary reassignment.
    function test_revokerCannotProposeBeneficiaryUpdate() public {
        vm.prank(deployer);  // deployer == revoker() == vestingManager.owner()
        vm.expectRevert(NotAuthorized.selector);
        wallet.proposeBeneficiaryUpdate(alice);
    }

    function test_revokerCannotConfirmBeneficiaryUpdate() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        vm.warp(wallet.beneficiaryUpdateAt());

        vm.prank(deployer);
        vm.expectRevert(NotAuthorized.selector);
        wallet.confirmBeneficiaryUpdate();
    }

    function test_revokerCanStillCancelBeneficiaryUpdate() public {
        // Revoker retains cancel power as a safety-net against suspicious proposals.
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);

        vm.prank(deployer);  // revoker
        wallet.cancelBeneficiaryUpdate();
        assertEq(wallet.pendingBeneficiary(), address(0));
    }

    function test_beneficiaryUpdateCancelClearsPending() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);

        vm.prank(teamBeneficiary);
        wallet.cancelBeneficiaryUpdate();
        assertEq(wallet.pendingBeneficiary(), address(0));
    }

    function test_beneficiaryUpdateCancelByProposed() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        vm.prank(alice);
        wallet.cancelBeneficiaryUpdate();
        assertEq(wallet.pendingBeneficiary(), address(0));
    }

    function test_beneficiaryUpdatePendingBlocksNew() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        vm.prank(teamBeneficiary);
        vm.expectRevert(BeneficiaryUpdatePending.selector);
        wallet.proposeBeneficiaryUpdate(bob);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------
    function test_pauseBlocksClaim() public {
        vm.prank(deployer);
        wallet.pause();
        vm.warp(wallet.startTimestamp() + CLIFF + DURATION);
        vm.prank(teamBeneficiary);
        vm.expectRevert();
        wallet.claim();
    }

    function test_normalRevokeBlockedWhenPaused() public {
        // Standard revokeUnvested() is blocked by whenNotPaused after the pause/revoke split.
        // Emergency path is covered by EmergencyRevokeTest.
        vm.prank(deployer);
        wallet.pause();
        vm.prank(deployer);
        vm.expectRevert();  // EnforcedPause
        wallet.revokeUnvested();
        assertFalse(wallet.revoked());
    }

    // -------------------------------------------------------------------------
    // View functions — unvestedAmount, cliffEnd, vestingEnd
    // -------------------------------------------------------------------------
    function test_unvestedAmountBeforeCliff() public view {
        // Before any vesting, unvested == totalAllocation
        assertEq(wallet.unvestedAmount(wallet.startTimestamp()), ALLOCATION);
    }

    function test_unvestedAmountMidpoint() public view {
        uint256 mid = wallet.startTimestamp() + CLIFF + DURATION / 2;
        assertEq(wallet.unvestedAmount(mid), ALLOCATION / 2);
    }

    function test_unvestedAmountAtFullVesting() public view {
        uint256 end = wallet.startTimestamp() + CLIFF + DURATION;
        assertEq(wallet.unvestedAmount(end), 0);
    }

    function test_cliffEnd() public view {
        assertEq(wallet.cliffEnd(), wallet.startTimestamp() + CLIFF);
    }

    function test_vestingEnd() public view {
        assertEq(wallet.vestingEnd(), wallet.startTimestamp() + CLIFF + DURATION);
    }

    // -------------------------------------------------------------------------
    // Constructor revert guards
    // -------------------------------------------------------------------------
    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingWalletLinear(
            address(0), address(1), block.timestamp, 0, 1 days, 1e18,
            false, address(1), address(1), address(1)
        );
    }

    function test_constructorRevertsOnZeroBeneficiary() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingWalletLinear(
            address(1), address(0), block.timestamp, 0, 1 days, 1e18,
            false, address(1), address(1), address(1)
        );
    }

    function test_constructorRevertsOnZeroVestingManager() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingWalletLinear(
            address(1), address(1), block.timestamp, 0, 1 days, 1e18,
            false, address(0), address(1), address(1)
        );
    }

    function test_constructorRevertsOnZeroTreasury() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingWalletLinear(
            address(1), address(1), block.timestamp, 0, 1 days, 1e18,
            false, address(1), address(0), address(1)
        );
    }

    function test_constructorRevertsOnZeroUnlockController() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingWalletLinear(
            address(1), address(1), block.timestamp, 0, 1 days, 1e18,
            false, address(1), address(1), address(0)
        );
    }

    function test_constructorRevertsOnZeroVestingDuration() public {
        vm.expectRevert(ZeroAmount.selector);
        new VestingWalletLinear(
            address(1), address(1), block.timestamp, 0, 0, 1e18,
            false, address(1), address(1), address(1)
        );
    }

    function test_constructorRevertsOnZeroTotalAllocation() public {
        vm.expectRevert(ZeroAmount.selector);
        new VestingWalletLinear(
            address(1), address(1), block.timestamp, 0, 1 days, 0,
            false, address(1), address(1), address(1)
        );
    }

    // -------------------------------------------------------------------------
    // claimTo zero-address guard
    // -------------------------------------------------------------------------
    function test_claimToRevertsOnZeroAddress() public {
        vm.warp(block.timestamp + CLIFF + DURATION / 2);
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claimTo(address(0));
    }

    // -------------------------------------------------------------------------
    // cancelBeneficiaryUpdate — unauthorized caller revert (covers uncovered line)
    // -------------------------------------------------------------------------
    function test_cancelBeneficiaryUpdateUnauthorizedReverts() public {
        // Propose an update so there's something to cancel
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        assertEq(wallet.pendingBeneficiary(), alice);

        // bob is not beneficiary, not revoker, not pendingBeneficiary
        vm.expectRevert(NotAuthorized.selector);
        vm.prank(bob);
        wallet.cancelBeneficiaryUpdate();
    }

    // -------------------------------------------------------------------------
    // proposeBeneficiaryUpdate — zero-address guard and non-whitelisted contract
    // -------------------------------------------------------------------------
    function test_proposeBeneficiaryUpdateRevertsOnZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(address(0));
    }

    function test_proposeBeneficiaryUpdateRevertsForNonWhitelistedContract() public {
        // Deploy a contract that is NOT whitelisted in vestingManager
        address nonWhitelisted = address(new DummyContract());

        vm.expectRevert(InvalidBeneficiaryContract.selector);
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(nonWhitelisted);
    }
}

/// @dev Minimal contract used to test non-whitelisted beneficiary rejection.
contract DummyContract {}
