// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// core
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchVesting} from "@archliquid/vesting/ArchVesting.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {ArchTokenFactory} from "@archliquid/token/ArchTokenFactory.sol";
import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresaleDeployer} from "@archliquid/launchpad/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "@archliquid/launchpad/ArchCurveDeployer.sol";
import {ArchStakingFactory} from "@archliquid/staking/ArchStakingFactory.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

// lending (Compound v2 fork)
import {ArchLiquidPriceOracle, AggregatorV3Interface} from "@archliquid/lending/ArchLiquidPriceOracle.sol";
import {ArchComptroller} from "@archliquid/lending/ArchComptroller.sol";
import {ArchUnitroller} from "@archliquid/lending/ArchUnitroller.sol";
import {ArchJumpRateModel} from "@archliquid/lending/ArchJumpRateModel.sol";
import {ArchCErc20} from "@archliquid/lending/ArchCErc20.sol";
import {ComptrollerInterface} from "compound/ComptrollerInterface.sol";
import {InterestRateModel} from "compound/InterestRateModel.sol";
import {PriceOracle} from "compound/PriceOracle.sol";

// mock infra: Robinhood Chain testnet has no Uniswap V3 / WETH / stock tokens /
// Chainlink feeds at the mainnet addresses, so a self-contained testnet stands
// up its own. NOT for mainnet (DeployProtocol.s.sol wires the real addresses).
import {MockERC20, MockAggregator, MockNFPM, MockV3Router, MockWETH} from "../test/mocks/Mocks.sol";

/// @notice One-shot deploy of the FULL ArchLiquid protocol plus mock DEX/asset
///         infrastructure to a testnet that lacks it. The deployer is used as
///         treasury owner, comptroller admin and keeper (single-key testnet).
contract DeployTestnet is Script {
    uint16 constant REWARD_FEE_BPS = 500;
    uint24 constant FEE_TIER = 3000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address gov = vm.addr(pk);

        // Override any default via env to stand up a lower-fee test instance.
        uint256 LOCKER_FEE = vm.envOr("LOCKER_FEE", uint256(0.02 ether));
        uint256 VESTING_FEE = vm.envOr("VESTING_FEE", uint256(0.01 ether));
        uint256 FACTORY_FEE = vm.envOr("FACTORY_FEE", uint256(0.015 ether));
        uint256 LISTING_FEE = vm.envOr("LISTING_FEE", uint256(0.1 ether));
        uint256 STAKING_FEE = vm.envOr("STAKING_FEE", uint256(0.05 ether));

        vm.startBroadcast(pk);

        // ── mock DEX + assets ──
        MockWETH weth = new MockWETH();
        MockNFPM nfpm = new MockNFPM();
        MockV3Router router = new MockV3Router();
        router.setNfpm(nfpm);
        MockERC20 stock = new MockERC20("Mock NVDA", "mNVDAx");
        MockERC20 usdc = new MockERC20("Mock USDG", "mUSDG");

        // ── core services ──
        ArchTreasury treasury = new ArchTreasury(gov);
        address payable t = payable(address(treasury));
        ArchV3PositionLocker locker = new ArchV3PositionLocker(LOCKER_FEE, t, gov);
        ArchVesting vesting = new ArchVesting(VESTING_FEE, t);
        ArchStockRegistry registry = new ArchStockRegistry(gov);
        registry.setApproved(address(stock), true);
        ArchStockSwapExecutor stockSwapExecutor = new ArchStockSwapExecutor(IERC20(address(weth)), address(router));
        registry.setStockSwapExecutor(address(stockSwapExecutor));

        INonfungiblePositionManager infpm = INonfungiblePositionManager(address(nfpm));
        ISwapRouter iswap = ISwapRouter(address(router));
        IWETH9 iweth = IWETH9(address(weth));

        ArchTokenFactory factory =
            new ArchTokenFactory(FACTORY_FEE, t, gov, infpm, iswap, iweth, FEE_TIER, locker, registry);

        ArchPresaleDeployer presaleDeployer = new ArchPresaleDeployer();
        ArchCurveDeployer curveDeployer = new ArchCurveDeployer();
        ArchLaunchpad launchpad = new ArchLaunchpad(
            LISTING_FEE, t, locker, infpm, iswap, iweth, FEE_TIER, gov, registry, presaleDeployer, curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));

        ArchStakingFactory stakingFactory = new ArchStakingFactory(STAKING_FEE, t, REWARD_FEE_BPS);

        locker.setFeeExempt(address(factory), true);
        locker.setFactory(address(launchpad), true);

        // ── lending market ──
        ArchUnitroller unitroller = new ArchUnitroller();
        ArchComptroller impl = new ArchComptroller();
        unitroller._setPendingImplementation(address(impl));
        impl._become(unitroller);
        ArchComptroller comptroller = ArchComptroller(payable(address(unitroller)));

        ArchLiquidPriceOracle oracle = new ArchLiquidPriceOracle(gov);
        comptroller._setPriceOracle(PriceOracle(address(oracle)));
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.08e18);
        ArchJumpRateModel irm = new ArchJumpRateModel(0.02e18, 0.1e18, 1e18, 0.8e18, gov);

        // ArchCErc20: Compound v2 market + ERC-3156 flash loans (5 bps -> reserves)
        ArchCErc20 arUSDG = new ArchCErc20(
            address(usdc),
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            2e26,
            "ArchLiquid USDG",
            "arUSDG",
            8,
            payable(gov),
            5
        );
        ArchCErc20 arNVDAx = new ArchCErc20(
            address(stock),
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            2e26,
            "ArchLiquid NVDA",
            "arNVDAx",
            8,
            payable(gov),
            5
        );
        comptroller._supportMarket(arUSDG);
        comptroller._supportMarket(arNVDAx);

        MockAggregator usdcFeed = new MockAggregator(8, 1e8);
        MockAggregator stockFeed = new MockAggregator(8, 100e8);
        usdcFeed.setAnswer(1e8, block.timestamp);
        stockFeed.setAnswer(100e8, block.timestamp);
        oracle.setFeed(address(arUSDG), AggregatorV3Interface(address(usdcFeed)), 1 hours);
        oracle.setFeed(address(arNVDAx), AggregatorV3Interface(address(stockFeed)), 1 hours);
        comptroller._setCollateralFactor(arNVDAx, 0.75e18);
        arUSDG._setReserveFactor(0.2e18);
        arNVDAx._setReserveFactor(0.2e18);

        // seed the deployer with mock assets for smoke testing
        usdc.mint(gov, 1_000_000e18);
        stock.mint(gov, 10_000e18);

        vm.stopBroadcast();

        console2.log("== ArchLiquid testnet deployment ==");
        console2.log("factoryFee/listingFee (wei)", FACTORY_FEE, LISTING_FEE);
        console2.log("Treasury        ", address(treasury));
        console2.log("Locker(V3)      ", address(locker));
        console2.log("Vesting         ", address(vesting));
        console2.log("StockRegistry   ", address(registry));
        console2.log("StockExecutor   ", address(stockSwapExecutor));
        console2.log("TokenFactory    ", address(factory));
        console2.log("PresaleDeployer ", address(presaleDeployer));
        console2.log("CurveDeployer   ", address(curveDeployer));
        console2.log("Launchpad       ", address(launchpad));
        console2.log("StakingFactory  ", address(stakingFactory));
        console2.log("Comptroller     ", address(comptroller));
        console2.log("PriceOracle     ", address(oracle));
        console2.log("JumpRateModelV2 ", address(irm));
        console2.log("arUSDG           ", address(arUSDG));
        console2.log("arNVDAx          ", address(arNVDAx));
        console2.log("-- mock infra --");
        console2.log("WETH            ", address(weth));
        console2.log("NFPM            ", address(nfpm));
        console2.log("SwapRouter      ", address(router));
        console2.log("Stock(mNVDAx)   ", address(stock));
        console2.log("USDG(mUSDG)     ", address(usdc));
        console2.log("usdcFeed        ", address(usdcFeed));
        console2.log("stockFeed       ", address(stockFeed));
    }
}
