// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUnlockController — interface for GlobalUnlockController
/// @notice Consumed by all token-release sources (vesting wallets, ecosystem emissions, claim contracts)
///         to enforce a global per-period release cap.
///
/// Clamp semantics: `consumeAllowance` returns the actually-granted amount (≤ requested).
/// Callers MUST use the returned value to size their actual token transfer.
/// The contract NEVER reverts on cap exhaustion — only unauthorized callers or zero-amount revert.
interface IUnlockController {
    /// @notice Consume up to `amount` from the current period's global unlock budget.
    /// @param amount The amount the caller wishes to release.
    /// @return granted The amount actually allowed — `min(amount, remainingAllowance())`.
    ///                 May be 0 if the cap is exhausted; callers must handle this.
    function consumeAllowance(uint256 amount) external returns (uint256 granted);

    /// @notice Returns the remaining allowance in the current period.
    function remainingAllowance() external view returns (uint256);

    /// @notice Returns the deterministic current period index.
    function currentPeriod() external view returns (uint256);

    /// @notice Returns the maximum unlock amount allowed for a given period.
    function maxUnlockForPeriod(uint256 period) external view returns (uint256);

    /// @notice Authorize a newly-created vesting wallet as an unlock source.
    ///         Callable ONLY by the registered VestingManager.
    function addVestingSource(address wallet) external;
}
