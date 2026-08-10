# MULTYR Token Stack — Invariants & Trust Assumptions

## System-level invariants

These properties must hold at all times. The stateful invariant test suites (`test/invariant/`) verify them over 128k call sequences each.

| Invariant | Enforcement |
|-----------|-------------|
| `MTRYToken.totalSupply() == 300M − totalBurned` | No mint after constructor; `ERC20Burnable` reduces supply on burn; `totalBurned` counter tracked |
| `preMTRY.totalSupply() ≤ 10M` | `MAX_SUPPLY` check in `PreMTRYToken.mint()` |
| `totalRaisedUSDC ≤ 800K USDC` | `HARD_CAP_USDC` check in `PreMTRYSale.buy()` |
| `claimedMTRY[user] ≤ entitled[user]` | Vesting math + clamp semantics in `PreMTRYClaim` |
| `totalEntitled ≤ 40M MTRY` | `MAX_CLAIM_POOL` check in `PreMTRYClaim.lockPreTokens()` |
| `VestingWalletLinear.claimedAmount ≤ totalAllocation` | `vestedAmount()` capped by immutable `totalAllocation` |
| `activeBucketAllocated(bucket) ≤ maxBucketAllocation(bucket)` | `_reserveBucket` check in `VestingManager._createVesting()`; `recordRevocation` credits only `unvested` |
| `releasedInPeriod(p) + _protectedUsedTotal(p) ≤ maxUnlockForPeriod(p)` | Dual-lane guards in `consumeAllowance`; stateful invariant suite over 128k sequences |
| Shared sources never access the protected reserve | Hard reservation: shared lane bounded by `cap − protectedReserve` |
| `granted ≤ amount` in every `consumeAllowance` call | Clamp semantics: min(amount, remaining) |
| Duration bounds respected per wallet | `MAX_CLIFF_DURATION` (10y), `MAX_VESTING_DURATION` (10y), `MAX_TOTAL_DURATION` (20y) in `_createVesting` |

### Former transient exception — KL-2 (fixed)

The invariant `releasedInPeriod(p) + _protectedUsedTotal(p) ≤ maxUnlockForPeriod(p)` could previously be transiently violated for a specific historical period after a >120-period dormancy gap combined with a staged cap reduction. Commit `7cfa645` (MULTYR-2) closed this: `maxUnlockForPeriod()` now projects the due cap for any not-yet-initialized period regardless of physical catch-up progress, so `consumeAllowance()` enforces the correct cap unconditionally, even across a >120-period boundary. See `KnownLimitations.md` §KL-2 for the full analysis and `test_noStaleCapOverReleaseAfterLargeGap` / `test_catchupBoundary_projectedCapPreventsOverRelease` for the regression coverage.

## Trust assumptions

**SAFE_GOV (3/5 multisig)** is trusted as the owner of all ownable contracts. A fully compromised SAFE_GOV can:
- Authorize a malicious source to consume unlock allowance up to the per-period cap.
- Set `referenceSupply` to any value ≤ `initialReferenceSupply` (300M), scaling unlock velocity.
- Propose burns (7-day timelock, veto-cancellable).
- Update `protectedQuotaBps` within [25%, 75%] with a one-period delay (veto-cancellable).
- Grant new vesting allocations within bucket caps.

A compromised SAFE_GOV cannot: steal tokens from existing vesting wallets, retroactively modify period caps that are already snapshotted, remove the global unlock cap, or burn tokens during the 7-day timelock without veto consent.

**SAFE_GUARDIAN (1/1 hot key)** can pause all pausable contracts, creating a temporary DoS on claim and emission. Cannot unpause, propose changes, or access funds. `emergencyRevokeUnvested` bypasses `whenNotPaused` by design — beneficiaries can always exit.

**SAFE_VETO (1/1 cold key)** can cancel pending proposals (burns, cap changes, protected quota changes, reference supply changes) within their timelock/delay window. Cannot propose, pause, or access funds. Worst case: blocks a legitimate burn (delay only, not loss).

**Deployer EOA** is trusted for the narrow window between contract deployment and ownership transfer to SAFE_GOV. `PostDeployChecks.s.sol` asserts that the deployer holds zero privileges post-acceptance. The deploy key should be disposed after `acceptOwnership` is confirmed.

**VestingWalletLinear revoker** resolves dynamically to `VestingManager.owner()` at call time via `IVestingManager`. This means SAFE_GOV (as VestingManager owner) can revoke any revocable vesting wallet.

**USDC contract** — assumed to be the official Circle-issued USDC on Arbitrum One. No custom hooks, no fee on transfer, standard 6-decimal ERC-20. See `Dependencies.md`.

**Arbitrum One sequencer** — `block.timestamp` is assumed monotonic and clock-accurate within the sequencer's normal operating bounds. No reorg risk. See `Dependencies.md`.

## Intentional behaviors (not bugs)

These behaviors may look like security issues but are deliberate design choices:

**Late locking in PreMTRYClaim:** The vesting start is anchored to the global TGE timestamp, not the time the user calls `lockPreTokens`. A user who locks late still has their vesting start backdated to TGE. This is correct and intentional — all pre-sale participants vest on the same schedule regardless of when they lock.

**preMTRY purchase is KYC-gated on-chain; preMTRY is freely transferable afterwards.** `PreMTRYSale.buy()` reverts `NotWhitelisted` unless both `msg.sender` and `receiver` are on the `onlyOwner`-managed whitelist (a self-receiver is accepted). There is no exemption mechanism — protocol contracts that must receive preMTRY via `buy()` are individually whitelisted by governance (e.g. `PreMTRYClaim` at deploy time). `PreMTRYToken` itself has **no** transfer restriction, so preMTRY circulates freely once purchased; the gate is on acquisition only. Downstream KYC/AML remains enforced off-chain by the Foundation. See KL-6.

**`recoverToken` on PreMTRYClaim cannot recover MTRY or preMTRY.** Both are explicitly blocked in the recovery guard.

**Revoked wallet authorization is permanent.** After revocation, the wallet remains `authorizedSource[wallet] = true` in `GlobalUnlockController`. This is required because the beneficiary may still have unclaimed vested tokens (the wallet's claimable amount at revoke time remains accessible). `setAuthorizedSource(wallet, false)` is blocked for wallets registered via `addVestingSource` (`vestingWallet[wallet] == true`).

**`release()` and `claim()` are callable by the beneficiary only.** `claimTo(recipient)` allows the beneficiary to redirect tokens but must be called by the beneficiary.

**`emergencyRevokeUnvested()` is callable even when paused.** This is the intentional exit path for beneficiaries during a guardian-initiated pause.

**PreMTRYToken bindings are editable until finalized.** Before `finalizeSaleContract()` and `finalizeClaimContract()` are called, SAFE_GOV can update the sale and claim addresses. The deploy script finalizes both immediately; `PostDeployChecks` asserts both finalized flags.

**VestingWalletLinear cliff/duration values are governance conventions, not per-bucket code constraints.** The contract enforces global MAX bounds only (`MAX_CLIFF = 10y`, `MAX_VESTING = 10y`, `MAX_TOTAL = 20y`). The per-bucket cliff/duration values documented in `docs/ARCHITECTURE.md` are enforced by governance discipline when calling `VestingManager.createVesting`.

**`totalReleasedInPeriod` does not equal `releasedInPeriod + protectedReleasedInPeriod` for a single source.** `totalReleasedInPeriod(p)` returns the sum of shared released and total protected used across all protected sources. Per-source protected tracking uses `protectedReleasedInPeriod[source][period]`; the aggregate is `_protectedUsedTotalByPeriod[period]`.

**Unused protected capacity does not spill to the shared lane.** At period boundary, unused protected reserve is not reallocated to shared sources. Each new period starts with the configured split.

**`setReferenceSupply` applies immediately to `referenceSupply` but is next-period-delayed.** The new value is written to the pending slot read by `_rollPeriodIfNeeded`, which only promotes it in periods strictly greater than the commit period. So a reference supply change committed in period P cannot affect period P's unlock cap.
