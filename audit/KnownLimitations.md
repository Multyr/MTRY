# MULTYR Token Stack — Known Limitations & Accepted Risks

This document proactively discloses known rough edges: why each is accepted, what the residual risk is, and how it is monitored. This is not a finding list.

---

## KL-1 — Sub-bucket cap footgun — FIXED

**Description:** `setBucketCap` previously accepted `Growth`, `BDCore`, and `BDPerformance` (sub-bucket IDs) without reverting, silently writing a cap that was never read. `_reserveBucket` reads from `maxBucketAllocation[_capBucketFor(bucket)]` (i.e., the Team cap-bucket), so sub-bucket cap assignments were no-ops.

**Status:** Fixed (A-1). `setBucketCap` now reverts `InvalidCapBucket` when `_capBucketFor(bucket) != bucket`.

**Residual risk:** None.

---

## KL-2 — >120-period catch-up stale cap — FIXED

**Description:** `_rollPeriodIfNeeded` is bounded at `MAX_CATCHUP_PERIODS = 120` iterations per call. If the protocol is dormant for >120 periods (~10 years), a single `consumeAllowance` call physically initializes storage for periods up to `lastInitializedPeriod + 120`, not up to the current period. On the next call it advances another 120, and so on until fully caught up.

This previously created an edge case when a governance cap change was committed at period K and the protocol was dormant until period N > K + 120: the first `consumeAllowance` at period N could enforce the old fallback cap (because physical catch-up hadn't reached K yet), while a second call would finish the catch-up and write the new cap. Tokens granted under the first call at the old (potentially higher) cap were not clawed back, and `totalReleasedInPeriod(N)` could transiently exceed `maxUnlockForPeriod(N)`.

**Status:** Fixed by commit `7cfa645` (MULTYR-2 / informally "L-1"). `maxUnlockForPeriod()`, `remainingAllowanceForSource()`, and `availableThisEpoch()` now delegate to `_projectedCapBps` / `_projectedReferenceSupply` / `_projectedProtectedQuotaBps` / `_projectedMaxEmissionPerEpoch`, which simulate the promotion `_rollPeriodIfNeeded`/`_rollEpochIfNeeded` would apply if it ran right now — independent of how far physical, gas-bounded catch-up has actually progressed. Because `consumeAllowance()`/`_emit()` enforce their cap via these same public views, the very first call after an arbitrarily large dormancy gap already enforces the correct, fully-caught-up cap. `releasedInPeriod[p] <= maxUnlockForPeriod(p)` now holds unconditionally, even across a >120-period catch-up boundary.

**Verification:** `test_noStaleCapOverReleaseAfterLargeGap` (`test/poc/POC07_StaleCapLargeGap.t.sol`) and `test_catchupBoundary_projectedCapPreventsOverRelease` (`test/GlobalUnlockController.t.sol`) both confirm the fix at the exact catch-up boundary.

**Mitigation (still in force):**
- `MAX_CATCHUP_PERIODS = 120` still bounds gas per call (~5.7M gas for 120 iterations, measured) — this fix does not remove the gas-cost bound, only the correctness gap.
- I-3 (MULTYR-8) additionally makes every pending-value governance setter roll the current period/epoch first, so a >120-period gap is often partially or fully caught up as a side effect of the next governance action, not only via `consumeAllowance`.

**Residual risk:** None beyond the (unrelated, still-accepted) gas-cost rationale for `MAX_CATCHUP_PERIODS` itself.

---

## KL-3 — `referenceSupply` is governance-managed, not live token supply

**Description:** `maxUnlockForPeriod(p) = referenceSupply * capBpsByPeriod[p] / 10_000`. Burns on MTRY (`PreMTRYClaim.executeBurn`, `VestingManager.executeBurn`, `EcosystemEmissionController.executeBurn`) reduce `MTRYToken.totalSupply` but do NOT automatically reduce `referenceSupply`. Governance must call `setReferenceSupply` to reflect burns.

**Why accepted:** Intentional design — unlock velocity is governable, not automatic. Automatic coupling would allow any burn to unpredictably change unlock rates for all active beneficiaries.

**Bounds and constraints:**
- `setReferenceSupply` is bounded above by `initialReferenceSupply` (the deploy-time value, 300M). Governance cannot increase it beyond the original envelope.
- Changes take effect from the next period (commit-period delayed).
- `cancelPendingReferenceSupply()` is callable by veto or owner to reverse a pending change.

**Residual risk:** If large burns occur and governance does not reduce `referenceSupply`, the unlock velocity remains higher than the fraction of remaining supply. This is not fund-loss — it simply means the cap is expressed as a percentage of the original supply rather than the live supply.

**Monitoring:** Alert on `ReferenceSupplyUpdated` event; review after any significant burn.

---

## KL-4 — Shared-lane first-come-first-served

**Description:** The shared lane is bounded by `cap − protectedReserve − sharedUsed`, but protected sources can also access the remaining shared budget (they see `cap − totalUsed` where `totalUsed` includes shared used). A protected source that consumes its full budget (including unused shared) can therefore starve shared sources in that period — even though the protected reservation floor is 25%.

**Why accepted:**
- `PreMTRYClaim` (the largest claimant and the primary "user-facing" flow) is registered as a protected source. It gets access to the protected reserve.
- Shared sources (`EcosystemEmissionController`, vesting wallets) are protocol-controlled and scheduled rather than user-triggered. Transient epoch starvation is an operational concern, not a user-harm vector.
- The `MIN_PROTECTED_QUOTA_BPS = 2_500` and `MIN_SHARED_QUOTA_BPS = 2_500` constants ensure the reservation bounds cannot be collapsed to zero by governance.

**Mitigation:** `PostDeployChecks` asserts `unlockController.protectedSource(address(claim))`. Monitoring: track `UnlockThrottled` events per source.

---

## KL-5 — Pre-finalization owner power in PreMTRYToken

**Description:** Before `finalizeSaleContract()` and `finalizeClaimContract()` are called, SAFE_GOV can rewrite the `saleContract` and `claimContract` bindings. After finalization, the setter reverts.

**Why accepted:** The configuration window is intentional — it allows correction of deployment errors. The deploy script finalizes immediately after deploying and wiring.

**Mitigation:** Deploy script calls `finalizeSaleContract()` and `finalizeClaimContract()` in the same broadcast session. `PostDeployChecks` asserts `saleContractFinalized()` and `claimContractFinalized()` are both true.

**Residual risk:** None post-finalization.

---

## KL-6 — On-chain KYC gate on purchase only; preMTRY freely transferable afterwards

**Description:** `PreMTRYSale.buy()` enforces an on-chain KYC allowlist at the point of purchase: it reverts `NotWhitelisted` unless **both** the caller (`msg.sender`) **and** the `receiver` are on the whitelist (a `receiver` equal to `msg.sender` is accepted without a separate lookup). The whitelist is a single `mapping(address => bool)` written only by `setWhitelist` / `setWhitelistBatch`, both `onlyOwner` (SAFE_GOV). There is **no** transfer restriction on `PreMTRYToken` itself: once purchased, a holder can transfer preMTRY to any address, including non-whitelisted / non-KYC'd ones. The gate applies to acquisition, not to secondary circulation.

There is **no separate "system-contract exemption" mechanism** — no `code.length` check, role, or wildcard. Protocol contracts that must legitimately receive preMTRY through `buy()` are individually added to the same whitelist by governance (the deploy script calls `sale.setWhitelist(address(claim), true)` — see Scope.md Low-3). Every other address, EOA or contract, remains gated as a receiver.

**Why accepted:** On-chain enforcement covers the primary acquisition path — the point at which the Foundation onboards a participant. Secondary transfer restrictions were intentionally **not** added to `PreMTRYToken` (it must remain a standard, freely transferable ERC-20; `MTRYToken` is likewise unrestricted for future DEX listing). Eligibility of downstream holders continues to be enforced off-chain by the Foundation under applicable legal frameworks. The on-chain contracts enforce financial limits (hard cap, MAX_SUPPLY) plus acquisition-time KYC, not restrictions on secondary circulation.

**Residual risk:** The allowlist is fully governance-controlled (`onlyOwner`). SAFE_GOV can refuse to whitelist, or de-whitelist, any address — a censorship/DoS surface over *who may purchase*, not over funds. See ThreatModel.md §3.6.

---

## KL-7 — Integer division rounds in favor of the protocol

**Description:** Claimable amounts in `VestingWalletLinear.vestedAmount` use integer division: `(totalAllocation * elapsed) / duration`. The result is always rounded down to the nearest wei.

**Why accepted:** This is standard Solidity integer arithmetic. Dust (sub-wei truncation) is negligible for any real allocation. The protocol retains the dust; beneficiaries receive a marginally smaller amount per vesting tick.

---

## KL-8 — TGE activation is two sequential independent transactions

**Description:** `PreMTRYClaim.setTGE()` and `VestingManager.setTGE()` are independent one-time setters. `SetTGE.s.sol` issues both in the same Foundry broadcast session but as two separate on-chain transactions. A network desync (one confirms, one is dropped) leaves the protocol in a split TGE state with no recovery path (the setter is guarded by `TGEAlreadySet`).

**Why accepted:** Atomic coupling would require a coordinator contract (new audit surface) or cross-contract coupling that would couple otherwise independent lifecycles. The split state is observable on-chain before the TGE event is announced publicly.

**Mitigation:** After executing `SetTGE.s.sol`, verify on-chain that `claim.tgeTimestamp() == vestingManager.tgeTimestamp()` before any user-facing announcements. If only one transaction confirms, incident response is: the contract with TGE already set is live; the one without requires a governance decision (since the setter is irrevocable, recovery requires deploying a replacement contract and rewiring).

**Residual risk:** Operationally manageable with post-TGE on-chain verification.

---

## KL-9 — Revocation recovery bypasses the unlock cap and burn-delay lifecycle

**Description:** `VestingWalletLinear.revokeUnvested()` (and `emergencyRevokeUnvested()`) transfer unvested MTRY directly to `treasury`:

```solidity
if (unvested > 0) {
    token.safeTransfer(treasury, unvested);
}
```

This does not call `GlobalUnlockController.consumeAllowance()` and does not go through the `proposeBurn` / `executeBurn` timelock that other recovery paths (`VestingManager`, `PreMTRYClaim`, `EcosystemEmissionController`) use for moving MTRY out of programmatic circulation. A revocable pre-cliff grant can therefore be revoked to move the full unvested reserve into `treasury` instantly, without consuming any per-period unlock allowance.

**Why accepted:** The unlock cap governs programmatic beneficiary-facing releases (claim, vesting, emissions) — flows where an external party is drawing down a shared per-period budget. Revocation is a governance-initiated recovery of tokens that were never claimed by (and are no longer owed to) a beneficiary; the tokens remain protocol-owned and simply move between two protocol-controlled addresses (the wallet and `treasury`). Treating it as equivalent to a beneficiary claim would require routing every revocation through the shared cap and a multi-day burn-style delay, materially slowing down a routine governance action (e.g. offboarding a departed team member) for no fund-safety benefit — the tokens never leave protocol custody.

**Mitigation:** None required — this is documented, intended behavior. `test_I5_RevokeMovesUnvestedReserveToTreasuryWithoutUnlockOrBurnDelay` (`test/audit/InformationalFindings.t.sol`) confirms the transfer completes and does not consume unlock allowance.

**Residual risk:** None beyond the existing revoke authority (`revoker()`, resolved dynamically from `VestingManager.owner()`), which already controls issuance/cap policy for the entire bucket system.
