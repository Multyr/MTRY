// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPreTokenBinding
/// @notice Interface exposed by PreMTRYSale and PreMTRYClaim so PreMTRYToken can verify that
///         candidate sale/claim contracts point back at this very preToken before finalization.
interface IPreTokenBinding {
    function preToken() external view returns (address);
}
