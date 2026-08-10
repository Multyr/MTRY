// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {NothingToRelease, NothingToClaim} from "../../src/Errors.sol";

// =============================================================================
// POC-08: Guardian Pausing GlobalUnlockController Freezes All Protocol Unlocks
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   SAFE_GUARDIAN (1/1 role) calling pause() on GlobalUnlockController freezes
//   every token release in the protocol simultaneously: VestingWalletLinear.claim(),
//   PreMTRYClaim.claim(), and EcosystemEmissionController.emitTo/batchEmit() all
//   call consumeAllowance() which reverts with EnforcedPause. Only SAFE_GOV (3/5
//   multisig) can unpause. Guardian cannot unpause -- pause is one-directional.
//
// WHY NO FIX:
//   This is an explicitly designed property: the GlobalUnlockController IS the
//   single kill-switch for all token releases. The Guardian's ability to pause it
//   is the intended emergency mechanism (DoS temporaneo). The blast radius is
//   large by design -- the point is to halt everything quickly in a crisis.
//
// OPEN QUESTIONS:
//   Q1. The threat model documents Guardian DoS on claim/emission but does not
//       explicitly state it is via a single controller pause. The full blast radius
//       (all flows frozen, single call, no per-flow granularity) should be documented
//       explicitly in the threat model alongside the recovery SLA for SAFE_GOV unpause.
//   Q2. A compromised 1/1 Guardian key is therefore a full protocol pause key.
//       Is the key management for SAFE_GUARDIAN equivalent to that for a 1/5 SAFE_GOV
//       member (the minimum needed to halt a 3/5 quorum)? Should it be harder to pause?
//   Q3. No beneficiary can receive any tokens -- even fully vested -- while the
//       controller is paused. Is this documented in user-facing terms and conditions?
// =============================================================================

contract POC08_GuardianGlobalUnlockFreeze is TestSetup {
    VestingWalletLinear teamWallet;
    address constant CAROL_BENEFICIARY = address(0xCA401);

    uint256 constant ALLOCATION = 1_000_000e18;
    uint256 constant CLIFF = 0;
    uint256 constant DURATION = 365 days;

    function setUp() public {
        _deployAllCorrectly();

        vm.startPrank(deployer);
        vestingManager.setTGE(block.timestamp);
        claim.setTGE(block.timestamp);
        vm.stopPrank();

        // Create a Team GRANT_DATE vesting wallet for teamBeneficiary (no cliff)
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            ALLOCATION,
            uint64(CLIFF),
            uint64(DURATION),
            false
        );
        teamWallet = VestingWalletLinear(w);

        // Give alice some preMTRY and lock it
        _aliceBuys(1_000e6); // 1000 USDC -> 12,500 preMTRY
        // Cache balance before pranking -- vm.prank is consumed by the balanceOf view call
        // if passed inline as an argument, which would send the approve/lock from the test
        // contract (0x7FA9...) instead of alice.
        uint256 alicePreMTRY = preMTRY.balanceOf(alice);
        vm.prank(alice);
        preMTRY.approve(address(claim), alicePreMTRY);
        vm.prank(alice);
        claim.lockPreTokens(alicePreMTRY);
    }

    // -------------------------------------------------------------------------
    // Guardian pauses GlobalUnlockController → all claim() calls fail
    // -------------------------------------------------------------------------
    function test_guardianPauseFreezesVestingWalletClaim() public {
        // Warp to mid-vesting so wallet has claimable tokens
        vm.warp(block.timestamp + DURATION / 2);

        // Sanity: claim works before pause
        uint256 releasable = teamWallet.releasableAmount();
        assertGt(releasable, 0, "should have releasable tokens");

        // Guardian pauses the GLOBAL UNLOCK CONTROLLER (single call)
        vm.prank(safeGuardian);
        unlockController.pause();
        assertTrue(unlockController.paused(), "controller paused");

        // VestingWalletLinear.claim() now fails -- not because the wallet is paused,
        // but because consumeAllowance() inside claim() reverts with EnforcedPause.
        vm.expectRevert();  // EnforcedPause from Pausable
        vm.prank(teamBeneficiary, teamBeneficiary);
        teamWallet.claim();

        // QUESTION: the wallet itself is NOT paused, but the claim path is broken.
        assertFalse(teamWallet.paused(), "wallet itself is NOT paused");
    }

    // -------------------------------------------------------------------------
    // Same pause freezes PreMTRYClaim.claim() for Alice
    // -------------------------------------------------------------------------
    function test_guardianPauseFreezesPreMTRYClaim() public {
        // Warp past cliff
        uint256 tge = claim.tgeTimestamp();
        vm.warp(tge + 180 days + 1 days);

        assertGt(claim.claimable(alice), 0, "alice has claimable MTRY");

        vm.prank(safeGuardian);
        unlockController.pause();

        // claim() fails for alice -- controller paused
        vm.expectRevert();
        vm.prank(alice);
        claim.claim();
    }

    // -------------------------------------------------------------------------
    // Same pause freezes EcosystemEmissionController.emitTo()
    // -------------------------------------------------------------------------
    function test_guardianPauseFreezesEcosystemEmit() public {
        // Add an approved recipient
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(alice, true);

        // Warp to genesis (emit is possible)
        vm.warp(ecosystemGenesis);

        vm.prank(safeGuardian);
        unlockController.pause();

        // emitTo() will fail because it calls consumeAllowance()
        // (ecosystem itself is not paused)
        assertFalse(ecosystem.paused(), "ecosystem itself not paused");
        vm.expectRevert();
        vm.prank(deployer);
        ecosystem.emitTo(alice, 1_000e18);
    }

    // -------------------------------------------------------------------------
    // Guardian CAN pause per-contract without triggering the global freeze
    // -------------------------------------------------------------------------
    function test_perContractPauseIsLessBlastRadius() public {
        vm.warp(block.timestamp + DURATION / 2);

        // Guardian pauses only the vesting wallet (via wallet's own pause)
        vm.prank(safeGuardian);
        teamWallet.pause();
        assertTrue(teamWallet.paused(), "wallet paused");

        // GlobalUnlockController is still live
        assertFalse(unlockController.paused(), "controller not paused");

        // Claim on this wallet fails (wallet is paused)
        vm.expectRevert();
        vm.prank(teamBeneficiary, teamBeneficiary);
        teamWallet.claim();

        // QUESTION: Guardian can choose between pausing ONE wallet (narrow DoS)
        // or pausing the CONTROLLER (full protocol DoS). Both options exist.
        // Is the controller pause documented as the "nuclear option"?
    }

    // -------------------------------------------------------------------------
    // After Guardian pause, ONLY SAFE_GOV can unpause controller
    // -------------------------------------------------------------------------
    function test_onlyOwnerCanUnpauseController() public {
        vm.prank(safeGuardian);
        unlockController.pause();

        // Guardian CANNOT unpause (not owner, only can pause)
        vm.expectRevert();
        vm.prank(safeGuardian);
        unlockController.unpause();

        // Veto CANNOT unpause
        vm.expectRevert();
        vm.prank(safeVeto);
        unlockController.unpause();

        // SAFE_GOV (owner = deployer in test) CAN unpause
        vm.prank(deployer);
        unlockController.unpause();
        assertFalse(unlockController.paused(), "controller unpaused by owner");
    }
}
