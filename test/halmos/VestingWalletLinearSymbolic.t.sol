// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {IUnlockController} from "../../src/interfaces/IUnlockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mock token with a `mint` helper.
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Passthrough unlock controller: grants every request without clamping.
///      Used here so that Halmos can focus on VestingWalletLinear accounting without
///      mixing global-unlock paths.
contract PassthroughUnlockController is IUnlockController {
    function consumeAllowance(uint256 amount) external pure returns (uint256) { return amount; }
    function remainingAllowance() external pure returns (uint256) { return type(uint256).max; }
    function currentPeriod() external pure returns (uint256) { return 0; }
    function maxUnlockForPeriod(uint256) external pure returns (uint256) { return type(uint256).max; }
    function addVestingSource(address) external pure {}
}

/// @dev Ownable holder acting as the VestingManager for dynamic authority lookup.
///      Must implement recordRevocation so _doRevoke() doesn't revert on the callback, and
///      isWhitelistedBeneficiaryContract so the I-1 claim-time whitelist re-check in
///      VestingWalletLinear._claim() has something to call instead of reverting on a missing
///      selector (BENEFICIARY is a plain EOA in this harness, so it's never whitelisted here).
contract OwnerHolder is Ownable {
    constructor(address initialOwner) Ownable(initialOwner) {}
    function setOwnerForTesting(address newOwner) external { _transferOwnership(newOwner); }
    function recordRevocation(address, uint256) external {}
    function isWhitelistedBeneficiaryContract(address) external pure returns (bool) { return false; }
}

/// @title VestingWalletLinearSymbolic — Halmos proofs for per-wallet accounting.
contract VestingWalletLinearSymbolicTest is Test {
    VestingWalletLinear internal wallet;
    MockToken internal token;
    OwnerHolder internal manager;
    PassthroughUnlockController internal unlockCtrl;

    address internal constant BENEFICIARY = address(uint160(0xBEEF));
    address internal constant OWNER = address(uint160(0xABCD));
    address internal constant TREASURY = address(uint160(0xCAFE));

    uint256 internal constant START_TIMESTAMP = 1_000_000;
    uint256 internal constant CLIFF_DURATION = 180 days;
    uint256 internal constant VESTING_DURATION = 540 days;
    uint256 internal constant ALLOCATION = 1_000_000e18;

    function setUp() public {
        token = new MockToken();
        manager = new OwnerHolder(OWNER);
        unlockCtrl = new PassthroughUnlockController();

        wallet = new VestingWalletLinear(
            address(token),
            BENEFICIARY,
            START_TIMESTAMP,
            CLIFF_DURATION,
            VESTING_DURATION,
            ALLOCATION,
            true,              // revocable
            address(manager),  // manager — owner() is the dynamic revoker
            TREASURY,
            address(unlockCtrl)
        );

        // Fund the wallet so claim() can transfer tokens.
        token.mint(address(wallet), ALLOCATION);
    }

    // -------------------------------------------------------------------------
    // Accounting: claimedAmount never exceeds totalAllocation
    // -------------------------------------------------------------------------

    /// @notice claim + claimTo never push `claimedAmount` above `totalAllocation`.
    function check_claimedNeverExceedsAllocation(uint256 timestamp) external {
        vm.assume(timestamp >= START_TIMESTAMP);
        vm.assume(timestamp <= START_TIMESTAMP + CLIFF_DURATION + VESTING_DURATION + 365 days);
        vm.warp(timestamp);

        vm.prank(BENEFICIARY, BENEFICIARY);
        try wallet.claim() {} catch {}

        assert(wallet.claimedAmount() <= wallet.totalAllocation());
    }

    // -------------------------------------------------------------------------
    // Vesting math: vestedAmount never exceeds totalAllocation
    // -------------------------------------------------------------------------

    function check_vestedNeverExceedsAllocation(uint256 timestamp) external view {
        uint256 vested = wallet.vestedAmount(timestamp);
        assert(vested <= wallet.totalAllocation());
    }

    // -------------------------------------------------------------------------
    // Dynamic authority: only the live manager owner can revoke.
    // -------------------------------------------------------------------------

    /// @notice Any caller other than the current manager owner cannot revoke.
    function check_revokeOnlyByCurrentOwner(address caller) external {
        vm.assume(caller != manager.owner());

        vm.prank(caller);
        try wallet.revokeUnvested() {
            assert(false);  // must have reverted
        } catch {
            // expected
        }
    }

    /// @notice The manager owner can always revoke (when revocable and not yet revoked).
    function check_ownerCanRevoke() external {
        vm.prank(manager.owner());
        wallet.revokeUnvested();
        assert(wallet.revoked());
    }

    // -------------------------------------------------------------------------
    // Revoke invariant: post-revoke, beneficiary cannot claim more than vested-at-revoke.
    // -------------------------------------------------------------------------

    function check_postRevokeClaimBoundedByVestedAtRevoke(uint256 timeBeforeRevoke, uint256 timeAfterRevoke) external {
        vm.assume(timeBeforeRevoke >= START_TIMESTAMP);
        vm.assume(timeBeforeRevoke <= START_TIMESTAMP + CLIFF_DURATION + VESTING_DURATION);
        vm.assume(timeAfterRevoke >= timeBeforeRevoke);
        vm.assume(timeAfterRevoke <= START_TIMESTAMP + CLIFF_DURATION + VESTING_DURATION + 365 days);

        vm.warp(timeBeforeRevoke);
        uint256 vestedAtRevoke = wallet.vestedAmount(timeBeforeRevoke);

        vm.prank(manager.owner());
        wallet.revokeUnvested();

        vm.warp(timeAfterRevoke);
        vm.prank(BENEFICIARY, BENEFICIARY);
        try wallet.claim() {} catch {}

        // After revoke, total transferred to beneficiary <= vested at revoke time.
        assert(wallet.claimedAmount() <= vestedAtRevoke);
    }

    // -------------------------------------------------------------------------
    // Non-beneficiary cannot claim.
    // -------------------------------------------------------------------------

    function check_nonBeneficiaryCannotClaim(address caller) external {
        vm.assume(caller != BENEFICIARY);

        vm.warp(START_TIMESTAMP + CLIFF_DURATION + VESTING_DURATION);

        uint256 claimedBefore = wallet.claimedAmount();

        vm.prank(caller);
        try wallet.claim() {
            assert(false);  // must have reverted
        } catch {
            assert(wallet.claimedAmount() == claimedBefore);
        }
    }
}
