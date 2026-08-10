# MULTYR Token Stack — Remediation Response

Response to the HackenProof Private Security Audit of the MULTYR token stack
(audit period 13.07–30.07.2026, Preliminary Report dated 30.07.2026).

| | |
|---|---|
| **Scope** | https://github.com/hackenproof-public/MTRY |
| **Audited commit** | `7329c41` (tag `mtry-token-audit-v2`) |
| **Remediated commit** | the commit tagged `mtry-token-remediation-v1` |
| **Remediated tag** | `mtry-token-remediation-v1` |
| **Findings addressed** | 7 of 7 (MULTYR-1 through MULTYR-6, MULTYR-8) |
| **Forge test suite** | 561 passed / 0 failed |
| **Halmos symbolic proofs** | 27 / 27 pass |

MULTYR-7 does not appear in the Preliminary Report and is therefore not addressed here.

---

## 1. Summary

Every finding in the Preliminary Report has been addressed. Ten of the twelve
tracked items (six report findings plus six MULTYR-8 sub-findings) received a code
fix; one received a reporting-level mitigation; one is accepted as intended behaviour
and formally documented.

| ID | Severity | Status |
|----|----------|--------|
| MULTYR-5 | Medium | Fixed |
| MULTYR-2 | Low | Fixed |
| MULTYR-3 | Low | Fixed |
| MULTYR-4 | Low | Fixed |
| MULTYR-6 | Low | Fixed |
| MULTYR-1 | None | Fixed |
| MULTYR-8 / I-1 | Informational | Fixed |
| MULTYR-8 / I-2 | Informational | Fixed |
| MULTYR-8 / I-3 | Informational | Fixed |
| MULTYR-8 / I-4 | Informational | Mitigated |
| MULTYR-8 / I-5 | Informational | Accepted (documented as KL-9) |
| MULTYR-8 / I-6 | Informational | Fixed |

Every fix is accompanied by at least one regression test that reproduces the reported
scenario and fails against the audited commit. Test commands are given per finding in
section 3 and collected in section 4.

---

## 2. Traceability matrix

| ID | Severity | Title | Status | Commit |
|----|----------|-------|--------|--------|
| MULTYR-1 | None | `PreMTRYSale` can accept payment after `PreMTRYClaim` has permanently closed conversion | Fixed | `1fd65ec` |
| MULTYR-2 | Low | Lazy rollover makes `GlobalUnlockController` and `EcosystemEmissionController` advertise stale capacity after period boundaries | Fixed | `7cfa645` |
| MULTYR-3 | Low | `GlobalUnlockController`'s source allowance view omits authorization and genesis preconditions | Fixed | `c7045c6` |
| MULTYR-4 | Low | `VestingManager` registry returns the former beneficiary after a supported reassignment | Fixed | `7612241` |
| MULTYR-5 | Medium | Global TGE vesting in `PreMTRYClaim` lets late lockers immediately vest and exhaust the release cap | Fixed | `24e1388` |
| MULTYR-6 | Low | Immutable guardian in `VestingWalletLinear` lets stale guardians indefinitely freeze non-revocable grants | Fixed | `f886b31` |
| MULTYR-8 / I-1 | Informational | Counterfactual beneficiary bypasses the contract whitelist | Fixed | `1fd65ec`, `2193346` |
| MULTYR-8 / I-2 | Informational | Unbounded TGE timestamps | Fixed | `1fd65ec` |
| MULTYR-8 / I-3 | Informational | Skippable pending-value commits | Fixed | `1fd65ec`, `2193346` |
| MULTYR-8 / I-4 | Informational | Bucket accounting overstates fundable headroom | Mitigated | `1fd65ec` |
| MULTYR-8 / I-5 | Informational | Revocation recovery bypasses the unlock cap and burn-delay lifecycle | Accepted | `1fd65ec` (documentation only) |
| MULTYR-8 / I-6 | Informational | Renounceable ownership | Fixed | `1fd65ec` |

---

## 3. Findings

### MULTYR-1 — `PreMTRYSale` can accept payment after conversion has closed

**Severity:** None &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `1fd65ec`

**Issue.** `PreMTRYSale.saleEnd` and `PreMTRYClaim`'s conversion deadline were configured
independently, with no on-chain relationship between them. A buyer could purchase preMTRY
after the point at which `lockPreTokens()` would already reject their lock, stranding the
purchased tokens with no path to the 4x MTRY entitlement.

**Resolution.** `PreMTRYClaim` now binds a `PreMTRYSale` reference at `initialize()` and
`setTGE()` enforces that TGE cannot activate while the sale is still open:

```solidity
// src/PreMTRYClaim.sol — setTGE()
if (tgeTimestamp_ < ISaleWindow(saleContract).saleEnd()) revert TGEBeforeSaleEnd();
```

Because `saleEnd` is immutable and TGE can be set only once, the vulnerable state (sale open
while TGE is active) is unreachable. Every accepted purchase therefore retains the full
`CLIFF_DURATION` window after TGE in which to call `lockPreTokens()`. The precondition is
additionally recorded in `docs/DEPLOY_FLOW.md` (Phase B) and in the pre-broadcast launch
checklist.

**Verification.**

```bash
forge test --match-test "test_MULTYR1_"    # 4 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR1_setTGERevertsWhileSaleStillOpen` | `setTGE` reverts `TGEBeforeSaleEnd` during the sale window |
| `test_MULTYR1_setTGERevertsJustBeforeSaleEnd` | Boundary: still rejected at `saleEnd - 1` |
| `test_MULTYR1_setTGESucceedsAtSaleEndAndBuyerRetainsFullLockWindow` | Positive path; a buyer retains the full cliff-length lock window |
| `test_MULTYR1_buyStillRevertsAfterSaleEndIndependentOfTGE` | `buy()` remains bounded by its own immutable `saleEnd` |

---

### MULTYR-2 — Stale capacity advertised after period boundaries

**Severity:** Low &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `7cfa645`

**Issue.** Pending cap changes become effective in the next period/epoch but were promoted
only inside the state-changing consumption functions. The public capacity views
(`maxUnlockForPeriod`, `remainingAllowance`, `remainingAllowanceForSource`,
`availableThisEpoch`) did not simulate a due rollover, so immediately after a boundary they
returned a stale value that disagreed with the very next state-changing call at the same
timestamp. The reference-supply branch failed in the opposite direction: a same-period
`setReferenceSupply` commit was applied to the view a period early.

**Resolution.** Four projection helpers were added that mirror the promotion condition of the
corresponding rollover loop without writing storage: `_projectedCapBps`,
`_projectedReferenceSupply`, `_projectedProtectedQuotaBps` (`GlobalUnlockController`) and
`_projectedMaxEmissionPerEpoch` (`EcosystemEmissionController`). All public capacity views are
routed through them.

Because `consumeAllowance()` and `_emit()` compute their enforced cap via these same public
views, the view and the next state-changing call now agree unconditionally, in both directions
and for same-period governance commits.

**Side effect — previously accepted limitation KL-2 is now resolved.** A dormancy gap longer
than `MAX_CATCHUP_PERIODS` combined with a staged cap change could previously let the first
`consumeAllowance()` after the gap grant at the stale pre-rollover cap. The shared projection
enforces the correct cap immediately, so `releasedInPeriod(p) <= maxUnlockForPeriod(p)` now
holds unconditionally. `audit/KnownLimitations.md` §KL-2 has been updated from ACCEPTED to
FIXED accordingly.

**Verification.**

```bash
forge test --match-test "test_MULTYR2_"    # 6 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR2_globalUnlockViewReflectsPendingCapDecrease` | View shows a due cap decrease before the first consume; first write grants exactly what the view showed |
| `test_MULTYR2_globalUnlockViewReflectsPendingCapIncrease` | Same in the increase direction |
| `test_MULTYR2_globalUnlockViewSamePeriodReferenceSupplyNotProjectedEarly` | A same-period commit is *not* projected early, and becomes due exactly one period later |
| `test_MULTYR2_globalUnlockViewSourceAllowanceReflectsPendingProtectedQuota` | Shared-lane quote reflects the due protected-quota change |
| `test_MULTYR2_ecosystemViewReflectsPendingCapDecrease` | `availableThisEpoch()` reflects a due epoch-cap decrease |
| `test_MULTYR2_ecosystemViewReflectsPendingCapIncrease` | Same in the increase direction |

KL-2 regression coverage:

```bash
forge test --match-test "test_noStaleCapOverReleaseAfterLargeGap|test_catchupBoundary_projectedCapPreventsOverRelease"
```

---

### MULTYR-3 — Source allowance view omits authorization and genesis preconditions

**Severity:** Low &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `c7045c6`

**Issue.** `remainingAllowanceForSource(source)` computed lane capacity without mirroring two
preconditions that `consumeAllowance()` enforces before granting anything. An unauthorized
address received a positive quote even though its corresponding call always reverts
`UnauthorizedSource`; before genesis, an authorized protected source received a full-cap quote
while both the aggregate view and `consumeAllowance()` itself returned 0.

**Resolution.** The view now returns 0 for either precondition before computing any
lane-specific quote:

```solidity
// src/GlobalUnlockController.sol — remainingAllowanceForSource()
if (!authorizedSource[source]) return 0;
if (block.timestamp < genesisTimestamp) return 0;
```

**Verification.**

```bash
forge test --match-test "test_MULTYR3_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR3_unauthorizedSourceGetsZeroAllowanceView` | View returns 0 *and* the corresponding `consumeAllowance` reverts `UnauthorizedSource` |
| `test_MULTYR3_preGenesisAuthorizedSourceGetsZeroAllowanceView` | Pre-genesis, the source view, the aggregate view and `consumeAllowance` all return 0 |

---

### MULTYR-4 — Registry returns the former beneficiary after reassignment

**Severity:** Low &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `7612241`

**Issue.** `VestingWalletLinear` supports a delayed two-phase beneficiary reassignment, but
confirmation updated only the wallet's own `beneficiary` storage. The corresponding
`VestingManager.VestingRecord.beneficiary` was never synchronized, so the manager's on-chain
registry permanently reported the grant's creation-time beneficiary. The same gap affected
`VestingRecord.active`: `recordRevocation()` performed bucket-cap accounting but never cleared
the flag, so a fully revoked grant was reported as active indefinitely.

**Resolution.** An authenticated `recordBeneficiaryUpdate(wallet, newBeneficiary)` callback was
added to `VestingManager`, mirroring `recordRevocation`'s existing authentication (only the
registered wallet itself may call). `confirmBeneficiaryUpdate()` invokes it immediately after
updating its own state. `recordRevocation()` now also sets `record.active = false`.

Neither field carries any internal logic dependency elsewhere in the codebase, so this is a
registry-accuracy fix with no change to claim, revoke or pause enforcement.

**Verification.**

```bash
forge test --match-test "test_MULTYR4_"    # 3 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR4_BeneficiaryReassignmentSyncsToManagerRegistry` | Registry reflects the new beneficiary after a full two-phase reassignment |
| `test_MULTYR4_RevocationSyncsActiveFlagInManagerRegistry` | `active` flips to false on a completed revocation |
| `test_MULTYR4_RecordBeneficiaryUpdateRejectsNonWalletCaller` | The callback rejects any caller that is not the registered wallet |

---

### MULTYR-5 — Late lockers immediately vest and exhaust the release cap

**Severity:** Medium &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `24e1388`

**Issue.** `lockPreTokens()` bounded its deadline at `fullVestingEnd()` (cliff plus full vesting
duration). Because vesting is anchored to the global TGE timestamp rather than to the lock
timestamp, a holder could lock at any point up to that bound and inherit retroactive vesting
credit for time they never waited through. A late locker could therefore claim a near-full
entitlement immediately and, via the protected-source lane in `GlobalUnlockController`,
monopolize the shared per-period release cap and starve other beneficiaries.

**Resolution.** The lock window now closes at the start of the cliff:

```solidity
// src/PreMTRYClaim.sol — lockPreTokens()
if (tgeTimestamp != 0 && block.timestamp >= tgeTimestamp + CLIFF_DURATION) {
    revert LockDeadlineExpired();
}
```

`_vestedAmount()` returns 0 for any timestamp before `tgeTimestamp + CLIFF_DURATION`, and the
guard uses `>=`, so no accepted lock can ever be worth more than 0 at the instant it lands. The
retroactive-credit primitive is removed at its root rather than throttled downstream. Legitimate
pre-cliff locking is unaffected: a holder who locks before the cliff still receives the full 1:4
entitlement vested over the normal schedule.

**Verification.**

```bash
forge test --match-test "test_MULTYR5_"    # 3 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR5_LateLockDrainsCapAndBlocksSharedVesting` | The reported drain scenario is rejected; no entitlement is created and the shared cap is untouched |
| `test_MULTYR5_LateWhaleBlocksAnotherClaimHolder` | The whale-versus-small-holder starvation scenario is rejected for both holders; the protected lane is untouched |
| `test_MULTYR5_OnTimeLockerStillReceivesFullEntitlementOverSchedule` | Non-regression: an on-time locker still receives the full entitlement over the normal schedule |

Additional coverage of the underlying mechanism is in
`test/poc/POC01_LateLockRetroactiveVesting.t.sol`.

---

### MULTYR-6 — Immutable guardian can indefinitely freeze non-revocable grants

**Severity:** Low &nbsp;|&nbsp; **Status:** Fixed &nbsp;|&nbsp; **Commit:** `f886b31`

**Issue.** `VestingWalletLinear` stored its guardian as an immutable constructor value, set once
by `VestingManager` from a second, separate immutable. `VestingManager.setGuardian()` rotated
the manager's own mutable guardian but never reached already-deployed wallets: a rotated-out
(for example, compromised) guardian retained permanent pause authority over every wallet it was
originally assigned to, while the rotated-in guardian could not pause them at all. For
non-revocable grants `emergencyRevokeUnvested()` is unavailable, leaving governance with no path
to migrate the locked position.

**Resolution.** The immutable field was removed in favour of dynamic resolution, mirroring the
existing `revoker()` → `owner()` pattern:

```solidity
// src/VestingWalletLinear.sol
function guardian() public view returns (address) {
    return IVestingManager(vestingManager).guardian();
}
```

`VestingManager`'s redundant `vestingGuardian` immutable and its constructor parameter were
removed entirely, so the manager's own mutable guardian is the single source of truth propagated
to every wallet. A `setGuardian()` rotation now takes effect immediately for already-deployed
wallets.

**Operational note.** Because the wallet no longer receives a guardian at construction, the
guardian must be set on `VestingManager` before the first `createVesting()` call. This is
recorded as a pre-launch checklist item.

**Verification.**

```bash
forge test --match-test "test_MULTYR6_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_MULTYR6_GuardianRotationPropagatesToNonRevocableWallet` | The report's non-revocable scenario end to end: rotation propagates, the old guardian is locked out, the new guardian gains control, claims resume after unpause |
| `test_MULTYR6_GuardianRotationPropagatesToRevocableWallet` | The same resolution path on a revocable grant |

Additional coverage: `test_WalletGuardianFollowsManagerRotation` in
`test/GovernanceSeparation.t.sol`.

---

### MULTYR-8 — Informational (I-1 … I-6)

**Severity:** Informational &nbsp;|&nbsp; **Commits:** `1fd65ec`, `2193346`

Four sub-findings received code fixes, one a reporting-level mitigation, and one is accepted as
intended behaviour with formal documentation.

A post-merge self-review of this branch found that the initial fixes for I-1 and I-3 each left a
residual gap of their own. Both were reproduced with proof-of-concept tests and closed in commit
`2193346`; they are described in the relevant sub-sections below.

```bash
forge test --match-path "test/audit/InformationalFindings.t.sol"    # 12 passed
```

---

#### I-1 — Counterfactual beneficiary bypasses the contract whitelist

**Status:** Fixed &nbsp;|&nbsp; **Commits:** `1fd65ec`, `2193346`

**Issue.** The code-size checks in the beneficiary-update flow classified a counterfactual
(CREATE2) address as an EOA, because it holds no code at propose/confirm time. Code could then be
deployed to that address afterwards, leaving an unwhitelisted contract as the confirmed
beneficiary.

**Resolution (`1fd65ec`).** `_claim()` re-checks the whitelist against the live beneficiary code,
so code deployed after confirmation is still caught. The check is placed in `_claim()` and
therefore gates both `claim()` and `claimTo()`. As a side benefit it also re-enforces a
governance de-whitelist applied after a contract beneficiary was already confirmed.

**Residual gap and final resolution (`2193346`).** A `code.length` test alone remains bypassable
by a contract calling from its own constructor: `EXTCODESIZE(address(this))` reads 0 until
construction completes, although the caller is unambiguously a contract. This was reproduced —
a contract deployed at the previously confirmed CREATE2 address claimed real tokens from its
constructor. Because only a genuine EOA can be both `msg.sender` and `tx.origin`, the check now
requires both signals before treating a beneficiary as EOA-exempt:

```solidity
// src/VestingWalletLinear.sol — _claim()
if (beneficiary.code.length > 0 || beneficiary != tx.origin) {
    if (!IVestingManager(vestingManager).isWhitelistedBeneficiaryContract(beneficiary)) {
        revert InvalidBeneficiaryContract();
    }
}
```

The same defence was added to `confirmBeneficiaryUpdate()` for the case where the pending
beneficiary confirms on its own behalf.

**Verification.**

```bash
forge test --match-test "test_I1_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_I1_CounterfactualBeneficiaryBypassesContractWhitelist` | Code deployed to a confirmed counterfactual address is rejected at claim time |
| `test_I1_ConstructorCallBypassesCodeLengthCheck` | The constructor-call bypass is rejected; no tokens are released |

---

#### I-2 — Unbounded TGE timestamps

**Status:** Fixed &nbsp;|&nbsp; **Commit:** `1fd65ec`

**Issue.** Neither `setTGE()` function bounded its timestamp from above, so an extreme value
could push the claim and vesting lifecycles beyond any reachable horizon.

**Resolution.** Both `PreMTRYClaim.setTGE()` and `VestingManager.setTGE()` now reject timestamps
more than 3650 days in the future, matching the bound already applied in the
`GlobalUnlockController` and `EcosystemEmissionController` constructors:

```solidity
if (tgeTimestamp_ > block.timestamp + 3650 days) revert InvalidTimestamp();
```

**Verification.**

```bash
forge test --match-test "test_I2_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_I2_ExtremeTgeBricksClaimLifecycle` | `PreMTRYClaim.setTGE(type(uint256).max)` reverts `InvalidTimestamp` |
| `test_I2_ExtremeTgeBricksFundedTgeModeWallet` | `VestingManager.setTGE(type(uint256).max)` reverts `InvalidTimestamp` |

---

#### I-3 — Skippable pending-value commits

**Status:** Fixed &nbsp;|&nbsp; **Commits:** `1fd65ec`, `2193346`

**Issue.** Pending values occupy a single storage slot. If a value became due for a period or
epoch that had not yet been physically rolled, a second commit in that same unrolled window
overwrote the slot before the first value was ever promoted, silently discarding a scheduled cap
change.

**Resolution (`1fd65ec`).** Every pending-value setter and canceller now rolls the current
period/epoch before writing the slot, so an already-due value is promoted to storage first. All
eight entry points are covered: `setPendingUnlockCapBps`, `cancelPendingUnlockCap`,
`setPendingProtectedQuotaBps`, `cancelPendingProtectedQuotaBps`, `setReferenceSupply`,
`cancelPendingReferenceSupply`, `setPendingMaxEmissionPerEpoch`, `cancelPendingMaxEmission`.

**Residual gap and final resolution (`2193346`).** `GlobalUnlockController._rollPeriodIfNeeded`
is internally bounded by `MAX_CATCHUP_PERIODS`, but `EcosystemEmissionController._rollEpochIfNeeded`
has no bound of its own — it never required one, because its only previous caller (`_emit`) guards
`epoch < MAX_EPOCHS` first. The new setter calls did not carry that guard. A single governance call
made long after the emission horizon was measured at 14.6M gas after a 600-epoch gap, scaling with
no ceiling. A capped variant now clamps the roll at `MAX_EPOCHS - 1`; nothing remains to roll for
epochs in which emission can never occur, so the cap is free.

**Verification.**

```bash
forge test --match-test "test_I3_"    # 3 passed
```

| Test | Asserts |
|------|---------|
| `test_I3_PendingUnlockCapCommittedForNextPeriodCanBeSkipped` | The first pending cap is promoted into `capBpsByPeriod` rather than overwritten |
| `test_I3_PendingEmissionCapCommittedForNextEpochCanBeSkipped` | Same for `maxEmissionByEpoch` |
| `test_I3_EpochRollIsBoundedPastEmissionHorizon` | A setter called after a 600-epoch gap stays bounded and caps at `MAX_EPOCHS - 1` |

---

#### I-4 — Bucket accounting overstates fundable headroom

**Status:** Mitigated &nbsp;|&nbsp; **Commit:** `1fd65ec`

**Issue.** `getBucketRemaining()` reports nominal bucket cap headroom. A revocation frees that
nominal capacity without returning the tokens to the manager — they are sent to `treasury` — and
a manager-level burn does not reduce any bucket's reported remaining cap either. Reported
headroom can therefore exceed what a `createVesting` call could actually fund.

**Resolution.** A dedicated view bounds nominal headroom by the manager's live token balance:

```solidity
// src/VestingManager.sol
function fundableBucketRemaining(BucketType bucket) external view returns (uint256) {
    uint256 nominal = _bucketRemaining(bucket);
    uint256 balance = IERC20(token).balanceOf(address(this));
    return nominal < balance ? nominal : balance;
}
```

This is classified as **mitigated rather than fixed** because it is a reporting-accuracy addition,
not a change to fund flow. `getBucketRemaining()` retains its existing nominal-headroom semantics
so that existing integrations are not silently altered, and grant creation was never at risk:
`_fundAndVerify` already reverts on an underfunded wallet.

**Verification.**

```bash
forge test --match-test "test_I4_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_I4_RevocationFreesBucketCapWithoutReturningFundingToManager` | Nominal headroom is restored while fundable headroom correctly reports 0 |
| `test_I4_ManagerBurnCreatesUnfundedBucketHeadroom` | Fundable headroom tracks the reduced balance, and funding the full nominal headroom reverts |

---

#### I-5 — Revocation recovery bypasses the unlock cap and burn-delay lifecycle

**Status:** Accepted — documented as KL-9 &nbsp;|&nbsp; **Commit:** `1fd65ec` (documentation only)

**Issue.** `revokeUnvested()` and `emergencyRevokeUnvested()` transfer unvested MTRY directly to
`treasury` without consuming `GlobalUnlockController` allowance and without passing through the
`proposeBurn` / `executeBurn` timelock used by other recovery paths.

**Rationale for acceptance.** The unlock cap governs programmatic, beneficiary-facing releases —
claim, vesting and emission — where an external party draws down a shared per-period budget.
Revocation is a governance-initiated recovery of tokens that were never claimed by, and are no
longer owed to, a beneficiary; the tokens remain protocol-owned and move between two
protocol-controlled addresses. Routing every revocation through the shared cap and a multi-day
delay would materially slow a routine governance action with no fund-safety benefit.

This is recorded in `audit/KnownLimitations.md` §KL-9, including the residual-risk assessment.
No code change was made; the test below pins the intended behaviour so that any future
divergence is caught.

**Verification.**

```bash
forge test --match-test "test_I5_"    # 1 passed
```

| Test | Asserts |
|------|---------|
| `test_I5_RevokeMovesUnvestedReserveToTreasuryWithoutUnlockOrBurnDelay` | The transfer completes and consumes no unlock allowance, as intended |

---

#### I-6 — Renounceable ownership

**Status:** Fixed &nbsp;|&nbsp; **Commit:** `1fd65ec`

**Issue.** Ownership could be renounced on every ownable contract in the stack. Combined with a
paused controller this created a permanent freeze: with no owner, no account could ever unpause
or rotate the Guardian and Veto roles again. On `PreMTRYToken` the equivalent hazard applied to
the sale and claim bindings, which are owner-only until finalized.

**Resolution.** `renounceOwnership()` is permanently disabled and reverts
`RenounceOwnershipDisabled`. Ownership can leave only through a two-step transfer to a named
successor. Coverage is complete across the stack:

- `GovernanceRoles` — inherited by `PreMTRYSale`, `PreMTRYClaim`, `VestingManager`,
  `GlobalUnlockController` and `EcosystemEmissionController`
- `PreMTRYToken` — a separate override, as it extends `Ownable2Step` directly

`MTRYToken` and `VestingWalletLinear` are not ownable and require no change.

**Verification.**

```bash
forge test --match-test "test_I6_"    # 2 passed
```

| Test | Asserts |
|------|---------|
| `test_I6_ControllerPausePlusRenouncedOwnershipMakesReleaseFreezePermanent` | On a paused `GlobalUnlockController`, renounce reverts, ownership survives, and unpause remains possible |
| `test_I6_PreTokenRenouncedOwnershipStrandsUnfinalizedBindings` | On `PreMTRYToken` with unfinalized bindings, renounce reverts, ownership survives, and the owner can still finalize |

---

## 4. Reproducing the verification

```bash
git clone https://github.com/hackenproof-public/MTRY && cd MTRY
git checkout mtry-token-remediation-v1
forge install

# Full suite
forge test
# Expected: 561 passed, 0 failed

# Per-finding regression tests
forge test --match-test "test_MULTYR1_"    # 4 passed
forge test --match-test "test_MULTYR2_"    # 6 passed
forge test --match-test "test_MULTYR3_"    # 2 passed
forge test --match-test "test_MULTYR4_"    # 3 passed
forge test --match-test "test_MULTYR5_"    # 3 passed
forge test --match-test "test_MULTYR6_"    # 2 passed
forge test --match-test "test_I1_"         # 2 passed
forge test --match-test "test_I2_"         # 2 passed
forge test --match-test "test_I3_"         # 3 passed
forge test --match-test "test_I4_"         # 2 passed
forge test --match-test "test_I5_"         # 1 passed
forge test --match-test "test_I6_"         # 2 passed

# All finding regression tests in one run
forge test --match-path "test/audit/*"

# Symbolic proofs (Python 3.11+; AST output is preconfigured in foundry.toml)
pip install halmos==0.3.3
halmos --match-contract "Symbolic"
# Expected: 27 / 27 pass
```

Note on Halmos path counts: two proofs (`check_threeCallsStayUnderCap` and
`check_twoBuyersBoundedByHardCap`) do not report a stable path count across repeated runs on
identical code. All 27 proofs pass in every run. See `audit/FormalVerification.md` for the
observed ranges and `audit/evidence/halmos_output.log` for raw tool output.

---

## 5. Supporting documentation

| Document | Contents |
|----------|----------|
| `audit/README.md` | Audit package index and reproduction instructions |
| `audit/TestReport.md` | Test counts, coverage table, static analysis results |
| `audit/FormalVerification.md` | Halmos symbolic proof results and per-proof invariants |
| `audit/evidence/halmos_output.log` | Raw Halmos output |
| `audit/KnownLimitations.md` | Accepted limitations, including KL-2 (now fixed) and KL-9 (I-5) |
| `audit/Invariants.md` | System invariants and their enforcement points |
| `audit/ThreatModel.md` | Threat model and cross-check against findings |
| `docs/DEPLOY_FLOW.md` | Deployment sequence, including the MULTYR-1 TGE precondition |
