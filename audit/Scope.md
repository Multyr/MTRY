# MULTYR Token Stack — Audit Scope

**Branch:** `master`
**Current commit:** `a8dcd43` — merge of PR #7 (KYC whitelist on `PreMTRYSale`)
**Tag:** `audit/v1.0-rc1` marked the initial v1 freeze; the pre-audit remediations and the KYC-whitelist work (PR #7, merged at `a8dcd43`) are all in scope for this review.

---

## Contracts in scope

All files under `src/` and `script/`:

| File | Purpose |
|------|---------|
| `src/MTRYToken.sol` | Fixed-supply 300M ERC-20 with burn counter |
| `src/PreMTRYToken.sol` | Capped 10M preMTRY ERC-20; finalizable sale/claim bindings |
| `src/PreMTRYSale.sol` | USDC-only preMTRY sale (0.08 USDC / preMTRY, 800K USDC hard cap); on-chain KYC allowlist gating `buy()` on sender + receiver, managed `onlyOwner` (`setWhitelist` / `setWhitelistBatch`) |
| `src/PreMTRYClaim.sol` | Lock preMTRY → vested MTRY at 1:4; respects global unlock cap |
| `src/VestingManager.sol` | Factory + registry for per-beneficiary vesting wallets |
| `src/VestingWalletLinear.sol` | Single-beneficiary cliff + linear wallet; optional revocability |
| `src/GlobalUnlockController.sol` | Per-period release cap with dual-lane reserved-quota model |
| `src/EcosystemEmissionController.sol` | Epoch-based ecosystem emission with delayed caps |
| `src/base/GovernanceRoles.sol` | Abstract base: Ownable2Step + guardian + veto roles |
| `src/interfaces/IUnlockController.sol` | Interface consumed by callers of GlobalUnlockController |
| `src/interfaces/IVestingManager.sol` | Interface consumed by VestingWalletLinear |
| `src/interfaces/IPreTokenBinding.sol` | Interface for PreMTRYToken binding validation |
| `src/Errors.sol` | Shared custom errors |
| `script/Deploy.s.sol` | Deployment script (nonce-prediction, wiring, governance config) |
| `script/PostDeployChecks.s.sol` | Post-deploy assertions (allocations, wiring, ownership, caps) |
| `script/SetTGE.s.sol` | TGE activation script (two sequential calls) |

## Out of scope

- Off-chain infrastructure, frontend, backend services.
- OpenZeppelin v5.6.1 libraries (assumed audited; dependency assumptions in `Dependencies.md`).
- USDC contract on Arbitrum One (assumed official; address hard-coded in `PreMTRYSale`).
- `test/` — test files are provided as verification evidence only; test correctness is not in scope.
- `script/SetTGE.s.sol` — a two-call governance operation; relevant properties are covered by unit tests.

## Pre-audit remediations applied before the freeze

These changes were made after the initial codebase was assembled but before the external audit. This repository contains the audited and remediated source at the tagged commit. The full audit report is in [`../audit-reports/`](../audit-reports/).

**A-1 — `setBucketCap` sub-bucket guard:** `setBucketCap` now reverts `InvalidCapBucket` when called with Growth, BDCore, or BDPerformance (sub-buckets that share the Team cap). Previously it silently accepted and wrote a cap that was never read.

**A-2 — Catch-up loop gas bound:** `_rollPeriodIfNeeded` is now capped at `MAX_CATCHUP_PERIODS = 120` iterations per call (~10 years of 30-day periods). Longer gaps require successive `consumeAllowance` calls; the state catches up correctly over multiple calls.

**A-3 — PostDeployChecks wiring assertions:** Three assertions added: `preMTRY.saleContractFinalized()`, `preMTRY.claimContractFinalized()`, and `unlockController.protectedSource(address(claim))`.

**M-1 — Revocation accounting:** `recordRevocation` now credits only `unvested` (not the full original allocation) to `totalBucketRevoked`. This preserves the invariant that `activeBucketAllocated` represents total tokens still owed to active beneficiaries.

**M-2 — `setReferenceSupply` upper bound and cancel path:** New `initialReferenceSupply` immutable caps the setter. New `cancelPendingReferenceSupply()` callable by veto or owner, symmetric with `cancelPendingUnlockCap`.

**M-3 — Vesting wallet deauthorization blocked:** New `vestingWallet` mapping tracks wallets registered via `addVestingSource`. `setAuthorizedSource(wallet, false)` reverts `CannotDeauthorizeVestingWallet` for these wallets.

**M-4 — `protectedQuotaBps` delay + floor:** Renamed to `setPendingProtectedQuotaBps` with next-period-delayed semantics. Floor constant `MIN_PROTECTED_QUOTA_BPS = 2_500` bounds the valid range to [25%, 75%] symmetrically with `MIN_SHARED_QUOTA_BPS`. Cancel path `cancelPendingProtectedQuotaBps()` added.

**M-5 — Genesis validation in constructors:** Both `GlobalUnlockController` and `EcosystemEmissionController` constructors now revert `InvalidTimestamp` if the genesis argument exceeds `block.timestamp + 3650 days`. Deploy script also validates within `[now − 30d, now + 365d]`.

**Low-1 — NEW-02 regression test:** at the time of this round, `test_catchupBoundary_staledCapViolatesHistoricalInvariant` was added to document the then-accepted KL-2 scenario where `totalReleasedInPeriod(p) > maxUnlockForPeriod(p)` after a staged cap change combined with a >120-period dormancy gap. **Superseded:** commit `7cfa645` (MULTYR-2) fixed the underlying gap; that test no longer exists (renamed/replaced by `test_noStaleCapOverReleaseAfterLargeGap` in `test/poc/POC07_StaleCapLargeGap.t.sol`, which now asserts the *absence* of the over-release). KL-2 is FIXED, not accepted — see `KnownLimitations.md` §KL-2.

**Low-2 — Protected lane underflow guard:** `consumeAllowance` line 253 guarded as `totalUsed >= cap ? 0 : cap - totalUsed`, mirroring the existing shared-lane guard.

**Low-3 — PreMTRYClaim whitelisted as system receiver in sale:** `Deploy._wire()` and `TestSetup` now call `sale.setWhitelist(address(claim), true)` so that any future convenience path where `PreMTRYClaim` calls `sale.buy(amount, address(this))` works without a separate exemption mechanism. The standard user flow (users buy for themselves, then call `lockPreTokens`) is unaffected.

## Governance realignment (included in scope)

`GovernanceRoles` abstract base was introduced to standardize the three-role governance model across all five ownable contracts. Details in `docs/ARCHITECTURE.md`.

## Architecture reference

For a full description of contract interactions, token flows, and governance model, see [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).
