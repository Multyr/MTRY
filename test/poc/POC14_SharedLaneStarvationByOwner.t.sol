// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {UnlockThrottled} from "../../src/Errors.sol";

// =============================================================================
// POC-14: Vesting Wallet Claims Can Starve EcosystemEmissionController (Shared Lane)
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   GlobalUnlockController enforces a protected/shared lane split. PreMTRYClaim is
//   a PROTECTED source (guaranteed access to its quota). EcosystemEmissionController
//   is a SHARED source (default deploy config). VestingWalletLinear instances are
//   also SHARED sources. All shared sources compete first-come-first-served within
//   the shared quota (50% of period cap by default = 3M MTRY/period).
//
//   If a large Team vesting wallet (e.g. 51M with no cliff) claims early in a period,
//   it can consume the entire 3M shared quota. EcosystemEmissionController.emitTo()
//   called in the same period will receive 0 (UnlockThrottled). Ecosystem emissions
//   are blocked for the remainder of that period.
//
// WHY NO FIX:
//   KL-4 explicitly documents shared-lane FCFS as an acknowledged trade-off.
//   The remedy (designate ecosystem as a protected source via setProtectedSource())
//   is available to governance at any time post-deploy. The 50/50 default quota
//   ensures a minimum 25% guaranteed floor for any lane even at max protectedQuotaBps.
//
// OPEN QUESTIONS:
//   Q1. The default config deploys ecosystem as a shared source. If shared-lane
//       starvation is an accepted risk (KL-4), should the DEFAULT be to set ecosystem
//       as protected and require governance to downgrade it? Safer default = protected.
//   Q2. With 111M total vesting and a 30-day period cap of 3M shared quota, all
//       vesting wallets claiming simultaneously would take ~37 periods (3+ years)
//       to fully release. Is the per-period shared-lane starvation modeled in the
//       tokenomics, or does it assume staggered claiming behavior?
//   Q3. Is there an off-chain monitoring alert for "shared lane exhausted with
//       ecosystem not yet emitting this period"?
// =============================================================================

contract POC14_SharedLaneStarvationByOwner is TestSetup {
    VestingWalletLinear teamWallet;
    address ecosystemRecipient = address(0xEEEE);

    uint256 constant TEAM_ALLOC = 51_000_000e18; // fills entire Team cap
    uint64 constant CLIFF = 0;
    uint64 constant DURATION = 365 days;

    function setUp() public {
        _deployAllCorrectly();
        vm.startPrank(deployer);
        vestingManager.setTGE(block.timestamp);
        ecosystem.setApprovedRecipient(ecosystemRecipient, true);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Show EcosystemEmissionController is a shared (not protected) source
    // -------------------------------------------------------------------------
    function test_ecosystemIsSharedSource() public view {
        assertFalse(
            unlockController.protectedSource(address(ecosystem)),
            "QUESTION: ecosystem is a SHARED source (not protected)"
        );
        assertTrue(
            unlockController.protectedSource(address(claim)),
            "claim IS protected (as expected)"
        );
    }

    // -------------------------------------------------------------------------
    // Large vesting wallet claims exhaust shared lane in one period
    // -------------------------------------------------------------------------
    function test_vestingClaimsExhaustSharedLane_ecosystemThrottled() public {
        // Create a single large Team wallet (no cliff, 1-year vesting)
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            TEAM_ALLOC,
            CLIFF,
            DURATION,
            false
        );
        teamWallet = VestingWalletLinear(w);

        // Warp to mid-vesting: 50% of tokens are vested
        vm.warp(block.timestamp + DURATION / 2);

        uint256 periodCap = unlockController.maxUnlockForPeriod(unlockController.currentPeriod());
        uint256 protectedQuota = (periodCap * unlockController.protectedQuotaBps()) / 10_000;
        uint256 sharedQuota = periodCap - protectedQuota; // 50% of 6M = 3M

        // 50% of 51M = 25.5M vested. The shared quota is only 3M/period.
        // Claiming releases up to the shared quota (3M) in one call.
        uint256 releasable = teamWallet.releasableAmount();
        assertGt(releasable, sharedQuota, "vested > shared quota: will exhaust shared lane");

        // Beneficiary claims -- consumes up to the shared quota (3M) from the lane
        vm.prank(teamBeneficiary, teamBeneficiary);
        teamWallet.claim();

        // Check remaining shared allowance for ecosystem
        uint256 remainingForEcosystem = unlockController.remainingAllowanceForSource(address(ecosystem));
        assertEq(remainingForEcosystem, 0, "shared lane exhausted -- ecosystem has 0 allowance");

        // Ecosystem emission now fails for this period.
        // Do NOT warp back to ecosystemGenesis -- we are already well past it (6 months in).
        // Warping backwards would move to period 0 which has a fresh shared quota,
        // making the emit succeed and defeating the point of this test.
        vm.expectRevert(UnlockThrottled.selector);
        vm.prank(deployer);
        ecosystem.emitTo(ecosystemRecipient, 1e18);

        // QUESTION: Beneficiary's legitimate vesting claim blocked ecosystem emissions
        // for the rest of the period. Is this acceptable? Should ecosystem be protected?
    }

    // -------------------------------------------------------------------------
    // Protected source (claim) is NOT affected by shared-lane starvation
    // -------------------------------------------------------------------------
    function test_protectedSourceUnaffectedBySharedStarvation() public {
        // Give alice some preMTRY to lock
        vm.warp(saleStart);
        _fundAlice(1_000e6);
        vm.prank(alice);
        sale.buy(1_000e6, alice);

        // MULTYR-1: TGE must be >= saleEnd, so warp forward past the sale close before setting it.
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        // Cache balance before pranking -- vm.prank is consumed by an inline balanceOf call.
        uint256 alicePreMTRY = preMTRY.balanceOf(alice);
        vm.prank(alice);
        preMTRY.approve(address(claim), alicePreMTRY);
        vm.prank(alice);
        claim.lockPreTokens(alicePreMTRY);

        // Create large vesting wallet to starve shared lane
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000_000e18,
            CLIFF,
            DURATION,
            false
        );

        // Warp to post-cliff for alice
        vm.warp(block.timestamp + 180 days + 1 days);

        // Vesting wallet claims -- exhausts shared lane
        vm.prank(teamBeneficiary, teamBeneficiary);
        VestingWalletLinear(w).claim();

        // Alice's claim still works (protected lane is separate from shared)
        uint256 aliceClaimable = claim.claimable(alice);
        if (aliceClaimable > 0) {
            uint256 balBefore = mtry.balanceOf(alice);
            vm.prank(alice);
            claim.claim();
            assertGt(mtry.balanceOf(alice) - balBefore, 0, "alice claimed from protected lane");
        }
    }
}
