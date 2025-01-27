// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { BaseTest } from "./base/BaseTest.t.sol";

import { DummyDAppControl } from "./base/DummyDAppControl.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { SafeBlockNumber } from "src/contracts/libraries/SafeBlockNumber.sol";

import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/SolverOperation.sol";

contract SorterTest is BaseTest {
    DummyDAppControl dAppControl;
    UserOperation userOp;

    // Solvers 1 - 4 already defined in BaseTest

    uint256 public solverFivePK = 555_555;
    address public solverFiveEOA = vm.addr(solverFivePK);

    uint256 public solverSixPK = 666_666;
    address public solverSixEOA = vm.addr(solverSixPK);

    uint256 public solverSevenPK = 777_777;
    address public solverSevenEOA = vm.addr(solverSevenPK);

    uint256 atlEthToBond = 1 ether;

    function setUp() public override {
        super.setUp();

        deal(solverOneEOA, atlEthToBond);
        deal(solverTwoEOA, atlEthToBond);
        deal(solverThreeEOA, atlEthToBond);
        deal(solverFourEOA, atlEthToBond);
        deal(solverFiveEOA, atlEthToBond);
        deal(solverSixEOA, atlEthToBond);
        deal(solverSevenEOA, atlEthToBond);

        dAppControl = new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(new CallConfigBuilder().build())
            .buildAndIntegrate(atlasVerification);

        userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(SafeBlockNumber.get() + 2)
            .withDapp(address(dAppControl))
            .withControl(address(dAppControl))
            .withSessionKey(address(0))
            .withData("")
            .signAndBuild(address(atlasVerification), userPK);
    }

    function validSolverOperation(uint256 solverPK, uint256 bidAmount) public returns (SolverOperationBuilder) {
        return new SolverOperationBuilder()
            .withFrom(vm.addr(solverPK))
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(0))
            .withControl(userOp.control)
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(bidAmount)
            .withData("")
            .sign(address(atlasVerification), solverPK);
    }

    function validateSortedOps(SolverOperation[] memory sortedOps, uint256 validOps) internal pure {
        if (sortedOps.length > 1) {
            for (uint256 i; i < sortedOps.length - 1; i++) {
                assertTrue(sortedOps[i].bidAmount >= sortedOps[i + 1].bidAmount, "Not sorted");
            }
        }
        assertEq(sortedOps.length, validOps, "Invalid number of sortedOps");
    }

    function test_validateSortedOps() public {
        SolverOperation[] memory solverOps = new SolverOperation[](3);
        solverOps[0] = validSolverOperation(solverOnePK, 30).build();
        solverOps[1] = validSolverOperation(solverTwoPK, 20).build();
        solverOps[2] = validSolverOperation(solverThreePK, 10).build();
        validateSortedOps(solverOps, 3);
    }

    function test_sorter_allOpsInvalid() public {
        SolverOperation[] memory solverOps = new SolverOperation[](3);
        solverOps[0] = validSolverOperation(solverOnePK, 10).build(); // No AtlEth bonded
        solverOps[1] = validSolverOperation(solverTwoPK, 20).build(); // No AtlEth bonded
        solverOps[2] = validSolverOperation(solverThreePK, 30).build(); // No AtlEth bonded

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 0);
    }

    function test_sorter_singleOpValid() public {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(solverOnePK, 10).depositAndBondAtlEth(address(atlas), atlEthToBond).build();

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 1);
    }

    function test_sorter_allOpsValid_evenNumber() public {
        SolverOperation[] memory solverOps = new SolverOperation[](6);
        solverOps[0] = validSolverOperation(solverOnePK, 190).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[1] = validSolverOperation(solverTwoPK, 130).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[2] = validSolverOperation(solverThreePK, 110).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[3] = validSolverOperation(solverFourPK, 150).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[4] = validSolverOperation(solverFivePK, 140).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[5] = validSolverOperation(solverSixPK, 180).depositAndBondAtlEth(address(atlas), atlEthToBond).build();

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 6);
    }

    function test_sorter_allOpsValid_OddNumber() public {
        SolverOperation[] memory solverOps = new SolverOperation[](7);
        solverOps[0] = validSolverOperation(solverOnePK, 200).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[1] = validSolverOperation(solverTwoPK, 250).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[2] = validSolverOperation(solverThreePK, 210).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[3] = validSolverOperation(solverFourPK, 220).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[4] = validSolverOperation(solverFivePK, 270).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[5] = validSolverOperation(solverSixPK, 280).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[6] = validSolverOperation(solverSevenPK, 230).depositAndBondAtlEth(address(atlas), atlEthToBond).build();

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 7);
    }

    function test_sorter_mixedOpsValidity_1() public {
        SolverOperation[] memory solverOps = new SolverOperation[](7);
        solverOps[0] = validSolverOperation(solverOnePK, 310).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[1] = validSolverOperation(solverTwoPK, 350).build(); // No AtlEth bonded
        solverOps[2] = validSolverOperation(solverThreePK, 380).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[3] = validSolverOperation(solverFourPK, 300).build(); // No AtlEth bonded
        solverOps[4] = validSolverOperation(solverFivePK, 340).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[5] = validSolverOperation(solverSixPK, 390).depositAndBondAtlEth(address(atlas), atlEthToBond).build();
        solverOps[6] = validSolverOperation(solverSevenPK, 320).build(); // No AtlEth bonded

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 4);
    }

    function test_sorter_mixedOpsValidity_2() public {
        SolverOperation[] memory solverOps = new SolverOperation[](7);
        solverOps[0] = validSolverOperation(solverOnePK, 450)
            .depositAndBondAtlEth(address(atlas), atlEthToBond)
            .withUserOpHash("invalid") // Invalid userOpHash
            .signAndBuild(address(atlasVerification), solverOnePK);

        solverOps[1] = validSolverOperation(solverTwoPK, 480).build(); // No AtlEth bonded

        // This is the only valid solverOp
        solverOps[2] = validSolverOperation(solverThreePK, 420).depositAndBondAtlEth(address(atlas), atlEthToBond).build();

        solverOps[3] = validSolverOperation(solverFourPK, 410)
            .depositAndBondAtlEth(address(atlas), atlEthToBond)
            .withBidToken(address(1)) // Invalid bidToken
            .signAndBuild(address(atlasVerification), solverFourPK);

        vm.startPrank(solverFiveEOA);
        atlas.depositAndBond{value: atlEthToBond}(atlEthToBond);
        atlas.unbond(1); // This will set the solver's lastAccessedBlock to the current block
        vm.stopPrank();
        solverOps[4] = validSolverOperation(solverFivePK, 490).build();

        solverOps[5] = validSolverOperation(solverSixPK, 440)
            .depositAndBondAtlEth(address(atlas), atlEthToBond)
            .withControl(address(0)) // Invalid dAppControl
            .signAndBuild(address(atlasVerification), solverSixPK);

        solverOps[6] = validSolverOperation(solverSevenPK, 460)
            .depositAndBondAtlEth(address(atlas), atlEthToBond)
            .withMaxFeePerGas(userOp.maxFeePerGas - 1) // Invalid maxFeePerGas
            .signAndBuild(address(atlasVerification), solverSevenPK);

        SolverOperation[] memory sortedOps = sorter.sortBids(userOp, solverOps);
        validateSortedOps(sortedOps, 1);
    }
}
