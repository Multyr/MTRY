# MULTYR Token Stack — Architecture

**Solidity:** 0.8.28 | **OZ:** v5.6.1 | **Foundry:** forge | **Chain:** Arbitrum One (42161)

---

## Governance

The token stack uses a three-entity governance model aligned with the Multyr allocation protocol:

| Entity | Type | Role |
|--------|------|------|
| **SAFE_GOV** | 3/5 multisig | Owner of all contracts. Proposes parameter changes, burns, authorizations. All actions timelocked or delayed-apply. |
| **SAFE_GUARDIAN** | 1/1 multisig | Emergency pause on all pausable contracts. Cannot unpause, transfer ownership, or propose changes. |
| **SAFE_VETO** | 1/1 multisig | Cancels pending proposals (burns, cap changes) during timelock window. Cannot propose or pause. |
| **TREASURY_SAFE** | 3/5 multisig | Holds 75M MTRY (direct allocation). Independent from SAFE_GOV. |
| **LIQUIDITY_SAFE** | 3/5 multisig | Holds 45M MTRY for market making. Independent from SAFE_GOV. |

Five contracts inherit `GovernanceRoles` (extends `Ownable2Step`): `PreMTRYSale`, `PreMTRYClaim`, `VestingManager`, `GlobalUnlockController`, `EcosystemEmissionController`. These get `guardian`, `veto`, `setGuardian`, `setVeto`, `onlyGuardianOrOwner`, `onlyVetoOrOwner`.

`PreMTRYToken` inherits `Ownable2Step` directly — no guardian or veto roles.

`VestingWalletLinear` is non-ownable: it has an immutable `guardian` address and a dynamic `revoker` (resolves to `VestingManager.owner()` at call time via `IVestingManager`).

## Core contracts (8 + 1 abstract base)

| Contract | Purpose |
|----------|---------|
| `GovernanceRoles` | Abstract base: Ownable2Step + guardian + veto roles. |
| `MTRYToken` | Fixed-supply ERC20 + `ERC20Burnable`. 300M minted once to 5 recipients. `totalBurned` counter. |
| `PreMTRYToken` | Capped 10M preMTRY ERC20. Finalizable sale/claim bindings with contract + interface validation. |
| `PreMTRYSale` | USDC-only sale (0.08 USDC/preMTRY, 800K hard cap). Hard-coded Arbitrum USDC. Both buyer (`msg.sender`) and `receiver` must be whitelisted; managed via `setWhitelist` / `setWhitelistBatch`. |
| `PreMTRYClaim` | Lock preMTRY → vested MTRY at 1:4 (180d cliff + 540d linear). Claim respects global unlock cap. |
| `VestingManager` | Factory + registry for per-beneficiary wallets. 8 bucket types, dual start mode, duration bounds. |
| `VestingWalletLinear` | Single-beneficiary cliff+linear. Optional revocability, 2-phase beneficiary update, emergency revoke. |
| `GlobalUnlockController` | Global per-period release cap with clamp semantics and reserved-quota model. |
| `EcosystemEmissionController` | Epoch-based emission, whitelist, delayed caps. Shares global budget. |

## Token allocations (sum = 300M)

| Recipient | Amount | % | Contract |
|-----------|--------|---|----------|
| Treasury Safe | 75M | 25.00% | multisig (no vesting) |
| Liquidity Safe | 45M | 15.00% | multisig (no vesting) |
| PreMTRYClaim | 40M | 13.33% | on-chain (1:4 conversion pool) |
| VestingManager | 111M | 37.00% | on-chain (distributed to wallets) |
| EcosystemEmissionController | 29M | 9.67% | on-chain (epoch-based emission) |

## Vesting buckets (managed by VestingManager)

> Rows ordered to match `BucketType` enum indices (see `src/VestingManager.sol:65-74`).

| Bucket (enum idx) | Cap | Cliff/Duration | Start modes |
|-------------------|-----|----------------|-------------|
| StrategicStandard (0) | 27M | 6m / 18m | TGE or GRANT_DATE |
| StrategicExtended (1) | 18M | 6m / 24m | TGE or GRANT_DATE |
| Team (2) | 51M (shared) | 12m / 36m | GRANT_DATE only |
| Growth (3) | (from Team cap) | 6m / 18m | GRANT_DATE only |
| AdvisorsStandard (4) | 10.5M | 6m / 18m | GRANT_DATE only |
| AdvisorsShort (5) | 4.5M | 3m / 18m | GRANT_DATE only |
| BDCore (6) | (from Team cap) | 6m / 18m | GRANT_DATE only |
| BDPerformance (7) | (from Team cap) | 0 / 9m | GRANT_DATE only |

Duration bounds: `MAX_CLIFF_DURATION` = 10y, `MAX_VESTING_DURATION` = 10y, `MAX_TOTAL_DURATION` = 20y.

> **Note:** The cliff/duration values in the table above are governance conventions, not enforced by contract code per-bucket. Only the global MAX bounds are code-enforced. Governance is expected to follow the conventions when creating grants.

Revoked vestings free bucket capacity via `recordRevocation()`.

## Start mode policy

- **TGE mode:** `startTimestamp = tgeTimestamp`. Required for Strategic genesis grants.
- **GRANT_DATE mode:** `startTimestamp = block.timestamp` at creation. Required for Team, Growth, BD, Advisors.
- Strategic allows either mode. TGE is NOT required for GRANT_DATE wallet creation.

## Global unlock cap (clamp semantics)

- Single per-period cap: 2% of 300M = 6M per 30-day period.
- `consumeAllowance(amount) → granted` clamps to remaining. Never reverts on cap exhaustion.
- Cap changes via `setPendingUnlockCapBps` apply ONLY from the next period (commit-period tracking).
- `genesisTimestamp` and `periodDuration` are IMMUTABLE.

### Reserved quota (hard reserve, no spillover)

- **Shared lane** (vesting + ecosystem): bounded by `cap − protectedReserve`.
- **Protected lane** (PreMTRYClaim): may consume up to `cap − totalUsed`.
- Unused protected capacity does NOT spill to shared lane. Next period resets.
- Hard-bounded: `MIN_PROTECTED_QUOTA_BPS = 2_500` (floor, 25%) and `MIN_SHARED_QUOTA_BPS = 2_500` (floor, 25%). Valid range for `protectedQuotaBps`: [25%, 75%].
- Default: 50/50 split (`protectedQuotaBps = 5_000`).

Invariant: `totalReleasedInPeriod(p) ≤ maxUnlockForPeriod(p)`.

## Pause model

| Contract | Pause callable by | Unpause callable by |
|----------|-------------------|---------------------|
| PreMTRYSale | SAFE_GUARDIAN or SAFE_GOV | SAFE_GOV |
| PreMTRYClaim | SAFE_GUARDIAN or SAFE_GOV | SAFE_GOV |
| VestingManager | SAFE_GUARDIAN or SAFE_GOV | SAFE_GOV |
| GlobalUnlockController | SAFE_GUARDIAN or SAFE_GOV | SAFE_GOV |
| EcosystemEmissionController | SAFE_GUARDIAN or SAFE_GOV | SAFE_GOV |
| VestingWalletLinear | SAFE_GUARDIAN or SAFE_GOV (as revoker) | SAFE_GOV (as revoker) |

`revokeUnvested()` is blocked when paused. `emergencyRevokeUnvested()` is always callable.

## Veto model

| Contract | Veto-cancelable actions |
|----------|------------------------|
| PreMTRYClaim | `cancelBurn()` |
| VestingManager | `cancelBurn()` |
| EcosystemEmissionController | `cancelBurn()`, `cancelPendingMaxEmission()` |
| GlobalUnlockController | `cancelPendingUnlockCap()`, `cancelPendingReferenceSupply()`, `cancelPendingProtectedQuotaBps()` |

SAFE_VETO can cancel pending proposals during the timelock window. Cannot propose, pause, or transfer ownership.

## Burn policy (timelocked, 7-day delay)

- `MTRYToken` is `ERC20Burnable`. `totalBurned` cumulative counter.
- `PreMTRYClaim.executeBurn` — post-vesting horizon only.
- `VestingManager.executeBurn` — unallocated tokens only.
- `EcosystemEmissionController.executeBurn` — post MAX_EPOCHS only.
- Burns do NOT consume global unlock allowance and do NOT reduce `referenceSupply`.

## Ownership model

All ownable contracts inherit `GovernanceRoles` (extends `Ownable2Step`). Deploy → deployer owns → configure guardian/veto → `transferOwnership(SAFE_GOV)` → SAFE_GOV calls `acceptOwnership()`.
