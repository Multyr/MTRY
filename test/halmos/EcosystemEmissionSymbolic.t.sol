// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EcosystemEmissionController} from "../../src/EcosystemEmissionController.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MockToken is ERC20, ERC20Burnable {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title EcosystemEmissionSymbolic — Halmos proofs for per-epoch and horizon invariants.
contract EcosystemEmissionSymbolicTest is Test {
    MockToken internal token;
    EcosystemEmissionController internal ecosystem;
    GlobalUnlockController internal unlockCtrl;

    address internal constant OWNER = address(uint160(0xABCD));
    address internal constant RECIPIENT = address(uint160(0x1234));

    uint256 internal constant EPOCH_DURATION = 30 days;
    uint256 internal constant INITIAL_EPOCH_CAP = 1_000_000e18;

    function setUp() public {
        token = new MockToken();

        unlockCtrl = new GlobalUnlockController(
            address(token),
            OWNER,
            0,
            30 days,
            200,
            300_000_000e18
        );

        ecosystem = new EcosystemEmissionController(
            address(token),
            address(unlockCtrl),
            OWNER,
            0,
            EPOCH_DURATION,
            INITIAL_EPOCH_CAP
        );

        vm.prank(OWNER);
        unlockCtrl.setAuthorizedSource(address(ecosystem), true);

        token.mint(address(ecosystem), 100_000_000e18);

        vm.prank(OWNER);
        ecosystem.setApprovedRecipient(RECIPIENT, true);
    }

    // -------------------------------------------------------------------------
    // Local per-epoch cap: emittedInEpoch[e] <= maxEmissionByEpoch[e]
    // -------------------------------------------------------------------------

    function check_perEpochCapRespected(uint256 amount) external {
        vm.assume(amount > 0 && amount <= 10_000_000e18);

        uint256 epoch = ecosystem.currentEpoch();

        vm.prank(OWNER);
        try ecosystem.emitTo(RECIPIENT, amount) {} catch {}

        uint256 used = ecosystem.emittedInEpoch(epoch);
        uint256 localCap = ecosystem.maxEmissionByEpoch(epoch);
        if (localCap == 0) localCap = ecosystem.currentMaxEmissionPerEpoch();
        assert(used <= localCap);
    }

    // -------------------------------------------------------------------------
    // Granted amount <= requested amount (emitTo return)
    // -------------------------------------------------------------------------

    function check_emitGrantedLeqRequested(uint256 amount) external {
        vm.assume(amount > 0 && amount <= 10_000_000e18);

        vm.prank(OWNER);
        try ecosystem.emitTo(RECIPIENT, amount) returns (uint256 granted) {
            assert(granted <= amount);
        } catch {}
    }

    // -------------------------------------------------------------------------
    // Only approved recipients receive emissions.
    // -------------------------------------------------------------------------

    function check_onlyApprovedRecipient(address notApproved, uint256 amount) external {
        vm.assume(notApproved != RECIPIENT);
        vm.assume(amount > 0 && amount <= 1_000_000e18);

        uint256 receivedBefore = token.balanceOf(notApproved);

        vm.prank(OWNER);
        try ecosystem.emitTo(notApproved, amount) {
            assert(false);  // must revert
        } catch {
            assert(token.balanceOf(notApproved) == receivedBefore);
        }
    }

    // -------------------------------------------------------------------------
    // Only owner may emit.
    // -------------------------------------------------------------------------

    function check_onlyOwnerCanEmit(address caller, uint256 amount) external {
        vm.assume(caller != OWNER);
        vm.assume(amount > 0 && amount <= 1_000_000e18);

        uint256 totalEmittedBefore = ecosystem.totalEmitted();

        vm.prank(caller);
        try ecosystem.emitTo(RECIPIENT, amount) {
            assert(false);
        } catch {
            assert(ecosystem.totalEmitted() == totalEmittedBefore);
        }
    }

    // -------------------------------------------------------------------------
    // totalEmitted monotonically non-decreasing.
    // -------------------------------------------------------------------------

    function check_totalEmittedMonotonic(uint256 amount) external {
        vm.assume(amount > 0 && amount <= 1_000_000e18);
        uint256 before_ = ecosystem.totalEmitted();

        vm.prank(OWNER);
        try ecosystem.emitTo(RECIPIENT, amount) {} catch {}

        assert(ecosystem.totalEmitted() >= before_);
    }
}
