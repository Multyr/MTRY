# MULTYR Protocol — Documentation Index

## Governance

The MTRY token stack is governed by a three-entity architecture aligned with the Multyr allocation protocol:

- **SAFE_GOV (3/5 multisig)** — owner of all token contracts. Proposes parameter changes, burns, authorizations.
- **SAFE_GUARDIAN (1/1 multisig)** — emergency pause authority on all pausable contracts. Cannot unpause or propose.
- **SAFE_VETO (1/1 multisig)** — cancels pending burn proposals and cap changes during timelock window.

## Canonical documents

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Contracts, allocations, bucket policy, global unlock cap, governance roles |
| [DEPLOY_FLOW.md](DEPLOY_FLOW.md) | 3-phase deploy with triad governance |
| [TESTING.md](TESTING.md) | 528 forge tests + 27 Halmos proofs + 8 fork tests |
