// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { FactoryLib } from "../../src/contracts/atlas/FactoryLib.sol";
import { TestAtlas } from "./TestAtlas.sol";
import { AtlasVerification } from "../../src/contracts/atlas/AtlasVerification.sol";
import { ExecutionEnvironment } from "../../src/contracts/common/ExecutionEnvironment.sol";
import { Sorter } from "../../src/contracts/helpers/Sorter.sol";
import { Simulator } from "../../src/contracts/helpers/Simulator.sol";
import { GovernanceBurner } from "../../src/contracts/helpers/GovernanceBurner.sol";

contract BaseTest is Test {
    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    address deployer = makeAddr("Deployer");

    uint256 governancePK;
    address governanceEOA;

    uint256 userPK;
    address userEOA;

    uint256 solverOnePK;
    address solverOneEOA;

    uint256 solverTwoPK;
    address solverTwoEOA;

    uint256 solverThreePK;
    address solverThreeEOA;

    uint256 solverFourPK;
    address solverFourEOA;

    TestAtlas atlas;
    AtlasVerification atlasVerification;
    Simulator simulator;
    Sorter sorter;
    GovernanceBurner govBurner;

    address WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address DAI_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IERC20 WETH = IERC20(WETH_ADDRESS);
    IERC20 DAI = IERC20(DAI_ADDRESS);

    uint256 DEFAULT_ESCROW_DURATION = 64;
    uint256 DEFAULT_ATLAS_SURCHARGE_RATE = 1_000_000; // 10%
    uint256 DEFAULT_BUNDLER_SURCHARGE_RATE = 1_000_000; // 10%
    uint256 MAINNET_FORK_BLOCK = 17_441_786;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();
    }

    function __createAndLabelAccounts() internal {
        (userEOA, userPK) = makeAddrAndKey("userEOA");
        (governanceEOA, governancePK) = makeAddrAndKey("govEOA");
        (solverOneEOA, solverOnePK) = makeAddrAndKey("solverOneEOA");
        (solverTwoEOA, solverTwoPK) = makeAddrAndKey("solverTwoEOA");
        (solverThreeEOA, solverThreePK) = makeAddrAndKey("solverThreeEOA");
        (solverFourEOA, solverFourPK) = makeAddrAndKey("solverFourEOA");
    }

    function __deployAtlasContracts() internal {
        vm.startPrank(deployer);
        simulator = new Simulator();

        // Computes the addresses at which AtlasVerification will be deployed
        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);
        FactoryLib factoryLib = new FactoryLib(address(execEnvTemplate));

        atlas = new TestAtlas({
            escrowDuration: DEFAULT_ESCROW_DURATION,
            atlasSurchargeRate: DEFAULT_ATLAS_SURCHARGE_RATE,
            bundlerSurchargeRate: DEFAULT_BUNDLER_SURCHARGE_RATE,
            verification: expectedAtlasVerificationAddr,
            simulator: address(simulator),
            factoryLib: address(factoryLib),
            initialSurchargeRecipient: deployer,
            l2GasCalculator: address(0)
        });
        atlasVerification = new AtlasVerification(address(atlas));
        simulator.setAtlas(address(atlas));
        sorter = new Sorter(address(atlas));
        govBurner = new GovernanceBurner();

        vm.deal(address(simulator), 1000e18); // to allow userOp.value > 0 sims
        vm.stopPrank();

        vm.label(address(atlas), "Atlas");
        vm.label(address(atlasVerification), "AtlasVerification");
        vm.label(address(simulator), "Simulator");
        vm.label(address(sorter), "Sorter");
        vm.label(address(govBurner), "GovBurner");
    }

    function __fundSolversAndDepositAtlETH() internal {
        // All solverEOAs start with 100 ETH and 1 ETH deposited in Atlas
        hoax(solverOneEOA, 100e18);
        atlas.deposit{ value: 1e18 }();
        hoax(solverTwoEOA, 100e18);
        atlas.deposit{ value: 1e18 }();
        hoax(solverThreeEOA, 100e18);
        atlas.deposit{ value: 1e18 }();
        hoax(solverFourEOA, 100e18);
        atlas.deposit{ value: 1e18 }();
    }
}
