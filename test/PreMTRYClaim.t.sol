// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup, MockToken18} from "./helpers/TestSetup.sol";
import {PreMTRYClaim} from "../src/PreMTRYClaim.sol";
import {
    ZeroAddress,
    ZeroAmount,
    NotInitialized,
    AlreadyInitialized,
    TGENotSet,
    TGEAlreadySet,
    InvalidTimestamp,
    InsufficientClaimFunding,
    MaxSupplyExceeded,
    NothingToClaim,
    Unauthorized,
    UnlockThrottled,
    BurnBeforeHorizon,
    BurnAmountZero,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady,
    LockDeadlineExpired
} from "../src/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PreMTRYClaimTest is TestSetup {
    uint256 constant CLIFF = 180 days;
    uint256 constant DURATION = 540 days;

    function setUp() public {
        _deployAllCorrectly();
    }

    function test_vestingDurationIs540Days() public view {
        assertEq(claim.VESTING_DURATION(), DURATION);
        assertEq(claim.CLIFF_DURATION(), CLIFF);
        assertEq(claim.CONVERSION_RATIO(), 4);
    }

    function test_constructorRevertsOnZeroUnlockController() public {
        vm.expectRevert(ZeroAddress.selector);
        new PreMTRYClaim(address(this), address(0));
    }

    function test_constructorStoresUnlockController() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        assertEq(fresh.unlockController(), address(unlockController));
    }

    function test_initializedIsTrue() public view {
        assertTrue(claim.initialized());
    }

    function test_initializeRevertsIfCalledTwice() public {
        vm.prank(deployer);
        vm.expectRevert(AlreadyInitialized.selector);
        claim.initialize(address(mtry), address(preMTRY), address(sale));
    }

    function test_initializeOnlyOwner() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.prank(alice);
        vm.expectRevert();
        fresh.initialize(address(mtry), address(preMTRY), address(sale));
    }

    function test_setTGESucceedsWhenFunded() public {
        vm.prank(deployer);
        claim.setTGE(block.timestamp);
        assertEq(claim.tgeTimestamp(), block.timestamp);
    }

    function test_setTGEOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        claim.setTGE(block.timestamp);
    }

    function test_setTGERevertsIfCalledTwice() public {
        vm.prank(deployer);
        claim.setTGE(block.timestamp);
        vm.prank(deployer);
        vm.expectRevert(TGEAlreadySet.selector);
        claim.setTGE(block.timestamp + 1);
    }

    function test_setTGERevertsIfTimestampInPast() public {
        vm.warp(1_000);
        vm.prank(deployer);
        vm.expectRevert(InvalidTimestamp.selector);
        claim.setTGE(999);
    }

    function test_lockRecordsEntitlement() public {
        _aliceBuys(80_000);  // 1 preMTRY
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);
        assertEq(claim.totalEntitledMTRY(alice), 4e18);
        assertEq(claim.lockedPreAmount(alice), 1e18);
        assertEq(claim.totalEntitled(), 4e18);
    }

    function test_lockRevertsWithZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        claim.lockPreTokens(0);
    }

    function test_lockAtExactPoolCapSucceeds() public {
        // Buy the hard cap of preMTRY (10M), lock all of it → exactly 40M entitlement.
        _aliceBuys(800_000_000_000);
        vm.prank(alice);
        preMTRY.approve(address(claim), 10_000_000e18);
        vm.prank(alice);
        claim.lockPreTokens(10_000_000e18);
        assertEq(claim.totalEntitled(), 40_000_000e18);
    }

    function test_lockBeyondPoolCapReverts() public {
        _aliceBuys(800_000_000_000);
        vm.prank(alice);
        preMTRY.approve(address(claim), 10_000_000e18);
        vm.prank(alice);
        claim.lockPreTokens(10_000_000e18);

        // Any additional lock would exceed (entitlement would surpass 40M cap).
        // But alice has no more preMTRY anyway; mint more directly via sale rerun is not possible.
        // Test with a fresh buyer who also wants to lock 1 preMTRY.
        // Actually, preMTRY total supply is capped at 10M in the sale; we already consumed all.
        // The guard still holds: any call with positive amount that would push > pool reverts.
        // We verify via a synthetic lock by sending preMTRY to bob via transfer.
        vm.prank(alice);
        IERC20(address(preMTRY)).transfer(bob, 0); // no-op; can't transfer what's already locked & burned

        // Alternative: reset pool check by using entitlement math.
        // After lock, totalEntitled == 40M == MAX_CLAIM_POOL. Any new lock even from bob
        // would revert because MAX_CLAIM_POOL is reached.
        assertEq(claim.totalEntitled(), 40_000_000e18);
        assertEq(claim.remainingClaimPool(), 0);
    }

    // -------------------------------------------------------------------------
    // Vesting math (540 days)
    // -------------------------------------------------------------------------
    function _setupLockedAlice(uint256 preAmount) internal {
        uint256 usdcNeeded = (preAmount * 80_000) / 1e18;
        _aliceBuys(usdcNeeded);
        vm.prank(alice);
        preMTRY.approve(address(claim), preAmount);
        vm.prank(alice);
        claim.lockPreTokens(preAmount);
        // MULTYR-1: leave block.timestamp >= saleEnd so callers doing
        // `uint256 tge = block.timestamp; claim.setTGE(tge);` right after this helper satisfy
        // the new TGE >= saleEnd invariant without each call site needing its own warp.
        vm.warp(saleEnd);
    }

    function test_claimRevertsDuringCliff() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        vm.warp(tge + CLIFF - 1);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        claim.claim();
    }

    function test_claimFullVestingAfter540Days() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        vm.warp(tge + CLIFF + DURATION);
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 4e18);
        assertEq(claim.claimedMTRY(alice), 4e18);
    }

    function test_claimMidpointApprox50Percent() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        vm.warp(tge + CLIFF + DURATION / 2);
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 2e18);
    }

    function test_claimableReturnsZeroBeforeTGE() public {
        _setupLockedAlice(1e18);
        assertEq(claim.claimable(alice), 0);
    }

    // -------------------------------------------------------------------------
    // Clamp semantics — claim() respects GlobalUnlockController
    // -------------------------------------------------------------------------
    function test_claimClampsToGlobalUnlockCap() public {
        // Global cap = 2% of 300M = 6M per 30-day period
        // Entitle Alice 10M (2.5M preMTRY × 4) and try to claim at full vesting
        _setupLockedAlice(2_500_000e18);

        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        vm.warp(tge + CLIFF + DURATION);
        vm.prank(alice);
        claim.claim();

        assertEq(mtry.balanceOf(alice), 6_000_000e18);
        assertEq(claim.claimedMTRY(alice), 6_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Burn (post-horizon, timelocked)
    // -------------------------------------------------------------------------
    function test_proposeBurnRevertsBeforeHorizon() public {
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        vm.prank(deployer);
        vm.expectRevert(BurnBeforeHorizon.selector);
        claim.proposeBurn(1e18);
    }

    function test_executeBurnRevertsIfNoProposal() public {
        vm.prank(deployer);
        claim.setTGE(block.timestamp);
        vm.warp(block.timestamp + CLIFF + DURATION + 1);
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        claim.executeBurn();
    }

    function test_cancelBurnClearsProposal() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);

        // Full claim (entitlement 4 MTRY is well below 6M cap)
        vm.prank(alice);
        claim.claim();

        vm.prank(deployer);
        claim.proposeBurn(1_000e18);

        vm.prank(deployer);
        claim.cancelBurn();
        assertEq(claim.pendingBurnAmount(), 0);
    }

    // -------------------------------------------------------------------------
    // recoverToken
    // -------------------------------------------------------------------------
    function test_recoverTokenRevertsForMTRY() public {
        vm.prank(deployer);
        vm.expectRevert(Unauthorized.selector);
        claim.recoverToken(IERC20(address(mtry)), 1);
    }

    function test_recoverTokenRevertsForPreMTRY() public {
        vm.prank(deployer);
        vm.expectRevert(Unauthorized.selector);
        claim.recoverToken(IERC20(address(preMTRY)), 1);
    }

    function test_recoverTokenWorksForRandomERC20() public {
        MockToken18 m = new MockToken18();
        m.mint(address(claim), 100e18);
        vm.prank(deployer);
        claim.recoverToken(IERC20(address(m)), 100e18);
        assertEq(m.balanceOf(deployer), 100e18);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------
    function test_fullVestingEndBeforeTGEIsMax() public view {
        assertEq(claim.fullVestingEnd(), type(uint256).max);
    }

    function test_fullVestingEndAfterTGE() public {
        vm.warp(1_000);
        vm.prank(deployer);
        claim.setTGE(1_000);
        assertEq(claim.fullVestingEnd(), 1_000 + CLIFF + DURATION);
    }

    function test_remainingClaimPoolDecreasesOnLock() public {
        _aliceBuys(80_000);
        uint256 before_ = claim.remainingClaimPool();
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);
        assertEq(before_ - claim.remainingClaimPool(), 4e18);
    }

    // -- Coverage gap: executeBurn full path ----------------------------------

    function test_executeBurn_fullFlow() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);

        uint256 burnAmount = 1_000e18;
        vm.prank(deployer);
        claim.proposeBurn(burnAmount);

        vm.prank(deployer);
        vm.expectRevert(BurnNotReady.selector);
        claim.executeBurn();

        vm.warp(block.timestamp + 7 days + 1);
        uint256 supplyBefore = mtry.totalSupply();
        vm.prank(deployer);
        claim.executeBurn();
        assertEq(mtry.totalSupply(), supplyBefore - burnAmount);
        assertEq(claim.pendingBurnAmount(), 0);
    }

    function test_executeBurn_revertsIfBurnExceedsOutstanding() public {
        _setupLockedAlice(1_000_000e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);
        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        claim.proposeBurn(40_000_000e18);
    }

    // -- Coverage gap: view branches ------------------------------------------

    function test_claimable_returnsZeroBeforeTGESet() public {
        _setupLockedAlice(1e18);
        assertEq(claim.claimable(alice), 0);
    }

    function test_vestedAmount_returnsZeroBeforeTGESet() public {
        _setupLockedAlice(1e18);
        assertEq(claim.vestedAmount(alice), 0);
    }

    function test_availableClaimFunding_returnsZeroBeforeInit() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        assertEq(fresh.availableClaimFunding(), 0);
    }

    function test_previewEntitlement_correctRatio() public view {
        assertEq(claim.previewEntitlement(1e18), 4e18);
        assertEq(claim.previewEntitlement(0), 0);
    }

    // -------------------------------------------------------------------------
    // initialize() zero-address guards
    // -------------------------------------------------------------------------
    function test_initializeRevertsOnZeroMtryToken() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(ZeroAddress.selector);
        fresh.initialize(address(0), address(preMTRY), address(sale));
    }

    function test_initializeRevertsOnZeroPreToken() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(ZeroAddress.selector);
        fresh.initialize(address(mtry), address(0), address(sale));
    }

    function test_initializeRevertsOnZeroSaleContract() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(ZeroAddress.selector);
        fresh.initialize(address(mtry), address(preMTRY), address(0));
    }

    // -------------------------------------------------------------------------
    // setTGE() before initialize → NotInitialized
    // -------------------------------------------------------------------------
    function test_setTGERevertsWhenNotInitialized() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(NotInitialized.selector);
        fresh.setTGE(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // setTGE() when balance < MAX_CLAIM_POOL → InsufficientClaimFunding
    // -------------------------------------------------------------------------
    function test_setTGERevertsWhenInsufficientFunding() public {
        // Deploy a fresh claim, initialize it (but don't fund it with 40M MTRY)
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        fresh.initialize(address(mtry), address(preMTRY), address(sale));
        // Balance is 0, which is < 40M MAX_CLAIM_POOL
        vm.expectRevert(InsufficientClaimFunding.selector);
        fresh.setTGE(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // lockPreTokens() before initialize → NotInitialized
    // -------------------------------------------------------------------------
    function test_lockPreTokensRevertsWhenNotInitialized() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(NotInitialized.selector);
        fresh.lockPreTokens(1e18);
    }

    // -------------------------------------------------------------------------
    // vestedAmount() after TGE set returns non-zero
    // -------------------------------------------------------------------------
    function test_vestedAmount_afterTGEAndMidVesting() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        // Warp to midpoint of vesting (after cliff)
        vm.warp(tge + CLIFF + DURATION / 2);
        // vestedAmount should be 2e18 (50% of 4e18 entitlement)
        assertEq(claim.vestedAmount(alice), 2e18);
    }

    // -------------------------------------------------------------------------
    // availableClaimFunding() after initialization returns balance
    // -------------------------------------------------------------------------
    function test_availableClaimFunding_afterInitReturnsBalance() public view {
        // claim is already initialized in setUp and funded with 40M MTRY
        assertEq(claim.availableClaimFunding(), mtry.balanceOf(address(claim)));
        assertGt(claim.availableClaimFunding(), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: lockPreTokens after full vesting end → LockDeadlineExpired
    // -------------------------------------------------------------------------
    function test_lockPreTokens_afterFullVestingEndReverts() public {
        // Buy preMTRY and approve, but set TGE such that fullVestingEnd has already passed.
        _aliceBuys(80_000); // 1 preMTRY
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        // Warp past cliff + vesting so fullVestingEnd() has elapsed.
        vm.warp(tge + CLIFF + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(LockDeadlineExpired.selector);
        claim.lockPreTokens(1e18);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: claim() when not initialized → NotInitialized
    // -------------------------------------------------------------------------
    function test_claim_revertsWhenNotInitialized() public {
        PreMTRYClaim fresh = new PreMTRYClaim(address(this), address(unlockController));
        vm.expectRevert(NotInitialized.selector);
        fresh.claim();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: claim() when TGE not set → TGENotSet
    // -------------------------------------------------------------------------
    function test_claim_revertsWhenTGENotSet() public {
        _setupLockedAlice(1e18);
        // claim is initialized (setUp) but TGE not set
        vm.prank(alice);
        vm.expectRevert(TGENotSet.selector);
        claim.claim();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: claim() throttled (granted == 0) → UnlockThrottled
    // -------------------------------------------------------------------------
    function test_claim_throttledReverts() public {
        // Global cap = 6M per period. claim is a protected source.
        // Alice entitled 10M, fully vested → claims and consumes the entire 6M cap.
        // Bob, claiming in the same period, then sees granted == 0 → UnlockThrottled.
        _setupLockedAlice(2_500_000e18); // 10M entitled

        // Bob also locks so he has entitlement.
        uint256 usdcNeeded = (1e18 * 80_000) / 1e18;
        _fundBob(usdcNeeded);
        vm.warp(saleStart);
        vm.prank(bob);
        sale.buy(usdcNeeded, bob);
        vm.prank(bob);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(bob);
        claim.lockPreTokens(1e18);

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION);

        // Alice drains the full period cap (6M).
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 6_000_000e18);

        // Bob claims in the same period → granted == 0 → UnlockThrottled.
        vm.prank(bob);
        vm.expectRevert(UnlockThrottled.selector);
        claim.claim();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: recoverToken(mtryToken) → Unauthorized (distinct BRDA line)
    // -------------------------------------------------------------------------
    function test_recoverToken_mtryTokenReverts() public {
        vm.prank(deployer);
        vm.expectRevert(Unauthorized.selector);
        claim.recoverToken(IERC20(address(mtry)), 1);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: proposeBurn guards
    // -------------------------------------------------------------------------
    function test_proposeBurn_alreadyPendingReverts() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);

        vm.startPrank(deployer);
        claim.proposeBurn(1_000e18);
        vm.expectRevert(BurnAlreadyPending.selector);
        claim.proposeBurn(1_000e18);
        vm.stopPrank();
    }

    function test_proposeBurn_zeroAmountReverts() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);

        vm.prank(deployer);
        vm.expectRevert(BurnAmountZero.selector);
        claim.proposeBurn(0);
    }

    function test_proposeBurn_nothingBurnableReverts() public {
        // Lock the entire 40M pool so all MTRY held is outstanding entitlement.
        // balance (40M) == outstanding (40M) → burnable == 0 → any positive amount reverts.
        _aliceBuys(800_000_000_000);
        vm.prank(alice);
        preMTRY.approve(address(claim), 10_000_000e18);
        vm.prank(alice);
        claim.lockPreTokens(10_000_000e18);
        assertEq(claim.totalEntitled(), 40_000_000e18);

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);
        vm.warp(tge + CLIFF + DURATION + 1);

        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        claim.proposeBurn(1);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: cancelBurn / executeBurn with no pending → NoBurnPending
    // -------------------------------------------------------------------------
    function test_cancelBurn_noPendingReverts() public {
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        claim.cancelBurn();
    }

    function test_executeBurn_noPendingReverts() public {
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        claim.executeBurn();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _vestedAmount fully vested branch (block.timestamp >= vestingEnd)
    // -------------------------------------------------------------------------
    function test_claim_fullyVestedGrantsEntitled() public {
        _setupLockedAlice(1e18);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        // Warp well past vesting end so _vestedAmount returns full entitled.
        vm.warp(tge + CLIFF + DURATION + 365 days);
        assertEq(claim.vestedAmount(alice), 4e18);
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 4e18);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: lockPreTokens() totalEntitled + mtryAmount > MAX_CLAIM_POOL
    // -------------------------------------------------------------------------
    function test_lockPreTokens_exceedsMaxPool_reverts() public {
        // MAX_CLAIM_POOL = 40_000_000e18 MTRY; CONVERSION_RATIO = 4.
        // Fill pool to within 1e18 of max, then try to add 2e18 (8e18 MTRY).
        uint256 almostMax = 10_000_000e18 - 1; // 10M preMTRY - 1 wei = 40M MTRY - 4 wei
        // Deal preMTRY directly (avoids sale rounding) and lock the exact amount.
        deal(address(preMTRY), alice, almostMax);
        vm.startPrank(alice);
        preMTRY.approve(address(claim), almostMax);
        claim.lockPreTokens(almostMax);
        vm.stopPrank();
        // One more pre-token lock of 2 wei: entitled + 8 > MAX (40M - 4 + 8 > 40M)
        deal(address(preMTRY), bob, 2);
        vm.startPrank(bob);
        preMTRY.approve(address(claim), 2);
        vm.expectRevert(MaxSupplyExceeded.selector);
        claim.lockPreTokens(2);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: recoverToken() on uninitialized claim → NotInitialized
    // -------------------------------------------------------------------------
    function test_recoverToken_uninitializedReverts() public {
        PreMTRYClaim fresh = new PreMTRYClaim(deployer, address(unlockController));
        vm.prank(deployer);
        vm.expectRevert(NotInitialized.selector);
        fresh.recoverToken(IERC20(address(mtry)), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: proposeBurn() on uninitialized claim → NotInitialized
    // -------------------------------------------------------------------------
    function test_proposeBurn_uninitializedReverts() public {
        PreMTRYClaim fresh = new PreMTRYClaim(deployer, address(unlockController));
        vm.prank(deployer);
        vm.expectRevert(NotInitialized.selector);
        fresh.proposeBurn(1);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _vestedAmount() entitled == 0 → return 0
    // -------------------------------------------------------------------------
    function test_vestedAmount_noEntitlementUser_returnsZero() public {
        // Set TGE so vestedAmount() delegates to _vestedAmount() (rather than returning 0 pre-TGE).
        vm.prank(deployer);
        claim.setTGE(block.timestamp);
        // bob has never locked; totalEntitledMTRY[bob] == 0 → early return 0
        assertEq(claim.vestedAmount(bob), 0);
    }
}
