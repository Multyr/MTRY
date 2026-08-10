# MULTYR Token Stack — Access Control Matrix

Function-by-function access control. Columns: who can call, delay/timelock, worst-case effect if compromised.

**Roles:**
- **GOV** = SAFE_GOV (owner, 3/5 multisig)
- **GRD** = SAFE_GUARDIAN (1/1 hot key)
- **VTO** = SAFE_VETO (1/1 cold key)
- **BEN** = beneficiary of a specific VestingWalletLinear
- **RVK** = revoker (= VestingManager.owner() at call time)
- **SRC** = authorized unlock source (wallet registered with GlobalUnlockController)
- **ANY** = permissionless

---

## GlobalUnlockController

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `consumeAllowance` | SRC | none | Consumes up to remaining per-period cap |
| `setPendingUnlockCapBps` | GOV | next period | Changes cap velocity from next period; 1 bps ≤ cap ≤ 2000 bps |
| `cancelPendingUnlockCap` | VTO or GOV | none | Restores pending cap to current active cap |
| `setReferenceSupply` | GOV | next period | Changes unlock velocity; bounded above by initialReferenceSupply (300M) |
| `cancelPendingReferenceSupply` | VTO or GOV | none | Restores to last snapshotted period value |
| `setPendingProtectedQuotaBps` | GOV | next period | Shifts lane split within [25%, 75%] from next period |
| `cancelPendingProtectedQuotaBps` | VTO or GOV | none | Restores pending quota to current active quota |
| `setAuthorizedSource` | GOV | none | Authorizes/deauthorizes a source; cannot deauthorize vestingWallet entries |
| `setProtectedSource` | GOV | none | Moves a source between protected and shared lane |
| `setVestingManager` | GOV | none | Sets the address allowed to call `addVestingSource` |
| `addVestingSource` | vestingManager only | none | Authorizes a new vesting wallet; sets vestingWallet[wallet] = true |
| `pause` | GRD or GOV | none | Halts `consumeAllowance`; no fund loss |
| `unpause` | GOV | none | Restores normal operation |
| `setGuardian` | GOV | none | Rotates guardian role |
| `setVeto` | GOV | none | Rotates veto role |
| `transferOwnership` | GOV | accept step | Initiates ownership transfer to new address |
| `acceptOwnership` | pending owner | none | Completes ownership transfer |

---

## VestingManager

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `createVesting` | GOV | none | Creates a new vesting wallet within bucket cap |
| `batchCreateVestings` | GOV | none | Batch creation (up to 50) |
| `setBucketCap` | GOV | none | Raises/lowers a cap-bucket cap; reverts if cap < current allocated |
| `setTGE` | GOV | none | One-time; sets TGE timestamp for TGE-mode wallets |
| `setWhitelistedBeneficiaryContract` | GOV | none | Allows or blocks a contract address as vesting beneficiary |
| `recordRevocation` | wallet being revoked (self) | none | Credits unvested amount to bucket capacity |
| `proposeBurn` | GOV | 7-day timelock | Proposes to burn unallocated VestingManager balance |
| `cancelBurn` | VTO or GOV | none | Cancels pending burn |
| `executeBurn` | GOV | after 7 days | Burns unallocated tokens |
| `pause` | GRD or GOV | none | Halts `createVesting`; does not affect individual wallet claims |
| `unpause` | GOV | none | Restores |
| `setGuardian` / `setVeto` | GOV | none | Role rotation |
| `transferOwnership` / `acceptOwnership` | GOV / pending | accept step | Ownership transfer |

---

## VestingWalletLinear

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `claim(amount)` | BEN | none | Transfers vested tokens to beneficiary (clamped by global cap) |
| `claimTo(recipient, amount)` | BEN | none | Redirects vested tokens to a specified address |
| `revokeUnvested` | RVK (VestingManager.owner()) | none | Returns unvested tokens to treasury; blocked when paused |
| `emergencyRevokeUnvested` | RVK | none | Same as revokeUnvested; bypasses `whenNotPaused` |
| `proposeBeneficiaryUpdate` | BEN | 3-day delay | Proposes a new beneficiary address |
| `confirmBeneficiaryUpdate` | BEN or new BEN | after 3 days | Completes beneficiary change; re-validates contract beneficiaries |
| `cancelBeneficiaryUpdate` | BEN, RVK, or pending BEN | none | Cancels a pending beneficiary update |

Note: `VestingWalletLinear` has no `Ownable`. Guardian is an immutable address set at construction. The revoker is resolved dynamically via `IVestingManager(vestingManager).owner()`.

---

## PreMTRYClaim

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `setTGE` | GOV | none | One-time TGE activation |
| `lockPreTokens` | ANY | none | Burns preMTRY, records MTRY entitlement; bounded by MAX_CLAIM_POOL (40M) |
| `claim(amount)` | entitled user | none | Claims vested MTRY (clamped by global cap) |
| `claimTo(recipient, amount)` | entitled user | none | Redirects to a specified address |
| `recoverToken` | GOV | none | Recovers non-MTRY / non-preMTRY tokens sent by mistake |
| `proposeBurn` | GOV | 7-day timelock | Post-horizon burn of unclaimed pool |
| `cancelBurn` | VTO or GOV | none | Cancels pending burn |
| `executeBurn` | GOV | after 7 days | Burns unclaimed pool |
| `pause` | GRD or GOV | none | Halts claims |
| `unpause` | GOV | none | Restores claims |
| `setGuardian` / `setVeto` | GOV | none | Role rotation |
| `transferOwnership` / `acceptOwnership` | GOV / pending | accept step | Ownership transfer |

---

## EcosystemEmissionController

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `emitTo(recipient, amount)` | GOV | none | Distributes to approved recipient (bounded by epoch cap + shared lane) |
| `batchEmit(recipients, amounts)` | GOV | none | Batch distribution (up to 50) |
| `setApprovedRecipient` | GOV | none | Whitelists or de-whitelists emission recipients |
| `setPendingMaxEmissionPerEpoch` | GOV | next epoch | Changes per-epoch cap from next epoch |
| `cancelPendingMaxEmission` | VTO or GOV | none | Restores pending cap to current active cap |
| `proposeBurn` | GOV | 7-day timelock | Post-MAX_EPOCHS burn of remaining balance |
| `cancelBurn` | VTO or GOV | none | Cancels pending burn |
| `executeBurn` | GOV | after 7 days | Burns remaining post-epoch balance |
| `pause` | GRD or GOV | none | Halts emission |
| `unpause` | GOV | none | Restores emission |
| `setGuardian` / `setVeto` | GOV | none | Role rotation |
| `transferOwnership` / `acceptOwnership` | GOV / pending | accept step | Ownership transfer |

---

## PreMTRYSale

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `setWhitelist(account, bool)` | GOV | none | Adds or removes a single address from the purchase whitelist |
| `setWhitelistBatch(accounts[], bool)` | GOV | none | Bulk add/remove; reverts on any zero address in the array |
| `buy(usdcAmount, receiver)` | whitelisted sender + whitelisted receiver (within sale window) | none | Mints preMTRY, routes USDC to treasury; bounded by HARD_CAP and MAX_SUPPLY. `PreMTRYClaim` is whitelisted at deploy time as a system receiver. |
| `pause` | GRD or GOV | none | Halts sale |
| `unpause` | GOV | none | Restores sale |
| `setGuardian` / `setVeto` | GOV | none | Role rotation |
| `transferOwnership` / `acceptOwnership` | GOV / pending | accept step | Ownership transfer |

---

## MTRYToken

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `burn(amount)` | token holder | none | Burns caller's own tokens; reduces totalSupply |
| `burnFrom(account, amount)` | approved spender | none | Burns with allowance |
| `transfer` / `transferFrom` / standard ERC-20 | ANY | none | Standard token transfer |

MTRYToken has no owner after construction. No mint function. No pause.

---

## PreMTRYToken

| Function | Caller | Delay | Worst-case effect |
|----------|--------|-------|-------------------|
| `mint(to, amount)` | saleContract only | none | Mints preMTRY; bounded by MAX_SUPPLY (10M) |
| `burn(amount)` / `burnFrom` | holder / approved | none | Burns preMTRY |
| `setSaleContract` | GOV | none | Sets sale binding; blocked after finalizeSaleContract |
| `finalizeSaleContract` | GOV | none | Irrevocably locks sale binding |
| `setClaimContract` | GOV | none | Sets claim binding; blocked after finalizeClaimContract |
| `finalizeClaimContract` | GOV | none | Irrevocably locks claim binding |
| `transferOwnership` / `acceptOwnership` | GOV / pending | accept step | Ownership transfer |

Note: `PreMTRYToken` inherits `Ownable2Step` directly, not `GovernanceRoles`. It has no `guardian` or `veto` roles — no pause, no emergency controls.
