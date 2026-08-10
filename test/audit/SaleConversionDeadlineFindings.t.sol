// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {TGEBeforeSaleEnd, SaleEnded} from "../../src/Errors.sol";

// =============================================================================
// Audit finding MULTYR-1: PreMTRYSale can accept payment after PreMTRYClaim has
// permanently closed conversion.
//
// STATUS: FIXED
//
// PreMTRYSale.saleEnd and PreMTRYClaim's conversion deadline (tgeTimestamp +
// CLIFF_DURATION, since the MULTYR-5 fix) were configured independently. A buyer
// could purchase preMTRY via PreMTRYSale.buy() after the point in time at
// which PreMTRYClaim.lockPreTokens() would already reject their lock,
// stranding their preMTRY with no path to the promised 4x MTRY entitlement.
//
// FIX APPLIED (src/PreMTRYClaim.sol):
//   PreMTRYClaim now binds a PreMTRYSale reference at initialize() and
//   enforces `tgeTimestamp_ >= saleContract.saleEnd()` inside setTGE(). Since
//   the sale can never be reopened after saleEnd (immutable), and TGE can
//   only be set once, this makes it impossible for TGE to be activated while
//   the sale is still open -- so no purchase can ever land after the
//   lockPreTokens window (tgeTimestamp + CLIFF_DURATION) has already closed.
// =============================================================================
contract SaleConversionDeadlineTest is TestSetup {
    uint256 constant CLIFF = 180 days;

    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Reproduces the report's core configuration mistake: governance tries to
    // activate TGE while the sale is still within its window (or has closed,
    // but too recently to satisfy the invariant). setTGE must reject this
    // outright, so the vulnerable state (sale open, TGE active) can never be
    // reached.
    // -------------------------------------------------------------------------
    function test_MULTYR1_setTGERevertsWhileSaleStillOpen() public {
        vm.warp(saleStart);
        vm.prank(deployer);
        vm.expectRevert(TGEBeforeSaleEnd.selector);
        claim.setTGE(block.timestamp);
    }

    function test_MULTYR1_setTGERevertsJustBeforeSaleEnd() public {
        vm.warp(saleEnd - 1);
        vm.prank(deployer);
        vm.expectRevert(TGEBeforeSaleEnd.selector);
        claim.setTGE(block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Positive path: TGE set at (or after) saleEnd succeeds, and a buyer who
    // purchased before saleEnd still has the full CLIFF_DURATION window after
    // TGE to lock -- the fix does not shrink the legitimate conversion path.
    // -------------------------------------------------------------------------
    function test_MULTYR1_setTGESucceedsAtSaleEndAndBuyerRetainsFullLockWindow() public {
        _fundAlice(80_000); // 1 preMTRY
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(80_000, alice);

        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(saleEnd);
        assertEq(claim.tgeTimestamp(), saleEnd);

        // Buyer can still lock any time up to tgeTimestamp + CLIFF_DURATION.
        vm.warp(saleEnd + CLIFF - 1);
        vm.startPrank(alice);
        preMTRY.approve(address(claim), 1e18);
        claim.lockPreTokens(1e18);
        vm.stopPrank();

        assertEq(claim.totalEntitledMTRY(alice), 4e18, "buyer converted successfully");
    }

    // -------------------------------------------------------------------------
    // The sale itself is still bounded by its own immutable saleEnd regardless
    // of TGE -- buy() cannot succeed after saleEnd even if TGE is never set.
    // -------------------------------------------------------------------------
    function test_MULTYR1_buyStillRevertsAfterSaleEndIndependentOfTGE() public {
        vm.warp(saleEnd + 1);
        vm.prank(alice);
        vm.expectRevert(SaleEnded.selector);
        sale.buy(80_000, alice);
    }
}
