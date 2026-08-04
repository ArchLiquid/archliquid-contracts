// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchVesting} from "@archliquid/vesting/ArchVesting.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {ArchTokenFactory} from "@archliquid/token/ArchTokenFactory.sol";
import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresaleDeployer} from "@archliquid/launchpad/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "@archliquid/launchpad/ArchCurveDeployer.sol";
import {ArchStakingFactory} from "@archliquid/staking/ArchStakingFactory.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {IUniswapV4PositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";

/// @notice Deploys the ArchLiquid core services (treasury, lockers, vesting,
///         registry, token factory, launchpad, staking). Lending is a separate
///         deployment from the pinned Lending module. Env: PRIVATE_KEY,
///         PROTOCOL_MULTISIG, KEEPER, V2_FACTORY, V3_NFPM, V3_SWAP_ROUTER,
///         V4_POSITION_MANAGER, WETH, STOCK_SWAP_AGGREGATOR.
///
///         The deployer temporarily owns the lockers and registry to wire the
///         factories, then hands them to the multisig via Ownable2Step. The
///         multisig must acceptOwnership() and approve stock tokens after.
contract DeployProtocol is Script {
    uint256 constant LOCKER_FEE = 0.02 ether;
    uint256 constant VESTING_FEE = 0.01 ether;
    uint256 constant FACTORY_FEE = 0.015 ether;
    uint256 constant LISTING_FEE = 0.1 ether;
    uint256 constant STAKING_FEE = 0.05 ether;
    uint16 constant REWARD_FEE_BPS = 500; // 5%
    uint24 constant STOCK_POOL_FEE = 3000; // 0.3% fee tier for stock/WETH pools

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envAddress("PROTOCOL_MULTISIG");
        address keeper = vm.envAddress("KEEPER");
        IUniswapV2Factory v2Factory = IUniswapV2Factory(vm.envAddress("V2_FACTORY"));
        INonfungiblePositionManager nfpm = INonfungiblePositionManager(vm.envAddress("V3_NFPM"));
        ISwapRouter swapRouter = ISwapRouter(vm.envAddress("V3_SWAP_ROUTER"));
        IUniswapV4PositionManager v4PositionManager = IUniswapV4PositionManager(vm.envAddress("V4_POSITION_MANAGER"));
        IWETH9 weth = IWETH9(vm.envAddress("WETH"));
        address stockSwapAggregator = vm.envAddress("STOCK_SWAP_AGGREGATOR");

        vm.startBroadcast(pk);

        // treasury and registry owned by the multisig; locker/registry need
        // deployer ownership briefly to wire the factories
        ArchTreasury treasury = new ArchTreasury(multisig);
        address payable t = payable(address(treasury));
        ArchLiquidityLocker v2Locker = new ArchLiquidityLocker(LOCKER_FEE, t, v2Factory, deployer);
        ArchV3PositionLocker v3Locker = new ArchV3PositionLocker(LOCKER_FEE, t, deployer);
        ArchV4PositionLocker v4Locker = new ArchV4PositionLocker(LOCKER_FEE, t, v4PositionManager, deployer);
        ArchVesting vesting = new ArchVesting(VESTING_FEE, t);
        ArchStockRegistry registry = new ArchStockRegistry(deployer);
        ArchStockSwapExecutor stockSwapExecutor = new ArchStockSwapExecutor(IERC20(address(weth)), stockSwapAggregator);
        registry.setStockSwapExecutor(address(stockSwapExecutor));

        ArchTokenFactory tokenFactory =
            new ArchTokenFactory(FACTORY_FEE, t, keeper, nfpm, swapRouter, weth, STOCK_POOL_FEE, v3Locker, registry);
        // presale/curve creation code lives in these deployers so the launchpad
        // stays under the EIP-170 size limit
        ArchPresaleDeployer presaleDeployer = new ArchPresaleDeployer();
        ArchCurveDeployer curveDeployer = new ArchCurveDeployer();
        ArchLaunchpad launchpad = new ArchLaunchpad(
            LISTING_FEE,
            t,
            v3Locker,
            nfpm,
            swapRouter,
            weth,
            STOCK_POOL_FEE,
            keeper,
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        ArchStakingFactory stakingFactory = new ArchStakingFactory(STAKING_FEE, t, REWARD_FEE_BPS);

        // wiring (deployer owns locker + registry here)
        v3Locker.setFeeExempt(address(tokenFactory), true); // factory locks LP fee-free
        v3Locker.setFactory(address(launchpad), true); // launchpad exempts its presales

        // hand ownership to the multisig (two-step; multisig accepts later)
        v2Locker.transferOwnership(multisig);
        v3Locker.transferOwnership(multisig);
        v4Locker.transferOwnership(multisig);
        registry.transferOwnership(multisig);

        vm.stopBroadcast();

        console2.log("Treasury       ", address(treasury));
        console2.log("Locker(V2)     ", address(v2Locker));
        console2.log("Locker(V3)     ", address(v3Locker));
        console2.log("Locker(V4)     ", address(v4Locker));
        console2.log("Vesting        ", address(vesting));
        console2.log("StockRegistry  ", address(registry));
        console2.log("StockExecutor  ", address(stockSwapExecutor));
        console2.log("StockAggregator", stockSwapAggregator);
        console2.log("TokenFactory   ", address(tokenFactory));
        console2.log("Launchpad      ", address(launchpad));
        console2.log("StakingFactory ", address(stakingFactory));
        console2.log("");
        console2.log("Post-deploy, from the multisig:");
        console2.log("1. all three lockers: acceptOwnership()");
        console2.log("2. registry.acceptOwnership()");
        console2.log("3. registry.setApproved(<each Robinhood stock token>, true)");
        console2.log("Lending market deploys separately: script/DeployLending.s.sol");
    }
}
