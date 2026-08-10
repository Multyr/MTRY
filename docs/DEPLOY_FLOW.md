# MULTYR Token Stack — Deploy Flow

Three-phase deployment with triad governance (SAFE_GOV / SAFE_GUARDIAN / SAFE_VETO).

## Environment variables

```
SAFE_GOV                # 3/5 multisig — owner of all contracts
SAFE_GUARDIAN           # 1/1 multisig — emergency pause
SAFE_VETO               # 1/1 multisig — cancel pending proposals
TREASURY_SAFE           # 3/5 multisig — receives 75M MTRY
LIQUIDITY_SAFE          # 3/5 multisig — receives 45M MTRY
SALE_START
SALE_END
UNLOCK_GENESIS          # GlobalUnlockController genesis (IMMUTABLE)
ECOSYSTEM_GENESIS       # EcosystemEmissionController genesis (IMMUTABLE)
ARBITRUM_RPC_URL
```

## Phase A — pre-TGE contract deployment

Run `forge script script/Deploy.s.sol:Deploy --rpc-url $ARBITRUM_RPC_URL --broadcast`.

1. Deploy `GlobalUnlockController` (referenceSupply 300M, cap 200 bps, period 30 days).
2. Deploy `EcosystemEmissionController` (epochDuration 30 days, maxEmission 1M).
3. Deploy `PreMTRYClaim` (uninitialized).
4. Deploy `VestingManager` (guardian is resolved live from `VestingManager.guardian()` — see step 11 — not passed at construction; MULTYR-6/L-3).
5. Deploy `MTRYToken` — mints 75+45+40+111+29 = 300M.
6. Deploy `PreMTRYToken`.
7. Deploy `PreMTRYSale` (hard-coded Arbitrum USDC).
8. Wire: `claim.initialize`, `preMTRY.setSaleContract/finalize`, `preMTRY.setClaimContract/finalize`.
9. Wire: `unlockController.setVestingManager`, authorize sources, set protected source.
10. Set bucket caps on VestingManager.
11. Configure Guardian on all 5 ownable contracts.
12. Configure Veto on contracts that support it (claim, vestingManager, unlockController, ecosystem).
13. `transferOwnership(SAFE_GOV)` on all ownable contracts.

**At this point** GRANT_DATE vestings can already be created. TGE-based vestings wait for Phase B.

### Post-phase-A checks

Run `PostDeployChecks.s.sol` with `OWNERSHIP_PHASE=pre-acceptance`.

SAFE_GOV (3/5 signature) must call `acceptOwnership()` on:
- GlobalUnlockController
- VestingManager
- EcosystemEmissionController
- PreMTRYClaim
- PreMTRYToken
- PreMTRYSale

Re-run with `OWNERSHIP_PHASE=post-acceptance`.

## Phase B — TGE

SAFE_GOV (3/5 signature) calls:
1. `vestingManager.setTGE(tgeTimestamp)`
2. `preMTRYClaim.setTGE(tgeTimestamp)`

`tgeTimestamp` MUST be `>= sale.saleEnd()` — `preMTRYClaim.setTGE()` reverts `TGEBeforeSaleEnd`
otherwise (MULTYR-1). The sale must close before (or at) TGE so every accepted purchase still
has the full `CLIFF_DURATION` window after TGE to call `lockPreTokens`.

`GlobalUnlockController.genesisTimestamp` and `EcosystemEmissionController.genesis` are IMMUTABLE (set at deploy).

## Phase C — beneficiary assignment

SAFE_GOV calls `vestingManager.createVesting(...)` or `batchCreateVestings(params[])` (max 50 per call).

Each call:
1. Validates bucket × startMode policy and duration bounds.
2. Resolves startTimestamp per policy.
3. Enforces bucket cap (with revocation accounting).
4. Deploys VestingWalletLinear (guardian is not passed at construction; the wallet resolves it live from `VestingManager.guardian()` on every call — MULTYR-6/L-3).
5. Transfers allocation, verifies balance.
6. Authorizes wallet via `unlockController.addVestingSource`.
7. Registers in on-chain registry.
