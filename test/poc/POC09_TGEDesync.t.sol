// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {TGEAlreadySet} from "../../src/Errors.sol";

// =============================================================================
// POC-09: PreMTRYClaim and VestingManager Can Be Set to Different TGE Timestamps
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   PreMTRYClaim.setTGE() and VestingManager.setTGE() are independent one-time
//   setters with no cross-validation. If set to different values, preMTRY holders
//   vest on a different schedule than TGE-mode vesting wallet holders. Both setters
//   are one-time-only (TGEAlreadySet), so a mismatch cannot be corrected on-chain
//   without redeploying the affected contract.
//
// WHY NO FIX:
//   The design keeps the two TGE slots intentionally independent -- PreMTRYClaim
//   has its own lifecycle (burn horizon depends on its TGE) and VestingManager
//   uses TGE to anchor startTimestamp for strategic allocations. An on-chain
//   cross-check would couple the two contracts. The deploy script sets both in the
//   same transaction, making accidental desync unlikely in practice.
//
// OPEN QUESTIONS:
//   Q1. There is no on-chain "global TGE" -- two independent slots exist. The
//       audit claim "all vesting anchored to a single global TGE" is a social/deploy
//       convention, not an enforcement. Should the deploy script emit a comparison
//       event or add a post-deploy assertion?
//   Q2. If a governance migration redeploys one contract and re-sets TGE, the
//       other contract retains the old TGE permanently. Is there a documented
//       contingency for this scenario?
//   Q3. Off-chain tooling (subgraphs, dashboards) must read both TGE values
//       independently. Is there a canonical address/slot documented for UIs?
// =============================================================================

contract POC09_TGEDesync is TestSetup {
    uint64 constant CLIFF = 180 days;
    uint64 constant VEST = 540 days;

    uint256 claimTGE;
    uint256 vmTGE;

    // Intentionally set different TGE values
    function setUp() public {
        _deployAllCorrectly();

        claimTGE = block.timestamp + 7 days;   // claim TGE: 7 days from now
        vmTGE    = block.timestamp + 30 days;  // vesting TGE: 30 days from now

        vm.startPrank(deployer);
        claim.setTGE(claimTGE);          // claim anchored to T+7
        vestingManager.setTGE(vmTGE);   // vestingManager anchored to T+30
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // TGE timestamps are different -- one-time setters, no correction possible
    // -------------------------------------------------------------------------
    function test_tgeValuesAreDifferent() public view {
        assertEq(claim.tgeTimestamp(), claimTGE);
        assertEq(vestingManager.tgeTimestamp(), vmTGE);
        assertNotEq(claimTGE, vmTGE, "TGE values differ between the two contracts");
    }

    // -------------------------------------------------------------------------
    // TGEAlreadySet: cannot correct the mismatch after the fact
    // -------------------------------------------------------------------------
    function test_cannotCorrectTGEAfterSet() public {
        uint256 correctTGE = claimTGE; // trying to align vmTGE to claimTGE

        vm.expectRevert(TGEAlreadySet.selector);
        vm.prank(deployer);
        vestingManager.setTGE(correctTGE); // IMMUTABLE -- stuck with vmTGE

        vm.expectRevert(TGEAlreadySet.selector);
        vm.prank(deployer);
        claim.setTGE(vmTGE); // also immutable
    }

    // -------------------------------------------------------------------------
    // Consequence: PreMTRYClaim cliff expires 23 days before TGE-mode wallet cliff
    // -------------------------------------------------------------------------
    function test_cliffExpiresAtDifferentTimes() public {
        uint256 claimCliffEnd = claimTGE + CLIFF;     // T+7+180 = T+187
        uint256 walletCliffEnd = vmTGE + CLIFF;       // T+30+180 = T+210

        uint256 delta = walletCliffEnd - claimCliffEnd; // 23 days
        assertEq(delta, 23 days, "wallet cliff expires 23 days later than claim cliff");

        // Buy preMTRY and lock
        vm.warp(saleStart);
        _fundAlice(1_000e6);
        vm.prank(alice);
        sale.buy(1_000e6, alice);
        // Cache balance before pranking -- vm.prank is consumed by an inline balanceOf call,
        // causing the subsequent approve/lockPreTokens to execute from the test contract.
        uint256 alicePreMTRY = preMTRY.balanceOf(alice);
        vm.prank(alice);
        preMTRY.approve(address(claim), alicePreMTRY);
        vm.prank(alice);
        claim.lockPreTokens(alicePreMTRY);

        // Create a TGE-mode vesting wallet for the same beneficiary
        address wallet = _createTgeVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            100_000e18,
            CLIFF,
            VEST,
            false
        );

        // At claimCliffEnd + 1 day: claim is past cliff, wallet is still in cliff
        vm.warp(claimCliffEnd + 1 days);

        assertGt(claim.claimable(alice), 0, "claim: past cliff, tokens vesting");
        assertEq(
            VestingWalletLinear(wallet).releasableAmount(),
            0,
            "wallet: still in cliff -- TGE is 23 days later"
        );

        // QUESTION: Alice's preMTRY → MTRY vesting starts 23 days before her
        // TGE-mode wallet vesting. Is this the intended protocol behavior?
    }

    // -------------------------------------------------------------------------
    // Demonstrate: VestingManager.tgeTimestamp() feeds into startTimestamp of wallets
    // -------------------------------------------------------------------------
    function test_tgeWalletUsesVestingManagerTGE() public {
        address wallet = _createTgeVesting(
            VestingManager.BucketType.StrategicExtended,
            bob,
            50_000e18,
            CLIFF,
            VEST,
            false
        );

        VestingWalletLinear w = VestingWalletLinear(wallet);

        // Wallet's startTimestamp is vmTGE, NOT claimTGE
        assertEq(w.startTimestamp(), vmTGE, "wallet anchored to vmTGE");
        assertNotEq(w.startTimestamp(), claimTGE, "wallet NOT anchored to claimTGE");
    }
}
