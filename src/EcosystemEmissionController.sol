// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {GovernanceRoles} from "./base/GovernanceRoles.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IUnlockController} from "./interfaces/IUnlockController.sol";
import {
    ZeroAddress,
    ZeroAmount,
    InvalidTimestamp,
    RecipientNotApproved,
    EpochCapExceeded,
    EmissionHorizonExceeded,
    NotStarted,
    UnlockThrottled,
    InvalidBatchSize,
    ArrayLengthMismatch,
    BurnBeforeHorizon,
    BurnAmountZero,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady
} from "./Errors.sol";

/// @title EcosystemEmissionController — epoch-based ecosystem emissions
/// @notice Deterministic epoch math, recipient whitelist, delayed cap changes,
///         global unlock enforcement, pause, and burn.
/// @dev
///   - `genesis` and `epochDuration` are IMMUTABLE (no `start()` function)
///   - cap changes via `setPendingMaxEmissionPerEpoch` apply from the NEXT epoch
///   - per-epoch cap snapshot is immutable once initialized
///   - emission enforces BOTH local cap and global unlock cap (via `IUnlockController.consumeAllowance`)
///   - clamp semantics: reverts only when `granted == 0`
contract EcosystemEmissionController is GovernanceRoles, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_EPOCHS = 60;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant BURN_DELAY = 7 days;

    address public immutable token;
    address public immutable unlockController;

    uint256 public immutable genesis;
    uint256 public immutable epochDuration;

    uint256 public currentMaxEmissionPerEpoch;
    uint256 public pendingMaxEmissionPerEpoch;
    /// @notice Epoch in which `pendingMaxEmissionPerEpoch` was last set. Promotion only happens
    ///         for epochs STRICTLY GREATER than this value.
    uint256 public pendingMaxCommitEpoch;

    mapping(uint256 => uint256) public maxEmissionByEpoch;
    mapping(uint256 => uint256) public emittedInEpoch;
    uint256 public lastInitializedEpoch;

    uint256 public totalEmitted;

    mapping(address => bool) public approvedRecipients;
    mapping(address => uint256) public totalEmittedToRecipient;

    // Burn timelock
    uint256 public pendingBurnAmount;
    uint256 public pendingBurnExecutableAt;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event EmissionExecuted(address indexed recipient, uint256 amount, uint256 indexed epoch);
    event RecipientApprovalUpdated(address indexed recipient, bool approved);
    event PendingMaxEmissionUpdated(uint256 oldMax, uint256 newMax);
    event EpochRolled(uint256 indexed epoch, uint256 activeMax);
    event BurnProposed(uint256 amount, uint256 executableAt);
    event BurnCancelled();
    event BurnExecuted(uint256 amount);
    event EcosystemRemainingBurned(uint256 amount);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(
        address token_,
        address unlockController_,
        address initialOwner,
        uint256 genesis_,
        uint256 epochDuration_,
        uint256 initialMaxEmissionPerEpoch_
    ) Ownable(initialOwner) {
        if (token_ == address(0)) revert ZeroAddress();
        if (unlockController_ == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert ZeroAmount();
        if (initialMaxEmissionPerEpoch_ == 0) revert ZeroAmount();
        if (genesis_ > block.timestamp + 3650 days) revert InvalidTimestamp();

        token = token_;
        unlockController = unlockController_;
        genesis = genesis_;
        epochDuration = epochDuration_;
        currentMaxEmissionPerEpoch = initialMaxEmissionPerEpoch_;
        pendingMaxEmissionPerEpoch = initialMaxEmissionPerEpoch_;

        // Snapshot epoch 0 explicitly so its cap is immutable from construction.
        maxEmissionByEpoch[0] = initialMaxEmissionPerEpoch_;
        emit EpochRolled(0, initialMaxEmissionPerEpoch_);
    }

    // -------------------------------------------------------------------------
    // Epoch math (deterministic)
    // -------------------------------------------------------------------------
    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < genesis) return 0;
        return (block.timestamp - genesis) / epochDuration;
    }

    function availableThisEpoch() external view returns (uint256) {
        if (block.timestamp < genesis) return 0;
        uint256 epoch = currentEpoch();
        if (epoch >= MAX_EPOCHS) return 0;
        uint256 cap = _projectedMaxEmissionPerEpoch(epoch);
        uint256 used = emittedInEpoch[epoch];
        if (used >= cap) return 0;
        return cap - used;
    }

    /// @dev Max emission cap that WOULD be promoted into `epoch` if rollover ran at this exact
    ///      block. Mirrors the promotion condition inside `_rollEpochIfNeeded` — keep in sync if
    ///      that loop's cap-promotion logic ever changes.
    function _projectedMaxEmissionPerEpoch(uint256 epoch) internal view returns (uint256) {
        uint256 cap = maxEmissionByEpoch[epoch];
        if (cap != 0) return cap;
        return (pendingMaxCommitEpoch < epoch) ? pendingMaxEmissionPerEpoch : currentMaxEmissionPerEpoch;
    }

    // -------------------------------------------------------------------------
    // Emissions
    // -------------------------------------------------------------------------

    /// @notice Emit tokens to an approved recipient subject to local and global caps.
    function emitTo(address recipient, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyOwner
        returns (uint256 granted)
    {
        granted = _emit(recipient, amount);
    }

    function batchEmit(address[] calldata recipients, uint256[] calldata amounts)
        external
        nonReentrant
        whenNotPaused
        onlyOwner
        returns (uint256[] memory granted)
    {
        uint256 len = recipients.length;
        if (len == 0 || len > MAX_BATCH_SIZE) revert InvalidBatchSize();
        if (len != amounts.length) revert ArrayLengthMismatch();

        granted = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            granted[i] = _emit(recipients[i], amounts[i]);
        }
    }

    function _emit(address recipient, uint256 amount) internal returns (uint256 granted) {
        if (block.timestamp < genesis) revert NotStarted();
        if (!approvedRecipients[recipient]) revert RecipientNotApproved();
        if (amount == 0) revert ZeroAmount();

        uint256 epoch = currentEpoch();
        if (epoch >= MAX_EPOCHS) revert EmissionHorizonExceeded();

        _rollEpochIfNeeded(epoch);

        uint256 epochCap = maxEmissionByEpoch[epoch];
        uint256 usedLocal = emittedInEpoch[epoch];
        uint256 localRemaining = usedLocal >= epochCap ? 0 : epochCap - usedLocal;
        uint256 wantLocal = amount <= localRemaining ? amount : localRemaining;
        if (wantLocal == 0) revert EpochCapExceeded();

        // Global cap (clamp semantics)
        granted = IUnlockController(unlockController).consumeAllowance(wantLocal);
        if (granted == 0) revert UnlockThrottled();

        emittedInEpoch[epoch] = usedLocal + granted;
        totalEmitted += granted;
        totalEmittedToRecipient[recipient] += granted;

        IERC20(token).safeTransfer(recipient, granted);
        emit EmissionExecuted(recipient, granted, epoch);
    }

    /// @dev Initialize every epoch between `lastInitializedEpoch + 1` and `epoch` inclusive with
    ///      the active cap. Pending cap changes committed in epoch E can only apply from E+1.
    function _rollEpochIfNeeded(uint256 epoch) internal {
        if (epoch <= lastInitializedEpoch) return;

        for (uint256 e = lastInitializedEpoch + 1; e <= epoch; ++e) {
            if (pendingMaxCommitEpoch < e && pendingMaxEmissionPerEpoch != currentMaxEmissionPerEpoch) {
                currentMaxEmissionPerEpoch = pendingMaxEmissionPerEpoch;
            }
            maxEmissionByEpoch[e] = currentMaxEmissionPerEpoch;
            emit EpochRolled(e, currentMaxEmissionPerEpoch);
        }
        lastInitializedEpoch = epoch;
    }

    /// @dev Rolls up to MAX_EPOCHS - 1 (the last epoch emissions can ever occur in). Unlike
    ///      _emit(), the pending-value setters below have no caller-side epoch<MAX_EPOCHS guard,
    ///      so without this cap a governance call made long after the emission horizon has
    ///      passed (currentEpoch() far beyond MAX_EPOCHS) would run an unbounded loop -- there is
    ///      nothing to roll for epochs that can never emit, so capping is free.
    function _rollEpochIfNeededCapped() internal {
        uint256 epoch = currentEpoch();
        if (epoch >= MAX_EPOCHS) epoch = MAX_EPOCHS - 1;
        _rollEpochIfNeeded(epoch);
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------
    function setApprovedRecipient(address recipient, bool approved) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        approvedRecipients[recipient] = approved;
        emit RecipientApprovalUpdated(recipient, approved);
    }

    function setPendingMaxEmissionPerEpoch(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert ZeroAmount();
        // I-3: promote any already-due pending value before this slot is overwritten, so a value
        // due for an uninitialized epoch can never be silently skipped by a same-epoch overwrite.
        _rollEpochIfNeededCapped();
        emit PendingMaxEmissionUpdated(pendingMaxEmissionPerEpoch, newMax);
        pendingMaxEmissionPerEpoch = newMax;
        pendingMaxCommitEpoch = currentEpoch();
    }

    /// @notice Veto or Owner may cancel a pending per-epoch emission cap change.
    function cancelPendingMaxEmission() external onlyVetoOrOwner {
        _rollEpochIfNeededCapped();
        emit PendingMaxEmissionUpdated(pendingMaxEmissionPerEpoch, currentMaxEmissionPerEpoch);
        pendingMaxEmissionPerEpoch = currentMaxEmissionPerEpoch;
        pendingMaxCommitEpoch = currentEpoch();
    }

    // -------------------------------------------------------------------------
    // Emergency pause
    // -------------------------------------------------------------------------
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Burn (post-horizon, timelocked)
    // -------------------------------------------------------------------------
    function proposeBurn(uint256 amount) external onlyOwner {
        if (pendingBurnAmount != 0) revert BurnAlreadyPending();
        if (amount == 0) revert BurnAmountZero();
        if (currentEpoch() < MAX_EPOCHS) revert BurnBeforeHorizon();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert BurnExceedsBalance();
        pendingBurnAmount = amount;
        pendingBurnExecutableAt = block.timestamp + BURN_DELAY;
        emit BurnProposed(amount, pendingBurnExecutableAt);
    }

    function cancelBurn() external onlyVetoOrOwner {
        if (pendingBurnAmount == 0) revert NoBurnPending();
        pendingBurnAmount = 0;
        pendingBurnExecutableAt = 0;
        emit BurnCancelled();
    }

    function executeBurn() external nonReentrant whenNotPaused onlyOwner {
        if (pendingBurnAmount == 0) revert NoBurnPending();
        if (block.timestamp < pendingBurnExecutableAt) revert BurnNotReady();
        if (currentEpoch() < MAX_EPOCHS) revert BurnBeforeHorizon();

        uint256 amount = pendingBurnAmount;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert BurnExceedsBalance();

        pendingBurnAmount = 0;
        pendingBurnExecutableAt = 0;

        ERC20Burnable(token).burn(amount);

        emit BurnExecuted(amount);
        emit EcosystemRemainingBurned(amount);
    }
}
