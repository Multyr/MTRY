// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {
    InvalidTimestamp,
    InvalidBeneficiaryContract,
    RenounceOwnershipDisabled
} from "../../src/Errors.sol";

/// @dev Minimal contract used only for its CREATE2 address / bytecode presence (I-1).
contract CounterfactualStub {}

/// @dev Deploys itself and its constructor immediately tries to claim from the wallet passed
///      in at construction time. During construction, address(this).code.length == 0 even
///      though `this` is unambiguously a contract -- a documented Solidity/OZ caveat, and the
///      residual I-1 bypass that a plain code.length check cannot close on its own.
contract ConstructorClaimer {
    bool public claimSucceeded;

    constructor(VestingWalletLinear wallet) {
        try wallet.claim() {
            claimSucceeded = true;
        } catch {
            claimSucceeded = false;
        }
    }
}

// =============================================================================
// Audit finding MULTYR-8 (Informational, I-1..I-6)
// =============================================================================
//
// STATUS: I-1, I-2, I-3, I-6 FIXED. I-4 mitigated (new fundable-headroom view,
// no fund-flow change). I-5 documented (KL-9), no code change -- see
// audit/KnownLimitations.md.
//
// Post-merge self-review found the initial I-1 fix (code.length re-check at claim time) and
// the initial I-3 fix (roll-first pending setters) each had a residual gap of their own --
// both closed below (beneficiary==tx.origin gate; capped epoch roll).
// =============================================================================
contract InformationalFindings is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // I-1: Code-size checks in VestingWalletLinear beneficiary updates allowed
    // unwhitelisted counterfactual (CREATE2) contracts.
    //
    // FIX: _claim() now re-checks the whitelist against the LIVE beneficiary
    // code, so code deployed after confirmation is still caught.
    // -------------------------------------------------------------------------
    function test_I1_CounterfactualBeneficiaryBypassesContractWhitelist() public {
        address wallet = _createGrantVesting(
            VestingManager.BucketType.Team, alice, 1_000_000e18, 0, 365 days, false
        );

        bytes32 salt = keccak256("I1-counterfactual");
        address predicted = computeCreate2Address(salt, keccak256(type(CounterfactualStub).creationCode), address(this));
        assertEq(predicted.code.length, 0, "precondition: predicted address has no code yet");
        assertFalse(
            vestingManager.isWhitelistedBeneficiaryContract(predicted),
            "precondition: predicted address is not whitelisted"
        );

        // Propose + confirm while the address is still empty -- both checks take the EOA branch.
        vm.prank(alice);
        VestingWalletLinear(wallet).proposeBeneficiaryUpdate(predicted);
        vm.warp(block.timestamp + VestingWalletLinear(wallet).BENEFICIARY_UPDATE_DELAY());
        vm.prank(alice, alice);
        VestingWalletLinear(wallet).confirmBeneficiaryUpdate();
        assertEq(VestingWalletLinear(wallet).beneficiary(), predicted);

        // Now deploy code to that exact address (the counterfactual is realized).
        new CounterfactualStub{salt: salt}();
        assertGt(predicted.code.length, 0, "counterfactual contract now has code");

        // Claim must still be rejected: the unwhitelisted contract cannot pull funds.
        vm.warp(block.timestamp + 1 days);
        vm.prank(predicted);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        VestingWalletLinear(wallet).claim();
    }

    // -------------------------------------------------------------------------
    // I-1 residual: the code.length re-check above can itself be bypassed by
    // calling claim() from inside the counterfactual contract's OWN constructor --
    // EXTCODESIZE(address(this)) reads 0 until construction finishes, even though
    // `this` is unambiguously a contract. Only a genuine EOA can ever be both
    // msg.sender and tx.origin (nested calls are always contract-to-contract), so
    // _claim() now additionally requires beneficiary == tx.origin before treating
    // beneficiary as an EOA exempt from the whitelist.
    // -------------------------------------------------------------------------
    function test_I1_ConstructorCallBypassesCodeLengthCheck() public {
        address wallet = _createGrantVesting(
            VestingManager.BucketType.Team, alice, 1_000_000e18, 0, 365 days, false
        );

        bytes32 salt = keccak256("I1-constructor-bypass");
        bytes memory initCode = abi.encodePacked(
            type(ConstructorClaimer).creationCode, abi.encode(VestingWalletLinear(wallet))
        );
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(this));
        assertFalse(vestingManager.isWhitelistedBeneficiaryContract(predicted));

        vm.prank(alice);
        VestingWalletLinear(wallet).proposeBeneficiaryUpdate(predicted);
        vm.warp(block.timestamp + VestingWalletLinear(wallet).BENEFICIARY_UPDATE_DELAY() + 365 days);
        vm.prank(alice, alice);
        VestingWalletLinear(wallet).confirmBeneficiaryUpdate();
        assertEq(VestingWalletLinear(wallet).beneficiary(), predicted);

        // Deploy via CREATE2: the constructor calls wallet.claim() while
        // address(this).code.length is still 0. FIXED: the tx.origin gate still blocks it,
        // since msg.sender (the under-construction contract) != tx.origin (this test contract).
        ConstructorClaimer c = new ConstructorClaimer{salt: salt}(VestingWalletLinear(wallet));
        assertEq(address(c), predicted, "sanity: CREATE2 address matches");
        assertFalse(c.claimSucceeded(), "constructor claim must be rejected");
        assertEq(VestingWalletLinear(wallet).claimedAmount(), 0, "no tokens released to the unwhitelisted contract");
    }

    // -------------------------------------------------------------------------
    // I-2: Unbounded TGE timestamps in setTGE() could brick claim/vesting math.
    //
    // FIX: both setTGE() functions now reject timestamps more than 3650 days out.
    // -------------------------------------------------------------------------
    function test_I2_ExtremeTgeBricksClaimLifecycle() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidTimestamp.selector);
        claim.setTGE(type(uint256).max);
    }

    function test_I2_ExtremeTgeBricksFundedTgeModeWallet() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidTimestamp.selector);
        vestingManager.setTGE(type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // I-3: Single-slot pending updates could skip a scheduled cap reduction when
    // two commits land in the same not-yet-rolled period/epoch.
    //
    // FIX: every pending-value setter/canceller now rolls the current
    // period/epoch first, so an already-due value is promoted to storage
    // before the slot can be overwritten.
    // -------------------------------------------------------------------------
    function test_I3_PendingUnlockCapCommittedForNextPeriodCanBeSkipped() public {
        // Value A is committed during period 0, intending period 1 (commitPeriod 0 < 1).
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(100);

        // Time passes into period 1 with no intervening call, so lastInitializedPeriod is
        // still 0 in storage even though currentPeriod() now reads 1.
        vm.warp(unlockGenesis + PERIOD_DURATION);
        assertEq(unlockController.currentPeriod(), 1);
        assertEq(unlockController.lastInitializedPeriod(), 0, "period 1 not yet physically rolled");

        // Value B is committed inside the still-unrolled period 1. Without the fix this
        // silently overwrites A's slot (A is lost, and B itself can't apply to period 1
        // either since its own commitPeriod is 1, not < 1) -- with the fix, A is promoted
        // into storage before B ever overwrites the slot.
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(200);

        assertEq(unlockController.capBpsByPeriod(1), 100, "first pending value was promoted, not skipped");

        // A later commit intended for period 2 still applies normally: this call rolls
        // period 2 to the still-pending 200 first, then sets a fresh pending value (300)
        // intended for period 3.
        vm.warp(unlockGenesis + 2 * PERIOD_DURATION);
        vm.prank(deployer);
        unlockController.setPendingUnlockCapBps(300);
        assertEq(unlockController.capBpsByPeriod(2), 200);

        // Trigger period 3's rollover with an unrelated governance call and confirm the
        // 300 committed above (not skipped) is what lands.
        vm.warp(unlockGenesis + 3 * PERIOD_DURATION);
        vm.prank(deployer);
        unlockController.cancelPendingUnlockCap();
        assertEq(unlockController.capBpsByPeriod(3), 300);
    }

    function test_I3_PendingEmissionCapCommittedForNextEpochCanBeSkipped() public {
        // Value A committed during epoch 0, intending epoch 1.
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(100_000e18);

        // Time passes into epoch 1 with no intervening call.
        vm.warp(ecosystemGenesis + EPOCH_DURATION);
        assertEq(ecosystem.currentEpoch(), 1);
        assertEq(ecosystem.lastInitializedEpoch(), 0, "epoch 1 not yet physically rolled");

        // Value B committed inside the still-unrolled epoch 1 -- with the fix, A is
        // promoted into storage first instead of being silently dropped.
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(1_000_000e18);

        assertEq(ecosystem.maxEmissionByEpoch(1), 100_000e18, "first pending value was promoted, not skipped");
    }

    // -------------------------------------------------------------------------
    // I-3 residual: unlike GlobalUnlockController._rollPeriodIfNeeded (bounded by
    // MAX_CATCHUP_PERIODS), EcosystemEmissionController._rollEpochIfNeeded has no bound of
    // its own -- it never needed one, because its only other caller (_emit) already guards
    // epoch < MAX_EPOCHS first. The I-3 fix added calls to it from the pending-value setters
    // WITHOUT that guard, so a governance call made long after the emission horizon (60
    // epochs) has passed would run an unbounded loop. FIXED: _rollEpochIfNeededCapped() caps
    // the epoch at MAX_EPOCHS - 1 -- there is nothing left to roll for beyond that, since no
    // further emission can ever occur.
    // -------------------------------------------------------------------------
    function test_I3_EpochRollIsBoundedPastEmissionHorizon() public {
        // A 600-epoch gap (~50 years at the default 30-day epoch) with zero emissions in
        // between -- e.g. governance never called emitTo/batchEmit during a long dormancy,
        // then wants to adjust the pending cap once, long after the emission horizon passed.
        vm.warp(ecosystemGenesis + 600 * EPOCH_DURATION);

        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        ecosystem.setPendingMaxEmissionPerEpoch(1);
        uint256 gasUsed = gasBefore - gasleft();

        // Bounded regardless of how far in the future currentEpoch() actually is -- capped at
        // MAX_EPOCHS (60) iterations, not 600. A generous ceiling (well under what an
        // unbounded 600-iteration roll would have cost) proves the cap is doing its job.
        assertLt(gasUsed, 3_000_000, "epoch roll must stay bounded regardless of dormancy length");
        assertEq(ecosystem.lastInitializedEpoch(), ecosystem.MAX_EPOCHS() - 1, "capped at the last emittable epoch");
    }

    // -------------------------------------------------------------------------
    // I-4: Split bucket accounting could overstate fundable vesting headroom --
    // revocation frees nominal bucket cap without returning tokens to this
    // manager (they go to treasury), and a manager-level burn does not reduce
    // any bucket's reported remaining cap either.
    //
    // FIX: fundableBucketRemaining() bounds nominal headroom by the manager's
    // actual live token balance. getBucketRemaining() is unchanged (nominal
    // cap-issuance headroom) and grant creation still cannot be underfunded
    // (_fundAndVerify already reverts) -- this is a reporting fix, not a
    // fund-flow change.
    // -------------------------------------------------------------------------
    function test_I4_RevocationFreesBucketCapWithoutReturningFundingToManager() public {
        // Fully allocate every bucket (sums to the manager's entire 111M funded balance) so
        // the discrepancy between nominal and fundable headroom is unambiguous.
        address wallet = _createGrantVesting(
            VestingManager.BucketType.Team, teamBeneficiary, TEAM_CAP, 365 days, 365 days, true
        );
        _createGrantVesting(
            VestingManager.BucketType.StrategicStandard, strategicBeneficiary, STRATEGIC_STANDARD_CAP, 0, 365 days, false
        );
        _createGrantVesting(
            VestingManager.BucketType.StrategicExtended, alice, STRATEGIC_EXTENDED_CAP, 0, 365 days, false
        );
        _createGrantVesting(
            VestingManager.BucketType.AdvisorsStandard, advisorBeneficiary, ADVISORS_STANDARD_CAP, 0, 365 days, false
        );
        _createGrantVesting(
            VestingManager.BucketType.AdvisorsShort, bob, ADVISORS_SHORT_CAP, 0, 365 days, false
        );
        assertEq(mtry.balanceOf(address(vestingManager)), 0, "manager fully allocated");

        uint256 treasuryBefore = mtry.balanceOf(treasurySafe);
        vm.prank(deployer);
        VestingWalletLinear(wallet).revokeUnvested(); // 0% vested (before cliff) -> full TEAM_CAP returns to treasury

        assertEq(mtry.balanceOf(treasurySafe), treasuryBefore + TEAM_CAP, "unvested returned to treasury, not manager");
        assertEq(
            vestingManager.getBucketRemaining(VestingManager.BucketType.Team),
            TEAM_CAP,
            "nominal headroom fully restored"
        );
        assertEq(
            vestingManager.fundableBucketRemaining(VestingManager.BucketType.Team),
            0,
            "fundable headroom correctly reports the manager cannot actually fund a new Team grant"
        );
    }

    function test_I4_ManagerBurnCreatesUnfundedBucketHeadroom() public {
        // AdvisorsShort bucket has never been allocated -- nominal headroom is the full cap.
        uint256 nominal = vestingManager.getBucketRemaining(VestingManager.BucketType.AdvisorsShort);
        assertEq(nominal, ADVISORS_SHORT_CAP);

        // Burn almost the entire manager balance (111M funded at deploy), leaving less
        // than ADVISORS_SHORT_CAP.
        uint256 managerBalance = mtry.balanceOf(address(vestingManager));
        uint256 remaining = 1_000_000e18;
        vm.prank(deployer);
        vestingManager.proposeBurn(managerBalance - remaining);
        vm.warp(block.timestamp + vestingManager.BURN_DELAY() + 1);
        vm.prank(deployer);
        vestingManager.executeBurn();

        assertEq(
            vestingManager.getBucketRemaining(VestingManager.BucketType.AdvisorsShort),
            ADVISORS_SHORT_CAP,
            "nominal headroom is unchanged by the burn"
        );
        assertEq(
            vestingManager.fundableBucketRemaining(VestingManager.BucketType.AdvisorsShort),
            remaining,
            "fundable headroom correctly reflects the reduced balance"
        );

        // Attempting to actually fund the full nominal headroom now fails.
        vm.prank(deployer);
        vm.expectRevert();
        vestingManager.createVesting(
            VestingManager.BucketType.AdvisorsShort, bob, ADVISORS_SHORT_CAP, 0, 365 days, false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    // -------------------------------------------------------------------------
    // I-5: revokeUnvested() sends unvested MTRY directly to treasury, bypassing
    // GlobalUnlockController allowance consumption and the burn-delay lifecycle.
    //
    // DOCUMENTED (KL-9), not code-changed: the unlock cap governs programmatic
    // claim/vesting/emission releases, not governance-initiated revocation
    // recovery. This test confirms the (intended) current behavior.
    // -------------------------------------------------------------------------
    function test_I5_RevokeMovesUnvestedReserveToTreasuryWithoutUnlockOrBurnDelay() public {
        address wallet = _createGrantVesting(
            VestingManager.BucketType.Team, teamBeneficiary, 1_000_000e18, 365 days, 365 days, true
        );

        uint256 treasuryBefore = mtry.balanceOf(treasurySafe);
        uint256 period = unlockController.currentPeriod();

        vm.prank(deployer);
        VestingWalletLinear(wallet).revokeUnvested();

        assertEq(mtry.balanceOf(treasurySafe), treasuryBefore + 1_000_000e18);
        assertEq(
            unlockController.totalReleasedInPeriod(period), 0,
            "revocation recovery does not consume unlock allowance, by design"
        );
    }

    // -------------------------------------------------------------------------
    // I-6: Renounceable ownership + a paused controller could permanently
    // freeze all controller-gated releases (no account could ever unpause).
    //
    // FIX: renounceOwnership() is now permanently disabled on every
    // GovernanceRoles contract (and PreMTRYToken).
    // -------------------------------------------------------------------------
    function test_I6_ControllerPausePlusRenouncedOwnershipMakesReleaseFreezePermanent() public {
        vm.prank(safeGuardian);
        unlockController.pause();
        assertTrue(unlockController.paused());

        vm.prank(deployer); // deployer is still owner() in this fixture
        vm.expectRevert(RenounceOwnershipDisabled.selector);
        unlockController.renounceOwnership();

        // Ownership survives the attempt, so recovery remains possible.
        assertEq(unlockController.owner(), deployer);
        vm.prank(deployer);
        unlockController.unpause();
        assertFalse(unlockController.paused());
    }

    // -------------------------------------------------------------------------
    // I-6 (PreMTRYToken): PreMTRYToken does not inherit GovernanceRoles -- it
    // extends Ownable2Step directly -- so it needs its own renounceOwnership
    // override. Before the fix, the owner could renounce while the sale/claim
    // bindings were still unfinalized, permanently stranding them: no account
    // could ever call setSaleContract / setClaimContract / finalize* again, so a
    // misconfigured binding could never be corrected and the pretoken lifecycle
    // would be frozen in whatever state it happened to be in.
    //
    // FIX: renounceOwnership() reverts RenounceOwnershipDisabled, mirroring
    // GovernanceRoles. Ownership can only leave via a two-step transfer to a
    // named successor.
    // -------------------------------------------------------------------------
    function test_I6_PreTokenRenouncedOwnershipStrandsUnfinalizedBindings() public {
        // Preconditions: owner is live and both bindings are still mutable, so
        // owner-only recovery is the ONLY way to correct them.
        assertEq(preMTRY.owner(), deployer);
        assertFalse(preMTRY.saleContractFinalized(), "sale binding still mutable");
        assertFalse(preMTRY.claimContractFinalized(), "claim binding still mutable");

        vm.prank(deployer);
        vm.expectRevert(RenounceOwnershipDisabled.selector);
        preMTRY.renounceOwnership();

        // Ownership survives the attempt.
        assertEq(preMTRY.owner(), deployer, "owner must be unchanged after a rejected renounce");

        // Owner-only recovery still works: the bindings can be finalized, which is
        // exactly what a renounced owner could never have done.
        vm.startPrank(deployer);
        preMTRY.finalizeSaleContract();
        preMTRY.finalizeClaimContract();
        vm.stopPrank();

        assertTrue(preMTRY.saleContractFinalized(), "sale binding finalized by the surviving owner");
        assertTrue(preMTRY.claimContractFinalized(), "claim binding finalized by the surviving owner");
    }
}
