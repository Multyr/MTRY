// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {PreMTRYToken} from "./PreMTRYToken.sol";
import {IUnlockController} from "./interfaces/IUnlockController.sol";
import {ISaleWindow} from "./interfaces/ISaleWindow.sol";
import {GovernanceRoles} from "./base/GovernanceRoles.sol";
import {
    ZeroAddress,
    ZeroAmount,
    NotInitialized,
    AlreadyInitialized,
    TGENotSet,
    TGEAlreadySet,
    InvalidTimestamp,
    InsufficientClaimFunding,
    TGEBeforeSaleEnd,
    MaxSupplyExceeded,
    NothingToClaim,
    Unauthorized,
    UnlockThrottled,
    BurnAmountZero,
    BurnBeforeHorizon,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady,
    LockDeadlineExpired
} from "./Errors.sol";

/// @title PreMTRYClaim — Lock preMTRY, Convert to MTRY with Vesting
/// @notice Converts locked preMTRY into vested MTRY at a 1:4 ratio after TGE.
/// @dev
///      - 180d cliff + 540d linear vesting (18 months)
///      - claim() enforces global unlock cap via GlobalUnlockController (clamp semantics)
///      - burnUnclaimedAfterHorizon: timelocked burn of excess tokens after full vesting elapsed
///      - pause/unpause for emergency control
contract PreMTRYClaim is GovernanceRoles, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Conversion ratio: 1 preMTRY = 4 MTRY
    uint256 public constant CONVERSION_RATIO = 4;
    /// @notice Cliff duration: 180 days (6 months) after TGE before vesting begins
    uint256 public constant CLIFF_DURATION = 180 days;
    /// @notice Linear vesting duration: 540 days (18 months) after cliff end
    uint256 public constant VESTING_DURATION = 540 days;
    /// @notice Maximum aggregate MTRY entitlement
    uint256 public constant MAX_CLAIM_POOL = 40_000_000e18;
    /// @notice Burn proposal timelock
    uint256 public constant BURN_DELAY = 7 days;

    bool public initialized;
    PreMTRYToken public preToken;
    IERC20 public mtryToken;
    uint256 public tgeTimestamp;

    /// @notice GlobalUnlockController — enforces the shared per-period release cap
    address public immutable unlockController;

    /// @notice PreMTRYSale bound at initialize() — setTGE() requires TGE >= saleContract.saleEnd()
    ///         so a purchase can never succeed after the lockPreTokens window has closed (MULTYR-1).
    address public saleContract;

    mapping(address => uint256) public lockedPreAmount;
    mapping(address => uint256) public totalEntitledMTRY;
    mapping(address => uint256) public claimedMTRY;
    uint256 public totalEntitled;
    uint256 public totalClaimed;

    // Burn lifecycle (post-horizon)
    uint256 public pendingBurnAmount;
    uint256 public pendingBurnExecutableAt;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event Initialized(address indexed mtryToken, address indexed preToken);
    event TGESet(uint256 tgeTimestamp);
    event PreTokensLocked(address indexed user, uint256 preAmount, uint256 mtryEntitled);
    event MTRYClaimed(address indexed user, uint256 amount);
    event TokenRecovered(address indexed token, uint256 amount);
    event BurnProposed(uint256 amount, uint256 executableAt);
    event BurnCancelled();
    event BurnExecuted(uint256 amount);
    event UnclaimedBurned(uint256 amount);

    /// @param initialOwner Governance owner (transferred to SAFE_GOV post-deploy)
    /// @param unlockController_ Global unlock controller address (immutable)
    constructor(address initialOwner, address unlockController_) Ownable(initialOwner) {
        if (unlockController_ == address(0)) revert ZeroAddress();
        unlockController = unlockController_;
    }

    // -------------------------------------------------------------------------
    // Init & TGE
    // -------------------------------------------------------------------------
    function initialize(address mtryToken_, address preToken_, address saleContract_) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        if (mtryToken_ == address(0)) revert ZeroAddress();
        if (preToken_ == address(0)) revert ZeroAddress();
        if (saleContract_ == address(0)) revert ZeroAddress();

        mtryToken = IERC20(mtryToken_);
        preToken = PreMTRYToken(preToken_);
        saleContract = saleContract_;
        initialized = true;

        emit Initialized(mtryToken_, preToken_);
    }

    function setTGE(uint256 tgeTimestamp_) external onlyOwner {
        if (!initialized) revert NotInitialized();
        if (tgeTimestamp != 0) revert TGEAlreadySet();
        if (tgeTimestamp_ < block.timestamp) revert InvalidTimestamp();
        if (tgeTimestamp_ > block.timestamp + 3650 days) revert InvalidTimestamp();
        if (mtryToken.balanceOf(address(this)) < MAX_CLAIM_POOL) revert InsufficientClaimFunding();
        // MULTYR-1: the sale must close before (or at) TGE, so every accepted purchase still has
        // the full CLIFF_DURATION window after TGE to call lockPreTokens before the deadline.
        if (tgeTimestamp_ < ISaleWindow(saleContract).saleEnd()) revert TGEBeforeSaleEnd();

        tgeTimestamp = tgeTimestamp_;
        emit TGESet(tgeTimestamp_);
    }

    // -------------------------------------------------------------------------
    // Lock
    // -------------------------------------------------------------------------
    function lockPreTokens(uint256 amount) external nonReentrant whenNotPaused {
        if (!initialized) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();
        // Lock window closes at cliff start (not fullVestingEnd()): vesting is anchored to the
        // global TGE timestamp, so a lock accepted after the cliff would grant retroactive
        // credit for cliff+elapsed-vesting time the holder never waited through, letting a late
        // locker instantly claim a large entitlement and monopolize the shared release cap.
        if (tgeTimestamp != 0 && block.timestamp >= tgeTimestamp + CLIFF_DURATION) {
            revert LockDeadlineExpired();
        }

        uint256 mtryAmount = amount * CONVERSION_RATIO;
        if (totalEntitled + mtryAmount > MAX_CLAIM_POOL) revert MaxSupplyExceeded();

        IERC20(address(preToken)).safeTransferFrom(msg.sender, address(this), amount);
        preToken.burn(amount);

        lockedPreAmount[msg.sender] += amount;
        totalEntitledMTRY[msg.sender] += mtryAmount;
        totalEntitled += mtryAmount;

        emit PreTokensLocked(msg.sender, amount, mtryAmount);
    }

    // -------------------------------------------------------------------------
    // Claim (with global unlock clamp)
    // -------------------------------------------------------------------------
    function claim() external nonReentrant whenNotPaused {
        if (!initialized) revert NotInitialized();
        if (tgeTimestamp == 0) revert TGENotSet();

        uint256 vestedAmt = _vestedAmount(msg.sender);
        uint256 claimableAmt = vestedAmt - claimedMTRY[msg.sender];
        if (claimableAmt == 0) revert NothingToClaim();

        uint256 granted = IUnlockController(unlockController).consumeAllowance(claimableAmt);
        if (granted == 0) revert UnlockThrottled();

        claimedMTRY[msg.sender] += granted;
        totalClaimed += granted;

        mtryToken.safeTransfer(msg.sender, granted);

        emit MTRYClaimed(msg.sender, granted);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------
    function claimable(address user) external view returns (uint256) {
        if (!initialized || tgeTimestamp == 0) return 0;
        return _vestedAmount(user) - claimedMTRY[user];
    }

    function vestedAmount(address user) external view returns (uint256) {
        if (!initialized || tgeTimestamp == 0) return 0;
        return _vestedAmount(user);
    }

    function remainingClaimPool() external view returns (uint256) {
        return MAX_CLAIM_POOL - totalEntitled;
    }

    function availableClaimFunding() external view returns (uint256) {
        if (!initialized) return 0;
        return mtryToken.balanceOf(address(this));
    }

    /// @notice Timestamp after which all vesting has elapsed (used by burn gate).
    function fullVestingEnd() public view returns (uint256) {
        if (tgeTimestamp == 0) return type(uint256).max;
        return tgeTimestamp + CLIFF_DURATION + VESTING_DURATION;
    }

    // -------------------------------------------------------------------------
    // Recover accidental tokens
    // -------------------------------------------------------------------------
    function recoverToken(IERC20 token, uint256 amount) external onlyOwner {
        if (!initialized) revert NotInitialized();
        if (address(token) == address(mtryToken)) revert Unauthorized();
        if (address(token) == address(preToken)) revert Unauthorized();

        token.safeTransfer(owner(), amount);
        emit TokenRecovered(address(token), amount);
    }

    // -------------------------------------------------------------------------
    // Burn unclaimed after horizon (timelocked)
    // -------------------------------------------------------------------------
    function proposeBurn(uint256 amount) external onlyOwner {
        if (pendingBurnAmount != 0) revert BurnAlreadyPending();
        if (amount == 0) revert BurnAmountZero();
        if (!initialized) revert NotInitialized();
        if (tgeTimestamp == 0 || block.timestamp < fullVestingEnd()) revert BurnBeforeHorizon();
        uint256 outstanding = totalEntitled - totalClaimed;
        uint256 balance = mtryToken.balanceOf(address(this));
        uint256 burnable = balance > outstanding ? balance - outstanding : 0;
        if (amount > burnable) revert BurnExceedsBalance();

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
        if (block.timestamp < fullVestingEnd()) revert BurnBeforeHorizon();

        uint256 amount = pendingBurnAmount;
        uint256 outstanding = totalEntitled - totalClaimed;
        uint256 balance = mtryToken.balanceOf(address(this));
        uint256 burnable = balance > outstanding ? balance - outstanding : 0;
        if (amount > burnable) revert BurnExceedsBalance();

        pendingBurnAmount = 0;
        pendingBurnExecutableAt = 0;

        ERC20Burnable(address(mtryToken)).burn(amount);

        emit BurnExecuted(amount);
        emit UnclaimedBurned(amount);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function previewEntitlement(uint256 preAmount) external pure returns (uint256) {
        return preAmount * CONVERSION_RATIO;
    }

    // -------------------------------------------------------------------------
    // Internal vesting math (180d cliff + 540d linear)
    // -------------------------------------------------------------------------
    function _vestedAmount(address user) internal view returns (uint256) {
        uint256 entitled = totalEntitledMTRY[user];
        if (entitled == 0) return 0;

        uint256 vestingStart = tgeTimestamp + CLIFF_DURATION;
        uint256 vestingEnd = vestingStart + VESTING_DURATION;

        if (block.timestamp < vestingStart) return 0;
        if (block.timestamp >= vestingEnd) return entitled;

        return (entitled * (block.timestamp - vestingStart)) / VESTING_DURATION;
    }
}
