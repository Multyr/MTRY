# MULTYR Token Stack — Formal Verification (Halmos)

**Tool:** Halmos 0.3.3 (symbolic execution + SMT, by a16z crypto)
**Solver:** z3 4.12.6 (default backend)
**Status:** 27 / 27 proofs pass
**Last executed against:** tag `mtry-token-remediation-v1`, Python 3.11.15. The run itself was
executed at commit `2193346`; the tagged tree carries an identical `src/` and `test/halmos/`
(later commits are documentation and test-naming only), so these results apply unchanged.
**Requires:** Python 3.11+ (`pip install halmos==0.3.3`); `forge build` (AST output is now baked into `foundry.toml`, see Reproducing below)

**Note on path counts:** `check_threeCallsStayUnderCap` (GlobalUnlockController) does not report a stable path count across repeated runs — observed 22 through 28 across six runs of this exact suite against equivalent code, all still 100% pass. `check_twoBuyersBoundedByHardCap` (PreMTRYSale) was stable at 19 in five of six runs, but read 18 once. Every other proof's path count was identical across all runs. The counts below are from one representative run (raw output committed at `audit/evidence/halmos_output.log`); treat any total that includes these two figures as illustrative, not exact.

---

## What Halmos proves

Halmos treats function parameters as symbolic values (not concrete numbers) and asks the SMT solver whether an assertion holds for all possible inputs within the stated bounds. A passing test is a mathematical proof that no input in the bounded domain violates the property — unlike fuzz testing, which samples from that domain.

---

## Suite summary

| Contract | Tests | SMT paths | Result |
|----------|-------|-----------|--------|
| `GlobalUnlockController` | 6 | 45 (varies 42-48, see note above) | ✅ all pass |
| `VestingWalletLinear` | 6 | 23 | ✅ all pass |
| `VestingManager` | 5 | 16 | ✅ all pass |
| `EcosystemEmissionController` | 5 | 14 | ✅ all pass |
| `PreMTRYSale` | 5 | 32 (occasionally 31, see note above) | ✅ all pass |
| **Total** | **27** | **~130 (varies ~127-131)** | **✅ 27 / 27** |

Total solver time: ~1 s (this run).

---

## Proofs

### GlobalUnlockController

| Invariant | Paths | Meaning |
|-----------|-------|---------|
| `check_totalReleasedNeverExceedsCap` | 6 | Shared + protected release ≤ per-period cap |
| `check_sharedLaneBoundedByReservedQuota` | 3 | Shared sources never access the protected reserve |
| `check_protectedLaneBoundedByFullCap` | 3 | Protected sources bounded by `cap − totalUsed` |
| `check_unauthorizedSourceNeverReleases` | 3 | Unauthorized callers never increment any release counter |
| `check_grantedLeqRequested` | 3 | `granted ≤ amount` always |
| `check_threeCallsStayUnderCap` | 27 (varies 22-28 run to run) | 3-call interleaving stays within cap |

### VestingWalletLinear

| Invariant | Paths | Meaning |
|-----------|-------|---------|
| `check_claimedNeverExceedsAllocation` | 6 | `claimedAmount ≤ totalAllocation` under arbitrary time warps |
| `check_vestedNeverExceedsAllocation` | 5 | Vesting math never overshoots allocation |
| `check_revokeOnlyByCurrentOwner` | 2 | Non-owner cannot revoke (dynamic authority) |
| `check_ownerCanRevoke` | 1 | Live manager owner can always revoke |
| `check_postRevokeClaimBoundedByVestedAtRevoke` | 7 | Post-revoke, beneficiary claim ≤ vested-at-revoke |
| `check_nonBeneficiaryCannotClaim` | 2 | Only the beneficiary can claim |

### VestingManager

| Invariant | Paths | Meaning |
|-----------|-------|---------|
| `check_teamBucketCapRespected` | 6 | Team cap (including Growth/BD sub-buckets) never exceeded |
| `check_strategicStandardCapRespected` | 4 | Strategic Standard cap enforced |
| `check_tgeModeRequiresTgeSet` | 2 | TGE-mode creation requires `setTGE` to have been called |
| `check_teamRejectsTgeMode` | 2 | Team bucket rejects TGE start mode |
| `check_onlyOwnerCanCreate` | 2 | Non-owner cannot create vestings |

### EcosystemEmissionController

| Invariant | Paths | Meaning |
|-----------|-------|---------|
| `check_perEpochCapRespected` | 3 | `emittedInEpoch[e] ≤ maxEmissionByEpoch[e]` |
| `check_emitGrantedLeqRequested` | 4 | `granted ≤ requested` always |
| `check_onlyApprovedRecipient` | 3 | Emissions only to whitelisted recipients |
| `check_onlyOwnerCanEmit` | 2 | Non-owner cannot emit |
| `check_totalEmittedMonotonic` | 2 | `totalEmitted` monotonically non-decreasing |

### PreMTRYSale

| Invariant | Paths | Meaning |
|-----------|-------|---------|
| `check_totalRaisedNeverExceedsHardCap` | 6 | `totalRaisedUSDC ≤ 800,000 USDC` |
| `check_twoBuyersBoundedByHardCap` | 19 (occasionally 18) | Two concurrent buyers respects hard cap |
| `check_noBuyBeforeStart` | 1 | No buy before `saleStart` |
| `check_noBuyAfterEnd` | 1 | No buy after `saleEnd` |
| `check_saleRetainsNoUSDC` | 5 | Sale contract never retains USDC (all routed to treasury) |

---

## Scope exclusions

Halmos was not applied to:

- **`MTRYToken`** — vanilla OZ ERC-20 + ERC-20Burnable, already battle-tested upstream.
- **`PreMTRYToken`** — trivial capped ERC-20 with role-gated mint/burn.
- **`PreMTRYClaim`** — complex vesting math with external `preToken.burnFrom` call; Forge fuzz + integration coverage judged sufficient for the key properties.
- **`GovernanceRoles`** — access control modifier logic; covered by `GovernanceSeparation.t.sol` (29 tests).

---

## Reproducing

### Prerequisites

- Python 3.11+ (required by halmos 0.3.3; on Windows, install via WSL — `safe-pysha3` requires POSIX)
- Foundry

### Install

```bash
pip install halmos==0.3.3
```

### Run

```bash
# Build artifacts must exist and include AST output before halmos runs (KeyError: 'ast'
# otherwise). `ast = true` is set in foundry.toml, so a plain `forge build` is sufficient --
# no special flag needed. If you've already run `forge test` from the steps in README.md,
# the artifacts already have it.
forge build

# All symbolic suites
halmos --match-contract "Symbolic"

# Single contract
halmos --contract GlobalUnlockControllerSymbolicTest
```

### Files

- `test/halmos/GlobalUnlockControllerSymbolic.t.sol`
- `test/halmos/VestingWalletLinearSymbolic.t.sol` — `OwnerHolder`'s mock now implements `isWhitelistedBeneficiaryContract` and `BENEFICIARY` claims use two-arg `vm.prank` (tx.origin-matching), both required after the I-1 `tx.origin` gate (`2193346`) — without them the affected proofs still passed, but vacuously (`claim()` reverting unconditionally rather than being meaningfully exercised).
- `test/halmos/VestingManagerSymbolic.t.sol`
- `test/halmos/EcosystemEmissionSymbolic.t.sol`
- `test/halmos/PreMTRYSaleSymbolic.t.sol`
- `audit/evidence/halmos_output.log` — raw stdout from the representative run this document's numbers are drawn from (commit `2193346`, `forge build` immediately preceding, no manual `--ast` flag).
