// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PreMTRYSale} from "../../src/PreMTRYSale.sol";
import {PreMTRYToken} from "../../src/PreMTRYToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title PreMTRYSaleSymbolic — Halmos proofs for the sale hard-cap invariant.
contract PreMTRYSaleSymbolicTest is Test {
    PreMTRYSale internal sale;
    PreMTRYToken internal preToken;
    MockUSDC internal usdc;

    address internal constant OWNER = address(uint160(0xABCD));
    address internal constant TREASURY = address(uint160(0xCAFE));
    address internal constant BUYER = address(uint160(0xB0B));

    address internal constant OFFICIAL_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant SALE_START = 1_000_000;
    uint256 internal constant SALE_END = 1_000_000 + 30 days;

    function setUp() public {
        // Arbitrum chain id is required by the sale constructor.
        vm.chainId(42161);

        // Deploy MockUSDC and etch its code at the official USDC address.
        MockUSDC impl = new MockUSDC();
        vm.etch(OFFICIAL_USDC, address(impl).code);
        usdc = MockUSDC(OFFICIAL_USDC);

        // Deploy preMTRY and sale.
        preToken = new PreMTRYToken(OWNER);
        sale = new PreMTRYSale(address(preToken), TREASURY, SALE_START, SALE_END, OWNER);

        vm.prank(OWNER);
        preToken.setSaleContract(address(sale));

        vm.startPrank(OWNER);
        sale.setWhitelist(BUYER, true);
        sale.setWhitelist(address(uint160(0xAA11)), true);
        vm.stopPrank();

        vm.warp(SALE_START);
    }

    // -------------------------------------------------------------------------
    // Hard cap invariant: totalRaisedUSDC <= HARD_CAP_USDC
    // -------------------------------------------------------------------------

    /// @notice Any arbitrary buy attempt keeps totalRaisedUSDC bounded by HARD_CAP_USDC.
    function check_totalRaisedNeverExceedsHardCap(uint256 usdcAmount) external {
        vm.assume(usdcAmount > 0 && usdcAmount <= 10_000_000e6);  // up to 10M USDC symbolic

        // Fund buyer and approve.
        usdc.mint(BUYER, usdcAmount);
        vm.prank(BUYER);
        usdc.approve(address(sale), usdcAmount);

        vm.prank(BUYER);
        try sale.buy(usdcAmount, BUYER) {} catch {}

        assert(sale.totalRaisedUSDC() <= sale.HARD_CAP_USDC());
    }

    /// @notice Two buys from two buyers: aggregate still bounded by hard cap.
    function check_twoBuyersBoundedByHardCap(uint256 amt1, uint256 amt2) external {
        vm.assume(amt1 > 0 && amt1 <= 800_000e6);
        vm.assume(amt2 > 0 && amt2 <= 800_000e6);

        address BUYER2 = address(uint160(0xAA11));

        usdc.mint(BUYER, amt1);
        usdc.mint(BUYER2, amt2);
        vm.prank(BUYER);
        usdc.approve(address(sale), amt1);
        vm.prank(BUYER2);
        usdc.approve(address(sale), amt2);

        vm.prank(BUYER);
        try sale.buy(amt1, BUYER) {} catch {}
        vm.prank(BUYER2);
        try sale.buy(amt2, BUYER2) {} catch {}

        assert(sale.totalRaisedUSDC() <= sale.HARD_CAP_USDC());
    }

    // -------------------------------------------------------------------------
    // Sale window enforcement: buys outside [saleStart, saleEnd] revert.
    // -------------------------------------------------------------------------

    function check_noBuyBeforeStart(uint256 timestamp, uint256 usdcAmount) external {
        vm.assume(timestamp < SALE_START);
        vm.assume(usdcAmount > 0 && usdcAmount <= 800_000e6);

        vm.warp(timestamp);

        usdc.mint(BUYER, usdcAmount);
        vm.prank(BUYER);
        usdc.approve(address(sale), usdcAmount);

        uint256 raisedBefore = sale.totalRaisedUSDC();
        vm.prank(BUYER);
        try sale.buy(usdcAmount, BUYER) {
            assert(false);  // must revert
        } catch {
            assert(sale.totalRaisedUSDC() == raisedBefore);
        }
    }

    function check_noBuyAfterEnd(uint256 timestamp, uint256 usdcAmount) external {
        vm.assume(timestamp > SALE_END);
        vm.assume(timestamp < 2 * SALE_END);  // bound to avoid overflow paths
        vm.assume(usdcAmount > 0 && usdcAmount <= 800_000e6);

        vm.warp(timestamp);

        usdc.mint(BUYER, usdcAmount);
        vm.prank(BUYER);
        usdc.approve(address(sale), usdcAmount);

        uint256 raisedBefore = sale.totalRaisedUSDC();
        vm.prank(BUYER);
        try sale.buy(usdcAmount, BUYER) {
            assert(false);
        } catch {
            assert(sale.totalRaisedUSDC() == raisedBefore);
        }
    }

    // -------------------------------------------------------------------------
    // USDC accounting: sale contract never retains USDC.
    // -------------------------------------------------------------------------

    function check_saleRetainsNoUSDC(uint256 usdcAmount) external {
        vm.assume(usdcAmount > 0 && usdcAmount <= 800_000e6);

        usdc.mint(BUYER, usdcAmount);
        vm.prank(BUYER);
        usdc.approve(address(sale), usdcAmount);

        vm.prank(BUYER);
        try sale.buy(usdcAmount, BUYER) {} catch {}

        assert(usdc.balanceOf(address(sale)) == 0);
    }
}
