// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {TGENotSet, TGEAlreadySet} from "../../src/Errors.sol";

// =============================================================================
// POC-15: TGE-Mode Vesting Grants Fail If vestingManager.setTGE() Not Called
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   VestingManager.createVesting() with startMode=TGE reads tgeTimestamp. If setTGE()
//   has not yet been called, tgeTimestamp == 0 and the call reverts with TGENotSet.
//   Once setTGE(T) is called (one-time, immutable), all TGE-mode wallets receive
//   startTimestamp = T. Wallets can be created before T arrives -- they are funded and
//   authorized immediately, but vest from T. If the actual TGE is later delayed to T+90d,
//   the wallets still have startTimestamp = T and begin vesting 90 days early.
//   There is no startTimestamp update mechanism; the only recovery is to revoke and redeploy.
//
// WHY NO FIX:
//   TGENotSet on createVesting() is the correct guard -- it prevents wallets from being
//   created with startTimestamp=0 (which would mean vesting started at Unix epoch).
//   The immutability of startTimestamp is a deliberate design: strategic investors receive
//   legally binding vesting schedules that cannot be changed after grant. The "delayed TGE"
//   scenario is an operational concern managed off-chain; the Foundation is expected to set
//   TGE only when confident in the date.
//
// OPEN QUESTIONS:
//   Q1. If setTGE(T) is called and TGE is later delayed to T+90d, vesting wallets have
//       startTimestamp = T (early). Revoke + redeploy consumes additional bucket allocation.
//       Is there a contingency plan documented for TGE delays post-setTGE()?
//   Q2. setTGE() accepts any future timestamp with no upper bound. If set far in the future
//       (e.g. 5 years), all strategic wallets start vesting 5 years late. Is there a
//       max-lag validation on setTGE()?
//   Q3. See [[poc09-tge-desync]] -- vestingManager.setTGE() and claim.setTGE() are independent.
//       The deploy script should atomically verify both are set to the same timestamp or
//       emit a comparison event for off-chain monitoring.
// =============================================================================

contract POC15_TGEModeVestingWithoutTGESet is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
        // NOTE: We do NOT call setTGE() in setUp -- testing the unset case
    }

    // -------------------------------------------------------------------------
    // TGE-mode grant fails if setTGE() has not been called
    // -------------------------------------------------------------------------
    function test_tgeModeGrantRevertsIfTGENotSet() public {
        assertFalse(vestingManager.tgeSet(), "TGE not yet set");

        // Strategic Standard allows TGE mode
        vm.expectRevert(TGENotSet.selector);
        vm.prank(deployer);
        vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
    }

    // -------------------------------------------------------------------------
    // GRANT_DATE mode works without TGE set (no TGE dependency)
    // -------------------------------------------------------------------------
    function test_grantDateModeWorksWithoutTGE() public {
        assertFalse(vestingManager.tgeSet(), "TGE not yet set");

        // Strategic Standard also allows GRANT_DATE mode
        vm.prank(deployer);
        address wallet = vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );

        assertNotEq(wallet, address(0), "GRANT_DATE wallet created without TGE");
    }

    // -------------------------------------------------------------------------
    // TGE set to future timestamp: wallet created, but starts vesting in the future
    // -------------------------------------------------------------------------
    function test_futureTGE_walletFundedButVestingNotStarted() public {
        uint256 futureTGE = block.timestamp + 90 days;

        vm.startPrank(deployer);
        vestingManager.setTGE(futureTGE);

        address wallet = vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000_000e18,
            0,           // no cliff (for clarity)
            365 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
        vm.stopPrank();

        // Wallet is FUNDED NOW (tokens already in the wallet)
        assertEq(mtry.balanceOf(wallet), 1_000_000e18, "wallet funded immediately");

        // But vesting hasn't started yet
        VestingWalletLinear w = VestingWalletLinear(wallet);
        assertEq(w.startTimestamp(), futureTGE, "vesting starts at future TGE");
        assertEq(w.releasableAmount(), 0, "nothing releasable before TGE");

        // 30 days later: still before TGE, still nothing releasable
        vm.warp(block.timestamp + 30 days);
        assertEq(w.releasableAmount(), 0, "nothing releasable 30 days before TGE");

        // At TGE: vesting starts
        vm.warp(futureTGE);
        assertEq(w.releasableAmount(), 0, "still nothing releasable AT TGE (start of vesting)");

        // 1 year after TGE: fully vested
        vm.warp(futureTGE + 365 days);
        assertEq(w.releasableAmount(), 1_000_000e18, "fully vested 1 year after TGE");
    }

    // -------------------------------------------------------------------------
    // TGE cannot be changed -- delayed TGE scenario
    // -------------------------------------------------------------------------
    function test_delayedTGE_walletsCannotBeUpdated() public {
        uint256 originalTGE = block.timestamp + 30 days;
        uint256 delayedTGE  = block.timestamp + 120 days; // 90-day delay

        vm.prank(deployer);
        vestingManager.setTGE(originalTGE);

        // Create a TGE-mode wallet anchored to originalTGE
        vm.prank(deployer);
        address wallet = vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            500_000e18,
            0,
            365 days,
            false,
            VestingManager.VestingStartMode.TGE
        );

        // TGE is delayed -- but setTGE can NEVER be called again
        vm.expectRevert(TGEAlreadySet.selector);
        vm.prank(deployer);
        vestingManager.setTGE(delayedTGE);

        // The wallet's startTimestamp is permanently set to originalTGE
        assertEq(
            VestingWalletLinear(wallet).startTimestamp(),
            originalTGE,
            "wallet start timestamp frozen at original TGE"
        );

        // QUESTION: If actual TGE happens at delayedTGE, this wallet starts vesting
        // 90 days BEFORE the actual TGE. Is there any protocol-level way to handle this?
        // Only option: revoke the wallet and create a new GRANT_DATE wallet.
        // But revocation also burns the unvested tokens, which is destructive.
    }
}
