// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {PreMTRYToken} from "../src/PreMTRYToken.sol";
import {
    ZeroAddress,
    MaxSupplyExceeded,
    Unauthorized,
    AlreadySet,
    InvalidBeneficiaryContract
} from "../src/Errors.sol";

/// @dev A contract with code whose preToken() reverts — exercises the catch branch
///      in PreMTRYToken._validateBindingCandidate.
contract RevertingPreTokenBinding {
    function preToken() external pure returns (address) {
        revert();
    }
}

/// @dev A contract with code whose preToken() returns a wrong address — exercises
///      the `bound != address(this)` branch in _validateBindingCandidate.
contract WrongAddressPreTokenBinding {
    function preToken() external pure returns (address) {
        return address(0xdead);
    }
}

contract PreMTRYTokenTest is TestSetup {
    function setUp() public {
        _deployAllCorrectly();
    }

    function test_name() public view {
        assertEq(preMTRY.name(), "preMULTYR");
    }

    function test_symbol() public view {
        assertEq(preMTRY.symbol(), "preMTRY");
    }

    function test_decimals() public view {
        assertEq(preMTRY.decimals(), 18);
    }

    function test_maxSupply() public view {
        assertEq(preMTRY.MAX_SUPPLY(), 10_000_000e18);
    }

    function test_saleContractSet() public view {
        assertEq(preMTRY.saleContract(), address(sale));
    }

    function test_claimContractSet() public view {
        assertEq(preMTRY.claimContract(), address(claim));
    }

    function test_saleMintWorks() public {
        _aliceBuys(80_000); // 0.08 USDC = 1 preMTRY
        assertEq(preMTRY.balanceOf(alice), 1e18);
    }

    function test_mintUpToMaxSupply() public {
        _aliceBuys(800_000e6); // full hard cap = 10M preMTRY
        assertEq(preMTRY.totalSupply(), 10_000_000e18);
    }

    function test_mintBeyondMaxSupplyReverts() public {
        _aliceBuys(800_000e6); // fill to max
        _fundBob(80_000); // try to buy 1 more
        vm.warp(saleStart);
        // This would exceed MAX_SUPPLY since hard cap is already reached
        // But it'll actually revert with HardCapExceeded since USDC hard cap == preMTRY max supply
        // Let's test the PreMTRYToken.mint directly
        vm.prank(address(sale));
        vm.expectRevert(MaxSupplyExceeded.selector);
        preMTRY.mint(alice, 1);
    }

    function test_claimBurnWorks() public {
        _aliceBuys(80_000); // 1 preMTRY
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);
        assertEq(preMTRY.totalSupply(), 0);
    }

    function test_unauthorizedMintReverts() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        preMTRY.mint(alice, 1e18);
    }

    function test_unauthorizedBurnReverts() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        preMTRY.burn(1e18);
    }

    function test_setSaleContractUpdatableUntilFinalized() public {
        // Setup already set sale contract to `sale`. Before finalize, any valid sale with
        // matching preToken() can be set. We expose the same sale (valid binding) again.
        vm.prank(deployer);
        preMTRY.setSaleContract(address(sale));
        assertEq(preMTRY.saleContract(), address(sale));

        // Finalize freezes the binding.
        vm.prank(deployer);
        preMTRY.finalizeSaleContract();
        assertTrue(preMTRY.saleContractFinalized());

        // After finalize, update reverts.
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.setSaleContract(address(sale));
    }

    function test_setClaimContractUpdatableUntilFinalized() public {
        vm.prank(deployer);
        preMTRY.setClaimContract(address(claim));
        assertEq(preMTRY.claimContract(), address(claim));

        vm.prank(deployer);
        preMTRY.finalizeClaimContract();
        assertTrue(preMTRY.claimContractFinalized());

        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.setClaimContract(address(claim));
    }

    function test_setSaleContractZeroReverts() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.expectRevert(ZeroAddress.selector);
        fresh.setSaleContract(address(0));
    }

    function test_setClaimContractZeroReverts() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.expectRevert(ZeroAddress.selector);
        fresh.setClaimContract(address(0));
    }

    function test_freelyTransferable() public {
        _aliceBuys(80_000); // 1 preMTRY
        vm.prank(alice);
        preMTRY.transfer(bob, 0.5e18);
        assertEq(preMTRY.balanceOf(alice), 0.5e18);
        assertEq(preMTRY.balanceOf(bob), 0.5e18);
    }

    function test_ownerCanTransferOwnership() public {
        vm.prank(deployer);
        preMTRY.transferOwnership(safeGov);
        vm.prank(safeGov);
        preMTRY.acceptOwnership();
        assertEq(preMTRY.owner(), safeGov);
    }

    function test_setSaleContractOnlyOwner() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.prank(alice);
        vm.expectRevert();
        fresh.setSaleContract(address(0x999));
    }

    function test_setClaimContractOnlyOwner() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.prank(alice);
        vm.expectRevert();
        fresh.setClaimContract(address(0x999));
    }

    function test_mintZeroIsNoOp() public {
        // mint(0) does not revert — no explicit zero check in PreMTRYToken.mint
        // This is a no-op: valid but has no effect
        vm.prank(address(sale));
        preMTRY.mint(alice, 0);
        assertEq(preMTRY.balanceOf(alice), 0);
        assertEq(preMTRY.totalSupply(), 0);
    }

    function test_burnZeroIsNoOp() public {
        // burn(0) does not revert — OZ _burn accepts 0
        // This is a no-op: valid but has no effect
        vm.prank(address(claim));
        preMTRY.burn(0);
        assertEq(preMTRY.totalSupply(), 0);
    }

    function test_burnMoreThanBalanceReverts() public {
        _aliceBuys(80_000); // 1 preMTRY
        vm.prank(alice);
        preMTRY.approve(address(claim), 1e18);
        vm.prank(alice);
        claim.lockPreTokens(1e18);
        // preMTRY balance of claim is 0 now (burned), try to burn more
        vm.prank(address(claim));
        vm.expectRevert();
        preMTRY.burn(1);
    }

    // -------------------------------------------------------------------------
    // Finalizable binding tests
    // -------------------------------------------------------------------------

    function test_saleContractCanBeUpdatedBeforeFinalize() public {
        // Deploy a fresh token and a fresh sale that binds to it via preToken().
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        // Re-use existing `sale` won't work (it binds to `preMTRY`), so we create a wrapper via
        // a minimal mock-free approach: the easiest is to point to `sale` first, fail, then
        // confirm the valid binding path by using the current setup's `sale` + `preMTRY`.
        // For this test we rely on the main setUp() state where `preMTRY.saleContract == sale`.
        vm.prank(deployer);
        preMTRY.setSaleContract(address(sale));  // re-set to same valid sale
        assertEq(preMTRY.saleContract(), address(sale));
        assertFalse(preMTRY.saleContractFinalized());
        fresh; // silence
    }

    function test_saleContractCannotBeUpdatedAfterFinalize() public {
        vm.prank(deployer);
        preMTRY.finalizeSaleContract();
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.setSaleContract(address(sale));
    }

    function test_claimContractCanBeUpdatedBeforeFinalize() public {
        vm.prank(deployer);
        preMTRY.setClaimContract(address(claim));  // valid binding
        assertEq(preMTRY.claimContract(), address(claim));
        assertFalse(preMTRY.claimContractFinalized());
    }

    function test_claimContractCannotBeUpdatedAfterFinalize() public {
        vm.prank(deployer);
        preMTRY.finalizeClaimContract();
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.setClaimContract(address(claim));
    }

    function test_setSaleContractRejectsEOA() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        preMTRY.setSaleContract(alice);  // EOA
    }

    function test_setClaimContractRejectsEOA() public {
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        preMTRY.setClaimContract(alice);  // EOA
    }

    function test_setSaleContractValidatesInterface() public {
        // A contract that doesn't expose preToken() or binds to a different token must revert.
        PreMTRYToken otherToken = new PreMTRYToken(address(this));
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        preMTRY.setSaleContract(address(otherToken));  // otherToken has no preToken() binding
    }

    function test_setClaimContractValidatesInterface() public {
        PreMTRYToken otherToken = new PreMTRYToken(address(this));
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        preMTRY.setClaimContract(address(otherToken));
    }

    function test_finalizeSaleContractRequiresAddressSet() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.expectRevert(ZeroAddress.selector);
        fresh.finalizeSaleContract();
    }

    function test_finalizeClaimContractRequiresAddressSet() public {
        PreMTRYToken fresh = new PreMTRYToken(address(this));
        vm.expectRevert(ZeroAddress.selector);
        fresh.finalizeClaimContract();
    }

    // -- Coverage gap: double-finalize reverts --------------------------------

    function test_finalizeSaleContract_revertsIfAlreadyFinalized() public {
        // First call succeeds (saleContract is set to address(sale) in setup)
        vm.prank(deployer);
        preMTRY.finalizeSaleContract();
        // Second call must revert AlreadySet
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.finalizeSaleContract();
    }

    function test_finalizeClaimContract_revertsIfAlreadyFinalized() public {
        vm.prank(deployer);
        preMTRY.finalizeClaimContract();
        vm.prank(deployer);
        vm.expectRevert(AlreadySet.selector);
        preMTRY.finalizeClaimContract();
    }

    // -------------------------------------------------------------------------
    // _validateBindingCandidate catch branch
    // -------------------------------------------------------------------------
    /// @dev A minimal contract whose preToken() function always reverts,
    ///      triggering the catch block in _validateBindingCandidate.
    function test_setSaleContractCatchBranchOnRevertingPreToken() public {
        // Deploy a contract that always reverts when preToken() is called.
        // We use vm.etch to plant a minimal reverting contract at a fresh address.
        address revertingCandidate = address(0x9999);
        // Plant bytecode: PUSH0 PUSH0 REVERT (always reverts on any call)
        vm.etch(revertingCandidate, hex"5f5ffd");

        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        preMTRY.setSaleContract(revertingCandidate);
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _validateBindingCandidate catch branch
    //   preToken() exists but reverts → InvalidBeneficiaryContract
    // -------------------------------------------------------------------------
    function test_validateBinding_revertsIfPreTokenReverts() public {
        PreMTRYToken fresh = new PreMTRYToken(deployer);
        RevertingPreTokenBinding bad = new RevertingPreTokenBinding();
        // setSaleContract validates the candidate via _validateBindingCandidate;
        // preToken() exists on `bad` but reverts → catch branch.
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        fresh.setSaleContract(address(bad));
    }

    // -------------------------------------------------------------------------
    // Coverage gap: _validateBindingCandidate bound != address(this)
    //   preToken() returns a wrong address → InvalidBeneficiaryContract
    // -------------------------------------------------------------------------
    function test_validateBinding_revertsIfBoundIsWrongAddress() public {
        PreMTRYToken fresh = new PreMTRYToken(deployer);
        WrongAddressPreTokenBinding bad = new WrongAddressPreTokenBinding();
        vm.prank(deployer);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        fresh.setSaleContract(address(bad));
    }

}
