// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ZeroAddress, RenounceOwnershipDisabled} from "../Errors.sol";

/// @title GovernanceRoles
/// @notice Triad governance roles (Owner / Guardian / Veto) for MULTYR contracts.
/// @dev
///      - Owner: Ownable2Step. Full administrative authority.
///      - Guardian: single address. May trigger emergency pause but cannot unpause,
///        change ownership, or alter parameters.
///      - Veto: single address. May cancel pending proposals (burns, cap changes) during
///        their timelock window. Cannot propose or pause.
///      Contracts that do not need a veto role (e.g. PreMTRYSale) simply leave `veto` at
///      address(0); the setter is still callable by the owner if policy changes.
abstract contract GovernanceRoles is Ownable2Step {
    address public guardian;
    address public veto;

    event GuardianUpdated(address indexed previous, address indexed next);
    event VetoUpdated(address indexed previous, address indexed next);

    error NotGuardian();
    error NotGuardianOrOwner();
    error NotVetoOrOwner();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    modifier onlyVetoOrOwner() {
        if (msg.sender != veto && msg.sender != owner()) revert NotVetoOrOwner();
        _;
    }

    /// @notice Owner sets the Guardian address. Reverts on zero address.
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        address prev = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(prev, newGuardian);
    }

    /// @notice Owner sets the Veto address. Reverts on zero address.
    function setVeto(address newVeto) external onlyOwner {
        if (newVeto == address(0)) revert ZeroAddress();
        address prev = veto;
        veto = newVeto;
        emit VetoUpdated(prev, newVeto);
    }

    /// @notice I-6: permanently disabled. An ownerless contract can never be unpaused or have
    ///         its Guardian/Veto rotated again — renouncing must go through a governance
    ///         transfer to a new owner instead.
    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
