// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {PreMTRYClaim} from "../src/PreMTRYClaim.sol";
import {VestingManager} from "../src/VestingManager.sol";

/**
 * @title SetTGE
 * @notice Sets TGE timestamp on PreMTRYClaim and VestingManager in two SEPARATE
 *         transactions (NOT atomic — if the second reverts, the first is already final;
 *         see SetTGEIntegration.t.sol desync tests).
 *         GlobalUnlockController.genesisTimestamp and EcosystemEmissionController.genesis
 *         are IMMUTABLE — set at constructor. No longer toggled here.
 *
 * Required env vars:
 *   TGE_TIMESTAMP, PREMTRY_CLAIM_ADDRESS, VESTING_MANAGER_ADDRESS
 */
contract SetTGE is Script {
    function run() external {
        uint256 tge = vm.envUint("TGE_TIMESTAMP");
        require(tge >= block.timestamp, "TGE must be in present or future");

        PreMTRYClaim claim = PreMTRYClaim(vm.envAddress("PREMTRY_CLAIM_ADDRESS"));
        VestingManager vestingManager = VestingManager(vm.envAddress("VESTING_MANAGER_ADDRESS"));

        vm.startBroadcast();

        claim.setTGE(tge);
        console.log("PreMTRYClaim TGE set:", tge);

        vestingManager.setTGE(tge);
        console.log("VestingManager TGE set:", tge);

        vm.stopBroadcast();

        console.log("=== TGE activation complete ===");
    }
}
