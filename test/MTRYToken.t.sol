// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {MTRYToken} from "../src/MTRYToken.sol";
import {ZeroAddress} from "../src/Errors.sol";

contract MTRYTokenTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function test_totalSupply() public view {
        assertEq(mtry.totalSupply(), 300_000_000e18);
    }

    function test_name() public view {
        assertEq(mtry.name(), "MULTYR");
    }

    function test_symbol() public view {
        assertEq(mtry.symbol(), "MTRY");
    }

    function test_decimals() public view {
        assertEq(mtry.decimals(), 18);
    }

    function test_treasuryAllocation() public view {
        assertEq(mtry.balanceOf(treasurySafe), 75_000_000e18);
    }

    function test_liquidityAllocation() public view {
        assertEq(mtry.balanceOf(liquiditySafe), 45_000_000e18);
    }

    function test_claimPoolAllocation() public view {
        assertEq(mtry.balanceOf(address(claim)), 40_000_000e18);
    }

    function test_vestingManagerAllocation() public view {
        assertEq(mtry.balanceOf(address(vestingManager)), 111_000_000e18);
    }

    function test_ecosystemAllocation() public view {
        assertEq(mtry.balanceOf(address(ecosystem)), 29_000_000e18);
    }

    function test_allAllocationsSum() public view {
        uint256 sum = mtry.balanceOf(treasurySafe)
            + mtry.balanceOf(liquiditySafe)
            + mtry.balanceOf(address(claim))
            + mtry.balanceOf(address(vestingManager))
            + mtry.balanceOf(address(ecosystem));
        assertEq(sum, 300_000_000e18);
        assertEq(sum, mtry.totalSupply());
    }

    function test_constructorRevertsOnZeroTreasury() public {
        vm.expectRevert(ZeroAddress.selector);
        new MTRYToken(address(0), liquiditySafe, address(claim), address(vestingManager), address(ecosystem));
    }

    function test_constructorRevertsOnZeroLiquidity() public {
        vm.expectRevert(ZeroAddress.selector);
        new MTRYToken(treasurySafe, address(0), address(claim), address(vestingManager), address(ecosystem));
    }

    function test_constructorRevertsOnZeroClaim() public {
        vm.expectRevert(ZeroAddress.selector);
        new MTRYToken(treasurySafe, liquiditySafe, address(0), address(vestingManager), address(ecosystem));
    }

    function test_constructorRevertsOnZeroVestingManager() public {
        vm.expectRevert(ZeroAddress.selector);
        new MTRYToken(treasurySafe, liquiditySafe, address(claim), address(0), address(ecosystem));
    }

    function test_constructorRevertsOnZeroEcosystem() public {
        vm.expectRevert(ZeroAddress.selector);
        new MTRYToken(treasurySafe, liquiditySafe, address(claim), address(vestingManager), address(0));
    }

    function test_vanillaTransfer() public {
        vm.prank(treasurySafe);
        mtry.transfer(alice, 1000e18);
        assertEq(mtry.balanceOf(alice), 1000e18);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        mtry.transfer(bob, 1e18);
    }

    function test_approveAndTransferFromWorks() public {
        vm.prank(treasurySafe);
        mtry.approve(alice, 500e18);
        vm.prank(alice);
        mtry.transferFrom(treasurySafe, bob, 500e18);
        assertEq(mtry.balanceOf(bob), 500e18);
    }

    function test_totalSupplyNeverChangesAfterTransfers() public {
        uint256 supplyBefore = mtry.totalSupply();
        vm.prank(treasurySafe);
        mtry.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        mtry.transfer(bob, 500_000e18);
        vm.prank(bob);
        mtry.transfer(carol, 250_000e18);
        assertEq(mtry.totalSupply(), supplyBefore);
    }

    // -------------------------------------------------------------------------
    // Burn tracking
    // -------------------------------------------------------------------------
    function test_burnReducesSupplyAndTracksCumulative() public {
        vm.prank(treasurySafe);
        mtry.transfer(alice, 1_000e18);
        vm.prank(alice);
        mtry.burn(400e18);
        assertEq(mtry.totalBurned(), 400e18);
        assertEq(mtry.totalSupply(), 300_000_000e18 - 400e18);
    }

    function test_totalBurnedMonotonicallyIncreases() public {
        vm.prank(treasurySafe);
        mtry.transfer(alice, 2_000e18);
        vm.startPrank(alice);
        mtry.burn(500e18);
        uint256 t1 = mtry.totalBurned();
        mtry.burn(1_500e18);
        uint256 t2 = mtry.totalBurned();
        vm.stopPrank();
        assertGt(t2, t1);
        assertEq(t2, 2_000e18);
    }
}
