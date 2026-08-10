// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ZeroAddress} from "./Errors.sol";

/// @title MTRYToken — MULTYR Final Token
/// @notice Fixed-supply ERC-20. 300,000,000 MTRY minted once in constructor.
/// @dev
///   - 5 recipients: Treasury, Liquidity, PreMTRYClaim, VestingManager, EcosystemEmissionController
///   - ERC20Burnable enabled: protocol controllers (claim/vesting/ecosystem) can burn their holdings
///     via their own timelocked burn paths. `totalBurned` tracked cumulatively for transparency.
///   - No mint after constructor. No owner. No pause. No tax. No blacklist.
contract MTRYToken is ERC20, ERC20Burnable {
    /// @notice Total initial supply: 300M MTRY (18 decimals)
    uint256 public constant TOTAL_SUPPLY = 300_000_000e18;

    /// @notice Treasury Safe allocation (no vesting): 75M
    uint256 public constant TREASURY_ALLOCATION = 75_000_000e18;
    /// @notice Liquidity Safe allocation (no vesting): 45M
    uint256 public constant LIQUIDITY_ALLOCATION = 45_000_000e18;
    /// @notice PreMTRYClaim pool allocation (preToken conversion): 40M
    uint256 public constant CLAIM_POOL_ALLOCATION = 40_000_000e18;
    /// @notice VestingManager allocation (Strategic 45 + Team 51 + Advisors 15): 111M
    uint256 public constant VESTING_ALLOCATION = 111_000_000e18;
    /// @notice EcosystemEmissionController allocation: 29M
    uint256 public constant ECOSYSTEM_ALLOCATION = 29_000_000e18;

    /// @notice Cumulative tokens burned via `burn` or `burnFrom` across all holders.
    uint256 public totalBurned;

    /// @notice Emitted whenever tokens are burned via the ERC20 burn path.
    event Burned(address indexed from, uint256 amount, uint256 totalBurnedCumulative);

    /// @param treasurySafe Treasury Safe multisig
    /// @param liquiditySafe Liquidity Safe multisig
    /// @param preMTRYClaim PreMTRYClaim contract
    /// @param vestingManager VestingManager contract
    /// @param ecosystemController EcosystemEmissionController contract
    constructor(
        address treasurySafe,
        address liquiditySafe,
        address preMTRYClaim,
        address vestingManager,
        address ecosystemController
    ) ERC20("MULTYR", "MTRY") {
        if (treasurySafe == address(0)) revert ZeroAddress();
        if (liquiditySafe == address(0)) revert ZeroAddress();
        if (preMTRYClaim == address(0)) revert ZeroAddress();
        if (vestingManager == address(0)) revert ZeroAddress();
        if (ecosystemController == address(0)) revert ZeroAddress();

        _mint(treasurySafe, TREASURY_ALLOCATION);
        _mint(liquiditySafe, LIQUIDITY_ALLOCATION);
        _mint(preMTRYClaim, CLAIM_POOL_ALLOCATION);
        _mint(vestingManager, VESTING_ALLOCATION);
        _mint(ecosystemController, ECOSYSTEM_ALLOCATION);

        // Sanity check: mints sum to 300M
        assert(
            TREASURY_ALLOCATION + LIQUIDITY_ALLOCATION + CLAIM_POOL_ALLOCATION +
            VESTING_ALLOCATION + ECOSYSTEM_ALLOCATION == TOTAL_SUPPLY
        );
    }

    /// @dev Override to track cumulative burns and emit Burned event.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == address(0) && from != address(0)) {
            totalBurned += value;
            emit Burned(from, value, totalBurned);
        }
    }
}
