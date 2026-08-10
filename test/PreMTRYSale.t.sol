// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup, MockToken18} from "./helpers/TestSetup.sol";
import {PreMTRYSale} from "../src/PreMTRYSale.sol";
import {
    ZeroAddress, ZeroAmount, SaleNotActive, SaleEnded,
    HardCapExceeded, NotWhitelisted, InvalidTimeRange, InvalidChain
} from "../src/Errors.sol";

contract PreMTRYSaleTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    // --- Buy works ---

    function test_buyWorks() public {
        _fundAlice(800e6); // 800 USDC
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(800e6, alice);

        // 800e6 * 1e18 / 80_000 = 10_000e18 = 10,000 preMTRY
        assertEq(preMTRY.balanceOf(alice), 10_000e18);
        assertEq(sale.totalRaisedUSDC(), 800e6);
    }

    function test_buyCorrectPreMTRYAmount() public {
        _fundAlice(80_000); // 0.08 USDC = 1 preMTRY
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(80_000, alice);
        assertEq(preMTRY.balanceOf(alice), 1e18);
    }

    function test_buyUSDCRoutesToTreasury() public {
        _fundAlice(1_000e6);
        uint256 treasuryBefore = usdc.balanceOf(treasurySafe);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(1_000e6, alice);
        assertEq(usdc.balanceOf(treasurySafe), treasuryBefore + 1_000e6);
        assertEq(usdc.balanceOf(address(sale)), 0); // never sits in contract
    }

    function test_buyWithDifferentReceiver() public {
        _fundAlice(80_000);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(80_000, bob);
        assertEq(preMTRY.balanceOf(bob), 1e18);
        assertEq(preMTRY.balanceOf(alice), 0);
    }

    // --- Hard cap ---

    function test_buyExactHardCap() public {
        _fundAlice(800_000e6);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(800_000e6, alice);
        assertEq(sale.totalRaisedUSDC(), 800_000e6);
        assertEq(preMTRY.totalSupply(), 10_000_000e18);
    }

    function test_buyExceedingHardCapReverts() public {
        _fundAlice(800_001e6);
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(HardCapExceeded.selector);
        sale.buy(800_001e6, alice);
    }

    function test_multipleBuyersToHardCap() public {
        _fundAlice(400_000e6);
        _fundBob(400_000e6);
        vm.warp(saleStart);

        vm.prank(alice);
        sale.buy(400_000e6, alice);

        vm.prank(bob);
        sale.buy(400_000e6, bob);

        assertEq(sale.totalRaisedUSDC(), 800_000e6);
    }

    function test_buyAfterPartialFillExceedsHardCap() public {
        _fundAlice(700_000e6);
        _fundBob(200_000e6);
        vm.warp(saleStart);

        vm.prank(alice);
        sale.buy(700_000e6, alice);

        vm.prank(bob);
        vm.expectRevert(HardCapExceeded.selector);
        sale.buy(200_000e6, bob);
    }

    // --- Time window ---

    function test_buyBeforeSaleStartReverts() public {
        // The shared `sale` fixture uses saleStart == 0 (see TestSetup) so that TGE can be set
        // at the default block.timestamp without every test needing its own warp; that leaves no
        // valid "before saleStart" timestamp to warp to. Use a locally-deployed sale with a
        // nonzero saleStart instead to exercise this revert path.
        vm.prank(deployer);
        PreMTRYSale localSale = new PreMTRYSale(address(preMTRY), treasurySafe, 100, 200, deployer);
        vm.prank(deployer);
        localSale.setWhitelist(alice, true);

        _fundAlice(80_000);
        vm.prank(alice);
        usdc.approve(address(localSale), 80_000);
        vm.warp(99);
        vm.prank(alice);
        vm.expectRevert(SaleNotActive.selector);
        localSale.buy(80_000, alice);
    }

    function test_buyAfterSaleEndReverts() public {
        _fundAlice(80_000);
        vm.warp(saleEnd + 1);
        vm.prank(alice);
        vm.expectRevert(SaleEnded.selector);
        sale.buy(80_000, alice);
    }

    function test_buyAtExactSaleStart() public {
        _fundAlice(80_000);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(80_000, alice);
        assertEq(preMTRY.balanceOf(alice), 1e18);
    }

    function test_buyAtExactSaleEnd() public {
        _fundAlice(80_000);
        vm.warp(saleEnd);
        vm.prank(alice);
        sale.buy(80_000, alice);
        assertEq(preMTRY.balanceOf(alice), 1e18);
    }

    // --- Paused ---

    function test_buyWhilePausedReverts() public {
        _fundAlice(80_000);
        vm.prank(deployer);
        sale.pause();
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(); // Pausable: paused
        sale.buy(80_000, alice);
    }

    function test_unpauseAllowsBuy() public {
        _fundAlice(80_000);
        vm.prank(deployer);
        sale.pause();
        vm.prank(deployer);
        sale.unpause();
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(80_000, alice);
        assertEq(preMTRY.balanceOf(alice), 1e18);
    }

    // --- Zero / dust ---

    function test_buyZeroAmountReverts() public {
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        sale.buy(0, alice);
    }

    function test_buyReceiverZeroReverts() public {
        _fundAlice(80_000);
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        sale.buy(80_000, address(0));
    }

    function test_buyDustAmountReverts() public {
        _fundAlice(1);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(1, alice);
        // 1 * 1e18 / 80_000 = 12_500_000_000_000 = 0.0000125 preMTRY
        assertGt(preMTRY.balanceOf(alice), 0);
    }

    // --- Constructor validation ---

    function test_constructorRevertsIfNotArbitrumChain() public {
        vm.chainId(1); // Ethereum mainnet
        vm.expectRevert(InvalidChain.selector);
        new PreMTRYSale(
            address(preMTRY), treasurySafe,
            saleStart, saleEnd, deployer
        );
    }

    function test_constructorRevertsIfSaleStartGeSaleEnd() public {
        vm.chainId(42161);
        vm.expectRevert(InvalidTimeRange.selector);
        new PreMTRYSale(
            address(preMTRY), treasurySafe,
            saleEnd, saleStart, deployer
        );
    }

    function test_constructorRevertsIfSaleStartEqSaleEnd() public {
        vm.chainId(42161);
        vm.expectRevert(InvalidTimeRange.selector);
        new PreMTRYSale(
            address(preMTRY), treasurySafe,
            saleStart, saleStart, deployer
        );
    }

    function test_constructorRevertsIfPreTokenZero() public {
        vm.chainId(42161);
        vm.expectRevert(ZeroAddress.selector);
        new PreMTRYSale(
            address(0), treasurySafe,
            saleStart, saleEnd, deployer
        );
    }

    function test_constructorRevertsIfTreasuryZero() public {
        vm.chainId(42161);
        vm.expectRevert(ZeroAddress.selector);
        new PreMTRYSale(
            address(preMTRY), address(0),
            saleStart, saleEnd, deployer
        );
    }

    function test_officialUSDCIsPaymentToken() public view {
        assertEq(address(sale.paymentToken()), sale.OFFICIAL_USDC());
    }

    // --- Pause authorization ---

    function test_pauseOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sale.pause();
    }

    function test_unpauseOnlyOwner() public {
        vm.prank(deployer);
        sale.pause();
        vm.prank(alice);
        vm.expectRevert();
        sale.unpause();
    }

    // --- Preview ---

    function test_previewPurchase() public view {
        // 80_000 raw USDC → 1 preMTRY
        assertEq(sale.previewPurchase(80_000), 1e18);
        // 800_000e6 USDC → 10M preMTRY
        assertEq(sale.previewPurchase(800_000e6), 10_000_000e18);
        // 8_000e6 USDC → 100K preMTRY
        assertEq(sale.previewPurchase(8_000e6), 100_000e18);
    }

    function test_previewPurchaseZero() public view {
        assertEq(sale.previewPurchase(0), 0);
    }

    function test_previewPurchaseMaxCap() public view {
        assertEq(sale.previewPurchase(sale.HARD_CAP_USDC()), 10_000_000e18);
    }

    // --- Hardening ---

    function test_buyWithNonMultiplePriceAmount() public {
        // 100_001 raw USDC — not a clean multiple of 80_000
        uint256 oddAmount = 100_001;
        _fundAlice(oddAmount);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(oddAmount, alice);
        // 100_001 * 1e18 / 80_000 = 1_250_012_500_000_000 (truncated)
        uint256 expected = (oddAmount * 1e18) / 80_000;
        assertEq(preMTRY.balanceOf(alice), expected);
    }

    function test_buySmallestUnitWorks() public {
        // Smallest possible buy: 1 raw USDC unit
        _fundAlice(1);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(1, alice);
        // 1 * 1e18 / 80_000 = 12_500_000_000_000 wei of preMTRY
        uint256 expected = 1e18 / 80_000;
        assertEq(preMTRY.balanceOf(alice), expected);
        assertGt(expected, 0);
    }

    function test_buyRoundsDownAsExpected() public {
        // 79_999 raw USDC — just under 1 preMTRY
        _fundAlice(79_999);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(79_999, alice);
        uint256 expected = (79_999 * 1e18) / 80_000;
        assertEq(preMTRY.balanceOf(alice), expected);
        assertLt(expected, 1e18); // less than 1 preMTRY
    }

    function test_constructorRevertsIfOwnerZero() public {
        vm.chainId(42161);
        vm.expectRevert(); // OwnableInvalidOwner(address(0)) from OZ5
        new PreMTRYSale(
            address(preMTRY), treasurySafe,
            saleStart, saleEnd, address(0)
        );
    }

    // --- Accounting properties ---

    function test_totalRaisedMatchesTreasuryInflows() public {
        _fundAlice(500_000e6);
        _fundBob(200_000e6);
        vm.warp(saleStart);

        uint256 treasuryBefore = usdc.balanceOf(treasurySafe);

        vm.prank(alice);
        sale.buy(500_000e6, alice);
        vm.prank(bob);
        sale.buy(200_000e6, bob);

        uint256 treasuryAfter = usdc.balanceOf(treasurySafe);
        assertEq(sale.totalRaisedUSDC(), treasuryAfter - treasuryBefore);
    }

    function test_saleContractNeverRetainsUSDC() public {
        _fundAlice(1_000e6);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(1_000e6, alice);
        assertEq(usdc.balanceOf(address(sale)), 0);
    }

    function test_preMTRYSupplyMatchesPurchases() public {
        _fundAlice(400_000e6);
        _fundBob(300_000e6);
        vm.warp(saleStart);

        vm.prank(alice);
        sale.buy(400_000e6, alice);
        vm.prank(bob);
        sale.buy(300_000e6, bob);

        uint256 expectedTotal = sale.previewPurchase(400_000e6) + sale.previewPurchase(300_000e6);
        assertEq(preMTRY.totalSupply(), expectedTotal);
    }

    // --- Fuzz ---

    function testFuzz_buyAmountProducesExpectedPreMTRY(uint256 usdcAmount) public {
        usdcAmount = bound(usdcAmount, 1, 800_000e6);
        _fundAlice(usdcAmount);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(usdcAmount, alice);

        uint256 expected = (usdcAmount * 1e18) / 80_000;
        assertEq(preMTRY.balanceOf(alice), expected);
    }

    function testFuzz_totalRaisedNeverExceedsHardCap(uint256 a, uint256 b) public {
        a = bound(a, 1, 800_000e6);
        b = bound(b, 1, 800_000e6);
        vm.warp(saleStart);

        _fundAlice(a);
        vm.prank(alice);
        sale.buy(a, alice);

        if (a + b <= 800_000e6) {
            _fundBob(b);
            vm.prank(bob);
            sale.buy(b, bob);
        }

        assertLe(sale.totalRaisedUSDC(), sale.HARD_CAP_USDC());
    }

    function testFuzz_receiverGetsExactlyPreviewedAmount(uint256 usdcAmount) public {
        usdcAmount = bound(usdcAmount, 1, 800_000e6);
        uint256 preview = sale.previewPurchase(usdcAmount);

        _fundAlice(usdcAmount);
        vm.warp(saleStart);
        vm.prank(alice);
        sale.buy(usdcAmount, alice);

        assertEq(preMTRY.balanceOf(alice), preview);
    }

    // --- Whitelist ---

    function test_nonWhitelistedCannotBuy() public {
        address stranger = address(0x5555);
        usdc.mint(stranger, 80_000);
        vm.prank(stranger);
        usdc.approve(address(sale), 80_000);
        vm.warp(saleStart);
        vm.prank(stranger);
        vm.expectRevert(NotWhitelisted.selector);
        sale.buy(80_000, stranger);
    }

    function test_setWhitelistAddsAndRemoves() public {
        address stranger = address(0x5555);
        assertFalse(sale.whitelist(stranger));

        vm.prank(deployer);
        sale.setWhitelist(stranger, true);
        assertTrue(sale.whitelist(stranger));

        vm.prank(deployer);
        sale.setWhitelist(stranger, false);
        assertFalse(sale.whitelist(stranger));
    }

    function test_setWhitelistEmitsEvent() public {
        address stranger = address(0x5555);
        vm.prank(deployer);
        vm.expectEmit(true, false, false, true);
        emit PreMTRYSale.WhitelistUpdated(stranger, true);
        sale.setWhitelist(stranger, true);
    }

    function test_setWhitelistRevertsOnZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        sale.setWhitelist(address(0), true);
    }

    function test_setWhitelistOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sale.setWhitelist(bob, true);
    }

    function test_removedFromWhitelistCannotBuy() public {
        vm.prank(deployer);
        sale.setWhitelist(alice, false);

        _fundAlice(80_000);
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(NotWhitelisted.selector);
        sale.buy(80_000, alice);
    }

    function test_nonWhitelistedReceiverReverts() public {
        address stranger = address(0x5555);
        _fundAlice(80_000);
        vm.warp(saleStart);
        vm.prank(alice);
        vm.expectRevert(NotWhitelisted.selector);
        sale.buy(80_000, stranger); // alice is whitelisted sender, but receiver is not
    }

    function test_setWhitelistBatchAddsAll() public {
        address[] memory accounts = new address[](3);
        accounts[0] = address(0x1111);
        accounts[1] = address(0x2222);
        accounts[2] = address(0x3333);

        vm.prank(deployer);
        sale.setWhitelistBatch(accounts, true);

        assertTrue(sale.whitelist(accounts[0]));
        assertTrue(sale.whitelist(accounts[1]));
        assertTrue(sale.whitelist(accounts[2]));
    }

    function test_setWhitelistBatchRemovesAll() public {
        vm.prank(deployer);
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        sale.setWhitelistBatch(accounts, false);

        assertFalse(sale.whitelist(alice));
        assertFalse(sale.whitelist(bob));
    }

    function test_setWhitelistBatchRevertsOnZeroAddress() public {
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = address(0);

        vm.prank(deployer);
        vm.expectRevert(ZeroAddress.selector);
        sale.setWhitelistBatch(accounts, true);
    }

    function test_setWhitelistBatchOnlyOwner() public {
        address[] memory accounts = new address[](1);
        accounts[0] = carol;

        vm.prank(alice);
        vm.expectRevert();
        sale.setWhitelistBatch(accounts, true);
    }

    function test_setWhitelistBatchEmitsEvents() public {
        address[] memory accounts = new address[](2);
        accounts[0] = address(0xAAAA);
        accounts[1] = address(0xBBBB);

        vm.prank(deployer);
        vm.expectEmit(true, false, false, true);
        emit PreMTRYSale.WhitelistUpdated(accounts[0], true);
        vm.expectEmit(true, false, false, true);
        emit PreMTRYSale.WhitelistUpdated(accounts[1], true);
        sale.setWhitelistBatch(accounts, true);
    }
}
