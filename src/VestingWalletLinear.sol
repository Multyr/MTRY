// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUnlockController} from "./interfaces/IUnlockController.sol";
import {IVestingManager} from "./interfaces/IVestingManager.sol";
import {
    ZeroAddress,
    ZeroAmount,
    NothingToRelease,
    AlreadyRevoked,
    NotRevocable,
    NotRevoker,
    NotBeneficiary,
    NotAuthorized,
    BeneficiaryUpdatePending,
    NoBeneficiaryUpdatePending,
    BeneficiaryUpdateNotReady,
    UnlockThrottled,
    InvalidBeneficiaryContract
} from "./Errors.sol";

/// @title VestingWalletLinear — single-beneficiary cliff + linear vesting wallet
/// @notice Dumb storage of the vesting grant; VestingManager resolves TGE vs GRANT_DATE policy
///         and passes the final `startTimestamp` at construction.
/// @dev
///   - `startTimestamp` is IMMUTABLE and provided by the factory
///   - optional revocability: unvested tokens return to a pre-set `treasury` address
///   - 2-phase beneficiary update with 2-day delay (propose → confirm)
///   - claim enforces the global unlock cap via `IUnlockController.consumeAllowance` (clamp)
///   - `revokeUnvested` bypasses the unlock controller (tokens are not "released into circulation")
contract VestingWalletLinear is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The MTRY token held and released by this wallet.
    IERC20 public immutable token;

    /// @notice Vesting grant start timestamp (TGE or GRANT_DATE, resolved by the manager).
    uint256 public immutable startTimestamp;
    uint256 public immutable cliffDuration;
    uint256 public immutable vestingDuration;
    uint256 public immutable totalAllocation;

    /// @notice Mutable beneficiary (2-phase update). Immutable storage layout choice: mutable address.
    address public beneficiary;

    /// @notice Cumulative tokens released to the beneficiary (or claimTo recipient).
    uint256 public claimedAmount;

    /// @notice Revocability configuration.
    bool public immutable revocable;
    bool public revoked;
    uint256 public revokedAt;
    /// @notice VestingManager that deployed this wallet. Its `owner()` is resolved dynamically
    ///         as the authority for revoke / pause / beneficiary-update admin actions,
    ///         so governance migrations on the manager propagate to every wallet automatically.
    address public immutable vestingManager;
    address public immutable treasury;
    address public immutable unlockController;

    /// @notice 2-phase beneficiary update.
    address public pendingBeneficiary;
    uint256 public beneficiaryUpdateAt;
    uint256 public constant BENEFICIARY_UPDATE_DELAY = 2 days;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event Claimed(address indexed beneficiary, address indexed to, uint256 amount);
    event BeneficiaryUpdateProposed(address indexed oldBeneficiary, address indexed newBeneficiary, uint256 executableAt);
    event BeneficiaryUpdateConfirmed(address indexed oldBeneficiary, address indexed newBeneficiary);
    event BeneficiaryUpdateCancelled(address indexed proposed);
    event Revoked(address indexed revoker, uint256 unvestedRecovered, uint256 timestamp);
    event EmergencyRevoked(address indexed revoker, uint256 unvestedRecovered, uint256 timestamp);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @notice Current revoker — always the live `owner()` of the VestingManager.
    ///         Dynamic: follows governance migrations on the manager.
    function revoker() public view returns (address) {
        return Ownable(vestingManager).owner();
    }

    /// @notice Current guardian (triad emergency pause role) — always the live `guardian()` of
    ///         the VestingManager. Dynamic, mirroring `revoker()`: a governance rotation via
    ///         `VestingManager.setGuardian` propagates to every deployed wallet immediately,
    ///         instead of leaving already-deployed wallets pinned to a stale address.
    function guardian() public view returns (address) {
        return IVestingManager(vestingManager).guardian();
    }

    modifier onlyRevoker() {
        if (msg.sender != revoker()) revert NotRevoker();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    /// @param token_ The MTRY token
    /// @param beneficiary_ Initial beneficiary
    /// @param startTimestamp_ Resolved grant start (TGE or grant-date) provided by manager
    /// @param cliffDuration_ Cliff length in seconds (may be 0 for no-cliff grants)
    /// @param vestingDuration_ Linear vesting length in seconds (must be > 0)
    /// @param totalAllocation_ Fixed token allocation (immutable)
    /// @param revocable_ Whether `revokeUnvested` is enabled
    /// @param vestingManager_ The VestingManager that deploys this wallet; its live `owner()` is
    ///                        the dynamic revoker authority for revoke / pause / beneficiary updates
    /// @param treasury_ Destination of revoked unvested tokens
    /// @param unlockController_ GlobalUnlockController for claim-time cap enforcement
    constructor(
        address token_,
        address beneficiary_,
        uint256 startTimestamp_,
        uint256 cliffDuration_,
        uint256 vestingDuration_,
        uint256 totalAllocation_,
        bool revocable_,
        address vestingManager_,
        address treasury_,
        address unlockController_
    ) {
        if (token_ == address(0)) revert ZeroAddress();
        if (beneficiary_ == address(0)) revert ZeroAddress();
        if (vestingManager_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (unlockController_ == address(0)) revert ZeroAddress();
        if (vestingDuration_ == 0) revert ZeroAmount();
        if (totalAllocation_ == 0) revert ZeroAmount();

        token = IERC20(token_);
        beneficiary = beneficiary_;
        startTimestamp = startTimestamp_;
        cliffDuration = cliffDuration_;
        vestingDuration = vestingDuration_;
        totalAllocation = totalAllocation_;
        revocable = revocable_;
        vestingManager = vestingManager_;
        treasury = treasury_;
        unlockController = unlockController_;
    }

    // -------------------------------------------------------------------------
    // Claim (clamp semantics via GlobalUnlockController)
    // -------------------------------------------------------------------------

    /// @notice Beneficiary claims vested tokens. Amount may be clamped by the global cap.
    function claim() external nonReentrant whenNotPaused {
        _claim(beneficiary);
    }

    /// @notice Beneficiary redirects the claim to another address.
    function claimTo(address to) external nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        _claim(to);
    }

    function _claim(address to) internal {
        if (msg.sender != beneficiary) revert NotBeneficiary();

        // I-1: re-check the contract whitelist at claim time, not just at propose/confirm. A
        // counterfactual (CREATE2) address has no code at confirmation and passes as an EOA, but
        // could have code deployed to it afterward. This closes that bypass without weakening the
        // propose/confirm checks, and also re-enforces a governance de-whitelist that happens
        // after a contract beneficiary was already confirmed.
        //
        // code.length alone is not sufficient: a contract calling out from its own constructor
        // reports code.length == 0 even though it is unambiguously a contract (EXTCODESIZE is 0
        // until construction finishes -- a documented Solidity/OZ caveat). Only a genuine EOA can
        // ever be both msg.sender and tx.origin (nested calls are always contract-to-contract), so
        // require both signals -- not code.length alone -- before treating beneficiary as an EOA
        // exempt from the whitelist.
        if (beneficiary.code.length > 0 || beneficiary != tx.origin) {
            if (!IVestingManager(vestingManager).isWhitelistedBeneficiaryContract(beneficiary)) {
                revert InvalidBeneficiaryContract();
            }
        }

        uint256 amount = _releasable();
        if (amount == 0) revert NothingToRelease();

        uint256 granted = IUnlockController(unlockController).consumeAllowance(amount);
        if (granted == 0) revert UnlockThrottled();

        claimedAmount += granted;
        token.safeTransfer(to, granted);

        emit Claimed(beneficiary, to, granted);
    }

    // -------------------------------------------------------------------------
    // Revoke — standard (blocked when paused) and emergency (always callable)
    // -------------------------------------------------------------------------

    /// @notice Standard revocation — clawback unvested to `treasury`. Blocked while paused.
    /// @dev I-5 / KL-9: this bypasses GlobalUnlockController's allowance consumption and the
    ///      proposeBurn/executeBurn timelock by design — the unlock cap governs programmatic
    ///      claim/vesting/emission releases, not governance-initiated revocation recovery. See
    ///      audit/KnownLimitations.md KL-9.
    function revokeUnvested() external nonReentrant whenNotPaused onlyRevoker {
        _doRevoke(false);
    }

    /// @notice Emergency revocation — callable even while paused. Use only in incidents
    ///         where normal claim/pause flow must be bypassed (e.g. compromised beneficiary).
    function emergencyRevokeUnvested() external nonReentrant onlyRevoker {
        _doRevoke(true);
    }

    function _doRevoke(bool emergency) internal {
        if (!revocable) revert NotRevocable();
        if (revoked) revert AlreadyRevoked();

        uint256 vested = _vestedAmount(block.timestamp);
        uint256 unvested = totalAllocation - vested;

        revoked = true;
        revokedAt = block.timestamp;

        if (unvested > 0) {
            token.safeTransfer(treasury, unvested);
        }

        // Notify the manager: only the unvested amount is freed from bucket capacity.
        IVestingManager(vestingManager).recordRevocation(address(this), unvested);

        if (emergency) {
            emit EmergencyRevoked(msg.sender, unvested, block.timestamp);
        } else {
            emit Revoked(msg.sender, unvested, block.timestamp);
        }
    }

    // -------------------------------------------------------------------------
    // Beneficiary 2-phase update
    // -------------------------------------------------------------------------

    /// @notice Propose a beneficiary change. Only the current beneficiary can propose.
    /// @dev Beneficiary reassignment is an exclusive beneficiary action. The revoker retains
    ///      revoke and pause authority only.
    ///      Contract beneficiaries require governance whitelisting; EOAs are always allowed.
    function proposeBeneficiaryUpdate(address newBeneficiary) external {
        if (msg.sender != beneficiary) revert NotAuthorized();
        if (newBeneficiary == address(0)) revert ZeroAddress();
        if (pendingBeneficiary != address(0)) revert BeneficiaryUpdatePending();

        if (newBeneficiary.code.length > 0) {
            if (!IVestingManager(vestingManager).isWhitelistedBeneficiaryContract(newBeneficiary)) {
                revert InvalidBeneficiaryContract();
            }
        }

        pendingBeneficiary = newBeneficiary;
        beneficiaryUpdateAt = block.timestamp + BENEFICIARY_UPDATE_DELAY;
        emit BeneficiaryUpdateProposed(beneficiary, newBeneficiary, beneficiaryUpdateAt);
    }

    /// @notice Confirm the pending beneficiary update after the delay elapses.
    /// @dev Only the beneficiary or the pending beneficiary can confirm. The revoker cannot.
    ///      The contract-whitelist check is re-evaluated at confirmation time so a governance
    ///      de-whitelist during the delay window blocks finalization.
    function confirmBeneficiaryUpdate() external {
        if (pendingBeneficiary == address(0)) revert NoBeneficiaryUpdatePending();
        if (block.timestamp < beneficiaryUpdateAt) revert BeneficiaryUpdateNotReady();
        if (msg.sender != beneficiary && msg.sender != pendingBeneficiary) {
            revert NotAuthorized();
        }

        // I-1 defense-in-depth: if pendingBeneficiary is confirming for itself, apply the same
        // tx.origin signal _claim() uses -- a contract confirming from its own constructor would
        // otherwise report code.length == 0 despite being unambiguously a contract. This does not
        // affect the normal case where the CURRENT beneficiary confirms on behalf of a not-yet-
        // used EOA target (pendingBeneficiary != msg.sender there, so the added check is a no-op).
        bool pendingConfirmsForItself = msg.sender == pendingBeneficiary;
        if (pendingBeneficiary.code.length > 0 || (pendingConfirmsForItself && pendingBeneficiary != tx.origin)) {
            if (!IVestingManager(vestingManager).isWhitelistedBeneficiaryContract(pendingBeneficiary)) {
                revert InvalidBeneficiaryContract();
            }
        }

        address old = beneficiary;
        beneficiary = pendingBeneficiary;
        pendingBeneficiary = address(0);
        beneficiaryUpdateAt = 0;

        IVestingManager(vestingManager).recordBeneficiaryUpdate(address(this), beneficiary);

        emit BeneficiaryUpdateConfirmed(old, beneficiary);
    }

    /// @notice Cancel a pending beneficiary update. Revoker can cancel (safety-net) but cannot
    ///         propose or confirm a replacement.
    function cancelBeneficiaryUpdate() external {
        if (msg.sender != beneficiary && msg.sender != revoker() && msg.sender != pendingBeneficiary) {
            revert NotAuthorized();
        }
        if (pendingBeneficiary == address(0)) revert NoBeneficiaryUpdatePending();
        address cancelled = pendingBeneficiary;
        pendingBeneficiary = address(0);
        beneficiaryUpdateAt = 0;
        emit BeneficiaryUpdateCancelled(cancelled);
    }

    // -------------------------------------------------------------------------
    // Pause (revoker-only emergency control)
    // -------------------------------------------------------------------------
    function pause() external {
        if (msg.sender != guardian() && msg.sender != revoker()) revert NotAuthorized();
        _pause();
    }

    function unpause() external onlyRevoker {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------
    function vestedAmount(uint256 timestamp) external view returns (uint256) {
        return _vestedAmount(timestamp);
    }

    function releasableAmount() external view returns (uint256) {
        return _releasable();
    }

    function unvestedAmount(uint256 timestamp) external view returns (uint256) {
        uint256 vested = _vestedAmount(timestamp);
        return totalAllocation - vested;
    }

    function cliffEnd() external view returns (uint256) {
        return startTimestamp + cliffDuration;
    }

    function vestingEnd() external view returns (uint256) {
        return startTimestamp + cliffDuration + vestingDuration;
    }

    // -------------------------------------------------------------------------
    // Internal math
    // -------------------------------------------------------------------------

    /// @dev Vesting formula (linear after cliff). Unaffected by TGE/GRANT_DATE distinction —
    ///      the manager has already resolved `startTimestamp`.
    function _vestedAmount(uint256 timestamp) internal view returns (uint256) {
        if (revoked) {
            // After revoke, only tokens vested at revoke time (or earlier) are claimable.
            return _vestedBeforeRevoke();
        }
        uint256 start = startTimestamp + cliffDuration;
        if (timestamp < start) return 0;
        uint256 end = start + vestingDuration;
        if (timestamp >= end) return totalAllocation;
        return (totalAllocation * (timestamp - start)) / vestingDuration;
    }

    function _vestedBeforeRevoke() internal view returns (uint256) {
        uint256 start = startTimestamp + cliffDuration;
        if (revokedAt < start) return 0;
        uint256 end = start + vestingDuration;
        if (revokedAt >= end) return totalAllocation;
        return (totalAllocation * (revokedAt - start)) / vestingDuration;
    }

    function _releasable() internal view returns (uint256) {
        uint256 vested = _vestedAmount(block.timestamp);
        if (vested <= claimedAmount) return 0;
        return vested - claimedAmount;
    }
}
