# Security Policy

## Reporting a Vulnerability

Report suspected vulnerabilities in the MULTYR contracts, infrastructure, or processes by email:

**[security@multyr.fi](mailto:security@multyr.fi)**

Do not open a public GitHub issue, pull request, or discussion for a security report, and do not disclose the issue publicly until it has been remediated.

Include where practical:

- affected contract, address, or repository path
- a description of the impact and the conditions required to trigger it
- reproduction steps, a proof-of-concept, or a failing test
- any suggested remediation

### What to expect

- acknowledgement of the report within 72 hours
- an initial assessment within 7 days
- coordination with you before any public disclosure

The full process, including the planned bug bounty program and PGP key, is documented at [docs.multyr.fi/security/responsible-disclosure](https://docs.multyr.fi/security/responsible-disclosure).

## Audit Reports

Published audit reports live in [`audit-reports/`](./audit-reports/), with the current status of each engagement in [`audit-reports/README.md`](./audit-reports/README.md).

The internal audit preparation package — scope, threat model, access-control matrix, invariants, and test evidence — is in [`audit/`](./audit/).

## Security Documentation

| Page | Contents |
|---|---|
| [Security Overview](https://docs.multyr.fi/security/overview) | Security architecture, governance triad, capital protection |
| [Audits & Bug Bounty](https://docs.multyr.fi/security/audits) | Audit status and bounty program |
| [Responsible Disclosure](https://docs.multyr.fi/security/responsible-disclosure) | Full disclosure process and contacts |
| [Access Control](https://docs.multyr.fi/security/access-control) | Roles, permissions, timelocks |
| [Emergency Procedures](https://docs.multyr.fi/security/emergency) | Pause, veto, and incident response |

## Scope

This policy covers the contracts in this repository. The deployed addresses under audit are listed in [`audit/Scope.md`](./audit/Scope.md).

Contracts are non-upgradeable and deployed on Arbitrum One. Reports concerning third-party dependencies (OpenZeppelin, USDC, the Arbitrum sequencer) should be directed to their respective maintainers.
