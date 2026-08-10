# MULTYR Token Stack — Dependencies & External Assumptions

## Solidity

- **Version:** 0.8.28 (fixed in all source files)
- **Optimizer:** enabled; runs configurable via `foundry.toml`
- **Checked arithmetic:** enabled by default (overflow/underflow revert at runtime)

## OpenZeppelin Contracts v5.6.1

The following OZ contracts are used directly:

| OZ Contract | Used in |
|-------------|---------|
| `Ownable` / `Ownable2Step` | `GovernanceRoles` base, `PreMTRYToken` |
| `Pausable` | `PreMTRYSale`, `PreMTRYClaim`, `VestingManager`, `GlobalUnlockController`, `EcosystemEmissionController` |
| `ReentrancyGuard` | `PreMTRYSale`, `PreMTRYClaim`, `VestingManager`, `EcosystemEmissionController` |
| `ERC20` | `MTRYToken`, `PreMTRYToken` |
| `ERC20Burnable` | `MTRYToken`, `PreMTRYClaim`, `VestingManager`, `EcosystemEmissionController` |
| `SafeERC20` | `PreMTRYSale`, `PreMTRYClaim`, `VestingManager`, `VestingWalletLinear`, `EcosystemEmissionController` |

OZ v5.6.1 was the latest stable release at audit time. No known critical vulnerabilities affecting these contracts at audit time.

**Assumptions:**
- OZ `Ownable2Step` two-step ownership transfer is correctly implemented.
- OZ `Pausable` modifier `whenNotPaused` is correctly enforced.
- OZ `ReentrancyGuard` prevents reentrancy in the decorated functions.
- OZ `SafeERC20` correctly handles non-standard ERC-20 return values.
- OZ `ERC20Burnable.burn` permanently reduces `totalSupply`.

## USDC on Arbitrum One

**Address:** `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`

Hard-coded in `PreMTRYSale.sol` alongside a chain ID check (`block.chainid == 42161`). This is the official Circle-issued USDC on Arbitrum One, as listed in the Circle developer documentation at audit time.

**Assumptions:**
- USDC is a standard ERC-20 (6 decimals, no fee on transfer, no rebase).
- The USDC contract is not upgradeable in a way that changes the ERC-20 interface.
- The hard-coded address is not subject to blacklisting that would affect the treasury recipient.
- USDC does not implement hooks that could cause reentrancy.

The sale contract uses `SafeERC20.safeTransferFrom` to pull USDC from buyers and `safeTransfer` to route to the treasury. No balance-checks that would be sensitive to non-standard USDC behavior.

## Arbitrum One Sequencer

The protocol deploys on Arbitrum One (chain ID 42161).

**Assumptions:**
- `block.timestamp` advances monotonically and reflects real elapsed time within reasonable bounds (the sequencer follows real-world clock with ~second-level accuracy).
- Period and epoch boundaries are computed from `block.timestamp` against an immutable genesis. A sequencer timestamp manipulation would have to shift `block.timestamp` by a full period duration (default: 30 days) to meaningfully affect period accounting — far beyond any realistic sequencer soft-reordering.
- No front-running risk exists in the critical paths: `consumeAllowance` granted amounts are deterministic at the time of the call (cap remaining at that point); MEV cannot profitably extract value by reordering calls.
- Arbitrum One does not produce chain reorganizations under normal sequencer operation. Fork safety for multi-block actions (e.g., 7-day burn timelock) is therefore not a concern.

## No Price Oracle, No AMM, No Flash Loan Entry

The MTRY token stack contains no price oracle integrations, no AMM liquidity operations, and no flash loan entry points. All token amounts are governance-set or deterministic (vesting schedules, period caps). There is no economic attack surface from oracle manipulation or flash loan abuse.

## Gnosis Safe

The three governance entities (SAFE_GOV 3/5, SAFE_GUARDIAN 1/1, SAFE_VETO 1/1) are expected to be Gnosis Safe multisigs. The protocol does not interact with Safe contracts directly; it only checks `msg.sender == owner()` (or guardian/veto address). Safe correctness is out of scope.
