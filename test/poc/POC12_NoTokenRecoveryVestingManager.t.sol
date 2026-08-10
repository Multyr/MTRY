// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup, MockToken18} from "../helpers/TestSetup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoBurnPending, BurnNotReady} from "../../src/Errors.sol";

// =============================================================================
// POC-12: VestingManager Has No Token Recovery Function
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   VestingManager has no recoverToken() function. PreMTRYClaim has one (for
//   non-MTRY/preMTRY tokens). VestingManager holds up to 111M MTRY. If MTRY is
//   accidentally sent directly to VestingManager (outside createVesting()), it
//   merges silently into the unallocated balance. The only removal path is
//   proposeBurn → executeBurn (7-day Veto window). There is no recovery-to-treasury
//   path. Non-MTRY tokens sent here are permanently irrecoverable -- no burn path
//   exists for them at all.
//
// WHY NO FIX:
//   Adding recoverToken() to VestingManager would be a larger scope change and
//   requires clear policy decisions: which tokens are recoverable, to whom, under
//   what conditions. The MTRY case is arguably covered by the burn lifecycle.
//   Non-MTRY recovery is an operational hygiene improvement, not a security issue.
//
// OPEN QUESTIONS:
//   Q1. PreMTRYClaim has recoverToken() but VestingManager does not. Should
//       VestingManager have a recoverToken() that blocks MTRY (forcing the burn
//       path for MTRY) but allows recovery of other accidental ERC-20 sends?
//   Q2. The burn path for accidentally-sent MTRY is destructive -- tokens are
//       permanently burned, not returned to treasury. Is this intentional, or should
//       there be a governance "sweep unallocated MTRY to treasury" path?
//   Q3. VestingManager is the largest token holder (111M MTRY at deploy). Documenting
//       the absence of recoverToken() in user-facing docs would reduce accidental sends.
// =============================================================================

contract POC12_NoTokenRecoveryVestingManager is TestSetup {
    MockToken18 randomToken;

    function setUp() public {
        _deployAllCorrectly();
        randomToken = new MockToken18();
    }

    // -------------------------------------------------------------------------
    // Non-MTRY tokens sent to VestingManager are permanently irrecoverable
    // -------------------------------------------------------------------------
    function test_nonMTRYTokensArePermanentlyLocked() public {
        uint256 accidentAmount = 50_000e18;

        // Accidentally send random ERC-20 to VestingManager
        randomToken.mint(address(vestingManager), accidentAmount);

        assertEq(
            randomToken.balanceOf(address(vestingManager)),
            accidentAmount,
            "random tokens trapped in VestingManager"
        );

        // QUESTION: There is no function to call to recover these tokens.
        // They are permanently stuck.
        // PreMTRYClaim.recoverToken() would work for this in that contract,
        // but VestingManager has no such function.
    }

    // -------------------------------------------------------------------------
    // Accidentally sent MTRY can ONLY be burned (7-day delay), not recovered
    // -------------------------------------------------------------------------
    function test_mtryAccidentallySentCanOnlyBeBurned() public {
        // The vestingManager already holds 111M MTRY from the constructor mint.
        // Simulate an extra 1M MTRY accidentally sent directly to vestingManager.
        // We do this by pranking as treasurySafe (which holds 75M) and transferring.
        uint256 extraAmount = 1_000_000e18;

        vm.prank(treasurySafe);
        mtry.transfer(address(vestingManager), extraAmount);

        uint256 balanceBefore = mtry.balanceOf(address(vestingManager));

        // The "unallocated balance" now includes this accidental 1M
        uint256 unallocated = vestingManager.getUnallocatedBalance();
        assertGe(unallocated, extraAmount, "extra MTRY included in unallocated balance");

        // The ONLY path to remove it is proposeBurn → executeBurn (7-day delay)
        vm.prank(deployer);
        vestingManager.proposeBurn(extraAmount); // proposes to BURN the accidental tokens

        assertEq(vestingManager.pendingBurnAmount(), extraAmount);

        // Cannot execute yet -- 7-day delay
        vm.expectRevert(BurnNotReady.selector);
        vm.prank(deployer);
        vestingManager.executeBurn();

        // After 7 days, tokens are BURNED (not recovered to treasury)
        vm.warp(block.timestamp + 7 days);
        vm.prank(deployer);
        vestingManager.executeBurn();

        uint256 balanceAfter = mtry.balanceOf(address(vestingManager));

        // QUESTION: The tokens were BURNED, not recovered to treasury.
        // Is this the intended behavior for mis-sent tokens?
        assertEq(balanceBefore - balanceAfter, extraAmount, "accidental MTRY burned, not recovered");
        assertGt(mtry.totalBurned(), 0, "total burned increased");
    }

    // -------------------------------------------------------------------------
    // Contrast: PreMTRYClaim has recoverToken() for non-MTRY tokens
    // -------------------------------------------------------------------------
    function test_preMTRYClaim_hasRecovery_vestingManager_doesNot() public {
        uint256 amount = 1_000e18;
        randomToken.mint(address(claim), amount);

        // PreMTRYClaim CAN recover the random token
        uint256 ownerBalanceBefore = randomToken.balanceOf(deployer);
        vm.prank(deployer);
        claim.recoverToken(IERC20(address(randomToken)), amount);
        assertEq(
            randomToken.balanceOf(deployer) - ownerBalanceBefore,
            amount,
            "PreMTRYClaim recovered random token"
        );

        // VestingManager has NO equivalent function
        // The following would be the call if it existed -- it doesn't.
        // vm.prank(deployer);
        // vestingManager.recoverToken(IERC20(address(randomToken)), amount);
        // QUESTION: Why does PreMTRYClaim have recoverToken but VestingManager does not?
    }
}
