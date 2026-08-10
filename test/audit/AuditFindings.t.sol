// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";

// =============================================================================
// Audit finding MULTYR-5 (Medium; informally tracked as M-1 pre-response):
// Global TGE vesting in PreMTRYClaim let late lockers immediately vest and
// exhaust the shared release cap.
//
// STATUS: FIXED
//
// lockPreTokens() now closes its lock window at the cliff boundary
// (tgeTimestamp + CLIFF_DURATION) instead of fullVestingEnd(). Since
// _vestedAmount() is 0 for any timestamp before vestingStart (== the cliff
// boundary), a lock accepted under the new guard can never carry retroactive
// vesting credit -- so it can no longer be used to instantly drain the
// GlobalUnlockController's shared per-period cap via the protected-source lane.
//
// See src/PreMTRYClaim.sol:lockPreTokens and test/poc/POC01_LateLockRetroactiveVesting.t.sol
// for the underlying mechanism and the original open/fixed staged history.
// =============================================================================
contract AuditFindings is TestSetup {
    uint256 constant CLIFF = 180 days;
    uint256 constant VESTING = 540 days;

    // Full sale (800_000 USDC hard cap @ 0.08 USDC/preMTRY) mints the entire
    // 10M preMTRY supply, which converts 1:4 into the full 40M MTRY claim pool.
    uint256 constant FULL_SALE_USDC = 800_000e6;
    uint256 constant FULL_PRE_SUPPLY = 10_000_000e18;
    uint256 constant FULL_ENTITLEMENT = 40_000_000e18;

    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // test_MULTYR5_LateLockDrainsCapAndBlocksSharedVesting
    //
    // Reproduces the report's attack path: Alice buys the full preMTRY sale
    // allocation, TGE is set, and she waits until just before the vesting
    // schedule would have ended before locking. Pre-fix, this lock would have
    // succeeded and granted near-100% instant entitlement, letting her drain
    // the shared unlock cap and throttle a legitimate vesting wallet claim.
    // Post-fix, the lock is rejected outright at the cliff boundary, so no
    // entitlement is ever created and the shared cap is untouched.
    // -------------------------------------------------------------------------
    function test_MULTYR5_LateLockDrainsCapAndBlocksSharedVesting() public {
        vm.warp(saleStart);
        _fundAlice(FULL_SALE_USDC);
        vm.prank(alice);
        sale.buy(FULL_SALE_USDC, alice);

        _setTGE(block.timestamp);

        VestingWalletLinear victimWallet = VestingWalletLinear(
            _createGrantVesting(VestingManager.BucketType.Team, teamBeneficiary, 10_000_000e18, 0, 1 days, false)
        );

        // Warp to just before the old fullVestingEnd() deadline -- deep inside what
        // used to be a valid (if late) lock window.
        vm.warp(claim.fullVestingEnd() - 1);

        vm.startPrank(alice);
        preMTRY.approve(address(claim), FULL_PRE_SUPPLY);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(FULL_PRE_SUPPLY);
        vm.stopPrank();

        // No entitlement was created, so alice has nothing to claim and the shared
        // cap remains fully available to other beneficiaries.
        assertEq(claim.totalEntitledMTRY(alice), 0, "late lock rejected -- no entitlement");
        assertEq(preMTRY.balanceOf(alice), FULL_PRE_SUPPLY, "preMTRY not burned");

        uint256 period = unlockController.currentPeriod();
        assertEq(unlockController.totalReleasedInPeriod(period), 0, "shared cap untouched");

        // The victim wallet can still claim its full releasable amount unthrottled.
        vm.prank(teamBeneficiary, teamBeneficiary);
        victimWallet.claim();
        assertGt(mtry.balanceOf(teamBeneficiary), 0, "vesting wallet claim succeeds normally");
    }

    // -------------------------------------------------------------------------
    // test_MULTYR5_LateWhaleBlocksAnotherClaimHolder
    //
    // Reproduces the report's second scenario: a large holder (Alice) and a
    // smaller holder (Bob) both try to lock late, after the cliff has passed.
    // Pre-fix, whoever claimed first could monopolize the protected-source
    // reserve and throttle the other's claim. Post-fix, late locks are
    // rejected for both holders equally -- neither can create an entitlement,
    // so neither can touch the cap at all.
    // -------------------------------------------------------------------------
    function test_MULTYR5_LateWhaleBlocksAnotherClaimHolder() public {
        vm.warp(saleStart);
        _fundAlice(FULL_SALE_USDC);
        vm.prank(alice);
        sale.buy(FULL_SALE_USDC, alice);

        _setTGE(block.timestamp);

        uint256 bobPre = 1_000_000e18;
        uint256 alicePre = FULL_PRE_SUPPLY - bobPre;
        vm.prank(alice);
        assertTrue(preMTRY.transfer(bob, bobPre));

        // Warp to just before the old fullVestingEnd() deadline, well past the cliff.
        vm.warp(claim.fullVestingEnd() - 1);

        vm.startPrank(alice);
        preMTRY.approve(address(claim), alicePre);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(alicePre);
        vm.stopPrank();

        vm.startPrank(bob);
        preMTRY.approve(address(claim), bobPre);
        vm.expectRevert(abi.encodeWithSignature("LockDeadlineExpired()"));
        claim.lockPreTokens(bobPre);
        vm.stopPrank();

        assertEq(claim.totalEntitledMTRY(alice), 0);
        assertEq(claim.totalEntitledMTRY(bob), 0);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        assertEq(cap, 6_000_000e18);
        assertEq(unlockController.remainingAllowanceForSource(address(claim)), cap, "protected lane untouched");
    }

    // -------------------------------------------------------------------------
    // test_MULTYR5_OnTimeLockerStillReceivesFullEntitlementOverSchedule
    //
    // Regression check: legitimate pre-cliff locking is unaffected by the fix.
    // A holder who locks before the cliff still receives the full 1:4
    // entitlement, vested linearly over the normal cliff + vesting schedule.
    // -------------------------------------------------------------------------
    function test_MULTYR5_OnTimeLockerStillReceivesFullEntitlementOverSchedule() public {
        vm.warp(saleStart);
        _fundAlice(FULL_SALE_USDC);
        vm.prank(alice);
        sale.buy(FULL_SALE_USDC, alice);

        _setTGE(block.timestamp);
        uint256 tge = claim.tgeTimestamp();

        vm.startPrank(alice);
        preMTRY.approve(address(claim), FULL_PRE_SUPPLY);
        claim.lockPreTokens(FULL_PRE_SUPPLY);
        vm.stopPrank();

        assertEq(claim.totalEntitledMTRY(alice), FULL_ENTITLEMENT);
        assertEq(claim.claimable(alice), 0, "nothing claimable before cliff");

        vm.warp(tge + CLIFF + VESTING);
        assertEq(claim.claimable(alice), FULL_ENTITLEMENT, "fully vested at end of schedule");
    }
}
