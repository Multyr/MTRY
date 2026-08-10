# Audit Reports

Published external security audit reports for the MULTYR protocol. Reports are published in full, unedited.

This folder holds the delivered reports. The internal preparation package that was handed to the auditors — scope, threat model, access-control matrix, invariants, and test evidence — is in [`../audit/`](../audit/).

| Scope | Auditor | Status | Report |
|---|---|---|---|
| MTRY token, PreMTRYSale contract (incl. on-chain KYC gating), preMTRY to MTRY conversion | HackenProof | Completed August 2026 — all findings remediated | [2026-08_HackenProof_MTRY-Token-Presale.pdf](./2026-08_HackenProof_MTRY-Token-Presale.pdf) |
| Protocol core (Strategy Vaults, Allocation Vault) | TBD | Planned ahead of public launch | — |

Audits follow the protocol's launch sequence: the token and presale contracts are audited first, because they are what the presale sells. The protocol core completes external audit before public deposits open.

To report a vulnerability, see [`../SECURITY.md`](../SECURITY.md).
