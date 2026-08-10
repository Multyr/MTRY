// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev Minimal mock token (ERC20 + burnable) used in symbolic tests.
contract MockMTRY is ERC20, ERC20Burnable {
    constructor() ERC20("Mock MTRY", "MMTRY") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title VestingManagerSymbolic — Halmos proofs for bucket allocation invariants.
contract VestingManagerSymbolicTest is Test {
    MockMTRY internal token;
    VestingManager internal manager;
    GlobalUnlockController internal unlockCtrl;

    address internal constant OWNER = address(uint160(0xABCD));
    address internal constant TREASURY = address(uint160(0xCAFE));

    uint256 internal constant TEAM_CAP = 51_000_000e18;
    uint256 internal constant STRAT_STD_CAP = 27_000_000e18;

    function setUp() public {
        token = new MockMTRY();

        unlockCtrl = new GlobalUnlockController(
            address(token),
            OWNER,
            0,              // genesis
            30 days,
            200,
            300_000_000e18
        );

        manager = new VestingManager(
            address(token),
            TREASURY,
            address(unlockCtrl),
            OWNER
        );

        // Wire the manager with the unlock controller and fund it.
        vm.prank(OWNER);
        unlockCtrl.setVestingManager(address(manager));
        token.mint(address(manager), 300_000_000e18);

        // Initialize bucket caps.
        vm.prank(OWNER);
        manager.setBucketCap(VestingManager.BucketType.Team, TEAM_CAP);
        vm.prank(OWNER);
        manager.setBucketCap(VestingManager.BucketType.StrategicStandard, STRAT_STD_CAP);
    }

    // -------------------------------------------------------------------------
    // Bucket cap invariant: totalBucketAllocated[bucket] <= maxBucketAllocation[bucket]
    // -------------------------------------------------------------------------

    /// @notice After any successful or failed create, bucket usage never exceeds its cap.
    function check_teamBucketCapRespected(uint256 a1, uint256 a2) external {
        vm.assume(a1 > 0 && a1 <= 60_000_000e18);
        vm.assume(a2 > 0 && a2 <= 60_000_000e18);

        vm.prank(OWNER);
        try manager.createVesting(
            VestingManager.BucketType.Team,
            address(uint160(0x1111)),
            a1,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        ) {} catch {}

        vm.prank(OWNER);
        try manager.createVesting(
            VestingManager.BucketType.Growth,  // shares Team cap
            address(uint160(0x2222)),
            a2,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        ) {} catch {}

        // Invariant: the Team cap (shared with Growth, BDCore, BDPerformance) is never exceeded.
        assert(manager.totalBucketAllocated(VestingManager.BucketType.Team) <= TEAM_CAP);
    }

    /// @notice Strategic Standard cap enforced independently.
    function check_strategicStandardCapRespected(uint256 a) external {
        vm.assume(a > 0 && a <= 30_000_000e18);

        vm.prank(OWNER);
        try manager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            address(uint160(0x3333)),
            a,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        ) {} catch {}

        assert(
            manager.totalBucketAllocated(VestingManager.BucketType.StrategicStandard)
            <= STRAT_STD_CAP
        );
    }

    // -------------------------------------------------------------------------
    // TGE mode requires tgeSet = true.
    // -------------------------------------------------------------------------

    /// @notice A TGE-mode create call reverts unless setTGE was called.
    function check_tgeModeRequiresTgeSet(uint256 a) external {
        vm.assume(a > 0 && a <= 10_000_000e18);

        // TGE has not been set in setUp(). StrategicStandard allows TGE mode but requires tgeSet.
        vm.prank(OWNER);
        try manager.createVesting(
            VestingManager.BucketType.StrategicStandard,
            address(uint160(0x4444)),
            a,
            180 days,
            540 days,
            false,
            VestingManager.VestingStartMode.TGE
        ) {
            assert(false);  // must have reverted
        } catch {
            // expected
        }
    }

    // -------------------------------------------------------------------------
    // Team/Growth/BD/Advisors reject TGE mode (policy enforcement).
    // -------------------------------------------------------------------------

    function check_teamRejectsTgeMode(uint256 a) external {
        vm.assume(a > 0 && a <= 10_000_000e18);

        // Even with TGE set, Team must reject TGE mode.
        vm.prank(OWNER);
        manager.setTGE(block.timestamp + 1);

        vm.prank(OWNER);
        try manager.createVesting(
            VestingManager.BucketType.Team,
            address(uint160(0x5555)),
            a,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.TGE
        ) {
            assert(false);
        } catch {}
    }

    // -------------------------------------------------------------------------
    // Only owner can create vestings.
    // -------------------------------------------------------------------------

    function check_onlyOwnerCanCreate(address caller, uint256 a) external {
        vm.assume(caller != OWNER);
        vm.assume(a > 0 && a <= 10_000_000e18);

        uint256 countBefore = manager.vestingCount();

        vm.prank(caller);
        try manager.createVesting(
            VestingManager.BucketType.Team,
            address(uint160(0x6666)),
            a,
            365 days,
            1095 days,
            false,
            VestingManager.VestingStartMode.GRANT_DATE
        ) {
            assert(false);
        } catch {
            assert(manager.vestingCount() == countBefore);
        }
    }
}
