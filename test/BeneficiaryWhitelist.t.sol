// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestSetup} from "./helpers/TestSetup.sol";
import {VestingManager} from "../src/VestingManager.sol";
import {VestingWalletLinear} from "../src/VestingWalletLinear.sol";
import {InvalidBeneficiaryContract, BeneficiaryUpdateNotReady, NotAuthorized} from "../src/Errors.sol";

/// @dev Dummy contract used to test contract-address beneficiaries.
contract DummyContract {
    function marker() external pure returns (uint256) { return 1; }
}

contract BeneficiaryWhitelistTest is TestSetup {
    VestingWalletLinear internal wallet;

    function setUp() public {
        _deployAllCorrectly();
        wallet = VestingWalletLinear(
            _createGrantVesting(
                VestingManager.BucketType.Team,
                teamBeneficiary,
                1_000e18,
                365 days,
                1095 days,
                false
            )
        );
    }

    function test_beneficiaryUpdateAllowsEOA() public {
        // Alice is an EOA (no code), so the update should pass.
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);
        assertEq(wallet.pendingBeneficiary(), alice);
    }

    function test_beneficiaryUpdateRejectsUnwhitelistedContract() public {
        DummyContract d = new DummyContract();
        vm.prank(teamBeneficiary);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        wallet.proposeBeneficiaryUpdate(address(d));
    }

    function test_beneficiaryUpdateAllowsWhitelistedContract() public {
        DummyContract d = new DummyContract();

        vm.prank(deployer);  // manager owner
        vestingManager.setWhitelistedBeneficiaryContract(address(d), true);

        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(address(d));
        assertEq(wallet.pendingBeneficiary(), address(d));
    }

    function test_whitelistOnlyOwner() public {
        DummyContract d = new DummyContract();
        vm.prank(alice);
        vm.expectRevert();
        vestingManager.setWhitelistedBeneficiaryContract(address(d), true);
    }

    function test_confirmStillRequiresDelay() public {
        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(alice);

        vm.prank(teamBeneficiary);
        vm.expectRevert(BeneficiaryUpdateNotReady.selector);
        wallet.confirmBeneficiaryUpdate();

        vm.warp(wallet.beneficiaryUpdateAt());
        vm.prank(teamBeneficiary, teamBeneficiary);
        wallet.confirmBeneficiaryUpdate();
        assertEq(wallet.beneficiary(), alice);
    }

    function test_confirmRejectsDeWhitelistedContract() public {
        DummyContract d = new DummyContract();
        vm.prank(deployer);
        vestingManager.setWhitelistedBeneficiaryContract(address(d), true);

        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(address(d));

        // Governance de-whitelists during the delay window.
        vm.prank(deployer);
        vestingManager.setWhitelistedBeneficiaryContract(address(d), false);

        vm.warp(wallet.beneficiaryUpdateAt());
        vm.prank(teamBeneficiary);
        vm.expectRevert(InvalidBeneficiaryContract.selector);
        wallet.confirmBeneficiaryUpdate();
        assertEq(wallet.beneficiary(), teamBeneficiary);
    }

    function test_cancelStillWorksAfterContractProposal() public {
        DummyContract d = new DummyContract();
        vm.prank(deployer);
        vestingManager.setWhitelistedBeneficiaryContract(address(d), true);

        vm.prank(teamBeneficiary);
        wallet.proposeBeneficiaryUpdate(address(d));

        // Revoker (safety-net) can cancel suspicious proposals.
        vm.prank(deployer);
        wallet.cancelBeneficiaryUpdate();
        assertEq(wallet.pendingBeneficiary(), address(0));
    }
}
