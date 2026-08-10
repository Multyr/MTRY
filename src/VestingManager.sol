// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IUnlockController} from "./interfaces/IUnlockController.sol";
import {VestingWalletLinear} from "./VestingWalletLinear.sol";
import {GovernanceRoles} from "./base/GovernanceRoles.sol";
import {
    ZeroAddress,
    ZeroAmount,
    AlreadySet,
    TGENotSet,
    TGEAlreadySet,
    InvalidTimestamp,
    BucketCapExceeded,
    InvalidBatchSize,
    ArrayLengthMismatch,
    FundingMismatch,
    InvalidStartModeForBucket,
    BurnAmountZero,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady,
    NotAuthorized,
    UnregisteredWallet,
    RevocationAlreadyRecorded,
    InvalidCapBucket,
    InvalidCliffDuration,
    InvalidVestingDuration,
    InvalidTotalDuration
} from "./Errors.sol";

/// @title VestingManager — factory + registry for vesting buckets
/// @notice Manages only vesting buckets (Strategic, Team, Growth, BD, Advisors).
///         Treasury, Liquidity, PreToken (Claim), and Ecosystem are handled by other contracts.
/// @dev
///   - Dual vesting start mode (TGE or GRANT_DATE) with on-chain bucket policy
///   - TGE NOT required to create GRANT_DATE vestings
///   - Each wallet is created, funded, balance-verified, and auto-authorized on GlobalUnlockController
///   - Paginated views (no OOG on large beneficiary counts)
///   - Paused state blocks vesting creation (not wallet claims)
///   - Burn policy with 7-day timelock (proposeBurn → executeBurn)
contract VestingManager is GovernanceRoles, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant BURN_DELAY = 7 days;

    /// @notice Upper bound for individual cliff duration (10 years).
    uint256 public constant MAX_CLIFF_DURATION = 10 * 365 days;
    /// @notice Upper bound for individual linear vesting duration (10 years).
    uint256 public constant MAX_VESTING_DURATION = 10 * 365 days;
    /// @notice Upper bound for cliff + vesting combined (20 years).
    uint256 public constant MAX_TOTAL_DURATION = 20 * 365 days;

    enum BucketType {
        StrategicStandard,
        StrategicExtended,
        Team,
        Growth,
        AdvisorsStandard,
        AdvisorsShort,
        BDCore,
        BDPerformance
    }

    enum VestingStartMode {
        TGE,
        GRANT_DATE
    }

    struct VestingRecord {
        BucketType bucket;
        VestingStartMode startMode;
        uint256 startTimestamp;
        address vestingWallet;
        /// @dev Kept in sync with the wallet's live `beneficiary()` via `recordBeneficiaryUpdate`,
        ///      called by the wallet itself when a 2-phase reassignment is confirmed.
        address beneficiary;
        uint256 allocation;
        uint64 cliffDuration;
        uint64 vestingDuration;
        bool revocable;
        /// @dev False once the wallet has recorded a completed revocation via `recordRevocation`.
        bool active;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    address public immutable token;
    address public immutable treasury;
    address public immutable unlockController;

    uint256 public tgeTimestamp;
    bool public tgeSet;

    mapping(uint256 => VestingRecord) public vestings;
    uint256 public vestingCount;

    mapping(BucketType => uint256[]) private _vestingIdsByBucket;

    /// @notice Allocated per CAP bucket. Team cap covers Growth, BDCore, BDPerformance.
    ///         Strategic caps are per-bucket (Standard, Extended) — they do not share.
    ///         Advisors caps are per-bucket (Standard, Short).
    mapping(BucketType => uint256) public totalBucketAllocated;
    mapping(BucketType => uint256) public maxBucketAllocation;

    /// @notice Allocation returned to the bucket via `recordRevocation`. `totalBucketAllocated`
    ///         minus this value is the live capacity in use.
    mapping(BucketType => uint256) public totalBucketRevoked;

    /// @notice Wallet -> record id. Used to look up a wallet's bucket and allocation without
    ///         trusting wallet-provided input at revocation time.
    mapping(address => uint256) public walletRecordId;
    mapping(address => bool) public walletRegistered;
    mapping(address => bool) public walletRevocationRecorded;

    /// @notice Beneficiary-contract whitelist. EOAs are always allowed; only contracts listed
    ///         here may be set as a vesting wallet beneficiary via proposeBeneficiaryUpdate.
    mapping(address => bool) public whitelistedBeneficiaryContract;

    uint256 public totalAllocatedAllBuckets;

    // Burn lifecycle (7-day timelock)
    uint256 public pendingBurnAmount;
    uint256 public pendingBurnExecutableAt;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event TGESet(uint256 timestamp);
    event BucketCapSet(BucketType indexed bucket, uint256 newCap);
    event VestingCreated(
        uint256 indexed id,
        BucketType indexed bucket,
        VestingStartMode startMode,
        uint256 startTimestamp,
        address indexed beneficiary,
        address vestingWallet,
        uint256 allocation
    );
    event BurnProposed(uint256 amount, uint256 executableAt);
    event BurnCancelled();
    event BurnExecuted(uint256 amount);
    event UnallocatedBurned(uint256 amount);
    event RevocationRecorded(address indexed wallet, BucketType indexed bucket, uint256 allocation);
    event BeneficiarySynced(address indexed wallet, address indexed oldBeneficiary, address indexed newBeneficiary);
    event BeneficiaryContractWhitelistUpdated(address indexed candidate, bool allowed);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(
        address token_,
        address treasury_,
        address unlockController_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (token_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (unlockController_ == address(0)) revert ZeroAddress();

        token = token_;
        treasury = treasury_;
        unlockController = unlockController_;
    }

    // -------------------------------------------------------------------------
    // Bucket caps (one-time configuration by governance)
    // -------------------------------------------------------------------------

    /// @notice Set a bucket cap. Only cap-buckets may have caps set.
    ///         Growth, BDCore, BDPerformance share the Team cap — passing them here reverts.
    ///         Prevents lowering the cap below the current live allocation.
    function setBucketCap(BucketType bucket, uint256 cap) external onlyOwner {
        if (_capBucketFor(bucket) != bucket) revert InvalidCapBucket();
        if (cap < totalBucketAllocated[bucket] - totalBucketRevoked[bucket]) revert BucketCapExceeded();
        maxBucketAllocation[bucket] = cap;
        emit BucketCapSet(bucket, cap);
    }

    // -------------------------------------------------------------------------
    // TGE
    // -------------------------------------------------------------------------

    /// @notice Set the TGE timestamp once. Required for TGE-mode grants.
    function setTGE(uint256 timestamp) external onlyOwner {
        if (tgeSet) revert TGEAlreadySet();
        if (timestamp < block.timestamp) revert InvalidTimestamp();
        if (timestamp > block.timestamp + 3650 days) revert InvalidTimestamp();
        tgeTimestamp = timestamp;
        tgeSet = true;
        emit TGESet(timestamp);
    }

    // -------------------------------------------------------------------------
    // Bucket policy
    // -------------------------------------------------------------------------

    /// @dev Resolve the CAP bucket for an allocation bucket.
    ///      Team, Growth, BDCore, BDPerformance all share the Team cap.
    ///      Strategic and Advisors use their own per-sub-bucket caps.
    function _capBucketFor(BucketType bucket) internal pure returns (BucketType) {
        if (
            bucket == BucketType.Growth ||
            bucket == BucketType.BDCore ||
            bucket == BucketType.BDPerformance
        ) {
            return BucketType.Team;
        }
        return bucket;
    }

    /// @dev Enforce bucket × startMode policy.
    ///      Strategic buckets allow both modes; all others (Team/Growth/BD/Advisors) require GRANT_DATE.
    function _validateStartMode(BucketType bucket, VestingStartMode mode) internal pure {
        if (bucket == BucketType.StrategicStandard || bucket == BucketType.StrategicExtended) {
            return;
        }
        if (mode != VestingStartMode.GRANT_DATE) revert InvalidStartModeForBucket();
    }

    // -------------------------------------------------------------------------
    // Create vesting
    // -------------------------------------------------------------------------

    struct CreateVestingParams {
        BucketType bucket;
        address beneficiary;
        uint256 allocation;
        uint64 cliffDuration;
        uint64 vestingDuration;
        bool revocable;
        VestingStartMode startMode;
    }

    /// @notice Create a new vesting grant — deploys wallet, funds it, registers, authorizes.
    function createVesting(
        BucketType bucket,
        address beneficiary,
        uint256 allocation,
        uint64 cliffDuration,
        uint64 vestingDuration,
        bool revocable,
        VestingStartMode startMode
    ) public nonReentrant whenNotPaused onlyOwner returns (address vestingWallet) {
        return _createVesting(CreateVestingParams({
            bucket: bucket,
            beneficiary: beneficiary,
            allocation: allocation,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            revocable: revocable,
            startMode: startMode
        }));
    }

    function _createVesting(CreateVestingParams memory p) internal returns (address vestingWallet) {
        if (p.beneficiary == address(0)) revert ZeroAddress();
        if (p.allocation == 0) revert ZeroAmount();
        if (p.vestingDuration == 0) revert ZeroAmount();
        if (p.cliffDuration > MAX_CLIFF_DURATION) revert InvalidCliffDuration();
        if (p.vestingDuration > MAX_VESTING_DURATION) revert InvalidVestingDuration();
        if (uint256(p.cliffDuration) + uint256(p.vestingDuration) > MAX_TOTAL_DURATION) {
            revert InvalidTotalDuration();
        }

        _validateStartMode(p.bucket, p.startMode);

        uint256 startTs = _resolveStartTs(p.startMode);
        _reserveBucket(p.bucket, p.allocation);

        vestingWallet = _deployWallet(p, startTs);
        _fundAndVerify(vestingWallet, p.allocation);

        IUnlockController(unlockController).addVestingSource(vestingWallet);
        _registerRecord(p, startTs, vestingWallet);
    }

    function _resolveStartTs(VestingStartMode mode) internal view returns (uint256) {
        if (mode == VestingStartMode.TGE) {
            if (!tgeSet) revert TGENotSet();
            return tgeTimestamp;
        }
        return block.timestamp;
    }

    function _reserveBucket(BucketType bucket, uint256 allocation) internal {
        BucketType capBucket = _capBucketFor(bucket);
        uint256 newAllocated = totalBucketAllocated[capBucket] + allocation;
        uint256 activeAllocated = newAllocated - totalBucketRevoked[capBucket];
        if (activeAllocated > maxBucketAllocation[capBucket]) revert BucketCapExceeded();
        totalBucketAllocated[capBucket] = newAllocated;
    }

    function _deployWallet(CreateVestingParams memory p, uint256 startTs) internal returns (address) {
        return address(new VestingWalletLinear(
            token,
            p.beneficiary,
            startTs,
            p.cliffDuration,
            p.vestingDuration,
            p.allocation,
            p.revocable,
            address(this),    // vestingManager — revoker() and guardian() resolved dynamically
            treasury,
            unlockController
        ));
    }

    function _fundAndVerify(address wallet, uint256 allocation) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(wallet);
        IERC20(token).safeTransfer(wallet, allocation);
        uint256 balanceAfter = IERC20(token).balanceOf(wallet);
        if (balanceAfter - balanceBefore != allocation) revert FundingMismatch();
    }

    function _registerRecord(CreateVestingParams memory p, uint256 startTs, address vestingWallet) internal {
        uint256 id = vestingCount++;
        vestings[id] = VestingRecord({
            bucket: p.bucket,
            startMode: p.startMode,
            startTimestamp: startTs,
            vestingWallet: vestingWallet,
            beneficiary: p.beneficiary,
            allocation: p.allocation,
            cliffDuration: p.cliffDuration,
            vestingDuration: p.vestingDuration,
            revocable: p.revocable,
            active: true
        });
        _vestingIdsByBucket[p.bucket].push(id);
        totalAllocatedAllBuckets += p.allocation;

        walletRecordId[vestingWallet] = id;
        walletRegistered[vestingWallet] = true;

        emit VestingCreated(id, p.bucket, p.startMode, startTs, p.beneficiary, vestingWallet, p.allocation);
    }

    /// @notice Batch version with max 50 entries.
    /// @dev Accepts an array of `CreateVestingParams` structs to avoid stack-too-deep
    ///      that occurs with 7 parallel calldata arrays. Callers construct the array off-chain.
    function batchCreateVestings(CreateVestingParams[] calldata params)
        external
        whenNotPaused
        onlyOwner
        returns (address[] memory wallets)
    {
        uint256 len = params.length;
        if (len == 0 || len > MAX_BATCH_SIZE) revert InvalidBatchSize();

        wallets = new address[](len);
        for (uint256 i; i < len; ++i) {
            wallets[i] = createVesting(
                params[i].bucket,
                params[i].beneficiary,
                params[i].allocation,
                params[i].cliffDuration,
                params[i].vestingDuration,
                params[i].revocable,
                params[i].startMode
            );
        }
    }

    // -------------------------------------------------------------------------
    // Burn (timelocked)
    // -------------------------------------------------------------------------

    /// @notice Governance proposes burning `amount` of unallocated tokens held by this manager.
    function proposeBurn(uint256 amount) external onlyOwner {
        if (pendingBurnAmount != 0) revert BurnAlreadyPending();
        if (amount == 0) revert BurnAmountZero();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert BurnExceedsBalance();
        pendingBurnAmount = amount;
        pendingBurnExecutableAt = block.timestamp + BURN_DELAY;
        emit BurnProposed(amount, pendingBurnExecutableAt);
    }

    /// @notice Cancel a pending burn proposal.
    function cancelBurn() external onlyVetoOrOwner {
        if (pendingBurnAmount == 0) revert NoBurnPending();
        pendingBurnAmount = 0;
        pendingBurnExecutableAt = 0;
        emit BurnCancelled();
    }

    /// @notice Execute a pending burn after BURN_DELAY has elapsed.
    function executeBurn() external nonReentrant whenNotPaused onlyOwner {
        if (pendingBurnAmount == 0) revert NoBurnPending();
        if (block.timestamp < pendingBurnExecutableAt) revert BurnNotReady();

        uint256 amount = pendingBurnAmount;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert BurnExceedsBalance();

        pendingBurnAmount = 0;
        pendingBurnExecutableAt = 0;

        ERC20Burnable(token).burn(amount);

        emit BurnExecuted(amount);
        emit UnallocatedBurned(amount);
    }

    // -------------------------------------------------------------------------
    // Emergency controls
    // -------------------------------------------------------------------------
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views (paginated)
    // -------------------------------------------------------------------------
    function getVestingsByBucketPaginated(
        BucketType bucket,
        uint256 offset,
        uint256 limit
    ) external view returns (VestingRecord[] memory page, uint256 total) {
        uint256[] storage ids = _vestingIdsByBucket[bucket];
        total = ids.length;
        if (offset >= total || limit == 0) {
            return (new VestingRecord[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new VestingRecord[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = vestings[ids[i]];
        }
    }

    function getBucketCount(BucketType bucket) external view returns (uint256) {
        return _vestingIdsByBucket[bucket].length;
    }

    function getUnallocatedBalance() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getBucketRemaining(BucketType bucket) external view returns (uint256) {
        return _bucketRemaining(bucket);
    }

    /// @notice I-4: headroom actually fundable right now, bounded by the manager's live token
    ///         balance. `getBucketRemaining` reports nominal cap headroom only — a revocation
    ///         frees bucket capacity without returning the tokens to this manager (they go to
    ///         `treasury`), so nominal headroom can exceed what a `createVesting` call could
    ///         actually fund. This view exists for off-chain tooling/dashboards; it does not
    ///         change grant-creation behavior (`_fundAndVerify` already reverts on underfunding).
    function fundableBucketRemaining(BucketType bucket) external view returns (uint256) {
        uint256 nominal = _bucketRemaining(bucket);
        uint256 balance = IERC20(token).balanceOf(address(this));
        return nominal < balance ? nominal : balance;
    }

    function _bucketRemaining(BucketType bucket) internal view returns (uint256) {
        BucketType capBucket = _capBucketFor(bucket);
        uint256 cap = maxBucketAllocation[capBucket];
        uint256 used = totalBucketAllocated[capBucket] - totalBucketRevoked[capBucket];
        if (used >= cap) return 0;
        return cap - used;
    }

    /// @notice Live-allocated (post-revocation) for the cap bucket associated with `bucket`.
    function activeBucketAllocated(BucketType bucket) external view returns (uint256) {
        BucketType capBucket = _capBucketFor(bucket);
        return totalBucketAllocated[capBucket] - totalBucketRevoked[capBucket];
    }

    // -------------------------------------------------------------------------
    // Revocation accounting — called by wallets when `revokeUnvested` succeeds.
    // -------------------------------------------------------------------------

    /// @notice Record a wallet revocation, freeing only the returned-to-treasury (unvested)
    ///         amount from bucket capacity — not the full original allocation.
    /// @dev Only the registered wallet itself may call. Records at most once per wallet.
    ///      The vested-but-unclaimed remainder stays in the wallet and is still owed to the
    ///      beneficiary; crediting only `returnedToTreasury` prevents `activeBucketAllocated`
    ///      from undercounting live releasable supply after a mid-vest revoke+regrant.
    function recordRevocation(address wallet, uint256 returnedToTreasury) external {
        if (!walletRegistered[wallet]) revert UnregisteredWallet();
        if (msg.sender != wallet) revert NotAuthorized();
        if (walletRevocationRecorded[wallet]) revert RevocationAlreadyRecorded();

        walletRevocationRecorded[wallet] = true;

        VestingRecord storage record = vestings[walletRecordId[wallet]];
        BucketType capBucket = _capBucketFor(record.bucket);
        totalBucketRevoked[capBucket] += returnedToTreasury;
        record.active = false;

        emit RevocationRecorded(wallet, record.bucket, returnedToTreasury);
    }

    /// @notice Synchronize the registry's `beneficiary` field after a wallet completes its
    ///         2-phase beneficiary reassignment. Keeps the public registry authoritative instead
    ///         of permanently reflecting the grant's creation-time beneficiary.
    /// @dev Only the registered wallet itself may call, mirroring `recordRevocation`'s
    ///      authentication. Callable any number of times (a wallet may be reassigned repeatedly).
    function recordBeneficiaryUpdate(address wallet, address newBeneficiary) external {
        if (!walletRegistered[wallet]) revert UnregisteredWallet();
        if (msg.sender != wallet) revert NotAuthorized();

        VestingRecord storage record = vestings[walletRecordId[wallet]];
        address old = record.beneficiary;
        record.beneficiary = newBeneficiary;

        emit BeneficiarySynced(wallet, old, newBeneficiary);
    }

    // -------------------------------------------------------------------------
    // Beneficiary contract whitelist (governance-controlled).
    // -------------------------------------------------------------------------

    /// @notice Governance enables/disables a contract address as a valid beneficiary.
    function setWhitelistedBeneficiaryContract(address candidate, bool allowed) external onlyOwner {
        if (candidate == address(0)) revert ZeroAddress();
        whitelistedBeneficiaryContract[candidate] = allowed;
        emit BeneficiaryContractWhitelistUpdated(candidate, allowed);
    }

    function isWhitelistedBeneficiaryContract(address candidate) external view returns (bool) {
        return whitelistedBeneficiaryContract[candidate];
    }
}
