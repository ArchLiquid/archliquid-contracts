// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArchAdapterCurveDeployer} from "@archliquid/launchpad/ArchAdapterCurveDeployer.sol";
import {ArchAdapterLaunchpad} from "@archliquid/launchpad/ArchAdapterLaunchpad.sol";
import {ArchAdapterPresaleDeployer} from "@archliquid/launchpad/ArchAdapterPresaleDeployer.sol";
import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchUserLiquidityProvisioner} from "@archliquid/launchpad/ArchUserLiquidityProvisioner.sol";
import {ArchV2LaunchLiquidityAdapter} from "@archliquid/launchpad/ArchV2LaunchLiquidityAdapter.sol";
import {IArchLaunchRegistry} from "@archliquid/launchpad/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Router02} from "@archliquid/launchpad/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @notice Fresh V2 token/launch family that supports locked or permanent
///         user liquidity, including a one-time deferred first market. The
///         existing V2 router, canonical factory, stock pair and locker remain
///         unchanged. No proxy or upgrade authority is introduced.
contract RedeployV2UserLiquidity is Script {
    uint256 private constant FACTORY_FEE = 0.00015 ether;
    uint256 private constant LISTING_FEE = 0.001 ether;
    address private constant GOVERNANCE = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;

    address payable private constant TREASURY = payable(0x48B49CEf2f6071405D6A62228ADC168a7baB2654);
    IWETH9 private constant WETH = IWETH9(0x61293a735E35d76E8980Bf17715b37A0C4196512);
    ArchStockRegistry private constant STOCK_REGISTRY = ArchStockRegistry(0xADB4b0D5908C179C97ce5A5b2879Ba3E8497Bd64);
    IUniswapV2Router02 private constant V2_ROUTER = IUniswapV2Router02(0x42F1CF708A3DB2D4f3fF59FE400a8e4530662880);
    ISwapRouter private constant V2_SWAP_ROUTER = ISwapRouter(0xb8525F9F98480d0A0f54A834f0A8d407D8CED3F2);
    ArchLiquidityLocker private constant V2_LOCKER = ArchLiquidityLocker(0xb92D2c218bBb51C0F21fc12a6141596EafD98Def);

    struct Deployment {
        ArchV2LaunchLiquidityAdapter adapter;
        ArchUserLiquidityProvisioner provisioner;
        ArchAdapterTokenFactory tokenFactory;
        ArchAdapterPresaleDeployer presaleDeployer;
        ArchAdapterCurveDeployer curveDeployer;
        ArchAdapterLaunchpad launchpad;
    }

    function run() external {
        require(block.chainid == 46630, "v2 liquidity: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(privateKey) == GOVERNANCE, "v2 liquidity: wrong signer");
        _validateDependencies();

        vm.startBroadcast(privateKey);
        Deployment memory deployed = _deploy();
        vm.stopBroadcast();

        _validateDeployment(deployed);
        console2.log("== ArchLiquid V2 user-liquidity family ==");
        console2.log("LiquidityAdapter", address(deployed.adapter));
        console2.log("LiquidityProvisioner", address(deployed.provisioner));
        console2.log("TokenFactory", address(deployed.tokenFactory));
        console2.log("PresaleDeployer", address(deployed.presaleDeployer));
        console2.log("CurveDeployer", address(deployed.curveDeployer));
        console2.log("Launchpad", address(deployed.launchpad));
    }

    function _deploy() private returns (Deployment memory deployed) {
        deployed.adapter = new ArchV2LaunchLiquidityAdapter(V2_ROUTER, V2_LOCKER, GOVERNANCE);
        deployed.provisioner = new ArchUserLiquidityProvisioner(deployed.adapter);
        deployed.adapter.bindLiquidityProvisioner(address(deployed.provisioner));

        deployed.tokenFactory = new ArchAdapterTokenFactory(
            FACTORY_FEE, TREASURY, GOVERNANCE, deployed.adapter, V2_SWAP_ROUTER, WETH, 0, 0, STOCK_REGISTRY
        );
        deployed.presaleDeployer = new ArchAdapterPresaleDeployer();
        deployed.curveDeployer = new ArchAdapterCurveDeployer();
        deployed.launchpad = new ArchAdapterLaunchpad(
            LISTING_FEE,
            TREASURY,
            deployed.adapter,
            V2_SWAP_ROUTER,
            WETH,
            0,
            0,
            GOVERNANCE,
            STOCK_REGISTRY,
            deployed.presaleDeployer,
            deployed.curveDeployer
        );
        deployed.presaleDeployer.setLaunchpad(address(deployed.launchpad));
        deployed.curveDeployer.setLaunchpad(address(deployed.launchpad));
        deployed.adapter.bindLaunchers(address(deployed.tokenFactory), IArchLaunchRegistry(address(deployed.launchpad)));
        V2_LOCKER.setFeeExempt(address(deployed.adapter), true);
    }

    function _validateDependencies() private view {
        require(TREASURY.code.length > 0, "v2 liquidity: treasury missing");
        require(address(WETH).code.length > 0, "v2 liquidity: weth missing");
        require(address(STOCK_REGISTRY).code.length > 0, "v2 liquidity: registry missing");
        require(address(V2_ROUTER).code.length > 0, "v2 liquidity: router missing");
        require(address(V2_SWAP_ROUTER).code.length > 0, "v2 liquidity: swap adapter missing");
        require(address(V2_LOCKER).code.length > 0, "v2 liquidity: locker missing");
        require(V2_LOCKER.owner() == GOVERNANCE, "v2 liquidity: locker owner");
        require(V2_ROUTER.WETH() == address(WETH), "v2 liquidity: router weth");
        require(address(V2_LOCKER.FACTORY()) == V2_ROUTER.factory(), "v2 liquidity: factory mismatch");
    }

    function _validateDeployment(Deployment memory deployed) private view {
        require(deployed.adapter.launchersBound(), "v2 liquidity: launchers not frozen");
        require(
            deployed.adapter.liquidityProvisioner() == address(deployed.provisioner),
            "v2 liquidity: provisioner mismatch"
        );
        require(deployed.adapter.tokenFactory() == address(deployed.tokenFactory), "v2 liquidity: factory binding");
        require(address(deployed.adapter.launchpad()) == address(deployed.launchpad), "v2 liquidity: launch binding");
        require(
            address(deployed.tokenFactory.LIQUIDITY_ADAPTER()) == address(deployed.adapter),
            "v2 liquidity: token adapter"
        );
        require(
            address(deployed.launchpad.LIQUIDITY_ADAPTER()) == address(deployed.adapter), "v2 liquidity: launch adapter"
        );
        require(deployed.tokenFactory.tokenCount() == 0, "v2 liquidity: factory not fresh");
        require(deployed.launchpad.presaleCount() == 0, "v2 liquidity: presales not fresh");
        require(deployed.launchpad.curveCount() == 0, "v2 liquidity: curves not fresh");
        require(V2_LOCKER.feeExempt(address(deployed.adapter)), "v2 liquidity: locker fee exemption");
    }
}
