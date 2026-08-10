// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUnlockController} from "./interfaces/IUnlockController.sol";
import {GovernanceRoles} from "./base/GovernanceRoles.sol";
import {
    ZeroAddress,
    ZeroAmount,
    AlreadySet,
    InvalidUnlockCap,
    InvalidTimestamp,
    UnauthorizedSource,
    NotAuthorized,
    CannotDeauthorizeVestingWallet
} from "./Errors.sol";

/// @title GlobalUnlockController — global per-period release cap enforcement
/// @notice Enforces a shared release budget across all unlock flows (vesting, ecosystem emissions, claim).
/// @dev CLAMP semantics: `consumeAllowance` returns `granted` (≤ requested); never reverts on cap exhaustion.
///      - `genesisTimestamp` and `periodDuration` are IMMUTABLE (set at constructor)
///      - cap changes via `setPendingUnlockCapBps` take effect only from the next period
///      - per-period cap snapshot is immutable once a period is initialized
///      - VestingManager auto-registers wallets via `addVestingSource` (strict path separation)
///      - Governance manages non-wallet sources via `setAuthorizedSource`
contract GlobalUnlockController is IUnlockController, GovernanceRoles, Pausable {
    /// @notice The MTRY token controlled by this unlock cap
    address public immutable token;

    /// @notice Genesis timestamp for deterministic period math — IMMUTABLE
    uint256 public immutable genesisTimestamp;

    /// @notice Period duration in seconds — IMMUTABLE (no setter to preserve period math integrity)
    uint256 public immutable periodDuration;

    /// @notice Denominator for bps arithmetic (10_000 = 100%)
    uint256 public constant CAP_DENOMINATOR = 10_000;

    /// @notice Hard sanity ceiling on the unlock cap (20%)
    uint256 public constant MAX_CAP_BPS = 2_000;

    /// @notice Minimum reservation for the shared lane (25% of CAP_DENOMINATOR).
    ///         Guarantees shared sources cannot be fully starved by governance setting
    ///         `protectedQuotaBps` too high.
    uint256 public constant MIN_SHARED_QUOTA_BPS = 2_500;

    /// @notice Minimum reservation for the protected lane (25% of CAP_DENOMINATOR).
    ///         Guarantees protected sources (e.g. PreMTRYClaim) retain a dedicated reserve even
    ///         if governance reduces `protectedQuotaBps` to its minimum.
    ///         Combined with MIN_SHARED_QUOTA_BPS: valid range is [2500, 7500] bps (25%–75%).
    uint256 public constant MIN_PROTECTED_QUOTA_BPS = 2_500;

    /// @notice Maximum number of periods to initialize in a single `_rollPeriodIfNeeded` call.
    ///         At 30-day periods this covers 10 years of catch-up per call.
    ///         Operational expectation: exercised at least once per period in normal operations.
    uint256 public constant MAX_CATCHUP_PERIODS = 120;

    /// @notice Reference supply at construction time — upper bound for `setReferenceSupply`.
    ///         Prevents governance from expanding the unlock rate beyond the original design envelope.
    uint256 public immutable initialReferenceSupply;

    /// @notice Current reference supply used to compute caps for future periods (initially 300M).
    ///         Per-period snapshots are stored in `referenceSupplyByPeriod` and are immutable
    ///         once the period is initialized. Changes take effect from the NEXT period only.
    uint256 public referenceSupply;

    /// @notice Period in which `referenceSupply` was last set. Changes only apply to periods
    ///         strictly greater than this value.
    uint256 public referenceSupplyCommitPeriod;

    /// @notice Immutable reference supply snapshot per period, filled at rollover.
    mapping(uint256 => uint256) public referenceSupplyByPeriod;

    /// @notice Active cap in bps for the current period (promoted from `pendingUnlockCapBps` at rollover)
    uint256 public currentUnlockCapBps;

    /// @notice Pending cap in bps for the next period (governance updates this)
    uint256 public pendingUnlockCapBps;

    /// @notice Period in which `pendingUnlockCapBps` was last set. The pending value can only be
    ///         promoted into `currentUnlockCapBps` for a period STRICTLY GREATER than this,
    ///         which makes it impossible for a pending change to apply to the period in which it was set.
    uint256 public pendingCapCommitPeriod;

    /// @notice Released amount per period index
    mapping(uint256 => uint256) public releasedInPeriod;

    /// @notice Cap (in bps) snapshot per period index — immutable once initialized
    mapping(uint256 => uint256) public capBpsByPeriod;

    /// @notice Last period that has been initialized
    uint256 public lastInitializedPeriod;

    /// @notice VestingManager address (one-time setter to avoid predicted-address fragility)
    address public vestingManager;

    /// @notice Whitelist of authorized unlock sources
    mapping(address => bool) public authorizedSource;

    /// @notice Tracks wallets registered via `addVestingSource` (called by VestingManager).
    ///         These wallets cannot be deauthorized via `setAuthorizedSource` — they must be
    ///         revoked through the VestingManager revocation flow to keep accounting consistent.
    mapping(address => bool) public vestingWallet;

    /// @notice Sources that draw from the reserved quota of the single per-period cap.
    /// @dev Reservation semantics:
    ///      - Total per-period release across all lanes <= maxUnlockForPeriod(p).
    ///      - The reserve (`protectedQuotaBps` of the cap) is inaccessible to shared sources
    ///        for the entire period, regardless of whether protected sources consume it.
    ///      - Unused protected capacity is not redistributed to shared sources; next period resets.
    ///      - Protected sources may use `cap - totalUsed` (reserve + any unused shared capacity).
    mapping(address => bool) public protectedSource;

    /// @notice Released amount per protected source per period (consumes from the single cap).
    mapping(address => mapping(uint256 => uint256)) public protectedReleasedInPeriod;

    /// @notice Active percentage of the period cap reserved for protected sources (promoted from
    ///         `pendingProtectedQuotaBps` at period rollover). Hard-bounded to
    ///         `CAP_DENOMINATOR - MIN_SHARED_QUOTA_BPS` (max 75%). Default 5000 = 50%.
    uint256 public protectedQuotaBps;

    /// @notice Pending protected quota set by governance; takes effect from the NEXT period.
    uint256 public pendingProtectedQuotaBps;

    /// @notice Period in which `pendingProtectedQuotaBps` was last set; promotion only applies to
    ///         periods strictly greater than this value.
    uint256 public pendingProtectedQuotaCommitPeriod;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event UnlockConsumed(address indexed source, uint256 indexed period, uint256 requested, uint256 granted, uint256 newReleased);
    event UnlockThrottled(address indexed source, uint256 indexed period, uint256 requested);
    event PendingUnlockCapUpdated(uint256 oldCapBps, uint256 newCapBps);
    event PeriodRolled(uint256 indexed period, uint256 activeCapBps);
    event AuthorizedSourceUpdated(address indexed source, bool allowed);
    event ProtectedSourceUpdated(address indexed source, bool protected_);
    event ProtectedQuotaUpdated(uint256 oldQuotaBps, uint256 newQuotaBps);
    event ReferenceSupplyUpdated(uint256 oldReferenceSupply, uint256 newReferenceSupply);
    event VestingManagerSet(address indexed manager);
    /// @notice Emitted after every successful `consumeAllowance`, summarizing period usage across
    ///         both lanes. Intended for subgraph indexing and off-chain monitoring dashboards.
    event PeriodUsage(
        uint256 indexed period,
        uint256 sharedReleased,
        uint256 protectedReleased,
        uint256 totalReleased,
        uint256 cap
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    /// @param token_ The MTRY token
    /// @param initialOwner Governance (SAFE_GOV)
    /// @param genesisTimestamp_ Immutable genesis (typically expected TGE)
    /// @param periodDuration_ Immutable period length in seconds (e.g. 30 days)
    /// @param initialUnlockCapBps_ Initial cap in bps (≤ MAX_CAP_BPS)
    /// @param referenceSupply_ Initial reference supply (e.g. 300_000_000e18)
    constructor(
        address token_,
        address initialOwner,
        uint256 genesisTimestamp_,
        uint256 periodDuration_,
        uint256 initialUnlockCapBps_,
        uint256 referenceSupply_
    ) Ownable(initialOwner) {
        if (token_ == address(0)) revert ZeroAddress();
        if (periodDuration_ == 0) revert ZeroAmount();
        if (referenceSupply_ == 0) revert ZeroAmount();
        if (initialUnlockCapBps_ == 0 || initialUnlockCapBps_ > MAX_CAP_BPS) revert InvalidUnlockCap();
        if (genesisTimestamp_ > block.timestamp + 3650 days) revert InvalidTimestamp();

        token = token_;
        genesisTimestamp = genesisTimestamp_;
        periodDuration = periodDuration_;
        currentUnlockCapBps = initialUnlockCapBps_;
        pendingUnlockCapBps = initialUnlockCapBps_;
        initialReferenceSupply = referenceSupply_;
        referenceSupply = referenceSupply_;

        // Default protected quota: 50% of each period cap reserved for protected sources.
        protectedQuotaBps = 5_000;
        pendingProtectedQuotaBps = 5_000;

        // Snapshot period 0 explicitly so its cap and reference supply are immutable.
        capBpsByPeriod[0] = initialUnlockCapBps_;
        referenceSupplyByPeriod[0] = referenceSupply_;
        emit PeriodRolled(0, initialUnlockCapBps_);
    }

    // -------------------------------------------------------------------------
    // Period & cap math (deterministic, view-only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IUnlockController
    function currentPeriod() public view returns (uint256) {
        if (block.timestamp < genesisTimestamp) return 0;
        return (block.timestamp - genesisTimestamp) / periodDuration;
    }

    /// @inheritdoc IUnlockController
    /// @dev Historical periods (initialized) use immutable snapshots. Forward projections for
    ///      periods not yet initialized simulate the promotion `_rollPeriodIfNeeded` would apply
    ///      if it ran right now, so the preview always agrees with the next state-changing call.
    function maxUnlockForPeriod(uint256 period) public view returns (uint256) {
        uint256 capBps = _projectedCapBps(period);
        uint256 refSupply = _projectedReferenceSupply(period);
        return (refSupply * capBps) / CAP_DENOMINATOR;
    }

    /// @dev Cap bps that WOULD be promoted into `period` if rollover ran at this exact block.
    ///      Mirrors the promotion condition inside `_rollPeriodIfNeeded` — keep in sync if that
    ///      loop's cap-promotion logic ever changes.
    function _projectedCapBps(uint256 period) internal view returns (uint256) {
        uint256 capBps = capBpsByPeriod[period];
        if (capBps != 0) return capBps;
        return (pendingCapCommitPeriod < period) ? pendingUnlockCapBps : currentUnlockCapBps;
    }

    /// @dev Reference supply that WOULD be promoted into `period` if rollover ran at this exact
    ///      block. Mirrors `_rollPeriodIfNeeded`'s referenceSupplyByPeriod computation: a commit
    ///      is only "due" for `period` when it was made strictly before it; otherwise the value
    ///      in effect is whatever was last actually snapshotted.
    function _projectedReferenceSupply(uint256 period) internal view returns (uint256) {
        uint256 refSupply = referenceSupplyByPeriod[period];
        if (refSupply != 0) return refSupply;
        if (referenceSupplyCommitPeriod < period) return referenceSupply;
        uint256 lastSnapshot = referenceSupplyByPeriod[lastInitializedPeriod];
        return lastSnapshot != 0 ? lastSnapshot : referenceSupply;
    }

    /// @dev Protected quota bps that WOULD be promoted for `period` if rollover ran at this exact
    ///      block. Mirrors the promotion condition inside `_rollPeriodIfNeeded`.
    function _projectedProtectedQuotaBps(uint256 period) internal view returns (uint256) {
        return (pendingProtectedQuotaCommitPeriod < period) ? pendingProtectedQuotaBps : protectedQuotaBps;
    }

    /// @inheritdoc IUnlockController
    /// @dev Total remaining across ALL lanes (shared + protected). This represents the unified
    ///      single-cap invariant: sum of all lane consumptions never exceeds `maxUnlockForPeriod`.
    function remainingAllowance() public view returns (uint256) {
        if (block.timestamp < genesisTimestamp) return 0;
        uint256 period = currentPeriod();
        uint256 cap = maxUnlockForPeriod(period);
        uint256 used = releasedInPeriod[period] + _protectedUsedTotalByPeriod[period];
        if (used >= cap) return 0;
        return cap - used;
    }

    // -------------------------------------------------------------------------
    // Core enforcement (clamp)
    // -------------------------------------------------------------------------

    /// @inheritdoc IUnlockController
    /// @dev All sources consume from a single per-period cap.
    ///      - Protected sources: consume up to `cap - totalUsed` (reserve + any unused shared capacity).
    ///      - Shared sources:   consume up to `cap - protectedReserve - sharedUsed`.
    ///      Invariant: `releasedInPeriod[p] + sum(protectedReleasedInPeriod[*][p]) <= maxUnlockForPeriod(p)`
    function consumeAllowance(uint256 amount) external whenNotPaused returns (uint256 granted) {
        if (!authorizedSource[msg.sender]) revert UnauthorizedSource();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < genesisTimestamp) {
            emit UnlockThrottled(msg.sender, 0, amount);
            return 0;
        }

        uint256 period = currentPeriod();
        _rollPeriodIfNeeded(period);

        uint256 cap = maxUnlockForPeriod(period);
        uint256 protectedReserve = (cap * protectedQuotaBps) / CAP_DENOMINATOR;
        uint256 sharedUsed = releasedInPeriod[period];
        uint256 protectedUsedTotal = _totalProtectedUsed(period);
        uint256 totalUsed = sharedUsed + protectedUsedTotal;

        if (protectedSource[msg.sender]) {
            // Protected source: can always use up to the reserved quota, plus any unused shared budget.
            uint256 protectedRemaining = totalUsed >= cap ? 0 : cap - totalUsed;
            granted = amount <= protectedRemaining ? amount : protectedRemaining;
            if (granted == 0) {
                emit UnlockThrottled(msg.sender, period, amount);
                return 0;
            }
            uint256 newProtected = protectedReleasedInPeriod[msg.sender][period] + granted;
            protectedReleasedInPeriod[msg.sender][period] = newProtected;
            uint256 newProtectedTotal = protectedUsedTotal + granted;
            _protectedUsedTotalByPeriod[period] = newProtectedTotal;
            emit UnlockConsumed(msg.sender, period, amount, granted, newProtected);
            emit PeriodUsage(period, sharedUsed, newProtectedTotal, sharedUsed + newProtectedTotal, cap);
            return granted;
        }

        // Shared source: bounded by (cap - totalUsed) AND (cap - protectedReserve - sharedUsed).
        // The second bound ensures shared sources cannot eat into the protected reserve even
        // before protected sources have consumed it.
        uint256 sharedAbsRemaining = totalUsed >= cap ? 0 : cap - totalUsed;
        uint256 sharedCapAfterReserve = protectedReserve >= cap ? 0 : cap - protectedReserve;
        uint256 sharedReservedRemaining = sharedUsed >= sharedCapAfterReserve ? 0 : sharedCapAfterReserve - sharedUsed;
        uint256 sharedRemaining = sharedAbsRemaining < sharedReservedRemaining
            ? sharedAbsRemaining
            : sharedReservedRemaining;

        granted = amount <= sharedRemaining ? amount : sharedRemaining;

        if (granted == 0) {
            emit UnlockThrottled(msg.sender, period, amount);
            return 0;
        }

        uint256 newReleased = sharedUsed + granted;
        releasedInPeriod[period] = newReleased;
        emit UnlockConsumed(msg.sender, period, amount, granted, newReleased);
        emit PeriodUsage(period, newReleased, protectedUsedTotal, newReleased + protectedUsedTotal, cap);
    }

    /// @dev Cache of total protected usage for a period. Stored so we don't need to iterate sources.
    mapping(uint256 => uint256) private _protectedUsedTotalByPeriod;

    function _totalProtectedUsed(uint256 period) internal view returns (uint256) {
        return _protectedUsedTotalByPeriod[period];
    }

    /// @dev Initialize every period between `lastInitializedPeriod + 1` and `period` inclusive,
    ///      up to MAX_CATCHUP_PERIODS at a time. Subsequent calls continue any remaining catch-up.
    ///      Pending changes committed in period P apply only from period P+1 onwards.
    function _rollPeriodIfNeeded(uint256 period) internal {
        if (period <= lastInitializedPeriod) return;

        uint256 catchUpEnd = lastInitializedPeriod + MAX_CATCHUP_PERIODS;
        if (catchUpEnd > period) catchUpEnd = period;

        for (uint256 p = lastInitializedPeriod + 1; p <= catchUpEnd; ++p) {
            if (pendingCapCommitPeriod < p && pendingUnlockCapBps != currentUnlockCapBps) {
                currentUnlockCapBps = pendingUnlockCapBps;
            }
            if (pendingProtectedQuotaCommitPeriod < p && pendingProtectedQuotaBps != protectedQuotaBps) {
                protectedQuotaBps = pendingProtectedQuotaBps;
            }
            capBpsByPeriod[p] = currentUnlockCapBps;
            referenceSupplyByPeriod[p] = (referenceSupplyCommitPeriod < p)
                ? referenceSupply
                : (referenceSupplyByPeriod[p - 1] != 0 ? referenceSupplyByPeriod[p - 1] : referenceSupply);
            emit PeriodRolled(p, currentUnlockCapBps);
        }
        lastInitializedPeriod = catchUpEnd;
    }

    // -------------------------------------------------------------------------
    // Governance — non-wallet authorization
    // -------------------------------------------------------------------------

    /// @notice Governance toggles authorization of a non-wallet source (e.g. ecosystem controller, claim).
    /// @dev VestingManager uses `addVestingSource` instead — strict path separation.
    ///      Wallets registered via `addVestingSource` cannot be deauthorized here; they must go
    ///      through the VestingManager revocation flow so bucket-cap accounting stays consistent.
    function setAuthorizedSource(address source, bool allowed) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        if (!allowed && vestingWallet[source]) revert CannotDeauthorizeVestingWallet();
        authorizedSource[source] = allowed;
        emit AuthorizedSourceUpdated(source, allowed);
    }

    /// @notice Flag a source as "protected" — it gets access to the reserved quota of the SINGLE
    ///         per-period budget. Used for user-facing claim flows that must not be griefable.
    /// @dev Must be paired with setAuthorizedSource. The reserved quota is shared across all
    ///      protected sources (not per-source), bounded by `protectedQuotaBps` of the cap.
    function setProtectedSource(address source, bool isProtected) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        protectedSource[source] = isProtected;
        emit ProtectedSourceUpdated(source, isProtected);
    }

    /// @notice Set the protected quota that takes effect from the NEXT period.
    /// @dev Applying the change next-period prevents a mid-period governance action from
    ///      retroactively starving protected (or shared) sources within the current period.
    ///      The shared lane setter bound (`MIN_SHARED_QUOTA_BPS`) still applies: the protected
    ///      quota may not exceed `CAP_DENOMINATOR - MIN_SHARED_QUOTA_BPS` (max 75%).
    ///      Typical value: 5000 (50%). Maximum value: 7500 (75%).
    function setPendingProtectedQuotaBps(uint256 newQuotaBps) external onlyOwner {
        if (newQuotaBps < MIN_PROTECTED_QUOTA_BPS) revert InvalidUnlockCap();
        if (newQuotaBps > CAP_DENOMINATOR - MIN_SHARED_QUOTA_BPS) revert InvalidUnlockCap();
        // I-3: promote any already-due pending value into storage before this slot is overwritten,
        // so a value that was due for an uninitialized period can never be silently skipped.
        _rollPeriodIfNeeded(currentPeriod());
        emit ProtectedQuotaUpdated(pendingProtectedQuotaBps, newQuotaBps);
        pendingProtectedQuotaBps = newQuotaBps;
        pendingProtectedQuotaCommitPeriod = currentPeriod();
    }

    /// @notice Veto or Owner may cancel a pending protected-quota change, reverting it to
    ///         the currently active `protectedQuotaBps`.
    function cancelPendingProtectedQuotaBps() external onlyVetoOrOwner {
        _rollPeriodIfNeeded(currentPeriod());
        emit ProtectedQuotaUpdated(pendingProtectedQuotaBps, protectedQuotaBps);
        pendingProtectedQuotaBps = protectedQuotaBps;
        pendingProtectedQuotaCommitPeriod = currentPeriod();
    }

    // -------------------------------------------------------------------------
    // Views — per-lane accounting
    // -------------------------------------------------------------------------

    /// @notice Remaining allowance for a specific source in the current period. Takes the
    ///         source's protection status into account (protected vs shared lane).
    /// @dev Mirrors the preconditions `consumeAllowance` enforces before granting anything:
    ///      an unauthorized source can never actually consume, and no source can consume before
    ///      genesis. Returning 0 here (rather than a positive quote a write would reject) keeps
    ///      the view actionable for integrations and monitoring.
    function remainingAllowanceForSource(address source) external view returns (uint256) {
        if (!authorizedSource[source]) return 0;
        if (block.timestamp < genesisTimestamp) return 0;

        uint256 period = currentPeriod();
        uint256 cap = maxUnlockForPeriod(period);
        uint256 sharedUsed = releasedInPeriod[period];
        uint256 protectedUsedTotal = _protectedUsedTotalByPeriod[period];
        uint256 totalUsed = sharedUsed + protectedUsedTotal;

        if (protectedSource[source]) {
            return totalUsed >= cap ? 0 : cap - totalUsed;
        }

        uint256 protectedReserve = (cap * _projectedProtectedQuotaBps(period)) / CAP_DENOMINATOR;
        uint256 sharedAbsRemaining = totalUsed >= cap ? 0 : cap - totalUsed;
        uint256 sharedCapAfterReserve = protectedReserve >= cap ? 0 : cap - protectedReserve;
        uint256 sharedReservedRemaining = sharedUsed >= sharedCapAfterReserve
            ? 0
            : sharedCapAfterReserve - sharedUsed;
        return sharedAbsRemaining < sharedReservedRemaining ? sharedAbsRemaining : sharedReservedRemaining;
    }

    /// @notice Total released across shared and protected lanes for the given period.
    function totalReleasedInPeriod(uint256 period) external view returns (uint256) {
        return releasedInPeriod[period] + _protectedUsedTotalByPeriod[period];
    }

    // -------------------------------------------------------------------------
    // VestingManager — restricted wallet authorization
    // -------------------------------------------------------------------------

    /// @notice One-time setter for the VestingManager. Avoids predicted-address fragility.
    function setVestingManager(address manager) external onlyOwner {
        if (vestingManager != address(0)) revert AlreadySet();
        if (manager == address(0)) revert ZeroAddress();
        vestingManager = manager;
        emit VestingManagerSet(manager);
    }

    /// @inheritdoc IUnlockController
    function addVestingSource(address wallet) external {
        if (msg.sender != vestingManager) revert NotAuthorized();
        if (wallet == address(0)) revert ZeroAddress();
        authorizedSource[wallet] = true;
        vestingWallet[wallet] = true;
        emit AuthorizedSourceUpdated(wallet, true);
    }

    // -------------------------------------------------------------------------
    // Governance — cap & reference supply (delayed params)
    // -------------------------------------------------------------------------

    /// @notice Governance sets the cap that will take effect from the NEXT period.
    /// @dev The commit period is recorded so `_rollPeriodIfNeeded` can only promote this value
    ///      into periods strictly greater than the one in which it was committed.
    function setPendingUnlockCapBps(uint256 newCapBps) external onlyOwner {
        if (newCapBps == 0 || newCapBps > MAX_CAP_BPS) revert InvalidUnlockCap();
        // I-3: see setPendingProtectedQuotaBps for why this must run before the slot is written.
        _rollPeriodIfNeeded(currentPeriod());
        emit PendingUnlockCapUpdated(pendingUnlockCapBps, newCapBps);
        pendingUnlockCapBps = newCapBps;
        pendingCapCommitPeriod = currentPeriod();
    }

    /// @notice Veto or Owner may cancel a pending cap change, reverting it to `currentUnlockCapBps`.
    ///         Useful during the period window before the change is promoted at rollover.
    function cancelPendingUnlockCap() external onlyVetoOrOwner {
        _rollPeriodIfNeeded(currentPeriod());
        emit PendingUnlockCapUpdated(pendingUnlockCapBps, currentUnlockCapBps);
        pendingUnlockCapBps = currentUnlockCapBps;
        pendingCapCommitPeriod = currentPeriod();
    }

    /// @notice Governance updates reference supply. Applies ONLY to periods strictly greater
    ///         than the current period at commit time. Historical snapshots are immutable.
    /// @dev Upper-bounded at `initialReferenceSupply` (the deploy-time value, 300M) to prevent
    ///      governance from expanding the unlock rate cap beyond the original design envelope.
    ///      Use `cancelPendingReferenceSupply` to revert an in-flight change before it promotes.
    function setReferenceSupply(uint256 newReferenceSupply) external onlyOwner {
        if (newReferenceSupply == 0) revert ZeroAmount();
        if (newReferenceSupply > initialReferenceSupply) revert InvalidUnlockCap();
        _rollPeriodIfNeeded(currentPeriod());
        emit ReferenceSupplyUpdated(referenceSupply, newReferenceSupply);
        referenceSupply = newReferenceSupply;
        referenceSupplyCommitPeriod = currentPeriod();
    }

    /// @notice Veto or Owner may cancel a pending reference-supply change, restoring the value
    ///         that was snapshotted at the last initialized period.
    function cancelPendingReferenceSupply() external onlyVetoOrOwner {
        _rollPeriodIfNeeded(currentPeriod());
        uint256 snapshotted = referenceSupplyByPeriod[lastInitializedPeriod];
        emit ReferenceSupplyUpdated(referenceSupply, snapshotted);
        referenceSupply = snapshotted;
        referenceSupplyCommitPeriod = currentPeriod();
    }

    // -------------------------------------------------------------------------
    // Emergency controls
    // -------------------------------------------------------------------------

    /// @notice Pause all `consumeAllowance` calls. Callable by Guardian or Owner.
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @notice Unpause. Owner only.
    function unpause() external onlyOwner {
        _unpause();
    }
}
