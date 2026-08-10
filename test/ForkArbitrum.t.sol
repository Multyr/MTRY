// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MTRYToken} from "../src/MTRYToken.sol";
import {PreMTRYToken} from "../src/PreMTRYToken.sol";
import {PreMTRYSale} from "../src/PreMTRYSale.sol";
import {PreMTRYClaim} from "../src/PreMTRYClaim.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {GlobalUnlockController} from "../src/GlobalUnlockController.sol";
import {EcosystemEmissionController} from "../src/EcosystemEmissionController.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";

/// @title ForkArbitrumTest — fork test against real Arbitrum USDC.
/// @dev Requires ARBITRUM_RPC_URL env var. Skipped when not available.
contract ForkArbitrumTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address deployer = address(0xDEAD);
    address safeGov = address(0xF00D);
    address safeGuardian = address(0x6AA6);
    address safeVeto = address(0xBE10);
    address treasurySafe = address(0xBEEF);
    address liquiditySafe = address(0xCAFE);
    address alice = address(0xA11CE);

    MTRYToken mtry;
    PreMTRYToken preMTRY;
    PreMTRYSale sale;
    PreMTRYClaim claim;
    VestingManager vestingManager;
    GlobalUnlockController unlockController;
    EcosystemEmissionController ecosystem;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);
    }

    modifier onlyFork() {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        _;
    }

    function _deployAll() internal {
        uint256 saleStart = block.timestamp + 1 hours;
        uint256 saleEnd = saleStart + 30 days;
        uint256 unlockGenesis = block.timestamp;
        uint256 ecosystemGenesis = block.timestamp;

        vm.startPrank(deployer);

        uint64 currentNonce = vm.getNonce(deployer);
        address predictedMTRY = vm.computeCreateAddress(deployer, currentNonce + 4);

        unlockController = new GlobalUnlockController(
            predictedMTRY, deployer, unlockGenesis, 30 days, 200, 300_000_000e18
        );
        ecosystem = new EcosystemEmissionController(
            predictedMTRY, address(unlockController), deployer, ecosystemGenesis, 30 days, 1_000_000e18
        );
        claim = new PreMTRYClaim(deployer, address(unlockController));
        vestingManager = new VestingManager(
            predictedMTRY, treasurySafe, address(unlockController), deployer
        );

        mtry = new MTRYToken(
            treasurySafe, liquiditySafe, address(claim),
            address(vestingManager), address(ecosystem)
        );
        require(address(mtry) == predictedMTRY, "MTRY prediction failed");

        preMTRY = new PreMTRYToken(deployer);
        sale = new PreMTRYSale(address(preMTRY), treasurySafe, saleStart, saleEnd, deployer);

        claim.initialize(address(mtry), address(preMTRY), address(sale));
        preMTRY.setSaleContract(address(sale));
        preMTRY.setClaimContract(address(claim));

        unlockController.setVestingManager(address(vestingManager));
        unlockController.setAuthorizedSource(address(ecosystem), true);
        unlockController.setAuthorizedSource(address(claim), true);
        unlockController.setProtectedSource(address(claim), true);

        vestingManager.setBucketCap(VestingManager.BucketType.Team, 51_000_000e18);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicStandard, 27_000_000e18);
        vestingManager.setBucketCap(VestingManager.BucketType.StrategicExtended, 18_000_000e18);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsStandard, 10_500_000e18);
        vestingManager.setBucketCap(VestingManager.BucketType.AdvisorsShort, 4_500_000e18);

        vm.stopPrank();
    }

    function test_chainIdIs42161() public onlyFork {
        assertEq(block.chainid, 42161);
    }

    function test_realUSDCDecimals() public onlyFork {
        assertEq(IERC20Metadata(USDC).decimals(), 6);
    }

    function test_realUSDCCodeExists() public onlyFork {
        uint256 codeSize;
        address usdc_ = USDC;
        assembly { codeSize := extcodesize(usdc_) }
        assertGt(codeSize, 0);
    }

    function test_deployWithRealUSDC() public onlyFork {
        _deployAll();
        assertEq(mtry.totalSupply(), 300_000_000e18);
        assertEq(mtry.balanceOf(address(claim)), 40_000_000e18);
        assertEq(mtry.balanceOf(address(vestingManager)), 111_000_000e18);
        assertEq(mtry.balanceOf(address(ecosystem)), 29_000_000e18);
        assertTrue(claim.initialized());
        assertEq(unlockController.vestingManager(), address(vestingManager));
    }

    function test_saleUsesOfficialUSDC() public onlyFork {
        _deployAll();
        assertEq(address(sale.paymentToken()), USDC);
        assertEq(address(sale.paymentToken()), sale.OFFICIAL_USDC());
    }

    function test_buyWithRealUSDC() public onlyFork {
        _deployAll();
        uint256 buyAmount = 80_000;
        deal(USDC, alice, buyAmount);
        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(sale), buyAmount);
        sale.buy(buyAmount, alice);
        vm.stopPrank();

        assertEq(preMTRY.balanceOf(alice), 1e18);
        assertEq(IERC20(USDC).balanceOf(treasurySafe), buyAmount);
    }

    function test_grantDateVestingOnFork() public onlyFork {
        _deployAll();
        vm.prank(deployer);
        address wallet = vestingManager.createVesting(
            VestingManager.BucketType.Team,
            alice, 1_000e18, 365 days, 1095 days, false,
            VestingManager.VestingStartMode.GRANT_DATE
        );
        assertEq(mtry.balanceOf(wallet), 1_000e18);
        assertEq(VestingWalletLinear(wallet).startTimestamp(), block.timestamp);
        assertTrue(unlockController.authorizedSource(wallet));
    }

    function test_fullLifecycleOnFork() public onlyFork {
        _deployAll();
        uint256 buyAmount = 80_000_000;  // 80 USDC → 1000 preMTRY
        deal(USDC, alice, buyAmount);

        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(sale), buyAmount);
        sale.buy(buyAmount, alice);
        preMTRY.approve(address(claim), 1_000e18);
        claim.lockPreTokens(1_000e18);
        vm.stopPrank();

        // MULTYR-1: TGE must be >= saleEnd (saleStart + 30 days from _deployAll()).
        vm.warp(block.timestamp + 30 days);
        uint256 tge = block.timestamp;
        vm.prank(deployer);
        claim.setTGE(tge);

        vm.warp(tge + 720 days);
        vm.prank(alice);
        claim.claim();
        assertEq(mtry.balanceOf(alice), 4_000e18);
    }
}
