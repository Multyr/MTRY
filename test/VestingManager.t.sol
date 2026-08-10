// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {
    ZeroAddress,
    ZeroAmount,
    TGENotSet,
    TGEAlreadySet,
    InvalidTimestamp,
    BucketCapExceeded,
    InvalidBatchSize,
    InvalidStartModeForBucket,
    BurnAmountZero,
    BurnExceedsBalance,
    NoBurnPending,
    BurnAlreadyPending,
    BurnNotReady,
    InvalidCapBucket,
    InvalidCliffDuration
} from "../src/Errors.sol";

contract VestingManagerTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // -------------------------------------------------------------------------
    // Caps
    // -------------------------------------------------------------------------
    function test_bucketCapsSumTo111M() public view {
        uint256 sum = vestingManager.maxBucketAllocation(VestingManager.BucketType.Team)
            + vestingManager.maxBucketAllocation(VestingManager.BucketType.StrategicStandard)
            + vestingManager.maxBucketAllocation(VestingManager.BucketType.StrategicExtended)
            + vestingManager.maxBucketAllocation(VestingManager.BucketType.AdvisorsStandard)
            + vestingManager.maxBucketAllocation(VestingManager.BucketType.AdvisorsShort);
        assertEq(sum, 111_000_000e18);
    }

    // ── A-1: setBucketCap reverts on sub-buckets ──────────────────────────────

    function test_setBucketCap_revertsOnGrowth() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidCapBucket.selector);
        vestingManager.setBucketCap(VestingManager.BucketType.Growth, 1_000_000e18);
    }

    function test_setBucketCap_revertsOnBDCore() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidCapBucket.selector);
        vestingManager.setBucketCap(VestingManager.BucketType.BDCore, 1_000_000e18);
    }

    function test_setBucketCap_revertsOnBDPerformance() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidCapBucket.selector);
        vestingManager.setBucketCap(VestingManager.BucketType.BDPerformance, 1_000_000e18);
    }

    function test_setBucketCap_succeedsOnTeam() public {
        vm.prank(deployer);
        vestingManager.setBucketCap(VestingManager.BucketType.Team, 60_000_000e18);
        assertEq(vestingManager.maxBucketAllocation(VestingManager.BucketType.Team), 60_000_000e18);
    }

    function test_setBucketCap_succeedsOnStrategicStandard() public {
        vm.prank(deployer);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicStandard, 30_000_000e18);
        assertEq(vestingManager.maxBucketAllocation(VestingManager.BucketType.StrategicStandard), 30_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Bucket × StartMode policy
    // -------------------------------------------------------------------------
    function test_strategicAllowsTgeMode() public {
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
        assertEq(VestingWalletLinear(w).startTimestamp(), block.timestamp);
    }

    function test_strategicAllowsGrantDateMode() public {
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(VestingWalletLinear(w).startTimestamp(), block.timestamp);
    }

    function test_teamRejectsTgeMode() public {
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartModeForBucket.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
    }

    function test_advisorsRejectsTgeMode() public {
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartModeForBucket.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.AdvisorsStandard,
            alice,
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
    }

    // -------------------------------------------------------------------------
    // TGE
    // -------------------------------------------------------------------------
    function test_tgeNotRequiredForGrantDateVesting() public {
        // Team is GRANT_DATE-only; should succeed without TGE set.
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1_000e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(VestingWalletLinear(w).startTimestamp(), block.timestamp);
        assertFalse(vestingManager.tgeSet());
    }

    function test_tgeRequiredForTgeMode() public {
        vm.prank(deployer);
        vm.expectRevert(TGENotSet.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
    }

    function test_setTGEOnceOnly() public {
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.prank(deployer);
        vm.expectRevert(TGEAlreadySet.selector);
        vestingManager.setTGE(block.timestamp + 1);
    }

    function test_setTGEPastReverts() public {
        vm.warp(1_000);
        vm.prank(deployer);
        vm.expectRevert(InvalidTimestamp.selector);
        vestingManager.setTGE(999);
    }

    // -------------------------------------------------------------------------
    // Bucket cap enforcement
    // -------------------------------------------------------------------------
    function test_exceedingBucketCapReverts() public {
        // StrategicStandard cap = 27M
        vm.prank(deployer);
        vm.expectRevert(BucketCapExceeded.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            alice,
            27_000_000e18 + 1,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    function test_teamCapSharedWithGrowthAndBD() public {
        // Team cap = 51M. Fill 30M via Team + 20M via Growth + 1M via BDCore → total 51M OK
        vm.startPrank(deployer);
        vestingManager.createVesting(VestingManager.BucketType.Team, alice, 30_000_000e18, 365 days, 1095 days, false, VestingManager.VestingStartMode.GRANT_DATE);
        vestingManager.createVesting(VestingManager.BucketType.Growth, bob, 20_000_000e18, 180 days, 540 days, false, VestingManager.VestingStartMode.GRANT_DATE);
        vestingManager.createVesting(VestingManager.BucketType.BDCore, carol, 1_000_000e18, 180 days, 540 days, false, VestingManager.VestingStartMode.GRANT_DATE);
        // Any more must fail
        vm.expectRevert(BucketCapExceeded.selector);
        vestingManager.createVesting(VestingManager.BucketType.BDPerformance, address(0xAAA), 1, 0, 270 days, false, VestingManager.VestingStartMode.GRANT_DATE);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Batch
    // -------------------------------------------------------------------------
    function test_batchCreateRespectsMaxSize() public {
        VestingManager.CreateVestingParams[] memory arr = new VestingManager.CreateVestingParams[](51);
        for (uint256 i; i < 51; ++i) {
            arr[i] = VestingManager.CreateVestingParams({
                bucket: VestingManager.BucketType.Team,
                beneficiary: address(uint160(100 + i)),
                allocation: 1e18,
                cliffDuration: 1 days,
                vestingDuration: 10 days,
                revocable: false,
                startMode: VestingManager.VestingStartMode.GRANT_DATE
            });
        }
        vm.prank(deployer);
        vm.expectRevert(InvalidBatchSize.selector);
        vestingManager.batchCreateVestings(arr);
    }

    function test_batchCreateEmptyReverts() public {
        VestingManager.CreateVestingParams[] memory arr = new VestingManager.CreateVestingParams[](0);
        vm.prank(deployer);
        vm.expectRevert(InvalidBatchSize.selector);
        vestingManager.batchCreateVestings(arr);
    }

    function test_batchCreateSucceeds() public {
        VestingManager.CreateVestingParams[] memory arr = new VestingManager.CreateVestingParams[](3);
        arr[0] = VestingManager.CreateVestingParams({
            bucket: VestingManager.BucketType.Team,
            beneficiary: alice,
            allocation: 1_000e18,
            cliffDuration: 365 days,
            vestingDuration: 1095 days,
            revocable: false,
            startMode: VestingManager.VestingStartMode.GRANT_DATE
        });
        arr[1] = VestingManager.CreateVestingParams({
            bucket: VestingManager.BucketType.Growth,
            beneficiary: bob,
            allocation: 500e18,
            cliffDuration: 180 days,
            vestingDuration: 540 days,
            revocable: true,
            startMode: VestingManager.VestingStartMode.GRANT_DATE
        });
        arr[2] = VestingManager.CreateVestingParams({
            bucket: VestingManager.BucketType.AdvisorsShort,
            beneficiary: carol,
            allocation: 200e18,
            cliffDuration: 90 days,
            vestingDuration: 540 days,
            revocable: false,
            startMode: VestingManager.VestingStartMode.GRANT_DATE
        });
        vm.prank(deployer);
        address[] memory wallets = vestingManager.batchCreateVestings(arr);
        assertEq(wallets.length, 3);
        assertEq(vestingManager.vestingCount(), 3);
    }

    // -------------------------------------------------------------------------
    // Wallet funding + authorization
    // -------------------------------------------------------------------------
    function test_createdWalletIsFunded() public {
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            500e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(mtry.balanceOf(w), 500e18);
    }

    function test_createdWalletIsAuthorizedSource() public {
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            500e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertTrue(unlockController.authorizedSource(w));
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------
    function test_paginatedViewReturnsRecords() public {
        vm.startPrank(deployer);
        for (uint256 i; i < 5; ++i) {
            vestingManager.createVesting(
                VestingManager.BucketType.Team,
                address(uint160(100 + i)),
                1e18,
                365 days,
                1095 days,
                false,
                VestingManager.VestingStartMode.GRANT_DATE
            );
        }
        vm.stopPrank();

        (VestingManager.VestingRecord[] memory page, uint256 total) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 3);
        assertEq(total, 5);
        assertEq(page.length, 3);
    }

    function test_paginatedViewOffsetBeyondTotalReturnsEmpty() public {
        (VestingManager.VestingRecord[] memory page, uint256 total) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 100, 10);
        assertEq(page.length, 0);
        assertEq(total, 0);
    }

    function test_getBucketRemaining() public {
        vm.prank(deployer);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            10_000_000e18,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(vestingManager.getBucketRemaining(VestingManager.BucketType.Team), 51_000_000e18 - 10_000_000e18);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------
    function test_pauseBlocksCreate() public {
        vm.prank(deployer);
        vestingManager.pause();
        vm.prank(deployer);
        vm.expectRevert();
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1e18,
            1 days,
            10 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    // -------------------------------------------------------------------------
    // Burn timelock
    // -------------------------------------------------------------------------
    function test_burnRequires7dayDelay() public {
        vm.prank(deployer);
        vestingManager.proposeBurn(1_000e18);
        vm.prank(deployer);
        vm.expectRevert(BurnNotReady.selector);
        vestingManager.executeBurn();

        vm.warp(block.timestamp + 7 days);
        uint256 supplyBefore = mtry.totalSupply();
        vm.prank(deployer);
        vestingManager.executeBurn();
        assertEq(mtry.totalSupply(), supplyBefore - 1_000e18);
        assertEq(mtry.totalBurned(), 1_000e18);
    }

    function test_burnAmountExceedsBalanceReverts() public {
        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        vestingManager.proposeBurn(200_000_000e18);
    }

    function test_cancelBurn() public {
        vm.prank(deployer);
        vestingManager.proposeBurn(1_000e18);
        vm.prank(deployer);
        vestingManager.cancelBurn();
        assertEq(vestingManager.pendingBurnAmount(), 0);
    }

    // -------------------------------------------------------------------------
    // unpause
    // -------------------------------------------------------------------------
    function test_unpauseRestoresCreate() public {
        vm.prank(deployer);
        vestingManager.pause();
        vm.prank(deployer);
        vestingManager.unpause();
        assertFalse(vestingManager.paused());
        // Create should now succeed
        vm.prank(deployer);
        address w = vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1e18,
            1 days,
            10 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertTrue(w != address(0));
    }

    // -------------------------------------------------------------------------
    // getBucketCount
    // -------------------------------------------------------------------------
    function test_getBucketCountZeroInitially() public view {
        assertEq(vestingManager.getBucketCount(VestingManager.BucketType.Team), 0);
    }

    function test_getBucketCountIncrementsOnCreate() public {
        vm.prank(deployer);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1e18,
            1 days,
            10 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(vestingManager.getBucketCount(VestingManager.BucketType.Team), 1);

        vm.prank(deployer);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            bob,
            1e18,
            1 days,
            10 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(vestingManager.getBucketCount(VestingManager.BucketType.Team), 2);
    }

    // -------------------------------------------------------------------------
    // Constructor revert guards
    // -------------------------------------------------------------------------
    function test_constructorRevertsOnZeroToken() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingManager(address(0), address(1), address(1), deployer);
    }

    function test_constructorRevertsOnZeroTreasury() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingManager(address(mtry), address(0), address(1), deployer);
    }

    function test_constructorRevertsOnZeroUnlockController() public {
        vm.expectRevert(ZeroAddress.selector);
        new VestingManager(address(mtry), address(1), address(0), deployer);
    }

    // -------------------------------------------------------------------------
    // _validateStartMode — non-Strategic bucket rejects TGE mode
    // -------------------------------------------------------------------------
    function test_nonStrategicBucketRejectsTgeMode() public {
        vm.prank(deployer);
        vestingManager.setTGE(block.timestamp);
        vm.prank(deployer);
        vm.expectRevert(InvalidStartModeForBucket.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.AdvisorsShort,
            alice,
            1_000e18,
            90 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        );
    }

    // -------------------------------------------------------------------------
    // getVestingsByBucketPaginated — limit == 0 returns empty
    // -------------------------------------------------------------------------
    function test_paginatedView_limitZeroReturnsEmpty() public {
        // Create one vesting so the bucket is non-empty
        _createGrantVesting(VestingManager.BucketType.Team, alice, 1_000e18, 0, 365 days, false);

        (VestingManager.VestingRecord[] memory page, uint256 total) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 0, 0);
        assertEq(page.length, 0, "limit=0 must return empty page");
        assertEq(total, 1, "total still reflects actual count");
    }

    // -------------------------------------------------------------------------
    // setWhitelistedBeneficiaryContract — zero-address guard
    // -------------------------------------------------------------------------
    function test_setWhitelistedBeneficiaryContract_revertsOnZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(deployer);
        vestingManager.setWhitelistedBeneficiaryContract(address(0), true);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: setBucketCap below current live allocation → BucketCapExceeded
    // -------------------------------------------------------------------------
    function test_setBucketCap_belowAllocatedReverts() public {
        // Allocate 10M into Team, then try to lower the cap below it.
        _createGrantVesting(VestingManager.BucketType.Team, alice, 10_000_000e18, 365 days, 1095 days, false);
        vm.prank(deployer);
        vm.expectRevert(BucketCapExceeded.selector);
        vestingManager.setBucketCap(VestingManager.BucketType.Team, 10_000_000e18 - 1);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _createVesting parameter guards
    // -------------------------------------------------------------------------
    function test_createVesting_zeroBeneficiaryReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            address(0),
            1_000e18,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    function test_createVesting_zeroAllocationReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAmount.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            0,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    function test_createVesting_zeroVestingDurationReverts() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAmount.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1_000e18,
            180 days,
            0,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    function test_createVesting_cliffExceedsMaxReverts() public {
        uint64 tooLongCliff = uint64(10 * 365 days + 1); // > MAX_CLIFF_DURATION
        vm.prank(deployer);
        vm.expectRevert(InvalidCliffDuration.selector);
        vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice,
            1_000e18,
            tooLongCliff,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }

    // -------------------------------------------------------------------------
    // Coverage gap: getVestingsByBucketPaginated end clamp (end > total)
    // -------------------------------------------------------------------------
    function test_paginatedView_endClampedToTotal() public {
        vm.startPrank(deployer);
        for (uint256 i; i < 3; ++i) {
            vestingManager.createVesting(
                VestingManager.BucketType.Team,
                address(uint160(200 + i)),
                1e18,
                365 days,
                1095 days,
                false,
                VestingManager.VestingStartMode.GRANT_DATE
            );
        }
        vm.stopPrank();

        // offset=1, limit=5 → end would be 6 > total 3, clamped to 3 → 2 entries.
        (VestingManager.VestingRecord[] memory page, uint256 total) =
            vestingManager.getVestingsByBucketPaginated(VestingManager.BucketType.Team, 1, 5);
        assertEq(total, 3);
        assertEq(page.length, 2);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: getBucketRemaining when fully allocated (used >= cap) → 0
    // -------------------------------------------------------------------------
    function test_getBucketRemaining_fullyAllocatedReturnsZero() public {
        // Fill the entire Team cap (51M) exactly.
        _createGrantVesting(VestingManager.BucketType.Team, alice, 51_000_000e18, 365 days, 1095 days, false);
        assertEq(vestingManager.getBucketRemaining(VestingManager.BucketType.Team), 0);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: proposeBurn already pending → BurnAlreadyPending
    // -------------------------------------------------------------------------
    function test_proposeBurn_alreadyPendingReverts() public {
        vm.startPrank(deployer);
        vestingManager.proposeBurn(1_000e18);
        vm.expectRevert(BurnAlreadyPending.selector);
        vestingManager.proposeBurn(1_000e18);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: executeBurn guards
    // -------------------------------------------------------------------------
    function test_executeBurn_noPendingReverts() public {
        vm.prank(deployer);
        vm.expectRevert(NoBurnPending.selector);
        vestingManager.executeBurn();
    }

    function test_executeBurn_exceedsBalanceReverts() public {
        uint256 balance = mtry.balanceOf(address(vestingManager));
        vm.prank(deployer);
        vestingManager.proposeBurn(balance);
        vm.warp(block.timestamp + 7 days);

        // Drain some tokens so balance drops below the pending amount.
        vm.prank(address(vestingManager));
        mtry.transfer(bob, 1);

        vm.prank(deployer);
        vm.expectRevert(BurnExceedsBalance.selector);
        vestingManager.executeBurn();
    }

    // -------------------------------------------------------------------------
    // Coverage gap: proposeBurn() amount == 0 → BurnAmountZero
    // -------------------------------------------------------------------------
    function test_proposeBurn_zeroAmountReverts() public {
        vm.prank(deployer);
        vm.expectRevert(BurnAmountZero.selector);
        vestingManager.proposeBurn(0);
    }
}

