// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// MULTYR Protocol — Shared Custom Errors

// -----------------------------------------------------------------------------
// Generic / shared
// -----------------------------------------------------------------------------

/// @notice Reverted when a zero address is passed where a valid address is required.
error ZeroAddress();
/// @notice Reverted when a zero amount is passed where a non-zero value is required.
error ZeroAmount();
/// @notice Reverted when a one-time setter is called but the value is already set.
error AlreadySet();
/// @notice Reverted when an action requires initialize() but it has not been called.
error NotInitialized();
/// @notice Reverted when initialize() is called but contract is already initialized.
error AlreadyInitialized();
/// @notice Reverted when a timestamp parameter is invalid (e.g. unreasonably far in the future).
error InvalidTimestamp();
/// @notice Reverted when constructor receives saleStart >= saleEnd.
error InvalidTimeRange();
/// @notice Reverted when an unauthorized caller attempts a restricted action.
error Unauthorized();
/// @notice Reverted for any unauthorized caller (generic access control).
error NotAuthorized();
/// @notice Reverted when renounceOwnership() is called — permanently disabled (I-6).
error RenounceOwnershipDisabled();

// -----------------------------------------------------------------------------
// PreMTRYSale
// -----------------------------------------------------------------------------

/// @notice Reverted when buy() is called before the sale start time.
error SaleNotActive();
/// @notice Reverted when buy() is called after the sale end time.
error SaleEnded();
/// @notice Reverted when a purchase would exceed the USDC hard cap.
error HardCapExceeded();
/// @notice Reverted when buy() is called by an address not on the whitelist.
error NotWhitelisted();
/// @notice Reverted when the contract is deployed on the wrong chain (expected Arbitrum One).
error InvalidChain();

// -----------------------------------------------------------------------------
// MTRYToken / PreMTRYToken
// -----------------------------------------------------------------------------

/// @notice Reverted when minting or locking would exceed the maximum supply or pool cap.
error MaxSupplyExceeded();

// -----------------------------------------------------------------------------
// TGE
// -----------------------------------------------------------------------------

/// @notice Reverted when an action requires TGE to be set but it has not been.
error TGENotSet();
/// @notice Reverted when setTGE() is called but TGE has already been set.
error TGEAlreadySet();

// -----------------------------------------------------------------------------
// PreMTRYClaim
// -----------------------------------------------------------------------------

/// @notice Reverted when claim() is called but no tokens are currently claimable.
error NothingToClaim();
/// @notice Reverted when setTGE() is called but the claim contract holds insufficient MTRY.
error InsufficientClaimFunding();
/// @notice Reverted when setTGE() is called with a TGE timestamp earlier than the linked
///         PreMTRYSale's saleEnd — sales must close before (or at) TGE so every buyer retains
///         the full lockPreTokens window.
error TGEBeforeSaleEnd();

// -----------------------------------------------------------------------------
// EcosystemEmissionController
// -----------------------------------------------------------------------------

/// @notice Reverted when emit is called beyond the maximum emission horizon.
error EmissionHorizonExceeded();
/// @notice Reverted when emit is called but start timestamp has not been reached.
error NotStarted();
/// @notice Reverted when emit targets a non-approved recipient.
error RecipientNotApproved();
/// @notice Reverted when per-epoch cap is exceeded by emission.
error EpochCapExceeded();

// -----------------------------------------------------------------------------
// VestingWalletLinear
// -----------------------------------------------------------------------------

/// @notice Reverted when release() is called but no tokens are releasable.
error NothingToRelease();
/// @notice Reverted when revokeUnvested() is called on an already-revoked wallet.
error AlreadyRevoked();
/// @notice Reverted when revokeUnvested() is called on a non-revocable wallet.
error NotRevocable();
/// @notice Reverted when revoker-only function is called by another address.
error NotRevoker();
/// @notice Reverted when beneficiary-only function is called by another address.
error NotBeneficiary();
/// @notice Reverted when a beneficiary update is already pending.
error BeneficiaryUpdatePending();
/// @notice Reverted when confirmBeneficiaryUpdate or cancelBeneficiaryUpdate is called with no update pending.
error NoBeneficiaryUpdatePending();
/// @notice Reverted when confirmBeneficiaryUpdate is called before the delay elapsed.
error BeneficiaryUpdateNotReady();

// -----------------------------------------------------------------------------
// VestingManager
// -----------------------------------------------------------------------------

/// @notice Reverted when a vesting allocation would exceed the bucket cap.
error BucketCapExceeded();
/// @notice Reverted when batch size is zero or exceeds MAX_BATCH_SIZE.
error InvalidBatchSize();
/// @notice Reverted when batch arrays have mismatched lengths.
error ArrayLengthMismatch();
/// @notice Reverted when the funded balance does not match the expected allocation.
error FundingMismatch();
/// @notice Reverted when a bucket does not allow the requested vesting start mode.
error InvalidStartModeForBucket();
/// @notice Reverted when a cliff duration exceeds the max allowed bound.
error InvalidCliffDuration();
/// @notice Reverted when a vesting duration exceeds the max allowed bound.
error InvalidVestingDuration();
/// @notice Reverted when cliff + vesting exceed the max total duration bound.
error InvalidTotalDuration();
/// @notice Reverted when a wallet address is not registered with the manager.
error UnregisteredWallet();
/// @notice Reverted when recordRevocation is called twice for the same wallet.
error RevocationAlreadyRecorded();
/// @notice Reverted when setBucketCap is called with a sub-bucket that shares a parent cap.
///         Only cap-buckets (Team, StrategicStandard, StrategicExtended, AdvisorsStandard,
///         AdvisorsShort) may have caps set directly. Growth, BDCore, and BDPerformance share
///         the Team cap and must not be passed to setBucketCap.
error InvalidCapBucket();
/// @notice Reverted when a beneficiary contract is not whitelisted.
error InvalidBeneficiaryContract();

// -----------------------------------------------------------------------------
// GlobalUnlockController
// -----------------------------------------------------------------------------

/// @notice Reverted when an invalid unlock cap (> MAX_CAP_BPS) is set.
error InvalidUnlockCap();
/// @notice Reverted when setAuthorizedSource(false) is called on a VestingManager-registered wallet.
error CannotDeauthorizeVestingWallet();
/// @notice Reverted when an unauthorized contract tries to consume unlock allowance.
error UnauthorizedSource();
/// @notice Reverted by callers when granted allowance is zero (throttled by global cap).
error UnlockThrottled();

// -----------------------------------------------------------------------------
// Burn lifecycle (PreMTRYClaim, VestingManager, EcosystemEmissionController)
// -----------------------------------------------------------------------------

/// @notice Reverted when a burn is attempted before the required horizon.
error BurnBeforeHorizon();
/// @notice Reverted when a burn amount exceeds the available balance.
error BurnExceedsBalance();
/// @notice Reverted when a burn amount is zero.
error BurnAmountZero();
/// @notice Reverted when executeBurn is called without a prior proposal.
error NoBurnPending();
/// @notice Reverted when proposeBurn is called while a burn proposal is already pending.
error BurnAlreadyPending();
/// @notice Reverted when executeBurn is called before BURN_DELAY has elapsed.
error BurnNotReady();
/// @notice Reverted when lockPreTokens is called after the full vesting horizon has elapsed.
error LockDeadlineExpired();
