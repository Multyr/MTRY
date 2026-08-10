// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PreMTRYToken} from "./PreMTRYToken.sol";
import {GovernanceRoles} from "./base/GovernanceRoles.sol";
import {
    ZeroAddress,
    ZeroAmount,
    SaleNotActive,
    SaleEnded,
    HardCapExceeded,
    NotWhitelisted,
    InvalidTimeRange,
    InvalidChain
} from "./Errors.sol";

/// @title PreMTRYSale — USDC Sale for preMTRY
/// @notice Sells preMTRY tokens for official Arbitrum USDC at a fixed price.
/// @dev Payment token is hard-coded to official Arbitrum One USDC. Chain ID is enforced
///      at construction time to prevent mis-deployment. USDC funds go directly to treasuryReceiver.
///      Pause is callable by Guardian or Owner; unpause by Owner only. Veto unused.
contract PreMTRYSale is GovernanceRoles, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Fixed price: 0.08 USDC per 1 preMTRY (80_000 in 6-decimal raw units)
    uint256 public constant PRICE = 80_000;

    /// @notice Hard cap in USDC raw units (800,000 USDC = 800_000e6)
    uint256 public constant HARD_CAP_USDC = 800_000e6;

    /// @notice Arbitrum One chain ID — enforced at construction
    uint256 public constant ARBITRUM_ONE_CHAIN_ID = 42161;

    /// @notice Official Arbitrum USDC (native, non-bridged) address
    address public constant OFFICIAL_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice The preMTRY token contract that receives minted tokens
    PreMTRYToken public immutable preToken;
    /// @notice The USDC payment token (hard-coded to official Arbitrum USDC)
    IERC20 public immutable paymentToken;
    /// @notice Treasury Safe multisig that receives all USDC payments
    address public immutable treasuryReceiver;
    /// @notice Unix timestamp when the sale opens
    uint256 public immutable saleStart;
    /// @notice Unix timestamp when the sale closes
    uint256 public immutable saleEnd;

    /// @notice Cumulative USDC raised across all purchases
    uint256 public totalRaisedUSDC;

    /// @notice Addresses approved to call buy()
    mapping(address => bool) public whitelist;

    /// @notice Emitted on each purchase of preMTRY
    event Purchase(
        address indexed buyer,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 preTokenAmount
    );

    /// @notice Emitted when an address is added to or removed from the whitelist
    event WhitelistUpdated(address indexed account, bool allowed);

    /// @param preToken_ PreMTRYToken contract
    /// @param treasuryReceiver_ Treasury Safe multisig that receives all USDC
    /// @param saleStart_ Sale start timestamp
    /// @param saleEnd_ Sale end timestamp
    /// @param initialOwner Initial owner (transferred to Foundation SAFE after deploy)
    constructor(
        address preToken_,
        address treasuryReceiver_,
        uint256 saleStart_,
        uint256 saleEnd_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (block.chainid != ARBITRUM_ONE_CHAIN_ID) revert InvalidChain();
        if (preToken_ == address(0)) revert ZeroAddress();
        if (treasuryReceiver_ == address(0)) revert ZeroAddress();
        // initialOwner == address(0) is already caught by Ownable (OwnableInvalidOwner)
        if (saleStart_ >= saleEnd_) revert InvalidTimeRange();

        preToken = PreMTRYToken(preToken_);
        paymentToken = IERC20(OFFICIAL_USDC);
        treasuryReceiver = treasuryReceiver_;
        saleStart = saleStart_;
        saleEnd = saleEnd_;
    }

    /// @notice Owner adds or removes an address from the purchase whitelist
    function setWhitelist(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        whitelist[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    /// @notice Owner adds or removes multiple addresses from the whitelist in one transaction
    function setWhitelistBatch(address[] calldata accounts, bool allowed) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            whitelist[accounts[i]] = allowed;
            emit WhitelistUpdated(accounts[i], allowed);
            unchecked { ++i; }
        }
    }

    /// @notice Buy preMTRY with USDC. Both caller and receiver must be whitelisted.
    /// @param usdcAmount Amount of USDC to spend (in 6-decimal raw units)
    /// @param receiver Address to receive the minted preMTRY (must also be whitelisted)
    function buy(uint256 usdcAmount, address receiver) external nonReentrant whenNotPaused {
        if (receiver == address(0)) revert ZeroAddress();
        if (!whitelist[msg.sender]) revert NotWhitelisted();
        if (receiver != msg.sender && !whitelist[receiver]) revert NotWhitelisted();
        if (block.timestamp < saleStart) revert SaleNotActive();
        if (block.timestamp > saleEnd) revert SaleEnded();
        if (usdcAmount == 0) revert ZeroAmount();
        if (totalRaisedUSDC + usdcAmount > HARD_CAP_USDC) revert HardCapExceeded();

        // Calculate preMTRY amount: usdcAmount * 1e18 / 80_000
        uint256 preMTRYAmount = (usdcAmount * 1e18) / PRICE;
        if (preMTRYAmount == 0) revert ZeroAmount(); // dust guard

        totalRaisedUSDC += usdcAmount;

        // Transfer USDC directly to treasury — never sits in this contract
        paymentToken.safeTransferFrom(msg.sender, treasuryReceiver, usdcAmount);

        // Mint preMTRY to receiver (will revert inside if MAX_SUPPLY exceeded)
        preToken.mint(receiver, preMTRYAmount);

        emit Purchase(msg.sender, receiver, usdcAmount, preMTRYAmount);
    }

    /// @notice Pause the sale (emergency). Only affects buy().
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @notice Unpause the sale.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Preview the preMTRY amount for a given USDC input (before fees/checks).
    /// @param usdcAmount Amount of USDC (6-decimal raw units)
    /// @return The preMTRY that would be minted (18-decimal)
    function previewPurchase(uint256 usdcAmount) external pure returns (uint256) {
        return (usdcAmount * 1e18) / PRICE;
    }
}
