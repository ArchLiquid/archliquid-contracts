// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresale} from "@archliquid/launchpad/ArchPresale.sol";
import {ArchPresaleDeployer} from "@archliquid/launchpad/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "@archliquid/launchpad/ArchCurveDeployer.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchStakingPool} from "@archliquid/staking/ArchStakingPool.sol";
import {MockERC20, MockFeeToken, MockNFPM, MockV3Router, MockWETH} from "./mocks/Mocks.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";

/// @notice Characterization tests for accepted configurations that need a
///         launch policy or an implementation guard before production use.
contract ArchSafetyEdgeCasesTest is Test {
    uint256 private constant LISTING_FEE = 0.1 ether;
    uint256 private constant DURATION = 30 days;

    function test_QA_extremePresaleConfigRejectedBeforeContributions() public {
        ArchTreasury treasury = new ArchTreasury(address(this));
        ArchV3PositionLocker locker = new ArchV3PositionLocker(0, payable(address(treasury)), address(this));
        ArchStockRegistry registry = new ArchStockRegistry(address(this));
        MockERC20 stock = new MockERC20("Stock", "STOCK");
        registry.setApproved(address(stock), true);

        MockNFPM nfpm = new MockNFPM();
        MockV3Router router = new MockV3Router();
        MockWETH weth = new MockWETH();
        registry.setStockSwapExecutor(address(router));
        ArchPresaleDeployer presaleDeployer = new ArchPresaleDeployer();
        ArchCurveDeployer curveDeployer = new ArchCurveDeployer();
        ArchLaunchpad launchpad = new ArchLaunchpad(
            LISTING_FEE,
            payable(address(treasury)),
            locker,
            INonfungiblePositionManager(address(nfpm)),
            ISwapRouter(address(router)),
            IWETH9(address(weth)),
            3000,
            makeAddr("keeper"),
            registry,
            presaleDeployer,
            curveDeployer
        );
        presaleDeployer.setLaunchpad(address(launchpad));
        curveDeployer.setLaunchpad(address(launchpad));
        locker.setFactory(address(launchpad), true);

        uint64 start = uint64(block.timestamp + 1);
        uint64 end = uint64(block.timestamp + 2 days);
        ArchPresale.TokenConfig memory tokenConfig = ArchPresale.TokenConfig({
            name: "Extreme",
            symbol: "X",
            totalSupply: 1e58,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchPresale.SaleConfig memory saleConfig = ArchPresale.SaleConfig({
            softCap: 1,
            hardCap: 1,
            start: start,
            end: end,
            perWalletCap: 0,
            salePct: 50,
            lpPct: 40,
            poolFee: 3000,
            lpLockDuration: 365 days,
            teamCliff: end,
            teamEnd: end + 365 days
        });

        address creator = makeAddr("creator");
        vm.deal(creator, LISTING_FEE);
        vm.prank(creator);
        vm.expectRevert();
        launchpad.createPresale{value: LISTING_FEE}(tokenConfig, saleConfig);
        assertEq(launchpad.presaleCount(), 0);
        assertEq(address(treasury).balance, 0);
    }

    function test_QA_sameFeeTokenRewardsPreserveStakeSolvency() public {
        ArchTreasury treasury = new ArchTreasury(address(this));
        MockFeeToken token = new MockFeeToken();
        address operator = makeAddr("operator");
        address staker = makeAddr("staker");
        ArchStakingPool pool = new ArchStakingPool(
            operator, IERC20(address(token)), IERC20(address(token)), payable(address(treasury)), 200, DURATION, 0
        );

        token.mint(staker, 1_000e18);
        token.mint(operator, 1_000e18);
        vm.prank(staker);
        token.approve(address(pool), type(uint256).max);
        vm.prank(operator);
        token.approve(address(pool), type(uint256).max);

        vm.prank(staker);
        pool.stake(1_000e18);
        assertEq(pool.balanceOf(staker), 990e18);

        vm.prank(operator);
        pool.notifyRewardAmount(1_000e18);
        vm.warp(block.timestamp + DURATION);

        vm.prank(staker);
        pool.getReward();
        vm.prank(staker);
        pool.withdraw(990e18);
        assertEq(pool.balanceOf(staker), 0);
        assertEq(pool.totalSupply(), 0);
    }
}
