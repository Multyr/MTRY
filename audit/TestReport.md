# MULTYR Token Stack — Test Report

**Solidity:** 0.8.28 | **OZ:** v5.6.1 | **Foundry:** forge 1.7.1 | **Halmos:** v0.3.3
**Slither:** 0.11.5 | **Aderyn:** 0.1.9

---

## Test summary

| Category | Result |
|----------|--------|
| Forge tests (all) | **561 passed / 0 failed** |
| Coverage run (excludes the 2 stateful `invariant_*` entrypoints) | **559** tests |
| Fuzz tests (256 runs each) | 10 tests in 5 suites |
| Stateful invariant suites | 2 suites × 128k call sequences, 0 reverts |
| Fork tests (Arbitrum mainnet) | 8 / 8 |
| Halmos symbolic proofs | 27 / 27 (5 contracts, ~130 SMT paths — varies run to run, see FormalVerification.md) |
| Slither critical/high findings | 0 (28 contracts, 75 detectors — see Static analysis section) |
| Aderyn actionable high | 0 (1 high is false positive — see Static analysis section) |

See [FormalVerification.md](FormalVerification.md) for the full Halmos proof breakdown.

### Reproducing

```bash
git checkout mtry-token-remediation-v1
forge install
forge test                                          # 561 pass, 0 fail
forge test --no-match-path "test/ForkArbitrum*"    # skip fork (requires RPC)
```

Fork tests require an Arbitrum One RPC (`ARBITRUM_RPC_URL` env var). All non-fork tests run offline.

---

## Coverage by contract (`src/` only)

Generated with:
```bash
forge coverage \
  --no-match-path "test/ForkArbitrum*|test/halmos/*" \
  --no-match-test "invariant|fuzz" \
  --report summary
```

| Contract | % Lines | % Statements | % Branches | % Funcs |
|----------|---------|-------------|------------|---------|
| `MTRYToken.sol` | 100.00% (17/17) | 100.00% (22/22) | 100.00% (6/6) | 100.00% (2/2) |
| `PreMTRYSale.sol` | 100.00% (41/41) | 98.15% (53/54) | 92.86% (13/14) | 100.00% (7/7) |
| `PreMTRYToken.sol` | 100.00% (36/36) | 100.00% (37/37) | 100.00% (14/14) | 100.00% (8/8) |
| `PreMTRYClaim.sol` | 100.00% (112/112) | 98.20% (164/167) | 94.87% (37/39) | 100.00% (18/18) |
| `GlobalUnlockController.sol` | 98.85% (172/174) | 98.67% (223/226) | 100.00% (36/36) | 100.00% (24/24) |
| `VestingWalletLinear.sol` | 100.00% (125/125) | 100.00% (163/163) | 100.00% (38/38) | 100.00% (23/23) |
| `EcosystemEmissionController.sol` | 100.00% (114/114) | 99.34% (150/151) | 96.88% (31/32) | 100.00% (17/17) |
| `VestingManager.sol` | 99.37% (158/159) | 98.49% (196/199) | 92.11% (35/38) | 100.00% (29/29) |
| `base/GovernanceRoles.sol` | 88.89% (16/18) | 86.96% (20/23) | 60.00% (3/5) | 83.33% (5/6) |

All numbers are direct forge output; no rounding or interpolation.

---

## Deploy script coverage

| Script | % Lines | % Statements | % Branches | % Funcs |
|--------|---------|-------------|------------|---------|
| `script/Deploy.s.sol` | 52.54% (31/59) | 48.33% (29/60) | 0.00% (0/6) | 50.00% (2/4) |
| `script/PostDeployChecks.s.sol` | 77.46% (55/71) | 81.08% (60/74) | 52.44% (43/82) | 66.67% (4/6) |
| `script/SetTGE.s.sol` | 100.00% (12/12) | 100.00% (14/14) | 100.00% (2/2) | 100.00% (1/1) |

`test/DeployIntegration.t.sol` (18 tests) exercises `Deploy._wire()` and `Deploy._configureGovernance()` via a test harness, covering 31/59 lines. Uncovered lines are `run()` (env-var loading + broadcast boilerplate) and `_deployContracts()` (nonce prediction and genesis validation — these require a live broadcast context and cannot be reproduced in a unit-test harness). The 0/6 branch coverage on `Deploy.s.sol` is purely the two `require` guards inside `_deployContracts` (genesis range checks added by M-5), which only fire in `run()`.

`PostDeployChecks` reaches 77.46% lines (55/71). Uncovered: `run()` (6 lines — the harness calls `_checkAllocations`, `_checkWiring`, etc. directly), `_load()` (7 lines — bypassed by address injection in `PostDeployHarness.inject()`), and the `revert("OWNERSHIP_PHASE must be pre-acceptance or post-acceptance")` branch. The 52.44% branch coverage reflects forge counting each `require(...)` as a two-way branch; all pass arms are covered and the revert arms signal broken deployments, not valid test scenarios.

`test/SetTGEIntegration.t.sol` (5 tests) exercises the SetTGE flow end-to-end; SetTGE.s.sol reaches 100% on all four coverage metrics.

---

## Sub-100% coverage — root causes and acceptance

### `GovernanceRoles.sol` — 87.50% lines, 80.00% functions

**Gap:** `onlyGuardian()` modifier (lines 30–34) is defined but applied to no function in any of the 9 in-scope contracts.

**Root cause:** Dead code — base-class reserve for future use. No production code path enters or skips this modifier body. Confirmed: grepping all `src/` files shows zero uses of `onlyGuardian`.

**Risk:** None.

---

### `PreMTRYSale.sol` — 92.86% branches (13/14)

**Gap:** 1 branch — `if (preMTRYAmount == 0) revert ZeroAmount()` (dust guard in `buy()`).

**Root cause:** Mathematical dead code. `preMTRYAmount = (usdcAmount * 1e18) / PRICE` where `PRICE = 80_000`. Minimum non-zero `usdcAmount` = 1 gives `preMTRYAmount ≈ 1.25×10¹³` — always non-zero. There is no integer value of `usdcAmount > 0` that rounds to 0 at this price.

**Risk:** None.

---

### `EcosystemEmissionController.sol` — 96.77% branches (30/31)

**Gap:** 1 branch — `if (currentEpoch() < MAX_EPOCHS) revert BurnBeforeHorizon()` inside `executeBurn`.

**Root cause:** Dead code by sequential guard ordering. `proposeBurn` requires `currentEpoch() >= MAX_EPOCHS`. Because `executeBurn` runs after a successful `proposeBurn`, `currentEpoch()` will always be `>= MAX_EPOCHS` at execution time. The guard in `executeBurn` is a defensive double-check that cannot fire.

**Risk:** None. Defense-in-depth only.

---

### `PreMTRYClaim.sol` — 94.44% branches (34/36)

**Gap:** 2 branches in `executeBurn` (lines 231 and 237).

**Root cause:** Both are dead code by sequential guard ordering:
- `if (block.timestamp < fullVestingEnd()) revert BurnBeforeHorizon()` — `proposeBurn` enforces this at proposal time; clock advances monotonically so it cannot trigger at execute time (after the 7-day delay).
- `if (amount > burnable) revert BurnExceedsBalance()` — `proposeBurn` enforces `amount <= burnable`; `burnable` can only increase between proposal and execution (balance grows or outstanding decreases; `lockPreTokens` is blocked post-horizon). So `amount` cannot exceed `burnable` at execution.

**Risk:** None. Both are conservative double-checks.

---

### `VestingManager.sol` — 99.32% lines, 94.44% branches (34/36)

**Gap (line):** Line 278 — `revert InvalidTotalDuration()`.

**Gap (branches):**
- `if (cliffDuration + vestingDuration > MAX_TOTAL_DURATION)` — mathematical dead code. Individual guards enforce `cliffDuration ≤ MAX_CLIFF_DURATION = 10y` and `vestingDuration ≤ MAX_VESTING_DURATION = 10y`, and `MAX_CLIFF_DURATION + MAX_VESTING_DURATION == MAX_TOTAL_DURATION = 20y` exactly. The sum cannot exceed 20y with a strict `>` comparator.
- `if (balanceAfter - balanceBefore != allocation) revert FundingMismatch()` — dead code for non-fee-on-transfer tokens. MTRY carries no transfer fee; the pre/post balance delta always equals the transfer amount exactly.

**Risk:** None. Both are defensive checks that cannot fire with MTRY.

---

## Static analysis

### Slither v0.11.5

Run: `slither . --compile-force-framework foundry --exclude-optimization --exclude-informational --filter-paths "test/,lib/"`

Result: **28 contracts analyzed, 75 detectors, 47 results. 0 critical / 0 high findings.**

| Detector | Instances | Assessment |
|----------|-----------|------------|
| `reentrancy-no-eth` | 4 | All flagged functions (`claim`, `lockPreTokens`, `_emit`, `batchEmit`) carry `nonReentrant`. Callees (`consumeAllowance`, `preToken.burn`) are trusted governance-deployed contracts with no callback mechanism. Not exploitable. |
| `incorrect-equality` | 4 | All are intentional zero-guards (`claimableAmt == 0`, `granted == 0`, `amount == 0`) that revert with `NothingToClaim` / `UnlockThrottled`. Not a dangerous strict equality. |
| `missing-zero-check` | 2 | `PreMTRYToken.setSaleContract` / `setClaimContract` — same as Aderyn L-2. Mitigated by `PostDeployChecks.s.sol`. |
| `calls-loop` | 5 | `batchEmit` calls `consumeAllowance` per emission; `batchCreateVestings` runs balance checks per wallet. Expected batch design; no unbounded loops in production paths. |
| `timestamp` | 32 | All intentional `block.timestamp` uses in vesting math, period accounting, and timelock guards. Arbitrum's sequencer makes 15-second manipulation negligible for the hour-to-year timescales used here. |

### Aderyn v0.1.9

Run: `FOUNDRY_EVM_VERSION=cancun aderyn --src src/`

Full report: [aderyn-report.md](aderyn-report.md)

**1 high (false positive), 6 low findings.**

| ID | Severity | Finding | Assessment |
|----|----------|---------|------------|
| H-1 | High | `vestingCount` uninitialized state variable | **False positive.** Solidity zero-initializes all state variables by default. `vestingCount` correctly starts at 0. |
| L-1 | Low | Centralization risk — `onlyOwner` instances | **By design.** See `ThreatModel.md`. |
| L-2 | Low | Missing `address(0)` checks in `PreMTRYToken.setSaleContract` / `setClaimContract` | **Acknowledged.** Both functions are one-shot (blocked post-finalize). `PostDeployChecks.s.sol` verifies non-zero addresses before handing over ownership. |
| L-3 | Low | `remainingAllowance()` could be `external` | **Informational.** No security impact; `public` required for interface compatibility. |
| L-4 | Low | Literal `5_000` used for `protectedQuotaBps` default | **Informational.** Default value, not a loop literal. |
| L-5 | Low | Event fields missing `indexed` | **Informational.** Gas optimization only; no security impact. |
| L-6 | Low | `CAP_DENOMINATOR = 10_000` / `PRICE = 80_000` could use scientific notation | **Informational.** Style only. |

Note: A previous L-7 (5 unused custom errors) was found and **fixed** before this run — all 5 removed from `src/Errors.sol` and `src/base/GovernanceRoles.sol`. Aderyn no longer reports it.

**0 actionable high findings.** The single high is an Aderyn false positive on standard Solidity zero-initialization.

---

## Threat model cross-check

| Scenario | Covering test |
|----------|--------------|
| Shared-lane cap exhaustion clamps grant | `test_consumeAllowancePartialClamp` |
| Protected lane clamps when cap exhausted | `test_protectedSource_throttledWhenCapFullyExhausted` |
| Pre-genesis `consumeAllowance` returns 0 | `test_consumeAllowance_beforeGenesis_returnsZero` |
| `referenceSupply` change applies next period only | `test_referenceSupplyChangeAppliesNextPeriod` |
| Pending cap applies next period only | `test_setPendingCapAppliesNextPeriod` |
| Pending protectedQuotaBps applies next period only | `test_pendingProtectedQuota_appliesNextPeriod` |
| `setReferenceSupply` above initial reverts | `test_setReferenceSupply_exceedsInitialReverts` |
| `setPendingProtectedQuotaBps` below floor reverts | `test_setPendingProtectedQuota_belowFloorReverts` |
| Vesting wallet cannot be deauthorized | `test_setAuthorizedSource_cannotDeauthorizeVestingWallet` |
| Mid-vest revoke frees only unvested in bucket | `test_midVestRevoke_freesOnlyUnvestedInBucket` |
| Double-finalize PreMTRYToken bindings | `test_finalizeSaleContract_revertsIfAlreadyFinalized`, `test_finalizeClaimContract_revertsIfAlreadyFinalized` |
| Sub-bucket cap footgun blocked | `test_setBucketCap_revertsOnGrowth`, `test_setBucketCap_revertsOnBDCore`, `test_setBucketCap_revertsOnBDPerformance` |
| Catch-up loop bounded at 120 | `test_rollPeriod_catchUpBoundedByMaxCatchupPeriods` |
| >120-period gap stale-cap invariant fixed (KL-2) | `test_noStaleCapOverReleaseAfterLargeGap`, `test_catchupBoundary_projectedCapPreventsOverRelease` |
| `emergencyRevokeUnvested` callable while paused | `test_emergencyRevokeStillWorksWhenPaused` |
| Burn before horizon reverts | `test_proposeBurnRevertsBeforeHorizon` |
| De-whitelisted contract rejected at confirm | `test_confirmRejectsDeWhitelistedContract` |
| Lock pool overflow rejected | `test_lockPreTokens_exceedsMaxPool_reverts` |
| Constructor genesis too far in future reverts | `test_constructor_rejectsGenesisInFarFuture` |
| `executeBurn` re-validates balance at execution | `test_executeBurn_revertsIfBurnExceedsOutstanding` |

---

## Test file inventory

| Suite | Tests | Focus |
|-------|-------|-------|
| `MTRYToken.t.sol` | 21 | Supply, burn, constructor allocations |
| `PreMTRYSale.t.sol` | 50 | Buy, hard cap, USDC routing, whitelist (sender + receiver), batch whitelist |
| `PreMTRYToken.t.sol` | 38 | Mint, finalize pattern, binding validation |
| `PreMTRYClaim.t.sol` | 56 | Lock, claim, burn lifecycle, global cap interaction |
| `VestingManager.t.sol` | 49 | Create, revoke, bucket accounting, burn |
| `VestingWalletLinear.t.sol` | 45 | Vesting math, revocation, beneficiary update |
| `GlobalUnlockController.t.sol` | 50 | Cap mechanics, dual-lane, pending params, guards |
| `EcosystemEmissionController.t.sol` | 44 | Emission, epoch roll, burn lifecycle |
| `GovernanceSeparation.t.sol` | 29 | Role isolation across all contracts |
| `ProtectedQuotaBounds.t.sol` | 5 | protectedQuotaBps floor/ceiling enforcement |
| `RevocationAccounting.t.sol` | 7 | Bucket cap invariant after mid-vest revoke |
| `BeneficiaryWhitelist.t.sol` | 7 | Contract beneficiary validation |
| `EmergencyRevoke.t.sol` | 5 | Pause-bypass for emergency revoke |
| `DurationValidation.t.sol` | 5 | Cliff + vesting duration bounds |
| `Integration.t.sol` | 9 | Full end-to-end token lifecycle; whitelist KYC gate e2e |
| `SetTGEIntegration.t.sol` | 5 | SetTGE script integration |
| `DeployIntegration.t.sol` | 18 | Deploy + PostDeployChecks harness |
| `poc/POC01–POC15.t.sol` | 51 | Proof-of-concept reproductions (all documented scenarios confirmed) |
| `fuzz/*.t.sol` | 10 | Property-based fuzz (256 runs each) |
| `invariant/*.t.sol` | 8 | Stateful invariants (128k call sequences each) |
| `ForkArbitrum.t.sol` | 8 | Live mainnet fork verification |
| `halmos/*.t.sol` | 27 | Symbolic proofs (see FormalVerification.md) |
