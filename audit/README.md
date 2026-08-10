# MULTYR Token Stack — Audit Package

**Solidity:** 0.8.28 | **OZ:** v5.6.1 | **Chain:** Arbitrum One (42161)
**Forge:** 1.7.1 | **Halmos:** 0.3.3 | **Slither:** 0.11.5 | **Aderyn:** 0.1.9

This folder contains the complete documentation package for the external security audit.
For architecture detail, see [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

---

## Documents in this package

| File | Contents |
|------|---------|
| `Scope.md` | Frozen scope: branch, contracts in/out, pre-audit remediations applied |
| `ThreatModel.md` | Per-role attacker capabilities, worst-case analysis, mis-deployment risks |
| `AccessControlMatrix.md` | Function-by-function table: who can call, delay, worst-case effect |
| `Invariants.md` | System-level invariants, trust assumptions, intentional behaviors |
| `KnownLimitations.md` | Accepted risks with rationale and monitoring notes |
| `TestReport.md` | Test counts, coverage table, static analysis, threat-model cross-check |
| `FormalVerification.md` | Halmos symbolic proof results (27 proofs, ~130 SMT paths — one proof's count varies run to run, see doc; 5 contracts) |
| `Dependencies.md` | External assumptions: OZ v5.6.1, USDC Arbitrum, sequencer/clock |

For full architecture: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)

---

## Quick start

```bash
# 1. Checkout the remediation snapshot
git checkout mtry-token-remediation-v1   # tag — full HackenProof remediation (MULTYR-1..6, MULTYR-8)

# 2. Install dependencies
forge install

# 3. Run all tests (no RPC required — skip fork tests)
forge test --no-match-path "test/ForkArbitrum*"
# Expected: 550 passed, 0 failed

# 4. Run all tests including fork (requires Arbitrum RPC)
ARBITRUM_RPC_URL=<your-rpc> forge test
# Expected: 561 passed, 0 failed

# 5. Coverage — note: the filters below exclude only the 2 stateful `invariant_*`
#    entrypoints; the fork, fuzz and multi-lane invariant suites still run (559 tests)
forge coverage \
  --no-match-path "test/ForkArbitrum*|test/halmos/*" \
  --no-match-test "invariant|fuzz" \
  --report summary

# 6. Halmos symbolic proofs (requires Python 3.10+)
# AST output is required in the build artifacts (halmos fails with KeyError: 'ast'
# otherwise) -- `ast = true` in foundry.toml means step 3's `forge test` already
# produced artifacts with it, so no separate --ast flag is needed here.
pip install halmos
halmos --match-contract "Symbolic"
# Expected: 27 / 27 pass (one proof's path count varies run to run -- see FormalVerification.md)
```

---

## Reading order

1. **Start here:** `Scope.md` — what's in scope, what changed before freeze.
2. **Architecture:** [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) — full contract map, token flows, governance model.
3. **Trust model:** `ThreatModel.md` and `Invariants.md` — what we trust, what we've proven, what we've accepted.
4. **Access control:** `AccessControlMatrix.md` — function-by-function caller/delay/effect.
5. **Edge cases:** `KnownLimitations.md` — documented rough edges and why they're accepted.
6. **Evidence:** `TestReport.md` and `FormalVerification.md` — test counts, coverage, Halmos proofs.
7. **Dependencies:** `Dependencies.md` — external contracts and sequencer assumptions.

---

## Test summary at a glance

| Metric | Value |
|--------|-------|
| Total Forge tests | **561 pass / 0 fail** |
| Coverage run (excludes the 2 stateful `invariant_*` entrypoints) | **559 tests** |
| Stateful invariant suites | 2 × 128k call sequences |
| Fork tests (Arbitrum mainnet) | 8 / 8 |
| Halmos symbolic proofs | 27 / 27 (~130 SMT paths, varies — see FormalVerification.md) |
| Slither critical/high | 0 (28 contracts analyzed, v0.11.5) |
| Aderyn actionable high | 0 (1 high finding is false positive) |
| Contracts at 100% line/statement/branch/function coverage | 3 of 9 |
