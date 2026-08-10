# MULTYR Token Stack — Testing

Full verification matrix: unit / integration / fuzz / stateful-invariant / fork / symbolic formal proofs / governance separation.

## Summary

| Metric | Value |
|--------|-------|
| Foundry test suites | 40 non-fork + 1 fork |
| Foundry tests | **520** non-fork; **528** total including 8 fork |
| Passing | 528 |
| Failing | 0 |
| Fuzz runs per fuzz test | 256 |
| Invariant runs × calls per suite | 256 × 500 = 128,000 |
| Halmos symbolic proofs | **27** (5 contracts, 147 SMT paths) |
| Fork tests on Arbitrum mainnet | 8 / 8 |

## Core unit and integration suites

| Suite | File | Tests |
|-------|------|-------|
| `MTRYTokenTest` | `test/MTRYToken.t.sol` | 21 |
| `PreMTRYTokenTest` | `test/PreMTRYToken.t.sol` | 38 |
| `PreMTRYSaleTest` | `test/PreMTRYSale.t.sol` | 50 |
| `PreMTRYClaimTest` | `test/PreMTRYClaim.t.sol` | 56 |
| `VestingWalletLinearTest` | `test/VestingWalletLinear.t.sol` | 45 |
| `VestingManagerTest` | `test/VestingManager.t.sol` | 49 |
| `EcosystemEmissionControllerTest` | `test/EcosystemEmissionController.t.sol` | 44 |
| `GlobalUnlockControllerTest` | `test/GlobalUnlockController.t.sol` | 50 |
| `IntegrationTest` | `test/Integration.t.sol` | 9 |
| `RevocationAccountingTest` | `test/RevocationAccounting.t.sol` | 7 |
| `BeneficiaryWhitelistTest` | `test/BeneficiaryWhitelist.t.sol` | 7 |
| `ProtectedQuotaBoundsTest` | `test/ProtectedQuotaBounds.t.sol` | 5 |
| `EmergencyRevokeTest` | `test/EmergencyRevoke.t.sol` | 5 |
| `DurationValidationTest` | `test/DurationValidation.t.sol` | 5 |
| `GovernanceSeparationTest` | `test/GovernanceSeparation.t.sol` | 29 |
| `SetTGEIntegrationTest` | `test/SetTGEIntegration.t.sol` | 5 |
| `DeployIntegrationTest` | `test/DeployIntegration.t.sol` | 18 |

POC regression suites under `test/poc/` (15 suites, 51 tests total) are included in the 520 non-fork count.

## Fuzz suites

| Suite | Tests | Runs |
|-------|-------|------|
| `GlobalUnlockControllerFuzzTest` | 4 | 256 × 4 |
| `VestingWalletLinearFuzzTest` | 3 | 256 × 3 |
| `VestingManagerFuzzTest` | 2 | 256 × 2 |
| `EcosystemEmissionControllerFuzzTest` | 2 | 256 × 2 |
| `TokenStackCrossFlowFuzzTest` | 1 | 256 |

## Stateful-invariant suites

| Suite | Tests | Calls per invariant |
|-------|-------|---------------------|
| `TokenStackInvariantsTest` | 4 | 256 × 500 |
| `UnlockCapInvariantsTest` | 2 | 256 × 500 |
| `UnlockCapInvariantsMultiLaneTest` | 6 | 256 × 500 |

## Fork tests

`test/ForkArbitrum.t.sol` — 8 tests on Arbitrum One mainnet (requires `ARBITRUM_RPC_URL`).

## Formal verification (Halmos)

`test/halmos/` — 27 symbolic proofs via Yices 2.6.4. See [audit/FormalVerification.md](../audit/FormalVerification.md).

| Suite | Proofs | Paths |
|-------|--------|-------|
| GlobalUnlockControllerSymbolicTest | 6 | 57 |
| VestingWalletLinearSymbolicTest | 6 | 24 |
| VestingManagerSymbolicTest | 5 | 16 |
| EcosystemEmissionSymbolicTest | 5 | 17 |
| PreMTRYSaleSymbolicTest | 5 | 33 |

## Running the suites

```bash
forge build
forge test                                          # 528 total (includes fork)
forge test --no-match-path "test/ForkArbitrum*"    # 520 (offline, no RPC)
forge test --match-contract GovernanceSeparationTest
forge test --match-path "test/fuzz/**"
forge test --match-path "test/invariant/**"
ARBITRUM_RPC_URL=... forge test --match-path test/ForkArbitrum.t.sol
halmos --match-contract "Symbolic"
```

## Static analysis

- **Slither v0.11.5** — `slither . --compile-force-framework foundry --exclude-optimization --exclude-informational --filter-paths "test/,lib/"`
- **Aderyn v0.1.9** — `FOUNDRY_EVM_VERSION=cancun aderyn --src src/`

See [audit/TestReport.md](../audit/TestReport.md) for current coverage numbers and static analysis results.
