// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SetTGE} from "../script/SetTGE.s.sol";
import {TestSetup} from "./helpers/TestSetup.sol";
import {TGEAlreadySet} from "../src/Errors.sol";

// =============================================================================
// Broadcast sender probe
// =============================================================================
//
// SetTGE.run() wraps its two setTGE calls in vm.startBroadcast(). Inside a test,
// calls made under broadcast come from Foundry's configured sender, not from the
// test contract. Rather than hardcoding that address, the probe records the
// msg.sender actually observed under startBroadcast, and setUp transfers
// ownership of claim/vestingManager to it — mirroring the real precondition
// that the broadcast key must be the owner of both contracts.
//
contract BroadcastSenderRecorder {
    address public lastSender;

    function record() external {
        lastSender = msg.sender;
    }
}

contract BroadcastSenderProbe is Script {
    function probe(BroadcastSenderRecorder recorder) external {
        vm.startBroadcast();
        recorder.record();
        vm.stopBroadcast();
    }
}

// =============================================================================
// SetTGEIntegrationTest
// =============================================================================
//
// Integration coverage for script/SetTGE.s.sol via its real run() entry point:
// env vars are injected with vm.setEnv and the script executes its own
// vm.envUint / vm.envAddress / vm.startBroadcast path.
//
contract SetTGEIntegrationTest is TestSetup {
    SetTGE internal setTgeScript;
    address internal broadcaster;

    /// @dev The single TGE_TIMESTAMP value used by every test in this suite.
    ///      vm.setEnv is process-global and forge runs tests in parallel, so
    ///      tests in one suite writing DIFFERENT values to the same env var race
    ///      each other. Every test therefore sets the same value (setUp computes
    ///      it from the same initial block.timestamp in each test's instance)
    ///      and scenarios vary via vm.warp instead of via the env var.
    uint256 internal tgeEnv;

    function setUp() public {
        _deployAllCorrectly();

        // Discover the sender used by vm.startBroadcast() in this test run.
        BroadcastSenderRecorder recorder = new BroadcastSenderRecorder();
        BroadcastSenderProbe probe = new BroadcastSenderProbe();
        probe.probe(recorder);
        broadcaster = recorder.lastSender();

        // The broadcast key must own both contracts for setTGE (onlyOwner).
        // GovernanceRoles is Ownable2Step: transfer + accept.
        vm.startPrank(deployer);
        claim.transferOwnership(broadcaster);
        vestingManager.transferOwnership(broadcaster);
        vm.stopPrank();
        vm.startPrank(broadcaster);
        claim.acceptOwnership();
        vestingManager.acceptOwnership();
        vm.stopPrank();

        setTgeScript = new SetTGE();

        // Env vars read by run(). Identical values in every test (see tgeEnv).
        tgeEnv = block.timestamp + 7 days;
        vm.setEnv("TGE_TIMESTAMP", vm.toString(tgeEnv));
        vm.setEnv("PREMTRY_CLAIM_ADDRESS", vm.toString(address(claim)));
        vm.setEnv("VESTING_MANAGER_ADDRESS", vm.toString(address(vestingManager)));
    }

    // -------------------------------------------------------------------------
    // Happy path — run() sets the same TGE on both contracts
    // -------------------------------------------------------------------------

    function test_run_setsSameTgeOnClaimAndVestingManager() public {
        setTgeScript.run();

        // Assert on state via getters, not merely absence of revert.
        assertEq(claim.tgeTimestamp(), tgeEnv, "claim TGE not set to env value");
        assertEq(vestingManager.tgeTimestamp(), tgeEnv, "vestingManager TGE not set to env value");
        assertTrue(vestingManager.tgeSet(), "vestingManager tgeSet flag not raised");
        assertEq(
            claim.tgeTimestamp(),
            vestingManager.tgeTimestamp(),
            "claim and vestingManager report different TGE values"
        );
    }

    function test_run_acceptsTgeEqualToBlockTimestamp() public {
        // Boundary of the script's require: tge >= block.timestamp ("present").
        vm.warp(tgeEnv);

        setTgeScript.run();

        assertEq(claim.tgeTimestamp(), tgeEnv, "claim TGE mismatch at boundary");
        assertEq(vestingManager.tgeTimestamp(), tgeEnv, "vestingManager TGE mismatch at boundary");
    }

    // -------------------------------------------------------------------------
    // Guard — TGE_TIMESTAMP in the past
    // -------------------------------------------------------------------------

    function test_run_revertsWhenTgeTimestampInPast() public {
        // Move time past the (fixed) env timestamp so run() sees it in the past.
        vm.warp(tgeEnv + 1);

        vm.expectRevert(bytes("TGE must be in present or future"));
        setTgeScript.run();

        // The guard fires before any external call: nothing was set.
        assertEq(claim.tgeTimestamp(), 0, "claim TGE must remain unset");
        assertFalse(vestingManager.tgeSet(), "vestingManager TGE must remain unset");
    }

    // -------------------------------------------------------------------------
    // Non-atomicity / TGE-desync (open design question)
    // -------------------------------------------------------------------------
    //
    // The script's docstring says it sets TGE "atomically", but run() issues TWO
    // separate calls — claim.setTGE(tge) then vestingManager.setTGE(tge). Under a
    // real `forge script --broadcast`, each call is its OWN signed transaction:
    // if the second transaction reverts, the first has already landed on-chain
    // and is NOT rolled back. The two tests below document both framings.
    //
    // These tests assert the ACTUAL resulting state. They do not claim that
    // state is correct — whether a desynced TGE is acceptable is an open design
    // question for review.

    // Framing 1: run() invoked as a single call (as in this test suite).
    // The second call reverting unwinds the whole run() frame, so the desync is
    // invisible here — this is an artifact of the single-transaction framing,
    // NOT evidence of atomicity on-chain.
    function test_run_secondCallReverts_singleFrameRollsBackFirstCall() public {
        // vestingManager already has a TGE (e.g. a previous partial activation).
        uint256 preExisting = block.timestamp + 1 days;
        vm.prank(broadcaster);
        vestingManager.setTGE(preExisting);

        // vestingManager.setTGE reverts TGEAlreadySet and takes claim.setTGE
        // down with it — but only because run() is one call frame here.
        vm.expectRevert(TGEAlreadySet.selector);
        setTgeScript.run();

        assertEq(claim.tgeTimestamp(), 0, "claim rollback is frame-scoped only");
        assertEq(vestingManager.tgeTimestamp(), preExisting, "pre-existing TGE untouched");
    }

    // Framing 2: broadcast semantics — one transaction per call, as
    // `forge script --broadcast` actually executes them. Failure mode: the
    // broadcast key owns claim but not vestingManager (access-control failure
    // on the second call). Result: claim has TGE set, vestingManager does not.
    function test_broadcastSemantics_secondTxReverts_leavesTgeDesync() public {
        // Ownership of vestingManager is moved back to `deployer`, so the
        // broadcaster owns claim only.
        vm.prank(broadcaster);
        vestingManager.transferOwnership(deployer);
        vm.prank(deployer);
        vestingManager.acceptOwnership();

        uint256 tge = block.timestamp + 7 days;

        // Tx 1 (claim.setTGE): lands.
        vm.prank(broadcaster);
        claim.setTGE(tge);

        // Tx 2 (vestingManager.setTGE): reverts — but tx 1 is already final.
        vm.prank(broadcaster);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, broadcaster));
        vestingManager.setTGE(tge);

        // Actual partial-failure state: TGE live on claim, absent on
        // vestingManager. Documented as-is; not asserted to be "correct".
        assertEq(claim.tgeTimestamp(), tge, "claim TGE is set and final");
        assertFalse(vestingManager.tgeSet(), "vestingManager TGE is NOT set");
        assertEq(vestingManager.tgeTimestamp(), 0, "vestingManager reports no TGE");
    }
}
