# MULTYR Protocol — MTRY Token Stack

> **These are the only official Multyr token contracts.** Verify addresses against the official audit report in [`audit-reports/`](audit-reports/). Beware of impersonators and fake tokens.

Non-upgradeable token stack for the MULTYR protocol on Arbitrum One.

**Status:** audited by HackenProof, August 2026 — all findings remediated. Full report: [`audit-reports/2026-08_HackenProof_MTRY-Token-Presale.pdf`](audit-reports/2026-08_HackenProof_MTRY-Token-Presale.pdf). Remediation detail: [`audit/RemediationResponse.md`](audit/RemediationResponse.md).

## Scope

The nine contracts in [`src/`](src/) are the complete token stack: the MTRY token itself, the presale pretoken and its KYC-gated sale, the pretoken-to-MTRY conversion, the vesting factory and wallets, the release-cap and emission controllers, and the shared governance base.

| Contract | Purpose |
|----------|---------|
| `MTRYToken` | Fixed 300M supply ERC-20, ERC20Burnable, `totalBurned` counter |
| `PreMTRYToken` | 10M max supply pretoken; mint by sale, burn by claim; finalizable bindings |
| `PreMTRYSale` | USDC-only sale at 0.08 USDC/preMTRY, 800K USDC hard cap; `buy()` gated by an on-chain KYC whitelist (sender + receiver) |
| `PreMTRYClaim` | Lock preMTRY into vested MTRY at 1:4 ratio (180d cliff + 540d linear) |
| `VestingManager` | Factory + registry for per-beneficiary vesting wallets; 8 bucket types; burn timelock |
| `VestingWalletLinear` | Single-beneficiary cliff+linear vesting wallet; optional revocability |
| `GlobalUnlockController` | Per-period dual-lane release cap with clamp semantics |
| `EcosystemEmissionController` | Epoch-based emission, whitelist, delayed caps |
| `GovernanceRoles` | Abstract base: Ownable2Step + guardian + veto triad |

## Token Allocations (sum = 300M)

| Category | Amount | Recipient |
|----------|--------|-----------|
| Treasury / Reserve | 75,000,000 | Treasury Safe (3/5 multisig) |
| Liquidity / Market Making | 45,000,000 | Liquidity Safe (3/5 multisig) |
| PreToken Claim Pool | 40,000,000 | PreMTRYClaim contract |
| Vesting (all buckets) | 111,000,000 | VestingManager contract |
| Ecosystem Emissions | 29,000,000 | EcosystemEmissionController contract |
| **Total** | **300,000,000** | |

### Vesting buckets (VestingManager, 111M total)

| Bucket | Cap | Cliff / Duration | Start modes |
|--------|-----|------------------|-------------|
| StrategicStandard | 27M | 6m / 18m | TGE or GRANT_DATE |
| StrategicExtended | 18M | 6m / 24m | TGE or GRANT_DATE |
| Team | 51M (shared with Growth, BDCore, BDPerformance) | 12m / 36m | GRANT_DATE only |
| AdvisorsStandard | 10.5M | 6m / 18m | GRANT_DATE only |
| AdvisorsShort | 4.5M | 3m / 18m | GRANT_DATE only |

## Governance

Three-role triad on all contracts:

- **SAFE_GOV** (3/5 multisig Owner) — proposes and executes all parameter changes
- **SAFE_GUARDIAN** (1/1 multisig) — emergency pause only; cannot unpause or propose
- **SAFE_VETO** (1/1 multisig) — cancels pending proposals within timelock windows

## Security properties

- No proxy, no upgradeability
- Ownable2Step on all ownable contracts
- ReentrancyGuard on all state-changing token operations
- SafeERC20 for all token transfers
- Custom errors throughout
- CEI pattern enforced
- Period-delayed governance parameters (cap changes, reference supply)
- 7-day burn timelock

To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Stack

- Solidity 0.8.28
- OpenZeppelin Contracts v5.6.1
- Deployment target: Arbitrum One (chain id 42161)
- Build / test: Foundry

## Build & test

```bash
# Clone with submodules (forge-std, openzeppelin-contracts)
git clone --recurse-submodules https://github.com/Multyr/MTRY.git
cd MTRY

# Build
forge build

# Full suite (561 tests; fork tests self-skip without an RPC)
forge test

# Fork tests against Arbitrum One
ARBITRUM_RPC_URL=<url> forge test --match-path "test/ForkArbitrum*" -vvv

# Deep fuzz (10,000 runs)
forge test --profile deep-fuzz

# Audit fuzz (50,000 runs)
forge test --profile audit
```

## Deploy

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARBITRUM_RPC_URL \
  --broadcast --verify
```

See [`docs/DEPLOY_FLOW.md`](docs/DEPLOY_FLOW.md) for the full deployment procedure and TGE activation.

## Audit

| Scope | Auditor | Outcome |
|---|---|---|
| MTRY token, PreMTRYSale (incl. on-chain KYC gating), preMTRY to MTRY conversion | HackenProof | Completed August 2026 — all findings remediated |
| Protocol core (Strategy Vaults, Allocation Vault) | TBD | Planned ahead of public launch |

The delivered report is published in full and unedited in [`audit-reports/`](audit-reports/). The preparation package handed to the auditors — scope, threat model, access-control matrix, invariants, formal verification and test evidence — is in [`audit/`](audit/).

## Documentation

| File | Contents |
|------|----------|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | System architecture, roles, invariants, dual-lane cap |
| [`docs/DEPLOY_FLOW.md`](docs/DEPLOY_FLOW.md) | Deploy procedure, wiring order, TGE activation |
| [`docs/TESTING.md`](docs/TESTING.md) | Test suite description and reproduction steps |
| [`audit/Scope.md`](audit/Scope.md) | Audit scope, frozen commit, pre-audit remediations |
| [`audit/RemediationResponse.md`](audit/RemediationResponse.md) | Per-finding remediation record |
| [`audit/Invariants.md`](audit/Invariants.md) | Trust assumptions, invariants, known patterns |
| [`audit/ThreatModel.md`](audit/ThreatModel.md) | Per-role abuse analysis, griefing surface |
| [`audit/KnownLimitations.md`](audit/KnownLimitations.md) | Accepted risks with monitoring notes |

## License

MIT — see [`LICENSE`](LICENSE).
