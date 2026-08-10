// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {UnlockThrottled, NotWhitelisted} from "../src/Errors.sol";

contract IntegrationTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Allocation math
    // -------------------------------------------------------------------------
    function test_allocationsSumTo300M() public view {
        uint256 sum = mtry.balanceOf(treasurySafe)
            + mtry.balanceOf(liquiditySafe)
            + mtry.balanceOf(address(claim))
            + mtry.balanceOf(address(vestingManager))
            + mtry.balanceOf(address(ecosystem));
        assertEq(sum, 300_000_000e18);
        assertEq(sum, mtry.totalSupply());
    }

    // -------------------------------------------------------------------------
    // Dual start mode coexistence
    // -------------------------------------------------------------------------
    function test_tgeAndGrantDateVestingsCoexist() public {
        // Team (GRANT_DATE) before TGE
        address teamWallet = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            10_000_000e18,
            365 days,
            1095 days,
            false
        );
        uint256 grantStart = block.timestamp;

        // Now set TGE
        uint256 tge = block.timestamp + 10 days;
        vm.warp(tge);
        _setTGE(tge);

        // Strategic (TGE) after TGE
        address stratWallet = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            5_000_000e18,
            180 days,
            540 days,
            false
        );

        assertEq(VestingWalletLinear(teamWallet).startTimestamp(), grantStart);
        assertEq(VestingWalletLinear(stratWallet).startTimestamp(), tge);
    }

    // -------------------------------------------------------------------------
    // Shared lane budget: vesting + ecosystem share the non-protected portion of the cap
    // -------------------------------------------------------------------------
    function test_sharedBudgetBetweenVestingAndEcosystem() public {
        // With default 50% protected quota, shared lane cap for a 6M period = 3M.
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address wallet = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            2_500_000e18,   // 2.5M — fits within 3M shared lane
            0,
            1 days,
            false
        );

        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(10_000_000e18);
        vm.prank(deployer);
        ecosystem.setApprovedRecipient(bob, true);

        vm.warp(block.timestamp + 1 days + 1);

        // Vesting claim: 2.5M fits in shared (3M - 0 used).
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        VestingWalletLinear(wallet).claim();
        assertEq(mtry.balanceOf(strategicBeneficiary), 2_500_000e18);

        // Ecosystem emits 1M → clamped by local per-epoch cap (1M) first. Shared remaining: 3M - 2.5M = 0.5M.
        // Local cap (pending 10M) applies next epoch; current epoch local cap = 1M. So wantLocal = 1M.
        // Global shared remaining = 0.5M → granted = 0.5M.
        vm.prank(deployer);
        uint256 granted = ecosystem.emitTo(bob, 1_000_000e18);
        assertEq(granted, 500_000e18);

        // Shared lane fully consumed. Protected lane reserve (3M) still available to protected sources.
        uint256 period = unlockController.currentPeriod();
        assertEq(unlockController.releasedInPeriod(period), 3_000_000e18);
        assertEq(unlockController.remainingAllowance(), 3_000_000e18);  // = protected reserve
    }

    // -------------------------------------------------------------------------
    // Revoke returns to treasury and does NOT consume unlock allowance
    // -------------------------------------------------------------------------
    function test_revokeDoesNotConsumeAllowance() public {
        address wallet = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            1_000_000e18,
            0,
            10 days,
            true
        );

        uint256 releasedBefore = unlockController.releasedInPeriod(unlockController.currentPeriod());
        vm.prank(deployer);
        VestingWalletLinear(wallet).revokeUnvested();
        uint256 releasedAfter = unlockController.releasedInPeriod(unlockController.currentPeriod());

        // Revoke returns everything to treasury (since 0 vested at t=0 effectively before cliff)
        assertEq(mtry.balanceOf(treasurySafe), 75_000_000e18 + 1_000_000e18);
        // Global cap consumption unchanged
        assertEq(releasedAfter, releasedBefore);
    }

    // -------------------------------------------------------------------------
    // Full lifecycle
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // Claim protection — shared lane cannot consume the reserved claim quota.
    // -------------------------------------------------------------------------
    function test_claimProtectedFromVestingGriefing() public {
        // Alice locks a large entitlement via claim
        _aliceBuys(200_000e6);  // 200_000 USDC → 2.5M preMTRY → 10M entitlement
        vm.prank(alice);
        preMTRY.approve(address(claim), 2_500_000e18);
        vm.prank(alice);
        claim.lockPreTokens(2_500_000e18);

        // Whale has 24M strategic vesting, fully vested
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        address whaleWallet = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            strategicBeneficiary,
            24_000_000e18,
            0,
            1 days,
            false
        );

        // MULTYR-1: TGE must be >= saleEnd.
        vm.warp(saleEnd);
        vm.prank(deployer);
        claim.setTGE(block.timestamp);

        vm.warp(block.timestamp + 180 days + 540 days);

        uint256 period = unlockController.currentPeriod();
        uint256 cap = unlockController.maxUnlockForPeriod(period);
        assertEq(cap, 6_000_000e18);

        // With 50% quota reserved for protected sources, shared lane (whale) can consume at most 3M.
        vm.prank(strategicBeneficiary, strategicBeneficiary);
        VestingWalletLinear(whaleWallet).claim();
        assertEq(mtry.balanceOf(strategicBeneficiary), 3_000_000e18);  // shared lane cap

        // Alice's claim (protected) can still use the reserved 3M
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 3_000_000e18);

        // Single-cap invariant: total release across all lanes <= per-period cap.
        uint256 totalReleased = unlockController.totalReleasedInPeriod(period);
        assertEq(totalReleased, 6_000_000e18);  // == cap, no inflation
        assertLe(totalReleased, cap);
    }

    function test_fullLifecycle() public {
        // Buy preMTRY
        _aliceBuys(80_000); // 1 preMTRY

        // Lock
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);

        // TGE
        _setTGE(block.timestamp);
        uint256 tge = claim.tgeTimestamp(); // _setTGE may clamp forward to saleEnd (MULTYR-1)

        // Create vesting grants
        _createTgeVesting(VestingManager.BucketType.StrategicStandard, strategicBeneficiary, 1_000e18, 180 days, 540 days, false);
        _createGrantVesting(VestingManager.BucketType.Team, teamBeneficiary, 1_000e18, 365 days, 1095 days, false);

        // Warp past full vesting for claim pool (180+540)
        vm.warp(tge + 180 days + 540 days);

        // Claim
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 4e18);
    }

    // -------------------------------------------------------------------------
    // Whitelist enforcement across the full buy → lock → claim path
    // -------------------------------------------------------------------------

    /// @notice Full buy→lock→claim with REAL sale + REAL whitelist: confirms the KYC gate
    ///         doesn't block a legitimately whitelisted user at any step.
    function test_whitelistedUserCanBuyLockAndClaim() public {
        assertTrue(sale.whitelist(alice), "alice must be whitelisted before test");

        // 1. Buy via real sale (alice is whitelisted as both sender and receiver)
        uint256 usdcCost = 80_000; // 1 preMTRY at 0.08 USDC
        _fundAlice(usdcCost);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(usdcCost, alice);
        assertEq(preMTRY.balanceOf(alice), 1e18);

        // 2. Lock
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);
        assertEq(claim.totalEntitledMTRY(alice), 4e18);
        assertEq(preMTRY.balanceOf(alice), 0);

        // 3. Set TGE and warp to full vest
        _setTGE(block.timestamp);
        uint256 tge = claim.tgeTimestamp(); // _setTGE may clamp forward to saleEnd (MULTYR-1)
        vm.warp(tge + 180 days + 540 days);

        // 4. Claim MTRY
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 4e18);
    }

    /// @notice A non-whitelisted address is blocked at buy() and therefore cannot
    ///         participate in lock→claim at all — the gate is at the sale entry point.
    function test_nonWhitelistedCannotEnterClaimFlow() public {
        address stranger = address(0x9999);
        assertFalse(sale.whitelist(stranger));

        uint256 usdcCost = 80_000;
        usdc.mint(stranger, usdcCost);
        vm.prank(stranger);
        usdc.approve(address(sale), usdcCost);
        vm.warp(saleStart);

        vm.prank(stranger);
        vm.expectRevert(NotWhitelisted.selector);
        sale.buy(usdcCost, stranger);

        // No preMTRY minted → lockPreTokens would also fail (ZeroAmount or transfer failure)
        assertEq(preMTRY.balanceOf(stranger), 0);
    }

    /// @notice The claim contract itself is whitelisted so that any future convenience
    ///         path that calls sale.buy(amount, address(claim)) works without a separate
    ///         exemption mechanism in buy().
    function test_claimContractIsWhitelistedAsSystemReceiver() public {
        assertTrue(sale.whitelist(address(claim)), "claim contract must be whitelisted");

        // A whitelisted sender (alice) can designate the claim contract as receiver.
        uint256 usdcCost = 80_000;
        _fundAlice(usdcCost);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(usdcCost, address(claim));

        // preMTRY lands at the claim contract
        assertEq(preMTRY.balanceOf(address(claim)), 1e18);
    }
}
