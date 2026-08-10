// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {PostDeployChecks} from "../script/PostDeployChecks.s.sol";

import {MTRYToken} from "../src/MTRYToken.sol";
import {PreMTRYToken} from "../src/PreMTRYToken.sol";
import {PreMTRYSale} from "../src/PreMTRYSale.sol";
import {PreMTRYClaim} from "../src/PreMTRYClaim.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {GlobalUnlockController} from "../src/GlobalUnlockController.sol";
import {EcosystemEmissionController} from "../src/EcosystemEmissionController.sol";

// =============================================================================
// DeployHarness
// =============================================================================
//
// Inherits Deploy (for access to internal _wire() and _configureGovernance())
// but deploys contracts inline inside fullDeploy(), using address(this) for
// both nonce prediction and initialOwner. This means:
//   - new X() deploys from address(this) → nonce prediction is correct.
//   - The harness is the initial owner of all contracts.
//   - When _wire() and _configureGovernance() make external calls they come
//     from address(this) (the owner) so onlyOwner checks pass.
//   - Lines in Deploy._wire() and Deploy._configureGovernance() are covered.
//
// Note: _deployContracts is NOT overridden (it is not virtual). Deployment is
// done inline so that the inherited _wire()/_configureGovernance() can be called
// with the correct state already populated.
//
contract DeployHarness is Deploy {
    // Single entry point: deploys all contracts, then calls the inherited
    // _wire() and _configureGovernance() for Deploy.sol line coverage.
    function fullDeploy(
        address _safeGov,
        address _safeGuardian,
        address _safeVeto,
        address _treasury,
        address _liquidity,
        uint256 _unlockGenesis,
        uint256 _ecosystemGenesis,
        uint256 _saleStart,
        uint256 _saleEnd
    ) external {
        // Populate governance state vars (used by _configureGovernance).
        safeGov      = _safeGov;
        safeGuardian = _safeGuardian;
        safeVeto     = _safeVeto;

        // Deploy all 7 contracts with address(this) as nonce-basis and initialOwner.
        address self = address(this);
        address predictedMTRY = vm.computeCreateAddress(self, vm.getNonce(self) + 4);

        unlockController = new GlobalUnlockController(
            predictedMTRY, self, _unlockGenesis, 30 days, 200, 300_000_000e18
        );
        ecosystem = new EcosystemEmissionController(
            predictedMTRY, address(unlockController), self,
            _ecosystemGenesis, 30 days, 1_000_000e18
        );
        claim          = new PreMTRYClaim(self, address(unlockController));
        vestingManager = new VestingManager(
            predictedMTRY, _treasury, address(unlockController), self
        );
        mtry = new MTRYToken(
            _treasury, _liquidity,
            address(claim), address(vestingManager), address(ecosystem)
        );
        require(address(mtry) == predictedMTRY, "MTRY prediction failed");
        preMTRY = new PreMTRYToken(self);
        sale    = new PreMTRYSale(address(preMTRY), _treasury, _saleStart, _saleEnd, self);

        // Wire and configure governance via the inherited Deploy.sol functions.
        // These calls produce coverage on Deploy._wire() and Deploy._configureGovernance().
        _wire();
        _configureGovernance();
    }

    // Expose deployed addresses for the test.
    function getAddresses() external view returns (
        address, address, address, address, address, address, address
    ) {
        return (
            address(mtry), address(preMTRY), address(sale), address(claim),
            address(vestingManager), address(ecosystem), address(unlockController)
        );
    }
}

// =============================================================================
// PostDeployHarness
// =============================================================================
//
// Inherits PostDeployChecks and bypasses _load() by injecting addresses directly.
// Each check function is exposed as an external wrapper so individual assertions
// can be isolated in tests.
//
contract PostDeployHarness is PostDeployChecks {
    function inject(
        address _mtry,
        address _preMTRY,
        address _sale,
        address _claim,
        address _vestingManager,
        address _ecosystem,
        address _unlockController
    ) external {
        mtry             = MTRYToken(_mtry);
        preMTRY          = PreMTRYToken(_preMTRY);
        sale             = PreMTRYSale(_sale);
        claim            = PreMTRYClaim(_claim);
        vestingManager   = VestingManager(_vestingManager);
        ecosystem        = EcosystemEmissionController(_ecosystem);
        unlockController = GlobalUnlockController(_unlockController);
    }

    function checkAllocations() external view { _checkAllocations(); }
    function checkWiring()      external view { _checkWiring();      }
    function checkCaps()        external view { _checkCaps();        }
    function checkOwnership()   external view { _checkOwnership();   }
}

// =============================================================================
// DeployIntegrationTest
// =============================================================================

contract DeployIntegrationTest is Test {
    address constant SAFE_GOV      = address(0xA600);
    address constant SAFE_GUARDIAN = address(0x6AAA);
    address constant SAFE_VETO     = address(0xBE10);
    address constant TREASURY      = address(0xFEE1);
    address constant LIQUIDITY     = address(0xCA1F);

    DeployHarness     internal d;
    PostDeployHarness internal checks;

    // Deployed contract addresses (extracted from harness after fullDeploy).
    address internal addrMtry;
    address internal addrPreMTRY;
    address internal addrSale;
    address internal addrClaim;
    address internal addrVestingManager;
    address internal addrEcosystem;
    address internal addrUnlockController;

    function setUp() public {
        // PreMTRYSale constructor checks block.chainid == 42161.
        vm.chainId(42161);

        uint256 now_ = block.timestamp;

        // Create harness and run the full deploy flow in one call.
        d = new DeployHarness();
        d.fullDeploy(
            SAFE_GOV, SAFE_GUARDIAN, SAFE_VETO,
            TREASURY, LIQUIDITY,
            now_,               // unlockGenesis
            now_,               // ecosystemGenesis
            now_ + 1 hours,     // saleStart
            now_ + 30 days      // saleEnd
        );

        // Extract addresses.
        (
            addrMtry, addrPreMTRY, addrSale, addrClaim,
            addrVestingManager, addrEcosystem, addrUnlockController
        ) = d.getAddresses();

        // Wire PostDeployChecks harness.
        checks = new PostDeployHarness();
        checks.inject(
            addrMtry, addrPreMTRY, addrSale, addrClaim,
            addrVestingManager, addrEcosystem, addrUnlockController
        );

        // Env vars consumed by PostDeployChecks internal functions.
        vm.setEnv("TREASURY_SAFE",  vm.toString(TREASURY));
        vm.setEnv("LIQUIDITY_SAFE", vm.toString(LIQUIDITY));
        vm.setEnv("SAFE_GOV",        vm.toString(SAFE_GOV));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(d)));
    }

    // -------------------------------------------------------------------------
    // Allocation checks
    // -------------------------------------------------------------------------

    function test_postDeploy_allocations_sumTo300M() public view {
        // Exercises PostDeployChecks._checkAllocations()
        checks.checkAllocations();
    }

    function test_postDeploy_allocations_individual() public view {
        MTRYToken mtry = MTRYToken(addrMtry);
        assertEq(mtry.totalSupply(), 300_000_000e18);
        assertEq(mtry.balanceOf(TREASURY),             75_000_000e18, "treasury 75M");
        assertEq(mtry.balanceOf(LIQUIDITY),            45_000_000e18, "liquidity 45M");
        assertEq(mtry.balanceOf(addrClaim),            40_000_000e18, "claim 40M");
        assertEq(mtry.balanceOf(addrVestingManager),  111_000_000e18, "vestingManager 111M");
        assertEq(mtry.balanceOf(addrEcosystem),        29_000_000e18, "ecosystem 29M");
    }

    // -------------------------------------------------------------------------
    // Wiring checks — A-3 assertions (the specific post-remediation checks)
    // -------------------------------------------------------------------------

    // A-3 check 1: preMTRY.saleContractFinalized()
    function test_postDeploy_saleContractFinalized() public view {
        assertTrue(
            PreMTRYToken(addrPreMTRY).saleContractFinalized(),
            "preMTRY saleContract not finalized"
        );
    }

    // A-3 check 2: preMTRY.claimContractFinalized()
    function test_postDeploy_claimContractFinalized() public view {
        assertTrue(
            PreMTRYToken(addrPreMTRY).claimContractFinalized(),
            "preMTRY claimContract not finalized"
        );
    }

    // A-3 check 3: claim is a protectedSource — prevents shared-lane starvation
    function test_postDeploy_claimIsProtectedSource() public view {
        assertTrue(
            GlobalUnlockController(addrUnlockController).protectedSource(addrClaim),
            "claim not protectedSource - user claims can be starved by shared-lane sources"
        );
    }

    // Full _checkWiring() pass (covers all wiring assertions in one call).
    function test_postDeploy_checkWiring_passes() public view {
        checks.checkWiring();
    }

    // -------------------------------------------------------------------------
    // Bucket cap checks
    // -------------------------------------------------------------------------

    function test_postDeploy_bucketCaps_correct() public view {
        // Exercises PostDeployChecks._checkCaps()
        checks.checkCaps();
    }

    function test_postDeploy_bucketCaps_individual() public view {
        VestingManager vm_ = VestingManager(addrVestingManager);
        assertEq(vm_.maxBucketAllocation(VestingManager.BucketType.Team),             51_000_000e18, "team cap");
        assertEq(vm_.maxBucketAllocation(VestingManager.BucketType.StrategicStandard),27_000_000e18, "strat std");
        assertEq(vm_.maxBucketAllocation(VestingManager.BucketType.StrategicExtended),18_000_000e18, "strat ext");
        assertEq(vm_.maxBucketAllocation(VestingManager.BucketType.AdvisorsStandard), 10_500_000e18, "adv std");
        assertEq(vm_.maxBucketAllocation(VestingManager.BucketType.AdvisorsShort),     4_500_000e18, "adv short");
        // Sum must equal the VestingManager MTRY allocation (111M)
        uint256 capSum = 51_000_000e18 + 27_000_000e18 + 18_000_000e18 + 10_500_000e18 + 4_500_000e18;
        assertEq(capSum, uint256(111_000_000e18), "caps must sum to 111M");
    }

    // -------------------------------------------------------------------------
    // Wiring detail checks
    // -------------------------------------------------------------------------

    function test_postDeploy_claimInitialized() public view {
        assertTrue(PreMTRYClaim(addrClaim).initialized(), "claim not initialized");
    }

    function test_postDeploy_unlockControllerHasVestingManager() public view {
        assertEq(
            GlobalUnlockController(addrUnlockController).vestingManager(),
            addrVestingManager,
            "unlock vestingManager mismatch"
        );
    }

    function test_postDeploy_ecosystemAuthorized() public view {
        assertTrue(
            GlobalUnlockController(addrUnlockController).authorizedSource(addrEcosystem),
            "ecosystem not authorized"
        );
    }

    function test_postDeploy_claimAuthorized() public view {
        assertTrue(
            GlobalUnlockController(addrUnlockController).authorizedSource(addrClaim),
            "claim not authorized"
        );
    }

    // -------------------------------------------------------------------------
    // Ownership — pre-acceptance (Deploy transfers to SAFE_GOV via Ownable2Step)
    // -------------------------------------------------------------------------

    function test_postDeploy_preAcceptance_pendingOwnerIsSafeGov() public {
        vm.setEnv("OWNERSHIP_PHASE", "pre-acceptance");
        checks.checkOwnership();
    }

    function test_postDeploy_preAcceptance_ownerIsStillDeployer() public view {
        address deployer = address(d); // harness is the initial owner
        assertEq(GlobalUnlockController(addrUnlockController).owner(),   deployer, "unlock owner");
        assertEq(VestingManager(addrVestingManager).owner(),             deployer, "vestingManager owner");
        assertEq(EcosystemEmissionController(addrEcosystem).owner(),     deployer, "ecosystem owner");
        assertEq(PreMTRYClaim(addrClaim).owner(),                        deployer, "claim owner");
        assertEq(PreMTRYToken(addrPreMTRY).owner(),                      deployer, "preMTRY owner");
        assertEq(PreMTRYSale(addrSale).owner(),                          deployer, "sale owner");
    }

    function test_postDeploy_preAcceptance_pendingOwnerIsGov() public view {
        assertEq(GlobalUnlockController(addrUnlockController).pendingOwner(), SAFE_GOV, "unlock pending");
        assertEq(VestingManager(addrVestingManager).pendingOwner(),           SAFE_GOV, "vesting pending");
        assertEq(EcosystemEmissionController(addrEcosystem).pendingOwner(),   SAFE_GOV, "ecosystem pending");
        assertEq(PreMTRYClaim(addrClaim).pendingOwner(),                      SAFE_GOV, "claim pending");
        assertEq(PreMTRYToken(addrPreMTRY).pendingOwner(),                    SAFE_GOV, "preMTRY pending");
        assertEq(PreMTRYSale(addrSale).pendingOwner(),                        SAFE_GOV, "sale pending");
    }

    // -------------------------------------------------------------------------
    // Ownership — post-acceptance (SAFE_GOV calls acceptOwnership on all 6)
    // -------------------------------------------------------------------------

    function test_postDeploy_postAcceptance_ownerIsSafeGov() public {
        // SAFE_GOV accepts ownership on all Ownable2Step contracts.
        vm.startPrank(SAFE_GOV);
        GlobalUnlockController(addrUnlockController).acceptOwnership();
        VestingManager(addrVestingManager).acceptOwnership();
        EcosystemEmissionController(addrEcosystem).acceptOwnership();
        PreMTRYClaim(addrClaim).acceptOwnership();
        PreMTRYToken(addrPreMTRY).acceptOwnership();
        PreMTRYSale(addrSale).acceptOwnership();
        vm.stopPrank();

        // Set env var for post-acceptance phase check.
        vm.setEnv("OWNERSHIP_PHASE",   "post-acceptance");
        vm.setEnv("DEPLOYER_ADDRESS",  vm.toString(address(d)));

        checks.checkOwnership();

        // Deployer (harness) must no longer be owner.
        assertTrue(GlobalUnlockController(addrUnlockController).owner() != address(d), "unlock still deployer");
    }

    // -------------------------------------------------------------------------
    // Guardian and veto assignment
    // -------------------------------------------------------------------------

    function test_postDeploy_guardianSet() public view {
        assertEq(GlobalUnlockController(addrUnlockController).guardian(), SAFE_GUARDIAN, "unlock guardian");
        assertEq(VestingManager(addrVestingManager).guardian(),           SAFE_GUARDIAN, "vesting guardian");
        assertEq(EcosystemEmissionController(addrEcosystem).guardian(),   SAFE_GUARDIAN, "ecosystem guardian");
        assertEq(PreMTRYClaim(addrClaim).guardian(),                      SAFE_GUARDIAN, "claim guardian");
        assertEq(PreMTRYSale(addrSale).guardian(),                        SAFE_GUARDIAN, "sale guardian");
    }

    function test_postDeploy_vetoSet() public view {
        assertEq(GlobalUnlockController(addrUnlockController).veto(), SAFE_VETO, "unlock veto");
        assertEq(VestingManager(addrVestingManager).veto(),           SAFE_VETO, "vesting veto");
        assertEq(EcosystemEmissionController(addrEcosystem).veto(),   SAFE_VETO, "ecosystem veto");
        assertEq(PreMTRYClaim(addrClaim).veto(),                      SAFE_VETO, "claim veto");
    }
}
