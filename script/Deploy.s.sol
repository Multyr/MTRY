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
 * @title Deploy
 * @notice Deploys the complete MULTYR token stack on Arbitrum with triad governance.
 *
 * Required env vars:
 *   SAFE_GOV, SAFE_GUARDIAN, SAFE_VETO
 *   TREASURY_SAFE, LIQUIDITY_SAFE
 *   SALE_START, SALE_END
 *   UNLOCK_GENESIS, ECOSYSTEM_GENESIS
 */
contract Deploy is Script {
    GlobalUnlockController public unlockController;
    EcosystemEmissionController public ecosystem;
    PreMTRYClaim public claim;
    VestingManager public vestingManager;
    MTRYToken public mtry;
    PreMTRYToken public preMTRY;
    PreMTRYSale public sale;

    uint256 public constant TEAM_CAP = 51_000_000e18;
    uint256 public constant STRATEGIC_STANDARD_CAP = 27_000_000e18;
    uint256 public constant STRATEGIC_EXTENDED_CAP = 18_000_000e18;
    uint256 public constant ADVISORS_STANDARD_CAP = 10_500_000e18;
    uint256 public constant ADVISORS_SHORT_CAP = 4_500_000e18;

    // Governance triad — loaded in run(), stored as state to avoid stack-too-deep.
    address safeGov;
    address safeGuardian;
    address safeVeto;

    function run() external {
        safeGov = vm.envAddress("SAFE_GOV");
        safeGuardian = vm.envAddress("SAFE_GUARDIAN");
        safeVeto = vm.envAddress("SAFE_VETO");
        address treasurySafe = vm.envAddress("TREASURY_SAFE");
        address liquiditySafe = vm.envAddress("LIQUIDITY_SAFE");

        vm.startBroadcast();

        _deployContracts(treasurySafe, liquiditySafe);
        _wire();
        _configureGovernance();

        vm.stopBroadcast();

        console.log("=== Deployment complete ===");
        console.log("SAFE_GOV must call acceptOwnership() on all 5 Ownable contracts.");
    }

    function _deployContracts(address treasurySafe, address liquiditySafe) internal {
        address predictedMTRY = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 4);

        uint256 unlockGenesis    = vm.envUint("UNLOCK_GENESIS");
        uint256 ecosystemGenesis = vm.envUint("ECOSYSTEM_GENESIS");
        uint256 now_             = block.timestamp;

        // Range-validate genesis params: must be within 30 days past → 365 days future.
        // A value outside this window almost certainly indicates a typo in the env file; since
        // both params are immutable there is no recovery path post-deploy.
        require(
            unlockGenesis >= now_ - 30 days && unlockGenesis <= now_ + 365 days,
            "UNLOCK_GENESIS out of range [now-30d, now+365d]"
        );
        require(
            ecosystemGenesis >= now_ - 30 days && ecosystemGenesis <= now_ + 365 days,
            "ECOSYSTEM_GENESIS out of range [now-30d, now+365d]"
        );

        unlockController = new GlobalUnlockController(
            predictedMTRY, msg.sender, unlockGenesis,
            30 days, 200, 300_000_000e18
        );

        ecosystem = new EcosystemEmissionController(
            predictedMTRY, address(unlockController), msg.sender,
            ecosystemGenesis, 30 days, 1_000_000e18
        );

        claim = new PreMTRYClaim(msg.sender, address(unlockController));

        vestingManager = new VestingManager(
            predictedMTRY, treasurySafe, address(unlockController), msg.sender
        );

        mtry = new MTRYToken(treasurySafe, liquiditySafe, address(claim), address(vestingManager), address(ecosystem));
        require(address(mtry) == predictedMTRY, "MTRY prediction failed");

        preMTRY = new PreMTRYToken(msg.sender);
        sale = new PreMTRYSale(
            address(preMTRY), treasurySafe,
            vm.envUint("SALE_START"), vm.envUint("SALE_END"), msg.sender
        );
    }

    function _wire() internal {
        claim.initialize(address(mtry), address(preMTRY), address(sale));
        preMTRY.setSaleContract(address(sale));
        preMTRY.finalizeSaleContract();
        preMTRY.setClaimContract(address(claim));
        preMTRY.finalizeClaimContract();

        unlockController.setVestingManager(address(vestingManager));
        unlockController.setAuthorizedSource(address(ecosystem), true);
        unlockController.setAuthorizedSource(address(claim), true);
        unlockController.setProtectedSource(address(claim), true);

        // Whitelist the claim contract as an approved sale participant so that it can
        // act as both sender and receiver in buy() for any future buyAndLock convenience path.
        sale.setWhitelist(address(claim), true);

        vestingManager.setBucketCap(VestingManager.BucketType.Team, TEAM_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicStandard, STRATEGIC_STANDARD_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicExtended, STRATEGIC_EXTENDED_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsStandard, ADVISORS_STANDARD_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsShort, ADVISORS_SHORT_CAP);
    }

    function _configureGovernance() internal {
        // Guardian + Veto must be set BEFORE ownership transfer (deployer is still owner here).
        sale.setGuardian(safeGuardian);
        claim.setGuardian(safeGuardian);
        vestingManager.setGuardian(safeGuardian);
        unlockController.setGuardian(safeGuardian);
        ecosystem.setGuardian(safeGuardian);

        claim.setVeto(safeVeto);
        vestingManager.setVeto(safeVeto);
        unlockController.setVeto(safeVeto);
        ecosystem.setVeto(safeVeto);
        // sale has no veto — no burn / no pending cap

        // Transfer ownership to SAFE_GOV (step 1 of Ownable2Step).
        unlockController.transferOwnership(safeGov);
        vestingManager.transferOwnership(safeGov);
        ecosystem.transferOwnership(safeGov);
        claim.transferOwnership(safeGov);
        preMTRY.transferOwnership(safeGov);
        sale.transferOwnership(safeGov);
    }
}
