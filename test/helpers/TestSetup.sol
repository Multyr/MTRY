// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MTRYToken} from "../../src/MTRYToken.sol";
import {PreMTRYToken} from "../../src/PreMTRYToken.sol";
import {PreMTRYSale} from "../../src/PreMTRYSale.sol";
import {PreMTRYClaim} from "../../src/PreMTRYClaim.sol";
import {VestingManager} from "../../src/VestingManager.sol";
import {VestingWalletLinear} from "../../src/VestingWalletLinear.sol";
import {GlobalUnlockController} from "../../src/GlobalUnlockController.sol";
import {EcosystemEmissionController} from "../../src/EcosystemEmissionController.sol";

/// @dev Mock USDC with 6 decimals (placed at OFFICIAL_USDC via vm.etch in unit tests).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Random 18-decimal mock for recoverToken tests.
contract MockToken18 is ERC20 {
    constructor() ERC20("Mock18", "M18") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Shared test setup for the MULTYR token stack.
abstract contract TestSetup is Test {
    // Contracts
    MTRYToken public mtry;
    PreMTRYToken public preMTRY;
    PreMTRYSale public sale;
    PreMTRYClaim public claim;
    VestingManager public vestingManager;
    GlobalUnlockController public unlockController;
    EcosystemEmissionController public ecosystem;
    MockUSDC public usdc;

    // Addresses
    address public deployer = address(0xDEAD);
    address public safeGov = address(0xF00D);
    address public safeGuardian = address(0x6AA6);
    address public safeVeto = address(0xBE10);
    address public treasurySafe = address(0xBEEF);
    address public liquiditySafe = address(0xCAFE);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA401);

    // Canonical beneficiaries used by integration tests.
    address public teamBeneficiary = address(0x1111);
    address public advisorBeneficiary = address(0x2222);
    address public strategicBeneficiary = address(0x3333);

    /// @dev Official Arbitrum USDC address (used for vm.etch in unit tests).
    address public constant OFFICIAL_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Time / genesis constants
    uint256 public constant SALE_DURATION = 30 days;
    uint256 public constant PERIOD_DURATION = 30 days;
    uint256 public constant EPOCH_DURATION = 30 days;
    uint256 public saleStart;
    uint256 public saleEnd;
    uint256 public unlockGenesis;
    uint256 public ecosystemGenesis;

    // Bucket caps (111M total — matches MTRYToken.VESTING_ALLOCATION)
    uint256 public constant TEAM_CAP = 51_000_000e18;
    uint256 public constant STRATEGIC_STANDARD_CAP = 27_000_000e18;
    uint256 public constant STRATEGIC_EXTENDED_CAP = 18_000_000e18;
    uint256 public constant ADVISORS_STANDARD_CAP = 10_500_000e18;
    uint256 public constant ADVISORS_SHORT_CAP = 4_500_000e18;

    /// @dev Deploy the complete stack. Genesis = block.timestamp so unlocks are live immediately.
    function _deployAllCorrectly() internal {
        // Sale window defaults to fixed, tiny absolute timestamps (NOT block.timestamp-relative
        // — Foundry's default block.timestamp is 1, so subtracting from "now" would underflow).
        // MULTYR-1 requires claim.setTGE() to be called with tgeTimestamp >= saleEnd, and most
        // tests set TGE around "now" without caring about sale timing at all; pinning the sale
        // window at the very start of time means any realistic TGE timestamp already satisfies
        // the invariant. Tests that specifically exercise a live sale window (sale.buy()) already
        // warp explicitly to saleStart/saleEnd — that still works identically since those
        // references are always relative to these state vars, never to an absolute clock.
        saleStart = 0;
        saleEnd = 1;
        unlockGenesis = block.timestamp;
        ecosystemGenesis = block.timestamp;

        vm.startPrank(deployer);

        // Predict MTRY address: nonce+4 (unlockController, ecosystem, claim, vestingManager, then MTRY)
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedMTRY = vm.computeCreateAddress(deployer, currentNonce + 4);

        // GlobalUnlockController
        unlockController = new GlobalUnlockController(
            predictedMTRY,
            deployer,
            unlockGenesis,
            PERIOD_DURATION,
            200,                        // 2% cap bps
            300_000_000e18              // reference supply
        );

        // EcosystemEmissionController
        ecosystem = new EcosystemEmissionController(
            predictedMTRY,
            address(unlockController),
            deployer,
            ecosystemGenesis,
            EPOCH_DURATION,
            1_000_000e18                // initial max emission per epoch
        );

        // PreMTRYClaim (uninitialized)
        claim = new PreMTRYClaim(deployer, address(unlockController));

        // VestingManager
        vestingManager = new VestingManager(
            predictedMTRY,
            treasurySafe,
            address(unlockController),
            deployer
        );

        // MTRYToken — mints to 5 recipients (75+45+40+111+29 = 300M)
        mtry = new MTRYToken(
            treasurySafe,
            liquiditySafe,
            address(claim),
            address(vestingManager),
            address(ecosystem)
        );
        require(address(mtry) == predictedMTRY, "MTRY address prediction failed");

        // PreMTRYToken
        preMTRY = new PreMTRYToken(deployer);

        vm.stopPrank();

        // Place MockUSDC code at OFFICIAL_USDC for unit tests, enable Arbitrum chain ID
        MockUSDC mockImpl = new MockUSDC();
        vm.etch(OFFICIAL_USDC, address(mockImpl).code);
        usdc = MockUSDC(OFFICIAL_USDC);

        vm.chainId(42161);
        vm.prank(deployer);
        sale = new PreMTRYSale(
            address(preMTRY),
            treasurySafe,
            saleStart,
            saleEnd,
            deployer
        );

        // Wire
        vm.startPrank(deployer);
        claim.initialize(address(mtry), address(preMTRY), address(sale));
        preMTRY.setSaleContract(address(sale));
        preMTRY.setClaimContract(address(claim));

        // Register vesting manager and authorize non-wallet sources
        unlockController.setVestingManager(address(vestingManager));
        unlockController.setAuthorizedSource(address(ecosystem), true);
        unlockController.setAuthorizedSource(address(claim), true);
        // PreMTRYClaim is a protected source: reserved quota of the single cap, no inflation.
        unlockController.setProtectedSource(address(claim), true);

        // Set bucket caps (sum = 111M)
        vestingManager.setBucketCap(VestingManager.BucketType.Team, TEAM_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicStandard, STRATEGIC_STANDARD_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicExtended, STRATEGIC_EXTENDED_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsStandard, ADVISORS_STANDARD_CAP);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsShort, ADVISORS_SHORT_CAP);

        // Whitelist test buyers
        sale.setWhitelist(alice, true);
        sale.setWhitelist(bob, true);
        sale.setWhitelist(carol, true);
        // Whitelist the claim contract so it can act as sender/receiver in buy() (e.g. future buyAndLock)
        sale.setWhitelist(address(claim), true);

        // Configure triad governance roles
        sale.setGuardian(safeGuardian);
        claim.setGuardian(safeGuardian);
        vestingManager.setGuardian(safeGuardian);
        unlockController.setGuardian(safeGuardian);
        ecosystem.setGuardian(safeGuardian);

        claim.setVeto(safeVeto);
        vestingManager.setVeto(safeVeto);
        unlockController.setVeto(safeVeto);
        ecosystem.setVeto(safeVeto);

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Sale helpers
    // -------------------------------------------------------------------------
    function _fundAlice(uint256 usdcAmount) internal {
        usdc.mint(alice, usdcAmount);
        vm.prank(alice);
        usdc.approve(address(sale), usdcAmount);
    }

    function _fundBob(uint256 usdcAmount) internal {
        usdc.mint(bob, usdcAmount);
        vm.prank(bob);
        usdc.approve(address(sale), usdcAmount);
    }

    function _fundCarol(uint256 usdcAmount) internal {
        usdc.mint(carol, usdcAmount);
        vm.prank(carol);
        usdc.approve(address(sale), usdcAmount);
    }

    function _aliceBuys(uint256 usdcAmount) internal {
        _fundAlice(usdcAmount);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(usdcAmount, alice);
    }

    function _bobBuys(uint256 usdcAmount) internal {
        _fundBob(usdcAmount);
        vm.warp(saleStart);
        vm.prank(bob);
        sale.buy(usdcAmount, bob);
    }

    // -------------------------------------------------------------------------
    // TGE helper
    // -------------------------------------------------------------------------
    function _setTGE(uint256 tge) internal {
        // MULTYR-1: claim.setTGE() requires tgeTimestamp >= saleEnd. Callers of this helper
        // generally want "TGE now-ish" and don't care about exact sale timing, so clamp forward
        // rather than requiring every call site to warp first.
        if (tge < saleEnd) tge = saleEnd;
        vm.startPrank(deployer);
        claim.setTGE(tge);
        vestingManager.setTGE(tge);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Vesting creation helpers
    // -------------------------------------------------------------------------
    function _createTgeVesting(
        VestingManager.BucketType bucket,
        address beneficiary,
        uint256 allocation,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) internal returns (address wallet) {
        vm.prank(deployer);
        wallet = vestingManager.createVesting(
            bucket,
            beneficiary,
            allocation,
            cliff,
            duration,
            revocable,
            VestingManager.VestingStartMode.TGE
        );
    }

    function _createGrantVesting(
        VestingManager.BucketType bucket,
        address beneficiary,
        uint256 allocation,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) internal returns (address wallet) {
        vm.prank(deployer);
        wallet = vestingManager.createVesting(
            bucket,
            beneficiary,
            allocation,
            cliff,
            duration,
            revocable,
            VestingManager.VestingStartMode.GRANT_DATE
        );
    }
}
