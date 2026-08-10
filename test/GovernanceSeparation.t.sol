// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {GovernanceRoles} from "../src/base/GovernanceRoles.sol";

contract GovernanceSeparationTest is TestSetup {
    VestingWalletLinear internal wallet;

    function setUp() public {
        _deployAllCorrectly();
        wallet = VestingWalletLinear(
            _createGrantVesting(
                VestingManager.BucketType.Team,
                teamBeneficiary,
                1_000e18,
                365 days,
                1095 days,
                true
            )
        );
    }

    // -------------------------------------------------------------------------
    // Guardian powers — pause on all pausable contracts
    // -------------------------------------------------------------------------
    function test_GuardianCanPauseSale() public {
        vm.prank(safeGuardian);
        sale.pause();
        assertTrue(sale.paused());
    }

    function test_GuardianCanPauseClaim() public {
        vm.prank(safeGuardian);
        claim.pause();
        assertTrue(claim.paused());
    }

    function test_GuardianCanPauseVestingManager() public {
        vm.prank(safeGuardian);
        vestingManager.pause();
        assertTrue(vestingManager.paused());
    }

    function test_GuardianCanPauseGlobalUnlock() public {
        vm.prank(safeGuardian);
        unlockController.pause();
        assertTrue(unlockController.paused());
    }

    function test_GuardianCanPauseEcosystem() public {
        vm.prank(safeGuardian);
        ecosystem.pause();
        assertTrue(ecosystem.paused());
    }

    function test_GuardianCanPauseVestingWallet() public {
        vm.prank(safeGuardian);
        wallet.pause();
        assertTrue(wallet.paused());
    }

    // -------------------------------------------------------------------------
    // Guardian limits — cannot unpause, cannot own, cannot propose
    // -------------------------------------------------------------------------
    function test_RevertWhen_GuardianTriesToUnpause() public {
        vm.prank(safeGuardian);
        claim.pause();
        vm.prank(safeGuardian);
        vm.expectRevert();
        claim.unpause();
    }

    function test_RevertWhen_GuardianTransfersOwnership() public {
        vm.prank(safeGuardian);
        vm.expectRevert();
        claim.transferOwnership(address(0xDEAD));
    }

    function test_RevertWhen_GuardianProposesBurn() public {
        vm.prank(safeGuardian);
        vm.expectRevert();
        vestingManager.proposeBurn(1_000e18);
    }

    function test_RevertWhen_GuardianSetsGuardian() public {
        vm.prank(safeGuardian);
        vm.expectRevert();
        claim.setGuardian(address(0xDEAD));
    }

    function test_RevertWhen_GuardianCreatesVesting() public {
        vm.prank(safeGuardian);
        vm.expectRevert();
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            address(0xAAAA),
            1e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    // -------------------------------------------------------------------------
    // Veto powers — cancel pending proposals
    // -------------------------------------------------------------------------
    function test_VetoCanCancelClaimBurn() public {
        vm.prank(deployer);
        claim.setTGE(block.timestamp);
        vm.warp(block.timestamp + 180 days + 540 days + 1);

        vm.prank(deployer);
        claim.proposeBurn(1_000e18);

        vm.prank(safeVeto);
        claim.cancelBurn();
        assertEq(claim.pendingBurnAmount(), 0);
    }

    function test_VetoCanCancelVestingManagerBurn() public {
        vm.prank(deployer);
        vestingManager.proposeBurn(1_000e18);

        vm.prank(safeVeto);
        vestingManager.cancelBurn();
        assertEq(vestingManager.pendingBurnAmount(), 0);
    }

    function test_VetoCanCancelUnlockCapChange() public {
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(500);

        vm.prank(safeVeto);
        unlockController.cancelPendingUnlockCap();
    }

    function test_VetoCanCancelEmissionCapChange() public {
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(2_000_000e18);

        vm.prank(safeVeto);
        ecosystem.cancelPendingMaxEmission();
    }

    // -------------------------------------------------------------------------
    // Veto limits — cannot pause, cannot propose, cannot transfer
    // -------------------------------------------------------------------------
    function test_RevertWhen_VetoPausesContract() public {
        vm.prank(safeVeto);
        vm.expectRevert();
        claim.pause();
    }

    function test_RevertWhen_VetoProposesBurn() public {
        vm.prank(safeVeto);
        vm.expectRevert();
        vestingManager.proposeBurn(1_000e18);
    }

    function test_RevertWhen_VetoTransfersOwnership() public {
        vm.prank(safeVeto);
        vm.expectRevert();
        claim.transferOwnership(address(0xDEAD));
    }

    function test_RevertWhen_VetoSetsCap() public {
        vm.prank(safeVeto);
        vm.expectRevert();
        unlockController.setPendingUnlockCapBps(500);
    }

    function test_RevertWhen_VetoCreatesVesting() public {
        vm.prank(safeVeto);
        vm.expectRevert();
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            address(0xAAAA),
            1e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    // -------------------------------------------------------------------------
    // Owner (SAFE_GOV) full powers
    // -------------------------------------------------------------------------
    function test_OwnerCanPauseAndUnpause() public {
        vm.prank(deployer);
        claim.pause();
        assertTrue(claim.paused());
        vm.prank(deployer);
        claim.unpause();
        assertFalse(claim.paused());
    }

    function test_OwnerCanSetGuardian() public {
        address newGuardian = address(0xAA55);
        vm.prank(deployer);
        claim.setGuardian(newGuardian);
        assertEq(claim.guardian(), newGuardian);
    }

    function test_OwnerCanSetVeto() public {
        address newVeto = address(0xBB66);
        vm.prank(deployer);
        claim.setVeto(newVeto);
        assertEq(claim.veto(), newVeto);
    }

    function test_OwnerCanCancelOwnBurnProposal() public {
        vm.prank(deployer);
        vestingManager.proposeBurn(1_000e18);
        vm.prank(deployer);
        vestingManager.cancelBurn();
        assertEq(vestingManager.pendingBurnAmount(), 0);
    }

    // -------------------------------------------------------------------------
    // Zero-address protection
    // -------------------------------------------------------------------------
    function test_RevertWhen_GuardianSetToZero() public {
        vm.prank(deployer);
        vm.expectRevert();
        claim.setGuardian(address(0));
    }

    function test_RevertWhen_VetoSetToZero() public {
        vm.prank(deployer);
        vm.expectRevert();
        claim.setVeto(address(0));
    }

    // -------------------------------------------------------------------------
    // Wallet-level guardian (passed by VestingManager at creation)
    // -------------------------------------------------------------------------
    function test_WalletGuardianCanPauseWallet() public {
        vm.prank(safeGuardian);
        wallet.pause();
        assertTrue(wallet.paused());
    }

    function test_WalletGuardianCannotUnpauseWallet() public {
        vm.prank(safeGuardian);
        wallet.pause();
        vm.prank(safeGuardian);
        vm.expectRevert();
        wallet.unpause();
    }

    function test_WalletGuardianMatchesManagerGuardian() public view {
        assertEq(wallet.guardian(), safeGuardian);
        assertEq(wallet.guardian(), vestingManager.guardian());
    }

    // -------------------------------------------------------------------------
    // MULTYR-6: wallet guardian is resolved dynamically from the manager, so a
    // manager-level guardian rotation propagates to already-deployed wallets
    // instead of leaving them pinned to a stale, rotated-out address.
    // -------------------------------------------------------------------------
    function test_WalletGuardianFollowsManagerRotation() public {
        address rotatedInGuardian = address(0xA11A);

        vm.prank(deployer);
        vestingManager.setGuardian(rotatedInGuardian);

        assertEq(wallet.guardian(), rotatedInGuardian, "wallet must follow the manager rotation");

        // Old guardian can no longer pause.
        vm.prank(safeGuardian);
        vm.expectRevert();
        wallet.pause();

        // Rotated-in guardian can pause.
        vm.prank(rotatedInGuardian);
        wallet.pause();
        assertTrue(wallet.paused());
    }
}
