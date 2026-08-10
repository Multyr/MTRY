// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {GlobalUnlockController} from "../src/GlobalUnlockController.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidUnlockCap,
    InvalidTimestamp,
    UnauthorizedSource,
    NotAuthorized,
    AlreadySet,
    CannotDeauthorizeVestingWallet
} from "../src/Errors.sol";

contract GlobalUnlockControllerTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    function test_constructorStoresParams() public view {
        assertEq(unlockController.token(), address(mtry));
        assertEq(unlockController.genesisTimestamp(), unlockGenesis);
        assertEq(unlockController.periodDuration(), PERIOD_DURATION);
        assertEq(unlockController.currentUnlockCapBps(), 200);
        assertEq(unlockController.pendingUnlockCapBps(), 200);
        assertEq(unlockController.referenceSupply(), 300_000_000e18);
    }

    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(ZeroAddress.selector);
        new GlobalUnlockController(address(0), deployer, block.timestamp, 30 days, 200, 300_000_000e18);
    }

    function test_constructorRevertsOnZeroPeriod() public {
        vm.expectRevert(ZeroAmount.selector);
        new GlobalUnlockController(address(mtry), deployer, block.timestamp, 0, 200, 300_000_000e18);
    }

    function test_constructorRevertsOnCapAboveMax() public {
        vm.expectRevert(InvalidUnlockCap.selector);
        new GlobalUnlockController(address(mtry), deployer, block.timestamp, 30 days, 2_001, 300_000_000e18);
    }

    function test_constructorRevertsOnCapZero() public {
        vm.expectRevert(InvalidUnlockCap.selector);
        new GlobalUnlockController(address(mtry), deployer, block.timestamp, 30 days, 0, 300_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Period math
    // -------------------------------------------------------------------------
    function test_currentPeriodAtGenesisIsZero() public view {
        assertEq(unlockController.currentPeriod(), 0);
    }

    function test_currentPeriodIncrementsWithTime() public {
        vm.warp(unlockGenesis + PERIOD_DURATION);
        assertEq(unlockController.currentPeriod(), 1);
        vm.warp(unlockGenesis + 3 * PERIOD_DURATION);
        assertEq(unlockController.currentPeriod(), 3);
    }

    function test_maxUnlockForPeriod() public view {
        // 300M * 200 / 10000 = 6M
        assertEq(unlockController.maxUnlockForPeriod(0), 6_000_000e18);
    }

    function test_rollPeriod_catchUpBoundedByMaxCatchupPeriods() public {
        // Warp 200 periods (> MAX_CATCHUP_PERIODS = 120)
        vm.warp(unlockGenesis + 200 * PERIOD_DURATION);

        uint256 gasBefore = gasleft();
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1e18);
        uint256 gasUsed = gasBefore - gasleft();

        // Must have initialized exactly MAX_CATCHUP_PERIODS, not all 200
        assertEq(unlockController.lastInitializedPeriod(), unlockController.MAX_CATCHUP_PERIODS());
        // 120 iterations × ~47k gas (3 SSTOREs + emit per period) ≈ 5.6M. Bound at 8M with margin.
        assertLt(gasUsed, 8_000_000, "catch-up loop consumed too much gas");
    }

    function test_rollPeriod_smallGapInitializesAll() public {
        vm.warp(unlockGenesis + 5 * PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1e18);
        assertEq(unlockController.lastInitializedPeriod(), 5);
    }

    // -------------------------------------------------------------------------
    // Clamp semantics
    // -------------------------------------------------------------------------
    function test_consumeAllowanceWithinCapGrantsFullAmount() public {
        // Use ecosystem as authorized source (setup authorizes it)
        vm.prank(address(ecosystem));
        uint256 granted = unlockController.consumeAllowance(1_000_000e18);
        assertEq(granted, 1_000_000e18);
        assertEq(unlockController.releasedInPeriod(0), 1_000_000e18);
    }

    function test_consumeAllowancePartialClamp() public {
        // Default protected quota is 50% → shared lane (ecosystem) capped at 6M - 3M = 3M.
        // Ecosystem asks 5M, clamp to 3M (shared remaining).
        vm.prank(address(ecosystem));
        uint256 granted1 = unlockController.consumeAllowance(5_000_000e18);
        assertEq(granted1, 3_000_000e18);

        // Further ecosystem request returns 0 (shared lane exhausted).
        vm.prank(address(ecosystem));
        uint256 granted2 = unlockController.consumeAllowance(2_000_000e18);
        assertEq(granted2, 0);
    }

    function test_consumeAllowanceReturnsZeroWhenExhausted() public {
        // Shared lane limit is 3M (with 50% protected quota). Asking 6M clamps to 3M.
        vm.prank(address(ecosystem));
        uint256 granted = unlockController.consumeAllowance(6_000_000e18);
        assertEq(granted, 3_000_000e18);

        // Shared lane exhausted — further requests return 0
        vm.prank(address(ecosystem));
        uint256 granted2 = unlockController.consumeAllowance(1e18);
        assertEq(granted2, 0);
    }

    function test_consumeAllowanceUnauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert(UnauthorizedSource.selector);
        unlockController.consumeAllowance(1e18);
    }

    function test_consumeAllowanceZeroAmountReverts() public {
        vm.prank(address(ecosystem));
        vm.expectRevert(ZeroAmount.selector);
        unlockController.consumeAllowance(0);
    }

    function test_remainingAllowance() public {
        assertEq(unlockController.remainingAllowance(), 6_000_000e18);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(2_000_000e18);
        assertEq(unlockController.remainingAllowance(), 4_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Cap changes only apply next period
    // -------------------------------------------------------------------------
    function test_setPendingCapDoesNotAffectCurrentPeriod() public {
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1_000_000e18);

        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(500); // 5%

        // Still current period; cap unchanged
        assertEq(unlockController.maxUnlockForPeriod(0), 6_000_000e18);
        assertEq(unlockController.remainingAllowance(), 5_000_000e18);
    }

    function test_setPendingCapAppliesNextPeriod() public {
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(500);

        vm.warp(unlockGenesis + PERIOD_DURATION);
        // Trigger rollover by consuming 1 wei
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);

        // Period 1 cap = 500 bps = 15M
        assertEq(unlockController.capBpsByPeriod(1), 500);
        assertEq(unlockController.maxUnlockForPeriod(1), 15_000_000e18);
    }

    function test_setPendingCapAboveMaxReverts() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setPendingUnlockCapBps(2_001);
    }

    // -------------------------------------------------------------------------
    // setReferenceSupply
    // -------------------------------------------------------------------------
    function test_setReferenceSupplyUpdates() public {
        vm.prank(deployer);
        unlockController.setReferenceSupply(100_000_000e18);
        assertEq(unlockController.referenceSupply(), 100_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Reference supply changes must not rewrite past or current period caps.
    // -------------------------------------------------------------------------
    function test_referenceSupplyChangeDoesNotAlterCurrentPeriodCap() public {
        uint256 capBefore = unlockController.maxUnlockForPeriod(0);

        vm.prank(deployer);
        unlockController.setReferenceSupply(100_000_000e18);

        // Period 0 cap unchanged (snapshot was 300M × 2% = 6M)
        assertEq(unlockController.maxUnlockForPeriod(0), capBefore);
        assertEq(unlockController.maxUnlockForPeriod(0), 6_000_000e18);
    }

    function test_referenceSupplyChangeAppliesNextPeriod() public {
        vm.prank(deployer);
        unlockController.setReferenceSupply(100_000_000e18);

        // Warp and trigger rollover
        vm.warp(unlockGenesis + PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);

        // Period 1 cap = 100M × 2% = 2M
        assertEq(unlockController.referenceSupplyByPeriod(1), 100_000_000e18);
        assertEq(unlockController.maxUnlockForPeriod(1), 2_000_000e18);

        // Period 0 snapshot still 300M × 2% = 6M
        assertEq(unlockController.referenceSupplyByPeriod(0), 300_000_000e18);
        assertEq(unlockController.maxUnlockForPeriod(0), 6_000_000e18);
    }

    function test_setReferenceSupplyZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAmount.selector);
        unlockController.setReferenceSupply(0);
    }

    // -------------------------------------------------------------------------
    // Authorization paths (strict separation)
    // -------------------------------------------------------------------------
    function test_setVestingManagerOneTimeOnly() public {
        // Already set in setup; calling again reverts
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        unlockController.setVestingManager(address(0x1234));
    }

    function test_addVestingSourceOnlyCallableByVestingManager() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        unlockController.addVestingSource(address(0x5678));
    }

    function test_setAuthorizedSourceOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        unlockController.setAuthorizedSource(alice, true);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------
    function test_pauseBlocksConsume() public {
        vm.prank(deployer);
        unlockController.pause();
        vm.prank(address(ecosystem));
        vm.expectRevert();
        unlockController.consumeAllowance(1e18);
    }

    function test_unpauseRestoresConsume() public {
        vm.prank(deployer);
        unlockController.pause();
        vm.prank(deployer);
        unlockController.unpause();
        vm.prank(address(ecosystem));
        uint256 granted = unlockController.consumeAllowance(1e18);
        assertEq(granted, 1e18);
    }

    // -- Coverage gap: pre-genesis returns 0 ----------------------------------

    function test_consumeAllowance_beforeGenesis_returnsZero() public {
        GlobalUnlockController future = new GlobalUnlockController(
            address(mtry), deployer,
            block.timestamp + 365 days,
            30 days, 200, 300_000_000e18
        );
        vm.prank(deployer);
        future.setAuthorizedSource(address(ecosystem), true);

        vm.prank(address(ecosystem));
        uint256 granted = future.consumeAllowance(1e18);
        assertEq(granted, 0, "should return 0 before genesis");
    }

    // -- Coverage gap: protected source throttled when cap exhausted ----------

    function test_protectedSource_throttledWhenCapFullyExhausted() public {
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(3_000_000e18);

        vm.prank(address(claim));
        unlockController.consumeAllowance(3_000_000e18);

        vm.prank(address(claim));
        uint256 granted = unlockController.consumeAllowance(1e18);
        assertEq(granted, 0, "protected source throttled at cap exhaustion");
    }

    // -- Coverage gap: remainingAllowanceForSource protected branch -----------

    function test_remainingAllowanceForSource_protectedSource() public {
        uint256 remaining = unlockController.remainingAllowanceForSource(address(claim));
        assertEq(remaining, 6_000_000e18);

        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1_000_000e18);
        remaining = unlockController.remainingAllowanceForSource(address(claim));
        assertEq(remaining, 5_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Constructor revert guard — referenceSupply == 0
    // -------------------------------------------------------------------------
    function test_constructorRevertsOnZeroReferenceSupply() public {
        vm.expectRevert(ZeroAmount.selector);
        new GlobalUnlockController(
            address(mtry), deployer, block.timestamp, 30 days, 200, 0
        );
    }

    // -------------------------------------------------------------------------
    // setAuthorizedSource — zero address guard
    // -------------------------------------------------------------------------
    function test_setAuthorizedSourceZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        unlockController.setAuthorizedSource(address(0), true);
    }

    // -------------------------------------------------------------------------
    // setProtectedSource — zero address guard
    // -------------------------------------------------------------------------
    function test_setProtectedSourceZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        unlockController.setProtectedSource(address(0), true);
    }

    // -------------------------------------------------------------------------
    // addVestingSource — zero address guard (called by vestingManager)
    // -------------------------------------------------------------------------
    function test_addVestingSourceZeroReverts() public {
        vm.prank(address(vestingManager));
        vm.expectRevert(ZeroAddress.selector);
        unlockController.addVestingSource(address(0));
    }

    // -------------------------------------------------------------------------
    // setVestingManager — zero-address guard (second guard after AlreadySet)
    // -------------------------------------------------------------------------
    function test_setVestingManagerZeroReverts() public {
        // Deploy a fresh controller with no vestingManager set yet
        GlobalUnlockController fresh = new GlobalUnlockController(
            address(mtry),
            deployer,
            block.timestamp,
            30 days,
            200,
            300_000_000e18
        );
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(deployer);
        fresh.setVestingManager(address(0));
    }

    // -------------------------------------------------------------------------
    // Coverage gap: currentPeriod() before genesis → return 0
    // -------------------------------------------------------------------------
    function test_currentPeriod_beforeGenesis_returns0() public {
        GlobalUnlockController future = new GlobalUnlockController(
            address(mtry), deployer,
            block.timestamp + 365 days,
            30 days, 200, 300_000_000e18
        );
        assertEq(future.currentPeriod(), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: remainingAllowance() when fully exhausted → return 0
    // -------------------------------------------------------------------------
    function test_remainingAllowance_fullyExhausted_returns0() public {
        // Exhaust shared lane (3M) + protected lane (3M) = full 6M cap.
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(3_000_000e18);
        vm.prank(address(claim));
        unlockController.consumeAllowance(3_000_000e18);

        // used = releasedInPeriod + _protectedUsedTotalByPeriod = 3M + 3M = 6M = cap
        assertEq(unlockController.remainingAllowance(), 0);
    }

    // -------------------------------------------------------------------------
    // M-2: setReferenceSupply upper bound + cancelPendingReferenceSupply
    // -------------------------------------------------------------------------

    function test_setReferenceSupply_exceedsInitialReverts() public {
        uint256 initial = unlockController.initialReferenceSupply();
        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setReferenceSupply(initial + 1);
    }

    function test_setReferenceSupply_equalToInitialSucceeds() public {
        uint256 initial = unlockController.initialReferenceSupply();
        vm.prank(deployer);
        unlockController.setReferenceSupply(initial);
        assertEq(unlockController.referenceSupply(), initial);
    }

    function test_cancelPendingReferenceSupply_restoresLastSnapshot() public {
        // Warp to period 1 so lastInitializedPeriod > 0 and a snapshot exists.
        vm.warp(unlockGenesis + PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);  // triggers period 1 rollover

        uint256 before = unlockController.referenceSupply();

        // Reduce reference supply (simulating a governance action).
        vm.prank(deployer);
        unlockController.setReferenceSupply(150_000_000e18);
        assertEq(unlockController.referenceSupply(), 150_000_000e18);

        // Veto cancels — restores to period-1 snapshot (which equals the initial value).
        vm.prank(safeVeto);
        unlockController.cancelPendingReferenceSupply();
        assertEq(unlockController.referenceSupply(), before);
    }

    // -------------------------------------------------------------------------
    // M-3: setAuthorizedSource cannot deauthorize vesting wallets
    // -------------------------------------------------------------------------

    function test_setAuthorizedSource_cannotDeauthorizeVestingWallet() public {
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000e18,
            0,
            365 days,
            false
        );

        // `w` was registered via addVestingSource — deauthorizing it must revert.
        vm.prank(deployer);
        vm.expectRevert(CannotDeauthorizeVestingWallet.selector);
        unlockController.setAuthorizedSource(w, false);

        // Authorizing again (already true) is fine.
        vm.prank(deployer);
        unlockController.setAuthorizedSource(w, true);
        assertTrue(unlockController.authorizedSource(w));
    }

    function test_setAuthorizedSource_canDeauthorizeNonVestingSource() public {
        // A non-vesting source (e.g. ecosystem) can be deauthorized.
        vm.prank(deployer);
        unlockController.setAuthorizedSource(address(ecosystem), false);
        assertFalse(unlockController.authorizedSource(address(ecosystem)));
    }

    // -------------------------------------------------------------------------
    // M-4: protectedQuotaBps is next-period-delayed; cancelPendingProtectedQuotaBps
    // -------------------------------------------------------------------------

    function test_pendingProtectedQuota_appliesNextPeriod() public {
        uint256 defaultQuota = unlockController.protectedQuotaBps();

        // Change pending quota (within [MIN_PROTECTED_QUOTA_BPS, 7500]) — must not affect current period.
        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(3_000);
        assertEq(unlockController.protectedQuotaBps(), defaultQuota, "quota must not change this period");
        assertEq(unlockController.pendingProtectedQuotaBps(), 3_000);

        // Advance to next period — pending value gets promoted.
        vm.warp(unlockGenesis + PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);  // triggers rollover
        assertEq(unlockController.protectedQuotaBps(), 3_000, "quota must be promoted to 3000");
    }

    function test_cancelPendingProtectedQuotaBps_revertsToActive() public {
        uint256 active = unlockController.protectedQuotaBps();

        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(2_500);  // minimum floor
        assertEq(unlockController.pendingProtectedQuotaBps(), 2_500);

        // Veto cancels — pending reverts to current active value.
        vm.prank(safeVeto);
        unlockController.cancelPendingProtectedQuotaBps();
        assertEq(unlockController.pendingProtectedQuotaBps(), active);

        // After advancing to next period, nothing changes.
        vm.warp(unlockGenesis + PERIOD_DURATION);
        vm.prank(address(ecosystem));
        unlockController.consumeAllowance(1);
        assertEq(unlockController.protectedQuotaBps(), active, "cancelled value must not be promoted");
    }

    // -------------------------------------------------------------------------
    // M-4: MIN_PROTECTED_QUOTA_BPS floor enforcement
    // -------------------------------------------------------------------------

    function test_setPendingProtectedQuota_belowFloorReverts() public {
        uint256 floor = unlockController.MIN_PROTECTED_QUOTA_BPS();

        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setPendingProtectedQuotaBps(floor - 1);

        vm.prank(deployer);
        vm.expectRevert(InvalidUnlockCap.selector);
        unlockController.setPendingProtectedQuotaBps(0);
    }

    function test_setPendingProtectedQuota_atFloorSucceeds() public {
        uint256 floor = unlockController.MIN_PROTECTED_QUOTA_BPS();
        vm.prank(deployer);
        unlockController.setPendingProtectedQuotaBps(floor);
        assertEq(unlockController.pendingProtectedQuotaBps(), floor);
    }

    // -------------------------------------------------------------------------
    // M-5: Constructor rejects genesis unreasonably far in the future
    // -------------------------------------------------------------------------

    function test_constructor_rejectsGenesisInFarFuture() public {
        vm.expectRevert(InvalidTimestamp.selector);
        new GlobalUnlockController(
            address(mtry), deployer,
            block.timestamp + 3651 days,  // just past the 3650-day ceiling
            30 days, 200, 300_000_000e18
        );
    }

    function test_constructor_acceptsGenesisTenYearsOut() public {
        // Exactly at the boundary is valid.
        new GlobalUnlockController(
            address(mtry), deployer,
            block.timestamp + 3650 days,
            30 days, 200, 300_000_000e18
        );
    }

    // -------------------------------------------------------------------------
    // KL-2 / MULTYR-2 (NEW-02): >120-period dormancy + staged cap change used to violate
    // releasedInPeriod[P] <= maxUnlockForPeriod(P) for the boundary period, because
    // consumeAllowance() read the not-yet-promoted `currentUnlockCapBps` for any
    // period beyond the physical MAX_CATCHUP_PERIODS catch-up horizon.
    //
    // FIXED as part of the MULTYR-2 fix: consumeAllowance() computes its cap via the
    // public maxUnlockForPeriod(), which now projects the cap a period WOULD get
    // once fully caught up (via `_projectedCapBps`) instead of falling back to the
    // stale pre-rollover scalar. Because the enforcement path and the preview path
    // share that same projection, the first consumeAllowance() after a long gap
    // already enforces the correct (fully-caught-up) cap, and the invariant
    // releasedInPeriod[P] <= maxUnlockForPeriod(P) now holds even across a >120
    // period catch-up boundary. See also test/poc/POC07_StaleCapLargeGap.t.sol.
    // -------------------------------------------------------------------------

    function test_catchupBoundary_projectedCapPreventsOverRelease() public {
        // Reproduces the former KL-2 / NEW-02 scenario, now fixed by MULTYR-2 (projected cap
        // views) and further hardened by I-3 (pending-value setters roll first):
        //   1. Governance halves the cap at period 122 (commit period = 122). Since I-3,
        //      the setter itself rolls first -- lastInitializedPeriod is 0 at that point
        //      (dormant since deploy), so this single call already physically catches up
        //      periods 1-120 (MAX_CATCHUP_PERIODS) before committing the new pending value.
        //   2. Protocol dormant through period 125 (no consumeAllowance).
        //   3. First consume at period 125 finishes the remaining catch-up (121-125, only
        //      5 periods -- well within the 120 bound) in one call. maxUnlockForPeriod(125)
        //      already projected the due 100 bps cap (commit period 122 < 125) even before
        //      this call, so claim (protected source) is clamped to the correct 3M cap.
        //   4. A second consume at period 125 is a no-op catch-up (already fully rolled)
        //      and confirms totalReleasedInPeriod(125) never exceeds maxUnlockForPeriod(125).

        // Step 1: commit a halved cap at period 122.
        vm.warp(unlockGenesis + 122 * PERIOD_DURATION);
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(100);  // 200 → 100 bps

        assertEq(
            unlockController.lastInitializedPeriod(), 120,
            "I-3: the setter itself proactively rolls up to MAX_CATCHUP_PERIODS before committing"
        );

        // Step 2: advance to period 125 without any consume call.
        vm.warp(unlockGenesis + 125 * PERIOD_DURATION);

        // Step 3: first consume by claim (protected source — accesses full remaining cap).
        // Only periods 121-125 remain to physically roll (well within MAX_CATCHUP_PERIODS),
        // so this single call finishes the catch-up. maxUnlockForPeriod(125) projects the
        // due 100 bps cap regardless of physical rollup progress: 300M * 100bps / 10000 = 3M.
        // The 10M request is clamped to that correct cap immediately.
        vm.prank(address(claim));
        uint256 granted1 = unlockController.consumeAllowance(10_000_000e18);

        assertEq(unlockController.lastInitializedPeriod(), 125, "remaining 121-125 catch-up finished in one call");
        assertEq(granted1, 3_000_000e18, "first grant already uses the projected 100 bps cap");

        uint256 period = unlockController.currentPeriod();  // 125

        // Step 4: second consume is a no-op catch-up (already fully rolled); confirms the
        // invariant holds and repeated calls remain safe.
        vm.prank(address(claim));
        unlockController.consumeAllowance(1);  // grants 0; cap already exhausted

        assertEq(unlockController.lastInitializedPeriod(), 125);

        uint256 cap125       = unlockController.maxUnlockForPeriod(period);
        uint256 totalUsed125 = unlockController.totalReleasedInPeriod(period);

        assertEq(cap125, 3_000_000e18, "period 125 cap is the new 100 bps value");
        assertEq(totalUsed125, 3_000_000e18, "only the correct 3M was ever released");

        // The invariant totalReleasedInPeriod[p] <= maxUnlockForPeriod(p) now holds.
        assertLe(totalUsed125, cap125, "MULTYR-2 fix: total released never exceeds the true cap");
    }
}
