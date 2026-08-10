// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPreTokenBinding} from "./interfaces/IPreTokenBinding.sol";
import {
    ZeroAddress,
    MaxSupplyExceeded,
    Unauthorized,
    AlreadySet,
    InvalidBeneficiaryContract,
    RenounceOwnershipDisabled
} from "./Errors.sol";

/// @title PreMTRYToken — MULTYR PreToken
/// @notice Capped ERC-20 pretoken. Max supply 10,000,000 preMTRY.
/// @dev Mint only by saleContract, burn only by claimContract. Freely transferable.
///      Sale and claim contract bindings are editable until explicitly finalized by governance,
///      after which they become permanent.
contract PreMTRYToken is ERC20, Ownable2Step {
    /// @notice Maximum supply of preMTRY tokens: 10 million (18 decimals)
    uint256 public constant MAX_SUPPLY = 10_000_000e18;

    /// @notice The authorized sale contract that can mint preMTRY.
    address public saleContract;
    /// @notice The authorized claim contract that can burn preMTRY.
    address public claimContract;

    /// @notice Finalization flags. Once true, the corresponding binding is immutable.
    bool public saleContractFinalized;
    bool public claimContractFinalized;

    event SaleContractSet(address indexed saleContract);
    event SaleContractFinalized(address indexed saleContract);
    event ClaimContractSet(address indexed claimContract);
    event ClaimContractFinalized(address indexed claimContract);

    /// @param initialOwner Initial owner (transferred to Foundation SAFE after deploy).
    /// @dev initialOwner == address(0) is caught by OpenZeppelin Ownable.
    constructor(address initialOwner) ERC20("preMULTYR", "preMTRY") Ownable(initialOwner) {}

    // -------------------------------------------------------------------------
    // Bindings — editable until finalized
    // -------------------------------------------------------------------------

    /// @notice Set or update the sale contract binding. Must be a deployed contract whose
    ///         `preToken()` view returns this token. Callable until `finalizeSaleContract`.
    function setSaleContract(address sale) external onlyOwner {
        if (saleContractFinalized) revert AlreadySet();
        _validateBindingCandidate(sale);
        saleContract = sale;
        emit SaleContractSet(sale);
    }

    /// @notice Freeze the sale contract binding. Requires a non-zero address already set.
    function finalizeSaleContract() external onlyOwner {
        if (saleContractFinalized) revert AlreadySet();
        if (saleContract == address(0)) revert ZeroAddress();
        saleContractFinalized = true;
        emit SaleContractFinalized(saleContract);
    }

    /// @notice Set or update the claim contract binding. Must be a deployed contract whose
    ///         `preToken()` view returns this token. Callable until `finalizeClaimContract`.
    function setClaimContract(address claim) external onlyOwner {
        if (claimContractFinalized) revert AlreadySet();
        _validateBindingCandidate(claim);
        claimContract = claim;
        emit ClaimContractSet(claim);
    }

    /// @notice Freeze the claim contract binding. Requires a non-zero address already set.
    function finalizeClaimContract() external onlyOwner {
        if (claimContractFinalized) revert AlreadySet();
        if (claimContract == address(0)) revert ZeroAddress();
        claimContractFinalized = true;
        emit ClaimContractFinalized(claimContract);
    }

    /// @dev Candidate must be a deployed contract whose `preToken()` returns this token.
    function _validateBindingCandidate(address candidate) internal view {
        if (candidate == address(0)) revert ZeroAddress();
        if (candidate.code.length == 0) revert InvalidBeneficiaryContract();
        try IPreTokenBinding(candidate).preToken() returns (address bound) {
            if (bound != address(this)) revert InvalidBeneficiaryContract();
        } catch {
            revert InvalidBeneficiaryContract();
        }
    }

    // -------------------------------------------------------------------------
    // Mint / burn
    // -------------------------------------------------------------------------

    /// @notice Mint preMTRY. Only callable by the authorized sale contract.
    function mint(address to, uint256 amount) external {
        if (msg.sender != saleContract) revert Unauthorized();
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    /// @notice Burn preMTRY from caller's balance. Only callable by the claim contract.
    function burn(uint256 amount) external {
        if (msg.sender != claimContract) revert Unauthorized();
        _burn(msg.sender, amount);
    }

    /// @notice I-6: permanently disabled — see GovernanceRoles.renounceOwnership for rationale.
    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
