// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVestingManager — minimal interface consumed by VestingWalletLinear
/// @notice Used for (a) dynamic authority lookup via `owner()` (OZ Ownable), (b) bucket-cap
///         revocation accounting, and (c) beneficiary contract whitelist checks.
interface IVestingManager {
    /// @notice Current guardian (triad emergency pause role). Dynamic authority lookup, mirroring
    ///         `owner()`: a governance rotation on the manager propagates to every deployed wallet.
    function guardian() external view returns (address);

    /// @notice Record a wallet's revocation, crediting only the returned-to-treasury (unvested)
    ///         amount against bucket capacity rather than the full original allocation.
    function recordRevocation(address wallet, uint256 returnedToTreasury) external;

    /// @notice Synchronize the registry's beneficiary field after a wallet's 2-phase
    ///         beneficiary reassignment is confirmed.
    function recordBeneficiaryUpdate(address wallet, address newBeneficiary) external;

    /// @notice Whether `candidate` is whitelisted as a beneficiary contract.
    function isWhitelistedBeneficiaryContract(address candidate) external view returns (bool);
}
