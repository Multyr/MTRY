// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";

// =============================================================================
// POC-01: Late Lock → Retroactive Vesting Credit
// =============================================================================
//
// STATUS: FIXED
//
// OLD BEHAVIOR (two stages):
//   1. lockPreTokens() originally had no deadline guard at all. Vesting is anchored
//      to the global TGE timestamp, not the lock timestamp. A holder could wait until
//      after TGE+cliff+vesting (720 days) and then lock, burning their preMTRY to
//      receive 100% of the 4x MTRY entitlement instantly in a single transaction.
//   2. A first fix bounded the lock window at `fullVestingEnd()`. That closed the
//      100%-instant case but still let a holder lock any time DURING the live vesting
//      window (i.e. after the 180-day cliff) and immediately receive retroactive
//      credit for the cliff + elapsed-vesting time they never waited through. Audit
//      finding MULTYR-5 showed this let a late locker instantly claim a near-full
//      entitlement and monopolize the shared per-period release cap via the
//      protected-source lane in GlobalUnlockController.
//
// ROOT CAUSE:
//   The lock deadline was anchored to `fullVestingEnd()` (cliff + full vesting
//   duration) instead of the cliff boundary, so any lock accepted after the cliff
//   started inherited vesting progress the locker never accrued.
//
// FIX APPLIED (src/PreMTRYClaim.sol, lockPreTokens):
//   The lock window now closes at the cliff boundary, not at fullVestingEnd():
//     if (tgeTimestamp != 0 && block.timestamp >= tgeTimestamp + CLIFF_DURATION) {
//         revert LockDeadlineExpired();
//     }
//   Because `_vestedAmount()` returns 0 for any timestamp before `vestingStart`
//   (== tgeTimestamp + CLIFF_DURATION), a lock accepted under the new guard can
//   never be worth more than 0 the instant it lands — there is no window left in
//   which a lock can carry retroactive vesting credit. The guard only activates
//   once TGE is set, so pre-TGE locking during/after the sale is unaffected.
// =============================================================================

contract POC01_LateLockRetroactiveVesting is TestSetup {
    uint256 constant CLIFF = 180 days;
    uint256 constant VESTING = 540 days;
    uint256 constant PRE_AMOUNT = 100_000e18; // 100k preMTRY
    uint256 constant USDC_SPEND = 8_000e6;   // 8 000 USDC → 100 000 preMTRY at $0.08

    function setUp() public {
        _deployAllCorrectly();
        // TGE = now (genesis). Claim pool already funded (40M MTRY from constructor).
        vm.startPrank(deployer);
        claim.setTGE(block.timestamp);
        vestingManager.setTGE(block.timestamp);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Scenario A [FIXED]: lock at/after cliff end now reverts — no more retroactive
    //   credit for time the holder never waited through.
    // -------------------------------------------------------------------------
    function test_lockAfterCliff_reverts() public {
        uint256 tge = claim.tgeTimestamp();

        // Alice buys 100k preMTRY during the sale window
        vm.warp(saleStart);
        _fundAlice(USDC_SPEND);
        vm.prank(alice);
        sale.buy(USDC_SPEND, alice);

        // Warp to 1 day PAST cliff end -- without locking
        vm.warp(tge + CLIFF + 1 days);

        // Lock now rejected: the window closes at the cliff boundary.
        vm.startPrank(alice);
        preMTRY.approve(address(claim), PRE_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(PRE_AMOUNT);
        vm.stopPrank();

        assertEq(preMTRY.balanceOf(alice), PRE_AMOUNT, "preMTRY not burned -- lock rejected");
        assertEq(claim.totalEntitledMTRY(alice), 0, "no entitlement created");
    }

    // -------------------------------------------------------------------------
    // Scenario A2 [FIXED]: locking right up to the cliff boundary is still allowed,
    //   but is worth exactly 0 the instant it lands -- no retroactive credit at all.
    // -------------------------------------------------------------------------
    function test_lockJustBeforeCliff_grantsNoInstantVesting() public {
        uint256 tge = claim.tgeTimestamp();

        vm.warp(saleStart);
        _fundAlice(USDC_SPEND);
        vm.prank(alice);
        sale.buy(USDC_SPEND, alice);

        // Warp to 1 second before the cliff boundary -- last moment locking is allowed.
        vm.warp(tge + CLIFF - 1);

        vm.startPrank(alice);
        preMTRY.approve(address(claim), PRE_AMOUNT);
        claim.lockPreTokens(PRE_AMOUNT);
        vm.stopPrank();

        assertEq(claim.totalEntitledMTRY(alice), PRE_AMOUNT * claim.CONVERSION_RATIO());
        assertEq(claim.claimable(alice), 0, "no instant vesting credit at lock time");

        // Crossing into the vesting window still starts from zero, not retroactively.
        vm.warp(tge + CLIFF);
        assertEq(claim.claimable(alice), 0, "still zero exactly at vesting start");
    }

    // -------------------------------------------------------------------------
    // Scenario B [FIXED]: lock after fullVestingEnd() (and now: after the cliff at all)
    //   reverts LockDeadlineExpired.
    //   Previously (pre-fix): 100% of entitled MTRY claimable instantly in one transaction.
    //   Now: the lock is rejected; preMTRY is NOT burned; entitlement is NOT created.
    // -------------------------------------------------------------------------
    function test_lockAfterFullVesting_reverts() public {
        uint256 tge = claim.tgeTimestamp();

        // Alice buys during sale, holds preMTRY for 720+ days without locking
        vm.warp(saleStart);
        _fundAlice(USDC_SPEND);
        vm.prank(alice);
        sale.buy(USDC_SPEND, alice);

        // Warp to TGE + full vesting period + 1 day
        vm.warp(tge + CLIFF + VESTING + 1 days);

        vm.startPrank(alice);
        preMTRY.approve(address(claim), PRE_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(PRE_AMOUNT);
        vm.stopPrank();

        // Confirm alice still holds her preMTRY (not burned)
        assertEq(preMTRY.balanceOf(alice), PRE_AMOUNT, "preMTRY not burned -- lock rejected");
        assertEq(claim.totalEntitledMTRY(alice), 0, "no entitlement created");
    }

    // -------------------------------------------------------------------------
    // Scenario C [FIXED]: a holder can no longer lock late within the vesting window
    //   at all, so there is no "later locker is never worse" case left to exploit --
    //   locking must happen before the cliff, and every accepted lock starts vesting
    //   from zero.
    // -------------------------------------------------------------------------
    function test_lockAfterCliff_rejectedForAllLateLockers() public {
        uint256 tge = claim.tgeTimestamp();

        vm.warp(saleStart);
        _fundAlice(USDC_SPEND);
        _fundBob(USDC_SPEND);
        vm.prank(alice);
        sale.buy(USDC_SPEND, alice);
        vm.prank(bob);
        sale.buy(USDC_SPEND, bob);

        // Alice locks on day 1 of sale (before TGE, no cliff elapsed) -- allowed.
        vm.startPrank(alice);
        preMTRY.approve(address(claim), PRE_AMOUNT);
        claim.lockPreTokens(PRE_AMOUNT);
        vm.stopPrank();

        // Bob WAITS until 200 days post-TGE (past the cliff) then tries to lock.
        vm.warp(tge + 200 days);
        vm.startPrank(bob);
        preMTRY.approve(address(claim), PRE_AMOUNT);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(PRE_AMOUNT);
        vm.stopPrank();

        assertEq(claim.totalEntitledMTRY(bob), 0, "bob's late lock is rejected outright");
        assertGt(claim.claimable(alice), 0, "alice, who locked on time, vests normally");
    }
}
