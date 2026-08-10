// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "../helpers/TestSetup.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {VestingManager} from "../../src/VestingManager.sol";

// =============================================================================
// POC-13: A Revoked VestingWalletLinear Remains Authorized in GlobalUnlockController
// =============================================================================
//
// STATUS: OPEN DESIGN QUESTION -- no fix applied
//
// BEHAVIOR:
//   createVesting() calls addVestingSource(wallet) setting authorizedSource[wallet]=true.
//   There is no removeVestingSource(). When a wallet is revoked (revokeUnvested()),
//   the authorization stays. This is a deliberate choice: a revoked wallet may still
//   have vested-but-unclaimed tokens that the beneficiary is entitled to claim via
//   consumeAllowance(). Removing authorization would block those legitimate claims.
//   Once all vested tokens are claimed, the wallet is fully drained but remains
//   permanently authorized -- a dead entry in the mapping that grows over time.
//
// WHY NO FIX:
//   The authorization is required for the post-revoke claim path. Adding a
//   removeVestingSource() function without a post-revoke claim path would lock
//   beneficiaries out of their entitled tokens. The security concern is low:
//   a fully-drained wallet cannot call consumeAllowance() with any economically
//   meaningful effect (the wallet enforces its own _releasable() accounting).
//   EIP-6780 eliminates the address-reuse attack vector on Arbitrum.
//
// OPEN QUESTIONS:
//   Q1. The authorizedSource mapping grows monotonically -- every wallet ever created
//       stays in it. At large scale (hundreds of grants/revocations), is there an
//       off-chain tool to enumerate live vs dead sources for monitoring purposes?
//   Q2. Once a revoked wallet has been fully claimed, should governance be able to
//       call a "decommission" function that removes the authorization (accepting the
//       tradeoff that the wallet can no longer call consumeAllowance)?
//   Q3. The controller trusts wallet._releasable() math implicitly. There is no
//       secondary check; this is documented as an explicit design decision but should
//       be called out in the security model.
// =============================================================================

contract POC13_RevokedWalletStaysAuthorized is TestSetup {
    VestingWalletLinear wallet;

    uint256 constant ALLOCATION = 1_000_000e18;
    uint64 constant CLIFF = 0;
    uint64 constant VEST = 365 days;

    function setUp() public {
        _deployAllCorrectly();
        vm.startPrank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.stopPrank();

        // Create a revocable wallet
        address w = _createGrantVesting(
            VestingManager.BucketType.Team,
            teamBeneficiary,
            ALLOCATION,
            CLIFF,
            VEST,
            true // revocable
        );
        wallet = VestingWalletLinear(w);
    }

    // -------------------------------------------------------------------------
    // Wallet starts authorized
    // -------------------------------------------------------------------------
    function test_walletIsAuthorizedAfterCreation() public view {
        assertTrue(
            unlockController.authorizedSource(address(wallet)),
            "wallet authorized in GlobalUnlockController"
        );
        assertFalse(wallet.revoked(), "wallet not yet revoked");
    }

    // -------------------------------------------------------------------------
    // After revocation, wallet stays authorized
    // -------------------------------------------------------------------------
    function test_revokedWalletRemainsAuthorized() public {
        // Warp to 50% vesting (no cliff, so 50% vested at 6 months)
        vm.warp(block.timestamp + VEST / 2);

        // Revoke -- transfers unvested 50% to treasury
        vm.prank(deployer);
        wallet.revokeUnvested();

        assertTrue(wallet.revoked(), "wallet is revoked");
        assertTrue(
            unlockController.authorizedSource(address(wallet)),
            "QUESTION: revoked wallet is still authorized in controller"
        );
        assertTrue(
            vestingManager.walletRevocationRecorded(address(wallet)),
            "revocation recorded in VestingManager"
        );
    }

    // -------------------------------------------------------------------------
    // After full claim post-revoke, wallet has 0 balance but stays authorized
    // -------------------------------------------------------------------------
    function test_fullyClaimedRevokedWalletStaysAuthorized() public {
        vm.warp(block.timestamp + VEST / 2);

        // Revoke at 50% vesting -- 500k vested, 500k returned to treasury
        vm.prank(deployer);
        wallet.revokeUnvested();

        // Beneficiary claims all remaining vested tokens (500k)
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.claim();

        // Wallet now has zero MTRY balance and zero releasable
        assertEq(mtry.balanceOf(address(wallet)), 0, "wallet balance is zero");
        assertEq(wallet.releasableAmount(), 0, "nothing releasable");

        // Wallet is still authorized -- permanently
        assertTrue(
            unlockController.authorizedSource(address(wallet)),
            "QUESTION: fully-drained revoked wallet stays authorized indefinitely"
        );

        // QUESTION: If this wallet tries to call consumeAllowance() (e.g. via claim()),
        // it would fail at wallet level (NothingToRelease) before reaching consumeAllowance.
        // But the authorization itself is never cleaned up.
    }

    // -------------------------------------------------------------------------
    // Demonstrate growing authorized-source set over multiple revocations
    // -------------------------------------------------------------------------
    function test_revokedWalletsAccumulateAsAuthorizedSources() public {
        address[] memory wallets = new address[](3);

        // Create 3 revocable Team wallets and revoke all of them
        for (uint256 i = 0; i < 3; i++) {
            address beneficiary = address(uint160(0x5000 + i));
            vm.prank(deployer);
            wallets[i] = vestingManager.createVesting(
                VestingManager.BucketType.Team,
                beneficiary,
                1_000e18, // small allocation
                0,
                365 days,
                true,
                VestingManager.VestingStartMode.GRANT_DATE
            );

            // Revoke immediately
            vm.prank(deployer);
            VestingWalletLinear(wallets[i]).revokeUnvested();
        }

        // All 3 revoked wallets are still authorized
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(
                unlockController.authorizedSource(wallets[i]),
                "revoked wallet remains authorized"
            );
        }

        // QUESTION: With many grants and revocations over the protocol's lifetime,
        // the authorizedSource mapping grows without bound. Is there a cleanup path?
    }
}
