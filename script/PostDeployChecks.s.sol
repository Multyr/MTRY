// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {MTRYToken} from "../src/MTRYToken.sol";
import {PreMTRYToken} from "../src/PreMTRYToken.sol";
import {PreMTRYSale} from "../src/PreMTRYSale.sol";
import {PreMTRYClaim} from "../src/PreMTRYClaim.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {GlobalUnlockController} from "../src/GlobalUnlockController.sol";
import {EcosystemEmissionController} from "../src/EcosystemEmissionController.sol";

/**
 * @title PostDeployChecks
 * @notice Verifies deployment wiring and allocations.
 *         Set OWNERSHIP_PHASE env var to:
 *           - "pre-acceptance": checks pendingOwner == safeGov (before acceptOwnership)
 *           - "post-acceptance": checks owner() == safeGov
 *
 * Required env vars:
 *   SAFE_GOV, SAFE_GUARDIAN, SAFE_VETO, TREASURY_SAFE, LIQUIDITY_SAFE, DEPLOYER_ADDRESS
 *   MTRY_ADDRESS, PREMTRY_ADDRESS, SALE_ADDRESS, CLAIM_ADDRESS
 *   VESTING_MANAGER_ADDRESS, ECOSYSTEM_ADDRESS, UNLOCK_CONTROLLER_ADDRESS
 *   OWNERSHIP_PHASE (pre-acceptance | post-acceptance)
 */
contract PostDeployChecks is Script {
    MTRYToken mtry;
    PreMTRYToken preMTRY;
    PreMTRYSale sale;
    PreMTRYClaim claim;
    VestingManager vestingManager;
    EcosystemEmissionController ecosystem;
    GlobalUnlockController unlockController;

    function run() external {
        _load();
        _checkAllocations();
        _checkWiring();
        _checkCaps();
        _checkOwnership();
        console.log("=== ALL CHECKS PASSED ===");
    }

    function _load() internal {
        mtry = MTRYToken(vm.envAddress("MTRY_ADDRESS"));
        preMTRY = PreMTRYToken(vm.envAddress("PREMTRY_ADDRESS"));
        sale = PreMTRYSale(vm.envAddress("SALE_ADDRESS"));
        claim = PreMTRYClaim(vm.envAddress("CLAIM_ADDRESS"));
        vestingManager = VestingManager(vm.envAddress("VESTING_MANAGER_ADDRESS"));
        ecosystem = EcosystemEmissionController(vm.envAddress("ECOSYSTEM_ADDRESS"));
        unlockController = GlobalUnlockController(vm.envAddress("UNLOCK_CONTROLLER_ADDRESS"));
    }

    function _checkAllocations() internal view {
        require(mtry.totalSupply() == 300_000_000e18, "totalSupply != 300M");
        require(mtry.balanceOf(vm.envAddress("TREASURY_SAFE")) == 75_000_000e18, "treasury != 75M");
        require(mtry.balanceOf(vm.envAddress("LIQUIDITY_SAFE")) == 45_000_000e18, "liquidity != 45M");
        require(mtry.balanceOf(address(claim)) == 40_000_000e18, "claim != 40M");
        require(mtry.balanceOf(address(vestingManager)) == 111_000_000e18, "vestingManager != 111M");
        require(mtry.balanceOf(address(ecosystem)) == 29_000_000e18, "ecosystem != 29M");
        console.log("[PASS] Allocations 75+45+40+111+29 = 300M");
    }

    function _checkWiring() internal view {
        require(preMTRY.saleContract() == address(sale), "saleContract mismatch");
        require(preMTRY.claimContract() == address(claim), "claimContract mismatch");
        require(preMTRY.saleContractFinalized(), "preMTRY saleContract not finalized");
        require(preMTRY.claimContractFinalized(), "preMTRY claimContract not finalized");
        require(claim.initialized(), "claim not initialized");
        require(claim.unlockController() == address(unlockController), "claim unlock mismatch");
        require(unlockController.vestingManager() == address(vestingManager), "unlock vestingManager mismatch");
        require(unlockController.authorizedSource(address(ecosystem)), "ecosystem not authorized");
        require(unlockController.authorizedSource(address(claim)), "claim not authorized");
        require(
            unlockController.protectedSource(address(claim)),
            "claim not protectedSource - user claims can be starved by shared-lane sources"
        );

        // M-5: assert both immutable genesis params are within a sane window.
        // A value outside [now-30d, now+365d] almost certainly indicates a deploy-time typo;
        // both params are immutable with no recovery path post-deploy.
        uint256 unlockGenesis    = unlockController.genesisTimestamp();
        uint256 ecosystemGenesis = ecosystem.genesis();
        require(unlockGenesis    > 0,                              "unlock genesis not set");
        require(ecosystemGenesis > 0,                              "ecosystem genesis not set");
        require(unlockGenesis    <= block.timestamp + 365 days,    "unlock genesis too far in future");
        require(ecosystemGenesis <= block.timestamp + 365 days,    "ecosystem genesis too far in future");

        console.log("[PASS] Wiring consistent");
    }

    function _checkCaps() internal view {
        require(
            vestingManager.maxBucketAllocation(VestingManager.BucketType.Team) == 51_000_000e18,
            "team cap"
        );
        require(
            vestingManager.maxBucketAllocation(VestingManager.BucketType.StrategicStandard) == 27_000_000e18,
            "strat std cap"
        );
        require(
            vestingManager.maxBucketAllocation(VestingManager.BucketType.StrategicExtended) == 18_000_000e18,
            "strat ext cap"
        );
        require(
            vestingManager.maxBucketAllocation(VestingManager.BucketType.AdvisorsStandard) == 10_500_000e18,
            "adv std cap"
        );
        require(
            vestingManager.maxBucketAllocation(VestingManager.BucketType.AdvisorsShort) == 4_500_000e18,
            "adv short cap"
        );
        console.log("[PASS] Bucket caps correct (111M total)");
    }

    function _checkOwnership() internal view {
        string memory phase = vm.envString("OWNERSHIP_PHASE");
        address safeGov = vm.envAddress("SAFE_GOV");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        if (keccak256(bytes(phase)) == keccak256("pre-acceptance")) {
            require(unlockController.pendingOwner() == safeGov, "unlock pending mismatch");
            require(vestingManager.pendingOwner() == safeGov, "vesting pending mismatch");
            require(ecosystem.pendingOwner() == safeGov, "ecosystem pending mismatch");
            require(claim.pendingOwner() == safeGov, "claim pending mismatch");
            require(preMTRY.pendingOwner() == safeGov, "preMTRY pending mismatch");
            require(sale.pendingOwner() == safeGov, "sale pending mismatch");
            require(unlockController.owner() == deployer, "unlock owner still deployer");
            console.log("[PASS] Pre-acceptance ownership state");
        } else if (keccak256(bytes(phase)) == keccak256("post-acceptance")) {
            require(unlockController.owner() == safeGov, "unlock owner");
            require(vestingManager.owner() == safeGov, "vestingManager owner");
            require(ecosystem.owner() == safeGov, "ecosystem owner");
            require(claim.owner() == safeGov, "claim owner");
            require(preMTRY.owner() == safeGov, "preMTRY owner");
            require(sale.owner() == safeGov, "sale owner");
            require(unlockController.owner() != deployer, "unlock still deployer");
            console.log("[PASS] Post-acceptance ownership state");
        } else {
            revert("OWNERSHIP_PHASE must be pre-acceptance or post-acceptance");
        }
    }
}
