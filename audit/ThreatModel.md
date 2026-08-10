# MULTYR Token Stack — Threat Model

**Scope:** 9 contracts, ~1,600 nSLOC, Solidity 0.8.28, OZ v5.6.1, Arbitrum One
**Architecture reference:** [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)

---

## 1. Assumed attacker capabilities

| Actor | Capability |
|-------|-----------|
| **Permissionless on-chain caller** | Can call any `public`/`external` function |
| **Beneficiary with a valid grant** | Has a `VestingWalletLinear`, can call `claim`/`claimTo` |
| **Approved ecosystem recipient** | Whitelisted for `EcosystemEmissionController.emitTo` |
| **Compromised SAFE_GOV (3/5)** | Controls all owner-gated actions |
| **Compromised SAFE_GUARDIAN (1/1)** | Can pause; cannot unpause, propose, or transfer |
| **Compromised SAFE_VETO (1/1)** | Can cancel pending proposals; cannot propose or pause |
| **MEV / Arbitrum sequencer** | Centralized sequencer; no typical reorgs; soft reordering possible |

---

## 2. Per-role abuse analysis

### 2.1 SAFE_GOV (Owner — 3/5 multisig)

**Can:**
- `VestingManager.createVesting` / `batchCreateVestings` — create new grants within bucket caps.
- `VestingManager.setBucketCap` — raise or lower a cap-bucket cap (cap-buckets only; sub-buckets blocked by A-1).
- `GlobalUnlockController.setAuthorizedSource` — authorize or deauthorize a source (cannot deauthorize vesting wallets — blocked by M-3).
- `GlobalUnlockController.setProtectedSource` — move a source between protected and shared lane.
- `GlobalUnlockController.setPendingProtectedQuotaBps` — set quota within [25%, 75%]; takes effect from next period.
- `GlobalUnlockController.setPendingUnlockCapBps` — lower or raise the per-period cap (≤ 20%); takes effect from next period.
- `GlobalUnlockController.setReferenceSupply` — reduce reference supply (≤ `initialReferenceSupply` = 300M); takes effect from next period.
- `proposeBurn` / `executeBurn` on `PreMTRYClaim`, `VestingManager`, `EcosystemEmissionController` — 7-day timelock.
- `EcosystemEmissionController.setPendingMaxEmissionPerEpoch` — change per-epoch cap; takes effect from next epoch.
- `EcosystemEmissionController.setApprovedRecipient` — whitelist or de-whitelist emission recipients.
- `PreMTRYSale.setWhitelist` / `setWhitelistBatch` — add or remove addresses from the purchase KYC allowlist (gates both `msg.sender` and `receiver` in `buy()`).
- `unpause` on all pausable contracts.
- `setGuardian` / `setVeto` on all `GovernanceRoles` contracts.
- `PreMTRYClaim.setTGE` / `VestingManager.setTGE` (one-time only, before TGE is set).

**Cannot:**
- Modify `genesisTimestamp` (GlobalUnlockController) or `genesis` (EcosystemEmissionController) — both `immutable`.
- Modify `periodDuration` — `immutable`.
- Apply cap changes retroactively — `capBpsByPeriod[p]` is written once and never changed.
- Exceed `initialReferenceSupply` (300M) via `setReferenceSupply`.
- Set `protectedQuotaBps` outside [25%, 75%] — floor and ceiling both enforced.
- Execute a burn within the 7-day timelock.
- Deauthorize a vesting wallet's unlock access (`vestingWallet` guard).

**Worst-case (full SAFE_GOV compromise):**
- Authorize a malicious source → it consumes unlock allowance up to the per-period cap. Tokens flow within cap; no bypass of the global throttle.
- Set `referenceSupply` to maximum allowed (300M, the deploy-time value) → unlock velocity unchanged (it's already at 300M by default). A reduction to a low value would slow unlock velocity.
- Set `protectedQuotaBps` to 75% via `setPendingProtectedQuotaBps` → shared sources (vesting, ecosystem) have access to at most 25% of the cap from next period. Protected sources (PreMTRYClaim) get up to the full cap via FCFS.
- Set `unlockCapBps` to 0 via `setPendingUnlockCapBps` → would revert (0 is below MIN bound — `if (newCapBps == 0) revert`). Minimum is 1 bps.
- Propose a burn of all unallocated VestingManager tokens or all post-horizon ecosystem tokens → 7-day veto window.
- **Cannot steal from existing vesting wallets** — tokens in `VestingWalletLinear` contracts are owned by those contracts; owner has no direct withdrawal path.

---

### 2.2 SAFE_GUARDIAN (1/1 hot key)

**Can:** Pause any of the 5 pausable contracts (via `onlyGuardianOrOwner`).

**Cannot:** Unpause, propose changes, transfer ownership, or access funds.

**Worst-case:** Temporary DoS on `claim`, `emitTo`, and `release`. `emergencyRevokeUnvested()` bypasses `whenNotPaused` — beneficiaries can always recover their unvested allocation to treasury and their vested amount remains claimable once unpaused.

---

### 2.3 SAFE_VETO (1/1 cold key)

**Can:**
- `cancelPendingUnlockCap()` — on GlobalUnlockController.
- `cancelPendingReferenceSupply()` — on GlobalUnlockController.
- `cancelPendingProtectedQuotaBps()` — on GlobalUnlockController.
- `cancelBurn()` — on PreMTRYClaim, VestingManager, EcosystemEmissionController.
- `cancelPendingMaxEmission()` — on EcosystemEmissionController.

**Cannot:** Propose, pause, transfer, or access funds.

**Worst-case:** Block a legitimate burn (introduces delay only, not loss). Block a legitimate cap change.

---

### 2.4 Beneficiary (grant holder)

**Can:** `claim(amount)` / `claimTo(recipient, amount)`, `proposeBeneficiaryUpdate`, `cancelBeneficiaryUpdate`, `confirmBeneficiaryUpdate`.

**Cannot:** Exceed the vested amount (`vestedAmount()` capped by `totalAllocation`), bypass the global unlock cap (clamp semantics — `consumeAllowance` returns `granted ≤ requested`), influence other wallets.

**Griefing:** None. Each `VestingWalletLinear` is isolated. Claiming in full uses only the caller's own unlock allowance.

---

### 2.5 Approved ecosystem recipient

**Can:** Receive tokens via `EcosystemEmissionController.emitTo` up to the per-epoch cap and the shared-lane budget.

**Cannot:** Exceed the epoch cap or the shared-lane budget (both enforced in `_emit`). Cannot call `emitTo` directly — only SAFE_GOV can.

---

## 3. Economic / griefing surface

### 3.1 `referenceSupply` misconfiguration (→ KL-3)

`maxUnlockForPeriod = referenceSupply * capBps / 10_000`. A reduction to a very low value → unlock velocity drops. An increase is capped at `initialReferenceSupply` (300M). Not fund-loss; purely velocity control.

**Mitigation:** 3/5 multisig threshold; next-period delayed; veto-cancellable; alert on `ReferenceSupplyUpdated`.

### 3.2 Shared-lane starvation (→ KL-4)

A protected source that calls `consumeAllowance` early in a period can consume beyond its reservation (up to `cap − totalUsed`). Shared sources arriving later see a reduced budget.

**Mitigation:** `PreMTRYClaim` (largest claimant) is the protected source. Shared sources (ecosystem, vesting wallets) are protocol-controlled and scheduled. `PostDeployChecks` asserts `protectedSource(claim) == true`.

### 3.3 Period-boundary timing / MEV

Cap resets at each period boundary (deterministic from genesis + period duration). Granted amounts are deterministic at call time. Front-running `consumeAllowance` is not profitable.

### 3.4 Catch-up loop gas (mitigated by A-2; stale-cap correctness gap fixed, KL-2)

Bounded at 120 periods per call. A >120-period gap requires successive calls to finish physical storage catch-up. Full catch-up completes without state loss. The correctness gap this used to create (a stale cap enforced before physical catch-up finished) is fixed — see KL-2.

### 3.5 MEV on `claim` / `emitTo`

`consumeAllowance` granted amount is deterministic. Reordering is not profitable.

### 3.6 Purchase-whitelist censorship / DoS (KYC allowlist)

`PreMTRYSale.buy()` gates on an `onlyOwner` allowlist covering both `msg.sender` and `receiver`. SAFE_GOV can therefore decide *who may purchase* preMTRY: it can refuse to whitelist an address, or de-whitelist a previously approved one, blocking that party from buying (and from designating a non-self receiver). This is an intentional KYC control, but it is also a censorship/DoS surface.

**Bounds:**
- Scope is acquisition only. The gate does **not** restrict `PreMTRYToken` transfers, `lockPreTokens`, `claim`, or any post-purchase flow — a holder who already bought is unaffected by later whitelist changes.
- No fund-loss vector: the owner cannot move, freeze, or seize a user's preMTRY or USDC via the whitelist; it can only allow/deny the `buy()` entry point.
- The allowlist is the *only* whitelist consulted — there is no separate exemption path, `code.length` shortcut, or wildcard that could either widen (self-exemption by an attacker) or be abused to bypass the gate. Protocol contracts that must receive preMTRY through `buy()` are individually whitelisted by governance (e.g. `PreMTRYClaim` at deploy time; see Scope.md Low-3).

**Mitigation:** 3/5 multisig threshold on all whitelist writes; `WhitelistUpdated` event emitted on every change (monitorable). Off-chain KYC/AML policy governs whom the Foundation whitelists.

---

## 4. Mis-deployment / mis-initialization

### 4.1 Genesis timestamp typo (→ M-5, mitigated)

Both `GlobalUnlockController` and `EcosystemEmissionController` constructors now revert `InvalidTimestamp` if genesis exceeds `block.timestamp + 3650 days`. Deploy script validates within `[now − 30d, now + 365d]`. `PostDeployChecks` asserts both genesis values are non-zero and within range.

**Residual:** A genesis set 31+ days in the past would still be accepted by the constructor guard. In a real deployment the gap between env-file preparation and broadcast is minutes, not days; the Deploy.s.sol range check catches realistic typos.

### 4.2 Wrong wiring order

If `GlobalUnlockController` is not wired before claims, calls revert `UnauthorizedSource`. No state is corrupted; SAFE_GOV can re-configure.

### 4.3 Ownership not transferred to SAFE_GOV

Deploy runbook required. `PostDeployChecks` asserts `owner() == SAFE_GOV` in both pre- and post-acceptance phases.

### 4.4 PreMTRYClaim not set as protectedSource (→ A-3)

Deploy script wires it. `PostDeployChecks` asserts it.

---

## 5. External dependencies

See `Dependencies.md` for full assumptions on OZ v5.6.1, USDC, and the Arbitrum sequencer.

---

## 6. Accepted risks

See `KnownLimitations.md`.
