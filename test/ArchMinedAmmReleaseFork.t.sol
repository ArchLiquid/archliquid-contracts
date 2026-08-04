// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchAdapterBondingCurve} from "@archliquid/launchpad/ArchAdapterBondingCurve.sol";
import {ArchAdapterLaunchpad} from "@archliquid/launchpad/ArchAdapterLaunchpad.sol";
import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV4PositionManager} from "@archliquid/lockers/interfaces/IUniswapV4.sol";

/// @notice Post-deployment lifecycle checks against the exact contracts in the
///         signed Robinhood testnet AMM module manifest. Run with --fork-url.
///         Every state change is confined to the local fork.
contract ArchMinedAmmReleaseForkTest is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant GOVERNANCE = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    address private constant WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;
    address private constant STOCK = 0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE;

    uint256 private constant FACTORY_FEE = 0.00015 ether;
    uint256 private constant LISTING_FEE = 0.001 ether;
    uint256 private constant SUPPLY = 1_000_000e18;
    uint24 private constant V4_FEE = 3000;

    IUniswapV2Factory private constant V2_FACTORY = IUniswapV2Factory(0x3d51588C41586Bc391A989156fBE6a7ceEd51446);
    ArchLiquidityLocker private constant V2_LOCKER = ArchLiquidityLocker(0xb92D2c218bBb51C0F21fc12a6141596EafD98Def);
    ISwapRouter private constant V2_SWAP = ISwapRouter(0xb8525F9F98480d0A0f54A834f0A8d407D8CED3F2);
    ArchAdapterTokenFactory private constant V2_TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0x692Ae18590AdEbd3Fd1A0daBa6F7dB44F772b8bd));
    ArchAdapterLaunchpad private constant V2_LAUNCHPAD =
        ArchAdapterLaunchpad(0x911106D9c52b854bFF327446180C95f552e72cCd);

    IUniswapV4PositionManager private constant V4_POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    ArchV4PositionLocker private constant V4_LOCKER = ArchV4PositionLocker(0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98);
    ISwapRouter private constant V4_SWAP = ISwapRouter(0xa4C298f17d051634f59Dd37FEE05D4892a8153Ea);
    ArchAdapterTokenFactory private constant V4_TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0xFf575Bc8DFE5Dd34c17814f71D091F1692e531AF));
    ArchAdapterLaunchpad private constant V4_LAUNCHPAD =
        ArchAdapterLaunchpad(0x94eEec9B20cDE4C58E7F982A863e913977AD73Ed);

    address private creator = makeAddr("mined-release-creator");
    address private trader = makeAddr("mined-release-trader");
    bool private liveFork;

    function setUp() public {
        liveFork = address(V2_TOKEN_FACTORY).code.length > 0 && address(V4_TOKEN_FACTORY).code.length > 0;
        if (!liveFork) return;

        vm.deal(creator, 20 ether);
        vm.deal(trader, 20 ether);
    }

    function test_minedV2FactoryCreatesTradesDistributesAndWithdraws() public {
        if (!liveFork) return;

        uint256 lockId = V2_LOCKER.lockCount();
        ArchToken token = _createFactoryToken(V2_TOKEN_FACTORY, 0, "Mined V2 Factory", "MV2F");
        address pair = V2_FACTORY.getPair(address(token), WETH);

        assertTrue(pair != address(0));
        assertTrue(V2_LOCKER.isCanonicalPair(pair));
        assertTrue(token.isMarketPair(pair));

        ArchLiquidityLocker.Lock memory created = V2_LOCKER.getLock(lockId);
        assertEq(created.token, pair);
        assertEq(created.owner, creator);
        assertGt(created.amount, 0);
        assertEq(IERC20(pair).balanceOf(address(V2_LOCKER)), created.amount);

        _tradeAndDistribute(token, V2_SWAP, 0);

        vm.warp(created.unlockTime);
        vm.prank(creator);
        V2_LOCKER.withdraw(lockId);
        assertEq(IERC20(pair).balanceOf(creator), created.amount);
    }

    function test_minedV4FactoryCreatesTradesCollectsAndWithdraws() public {
        if (!liveFork) return;

        uint256 lockId = V4_LOCKER.lockCount();
        ArchToken token = _createFactoryToken(V4_TOKEN_FACTORY, V4_FEE, "Mined V4 Factory", "MV4F");
        ArchV4PositionLocker.Lock memory created = V4_LOCKER.getLock(lockId);

        assertEq(created.owner, creator);
        assertEq(created.hooks, address(0));
        assertEq(V4_POSITION_MANAGER.ownerOf(created.tokenId), address(V4_LOCKER));
        assertTrue(token.isMarketPair(V4_POSITION_MANAGER.poolManager()));

        _tradeAndDistribute(token, V4_SWAP, V4_FEE);

        uint128 liquidityBefore = V4_POSITION_MANAGER.getPositionLiquidity(created.tokenId);
        vm.prank(creator);
        V4_LOCKER.collectFees(lockId, creator, "");
        assertEq(V4_POSITION_MANAGER.getPositionLiquidity(created.tokenId), liquidityBefore);

        vm.warp(created.unlockTime);
        vm.prank(creator);
        V4_LOCKER.withdraw(lockId);
        assertEq(V4_POSITION_MANAGER.ownerOf(created.tokenId), creator);
    }

    function test_minedV2LaunchpadCreatesAndGraduatesCurve() public {
        if (!liveFork) return;

        ArchAdapterBondingCurve curve = _createCurve(V2_LAUNCHPAD, 0, "Mined V2 Curve", "MV2C");
        vm.prank(trader);
        curve.buy{value: curve.graduationBuyAmount()}(0);

        address pair = V2_FACTORY.getPair(address(curve.token()), WETH);
        assertTrue(curve.graduated());
        assertEq(curve.pair(), pair);
        assertTrue(curve.token().isMarketPair(pair));
        assertGt(IERC20(pair).balanceOf(DEAD), 0);
    }

    function test_minedV4LaunchpadCreatesAndGraduatesCurve() public {
        if (!liveFork) return;

        uint256 positionId = V4_POSITION_MANAGER.nextTokenId();
        ArchAdapterBondingCurve curve = _createCurve(V4_LAUNCHPAD, V4_FEE, "Mined V4 Curve", "MV4C");
        vm.prank(trader);
        curve.buy{value: curve.graduationBuyAmount()}(0);

        assertTrue(curve.graduated());
        assertEq(curve.pair(), V4_POSITION_MANAGER.poolManager());
        assertTrue(curve.token().isMarketPair(V4_POSITION_MANAGER.poolManager()));
        assertEq(V4_POSITION_MANAGER.ownerOf(positionId), DEAD);
        assertGt(V4_POSITION_MANAGER.getPositionLiquidity(positionId), 0);
    }

    function _createFactoryToken(
        ArchAdapterTokenFactory factory,
        uint24 poolFee,
        string memory name,
        string memory symbol
    ) private returns (ArchToken token) {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: name, symbol: symbol, totalSupply: SUPPLY, taxBps: 300, stock: IERC20(STOCK), creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory liquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: true, lpPct: 50, poolFee: poolFee, burnLp: false, lockDuration: 180 days
        });

        vm.prank(creator);
        token = ArchToken(payable(factory.createToken{value: FACTORY_FEE + 2 ether}(tokenParams, liquidity)));
        assertTrue(token.wired());
        assertEq(token.TAX_BPS(), 300);
        assertEq(address(token.STOCK()), STOCK);
        assertEq(token.balanceOf(creator), SUPPLY / 2);
    }

    function _createCurve(ArchAdapterLaunchpad launchpad, uint24 poolFee, string memory name, string memory symbol)
        private
        returns (ArchAdapterBondingCurve curve)
    {
        ArchAdapterBondingCurve.TokenConfig memory tokenConfig = ArchAdapterBondingCurve.TokenConfig({
            name: name, symbol: symbol, totalSupply: SUPPLY, taxBps: 300, stock: IERC20(STOCK), creatorFeeBps: 0
        });
        ArchAdapterBondingCurve.CurveConfig memory curveConfig = ArchAdapterBondingCurve.CurveConfig({
            curvePct: 80, virtualEth: 1 ether, gradEth: 0.99 ether, poolFee: poolFee
        });

        vm.prank(creator);
        curve = ArchAdapterBondingCurve(payable(launchpad.createCurve{value: LISTING_FEE}(tokenConfig, curveConfig)));
        assertTrue(launchpad.isLaunch(address(curve)));
        assertEq(curve.graduationBuyAmount(), 1 ether);
    }

    function _tradeAndDistribute(ArchToken token, ISwapRouter router, uint24 poolFee) private {
        vm.startPrank(trader);
        IWETH9(WETH).deposit{value: 0.1 ether}();
        IERC20(WETH).approve(address(router), type(uint256).max);
        uint256 bought = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: address(token),
                fee: poolFee,
                recipient: trader,
                amountIn: 0.1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        assertEq(token.balanceOf(trader), bought);

        token.approve(address(router), type(uint256).max);
        uint256 wethOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: WETH,
                fee: poolFee,
                recipient: trader,
                amountIn: bought / 2,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        assertGt(wethOut, 0);
        assertGt(token.balanceOf(address(token)), 0);

        vm.prank(GOVERNANCE);
        token.processDistribution(1, 1);
        assertGt(token.totalDistributed(), 0);
        uint256 creatorClaimable = token.withdrawableDividendOf(creator);
        assertGt(creatorClaimable, 0);
        uint256 creatorStockBefore = IERC20(STOCK).balanceOf(creator);
        vm.prank(creator);
        token.claim();
        assertEq(IERC20(STOCK).balanceOf(creator) - creatorStockBefore, creatorClaimable);
    }
}
