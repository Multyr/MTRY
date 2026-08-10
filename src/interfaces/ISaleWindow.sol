// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISaleWindow
/// @notice Interface exposed by PreMTRYSale so PreMTRYClaim can bind TGE activation to the
///         sale's immutable close time (MULTYR-1: prevents a purchase from succeeding after
///         the preMTRY conversion window has already closed).
interface ISaleWindow {
    function saleEnd() external view returns (uint256);
}
