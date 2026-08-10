// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";

/// @title GlobalUnlockControllerSymbolic — Halmos formal-verification harness
/// @notice Proves the single-cap invariant on `GlobalUnlockController` via symbolic execution.
/// @dev Halmos treats function parameters as symbolic and attempts to prove that assertions
///      hold for ALL possible inputs. Run with:
///          halmos --match-contract GlobalUnlockControllerSymbolic
contract GlobalUnlockControllerSymbolicTest is Test {
    GlobalUnlockController internal ctrl;

    address internal constant TOKEN = address(uint160(0x1000));
    address internal constant OWNER = address(uint160(0xABCD));
    address internal constant SHARED = address(uint160(0x5AA5));
    address internal constant PROTECTED_SRC = address(uint160(0xCA1E));

    uint256 internal constant GENESIS = 0;
    uint256 internal constant PERIOD_DURATION = 30 days;
    uint256 internal constant INITIAL_CAP_BPS = 200;   // 2%
    uint256 internal constant REFERENCE_SUPPLY = 300_000_000e18;

    function setUp() public {
        ctrl = new GlobalUnlockController(
            TOKEN,
            OWNER,
            GENESIS,
            PERIOD_DURATION,
            INITIAL_CAP_BPS,
            REFERENCE_SUPPLY
        );
        vm.prank(OWNER);
        ctrl.setAuthorizedSource(SHARED, true);
        vm.prank(OWNER);
        ctrl.setAuthorizedSource(PROTECTED_SRC, true);
        vm.prank(OWNER);
        ctrl.setProtectedSource(PROTECTED_SRC, true);
    }

    /// @notice Single-cap invariant: two arbitrary consumptions across lanes stay within the cap.
    /// @dev Halmos makes `sharedAmt` and `protectedAmt` symbolic. If any assignment violates
    ///      the assertion, it is reported as a counter-example.
    function check_totalReleasedNeverExceedsCap(uint256 sharedAmt, uint256 protectedAmt) external {
        // Bound inputs to reasonable range (zero is rejected by consumeAllowance).
        vm.assume(sharedAmt > 0 && sharedAmt <= 100_000_000e18);
        vm.assume(protectedAmt > 0 && protectedAmt <= 100_000_000e18);

        vm.prank(SHARED);
        try ctrl.consumeAllowance(sharedAmt) {} catch {}

        vm.prank(PROTECTED_SRC);
        try ctrl.consumeAllowance(protectedAmt) {} catch {}

        uint256 period = ctrl.currentPeriod();
        uint256 total = ctrl.totalReleasedInPeriod(period);
        uint256 cap = ctrl.maxUnlockForPeriod(period);

        assert(total <= cap);
    }

    /// @notice Shared lane upper bound: shared release cannot exceed `cap - protectedReserve`.
    function check_sharedLaneBoundedByReservedQuota(uint256 sharedAmt) external {
        vm.assume(sharedAmt > 0 && sharedAmt <= 100_000_000e18);

        vm.prank(SHARED);
        try ctrl.consumeAllowance(sharedAmt) {} catch {}

        uint256 period = ctrl.currentPeriod();
        uint256 cap = ctrl.maxUnlockForPeriod(period);
        uint256 protectedReserve = (cap * ctrl.protectedQuotaBps()) / 10_000;
        uint256 sharedUsed = ctrl.releasedInPeriod(period);

        assert(sharedUsed <= cap - protectedReserve);
    }

    /// @notice Protected lane can access the full cap minus already-used shared capacity.
    function check_protectedLaneBoundedByFullCap(uint256 protectedAmt) external {
        vm.assume(protectedAmt > 0 && protectedAmt <= 100_000_000e18);

        vm.prank(PROTECTED_SRC);
        try ctrl.consumeAllowance(protectedAmt) {} catch {}

        uint256 period = ctrl.currentPeriod();
        uint256 protectedUsed = ctrl.protectedReleasedInPeriod(PROTECTED_SRC, period);
        uint256 cap = ctrl.maxUnlockForPeriod(period);

        assert(protectedUsed <= cap);
    }

    /// @notice Three-call interleaving: stress the solver with more paths.
    function check_threeCallsStayUnderCap(uint256 a1, uint256 a2, uint256 a3) external {
        vm.assume(a1 > 0 && a2 > 0 && a3 > 0);
        vm.assume(a1 <= 100_000_000e18 && a2 <= 100_000_000e18 && a3 <= 100_000_000e18);

        vm.prank(SHARED);
        try ctrl.consumeAllowance(a1) {} catch {}
        vm.prank(PROTECTED_SRC);
        try ctrl.consumeAllowance(a2) {} catch {}
        vm.prank(SHARED);
        try ctrl.consumeAllowance(a3) {} catch {}

        uint256 period = ctrl.currentPeriod();
        assert(ctrl.totalReleasedInPeriod(period) <= ctrl.maxUnlockForPeriod(period));
    }

    /// @notice Granted amount is never more than requested.
    function check_grantedLeqRequested(uint256 amt) external {
        vm.assume(amt > 0 && amt <= 100_000_000e18);

        vm.prank(SHARED);
        try ctrl.consumeAllowance(amt) returns (uint256 granted) {
            assert(granted <= amt);
        } catch {}
    }

    /// @notice Unauthorized sources never increase the counters.
    function check_unauthorizedSourceNeverReleases(address badGuy, uint256 amt) external {
        vm.assume(badGuy != SHARED && badGuy != PROTECTED_SRC);
        vm.assume(amt > 0);

        uint256 period = ctrl.currentPeriod();
        uint256 sharedBefore = ctrl.releasedInPeriod(period);
        uint256 protectedBefore = ctrl.protectedReleasedInPeriod(badGuy, period);

        vm.prank(badGuy);
        try ctrl.consumeAllowance(amt) {} catch {}

        assert(ctrl.releasedInPeriod(period) == sharedBefore);
        assert(ctrl.protectedReleasedInPeriod(badGuy, period) == protectedBefore);
    }
}
