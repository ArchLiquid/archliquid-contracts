// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchTreasury} from "@archliquid/core/ArchTreasury.sol";
import {ArchV3PositionLocker} from "@archliquid/lockers/ArchV3PositionLocker.sol";
import {ArchVesting} from "@archliquid/vesting/ArchVesting.sol";
import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {ArchTokenFactory} from "@archliquid/token/ArchTokenFactory.sol";
import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresaleDeployer} from "@archliquid/launchpad/ArchPresaleDeployer.sol";
import {ArchCurveDeployer} from "@archliquid/launchpad/ArchCurveDeployer.sol";
import {ArchStakingFactory} from "@archliquid/staking/ArchStakingFactory.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchPresale} from "@archliquid/launchpad/ArchPresale.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20, MockAggregator, MockNFPM, MockV3Router, MockWETH} from "./mocks/Mocks.sol";

// lending (Compound v2 fork)
import {ArchLiquidPriceOracle, AggregatorV3Interface} from "@archliquid/lending/ArchLiquidPriceOracle.sol";
import {ArchComptroller} from "@archliquid/lending/ArchComptroller.sol";
import {ArchUnitroller} from "@archliquid/lending/ArchUnitroller.sol";
import {ArchJumpRateModel} from "@archliquid/lending/ArchJumpRateModel.sol";
import {ArchCErc20} from "@archliquid/lending/ArchCErc20.sol";
import {ComptrollerInterface} from "compound/ComptrollerInterface.sol";
import {CToken} from "compound/CToken.sol";
import {InterestRateModel} from "compound/InterestRateModel.sol";
import {PriceOracle} from "compound/PriceOracle.sol";

/// @notice Full-protocol integration. Deploys every ArchLiquid service (core +
///         lending) against mocks and drives cross-service journeys, proving the
///         pieces compose and that fees reach the treasury and reserves. The
///         flagship path is the ecosystem loop: mint an RWA distributor token,
///         trade it, let a holder earn tokenized stock from the tax, then borrow
///         against that same stock in the lending market.
contract ArchIntegrationTest is Test {
    // fees mirror script/DeployProtocol.s.sol
    uint256 constant LOCKER_FEE = 0.02 ether;
    uint256 constant VESTING_FEE = 0.01 ether;
    uint256 constant FACTORY_FEE = 0.015 ether;
    uint256 constant LISTING_FEE = 0.1 ether;
    uint256 constant STAKING_FEE = 0.05 ether;
    uint16 constant REWARD_FEE_BPS = 200;
    uint24 constant FEE_TIER = 3000;

    // core
    ArchTreasury treasury;
    ArchV3PositionLocker locker;
    ArchVesting vesting;
    ArchStockRegistry registry;
    ArchTokenFactory factory;
    ArchLaunchpad launchpad;
    ArchStakingFactory stakingFactory;

    // dex + assets
    MockNFPM nfpm;
    MockV3Router router;
    MockWETH weth;
    MockERC20 stock; // tokenized stock: RWA payout target AND lending collateral
    MockERC20 usdc;

    // lending
    ArchComptroller comptroller;
    ArchLiquidPriceOracle oracle;
    ArchJumpRateModel irm;
    ArchCErc20 cUSDC;
    ArchCErc20 cSTOCK;
    MockAggregator usdcFeed;
    MockAggregator stockFeed;

    address gov = address(this);
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address lender = makeAddr("lender");

    function setUp() public {
        vm.warp(1_000_000); // off genesis for realistic oracle staleness

        // ── dex + assets ──
        nfpm = new MockNFPM();
        router = new MockV3Router();
        router.setNfpm(nfpm); // route swaps to their pools (faithful V3)
        weth = new MockWETH();
        vm.deal(address(weth), 1_000 ether); // back WETH.withdraw()
        stock = new MockERC20("NVIDIA", "NVDAx");
        usdc = new MockERC20("USD Coin", "USDC");

        // ── core services ──
        treasury = new ArchTreasury(gov);
        address payable t = payable(address(treasury));
        locker = new ArchV3PositionLocker(LOCKER_FEE, t, gov);
        vesting = new ArchVesting(VESTING_FEE, t);
        registry = new ArchStockRegistry(gov);
        registry.setApproved(address(stock), true);
        registry.setStockSwapExecutor(address(router));

        INonfungiblePositionManager infpm = INonfungiblePositionManager(address(nfpm));
        ISwapRouter iswap = ISwapRouter(address(router));
        IWETH9 iweth = IWETH9(address(weth));
        factory = new ArchTokenFactory(FACTORY_FEE, t, keeper, infpm, iswap, iweth, FEE_TIER, locker, registry);
        ArchPresaleDeployer pd = new ArchPresaleDeployer();
        ArchCurveDeployer cd = new ArchCurveDeployer();
        launchpad = new ArchLaunchpad(LISTING_FEE, t, locker, infpm, iswap, iweth, FEE_TIER, keeper, registry, pd, cd);
        pd.setLaunchpad(address(launchpad));
        cd.setLaunchpad(address(launchpad));
        stakingFactory = new ArchStakingFactory(STAKING_FEE, t, REWARD_FEE_BPS);
        locker.setFeeExempt(address(factory), true);
        locker.setFactory(address(launchpad), true);

        // ── lending market ──
        ArchUnitroller unitroller = new ArchUnitroller();
        ArchComptroller impl = new ArchComptroller();
        unitroller._setPendingImplementation(address(impl));
        impl._become(unitroller);
        comptroller = ArchComptroller(payable(address(unitroller)));

        oracle = new ArchLiquidPriceOracle(gov);
        comptroller._setPriceOracle(PriceOracle(address(oracle)));
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.08e18);
        irm = new ArchJumpRateModel(0.02e18, 0.1e18, 1e18, 0.8e18, gov);

        cUSDC = new ArchCErc20(
            address(usdc),
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            2e26,
            "ArchLiquid USDC",
            "arUSDC",
            8,
            payable(gov),
            5
        );
        cSTOCK = new ArchCErc20(
            address(stock),
            ComptrollerInterface(address(comptroller)),
            InterestRateModel(address(irm)),
            2e26,
            "ArchLiquid NVDAx",
            "arNVDAx",
            8,
            payable(gov),
            5
        );
        comptroller._supportMarket(cUSDC);
        comptroller._supportMarket(cSTOCK);

        usdcFeed = new MockAggregator(8, 1e8);
        stockFeed = new MockAggregator(8, 100e8);
        usdcFeed.setAnswer(1e8, block.timestamp);
        stockFeed.setAnswer(100e8, block.timestamp);
        oracle.setFeed(address(cUSDC), AggregatorV3Interface(address(usdcFeed)), 1 hours);
        oracle.setFeed(address(cSTOCK), AggregatorV3Interface(address(stockFeed)), 1 hours);
        comptroller._setCollateralFactor(cSTOCK, 0.75e18);
        cUSDC._setReserveFactor(0.15e18);
        cSTOCK._setReserveFactor(0.15e18);

        // ── funding ──
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        usdc.mint(lender, 2_000_000e18);
    }

    /* ── helpers ── */

    function _pool(address token) internal view returns (address) {
        (address a, address b) = token < address(weth) ? (token, address(weth)) : (address(weth), token);
        return nfpm.poolOf(keccak256(abi.encode(a, b, FEE_TIER)));
    }

    function _mkToken(address creator, uint16 taxBps) internal returns (ArchToken token, address pool) {
        vm.prank(creator);
        address addr = factory.createToken{value: FACTORY_FEE + 10 ether}(
            ArchTokenFactory.TokenParams({
                name: "Arch RWA",
                symbol: "ARWA",
                totalSupply: 1_000_000e18,
                taxBps: taxBps,
                stock: IERC20(address(stock)),
                creatorFeeBps: 0
            }),
            ArchTokenFactory.LiquidityParams({
                enabled: true, lpPct: 20, poolFee: FEE_TIER, burnLp: true, lockDuration: 0
            })
        );
        token = ArchToken(payable(addr));
        pool = _pool(addr);
    }

    /* ── composition ── */

    function test_lendingMarketsListedAndPriced() public view {
        (bool listedU,,) = comptroller.markets(address(cUSDC));
        (bool listedS,,) = comptroller.markets(address(cSTOCK));
        assertTrue(listedU && listedS, "markets listed");
        // oracle prices scaled for 18-decimal underlyings (36-18 => 1e18)
        assertEq(oracle.getUnderlyingPrice(CToken(address(cUSDC))), 1e18);
        assertEq(oracle.getUnderlyingPrice(CToken(address(cSTOCK))), 100e18);
    }

    /// @dev The flagship loop across four services: minter -> token tax ->
    ///      RWA distribution -> lending. A holder earns tokenized stock just by
    ///      holding, then borrows against that stock.
    function test_ecosystemLoop_earnStockThenBorrow() public {
        (ArchToken token, address pool) = _mkToken(alice, 300); // 3% tax
        assertEq(token.TAX_BPS(), 300, "immutable trade tax");
        assertEq(address(token.STOCK()), address(stock), "approved stock payout asset");
        assertEq(address(treasury).balance, FACTORY_FEE, "factory fee to treasury");
        assertEq(token.balanceOf(alice), 800_000e18, "creator holds 80%");
        assertTrue(token.isMarketPair(pool), "pool is a taxed pair");

        // alice shares with bob (wallet to wallet, untaxed), then sells into the
        // pool so 3% tax accrues at the token for distribution
        vm.prank(alice);
        assertTrue(token.transfer(bob, 300_000e18));
        vm.prank(alice);
        assertTrue(token.transfer(pool, 100_000e18));
        assertGt(token.balanceOf(address(token)), 0, "tax accrued");

        // keeper distribution: sell the tax for 10 ETH, buy 2000 stock
        router.setNextOut(address(weth), 10 ether);
        router.setNextOut(address(stock), 2_000e18);
        uint256 treBefore = address(treasury).balance;
        vm.prank(keeper);
        token.processDistribution(0, 0);

        assertEq(address(treasury).balance - treBefore, 1 ether, "10% protocol share as ETH");
        assertEq(token.totalDistributed(), 2_000e18, "stock distributed to holders");

        uint256 aliceStock = token.withdrawableDividendOf(alice);
        assertGt(aliceStock, 500e18, "holder earned meaningful stock");
        vm.prank(alice);
        token.claim();
        assertEq(stock.balanceOf(alice), aliceStock, "claimed stock in hand");

        // a lender funds the USDC market
        vm.startPrank(lender);
        usdc.approve(address(cUSDC), type(uint256).max);
        assertEq(cUSDC.mint(1_000_000e18), 0);
        vm.stopPrank();

        // alice supplies her earned stock as collateral and borrows USDC
        vm.startPrank(alice);
        stock.approve(address(cSTOCK), type(uint256).max);
        assertEq(cSTOCK.mint(aliceStock), 0, "supply stock collateral");
        address[] memory markets = new address[](1);
        markets[0] = address(cSTOCK);
        comptroller.enterMarkets(markets);
        // collateral is worth aliceStock * $100 * 75%; borrowing 5k USDC is safe
        assertEq(cUSDC.borrow(5_000e18), 0, "borrow against stock");
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 5_000e18, "received borrowed USDC");

        (uint256 err,, uint256 shortfall) = comptroller.getAccountLiquidity(alice);
        assertEq(err, 0);
        assertEq(shortfall, 0, "position healthy");
    }

    /// @dev A launchpad presale composes end to end: fee to treasury, the token
    ///      deploys via the factory infra, the raise becomes locked V3 liquidity,
    ///      and contributors claim.
    function test_presale_composesEndToEnd() public {
        uint64 start = uint64(block.timestamp + 1);
        uint64 end = uint64(block.timestamp + 1 days);
        ArchPresale.TokenConfig memory tc = ArchPresale.TokenConfig({
            name: "Presale RWA",
            symbol: "PRWA",
            totalSupply: 1_000_000e18,
            taxBps: 300,
            stock: IERC20(address(stock)),
            creatorFeeBps: 0
        });
        ArchPresale.SaleConfig memory sc = ArchPresale.SaleConfig({
            softCap: 5 ether,
            hardCap: 10 ether,
            start: start,
            end: end,
            perWalletCap: 8 ether,
            salePct: 50,
            lpPct: 40,
            poolFee: FEE_TIER,
            lpLockDuration: 365 days,
            teamCliff: end + 90 days,
            teamEnd: end + 365 days
        });

        vm.prank(alice);
        ArchPresale presale = ArchPresale(launchpad.createPresale{value: LISTING_FEE}(tc, sc));
        assertEq(address(treasury).balance, LISTING_FEE, "listing fee to treasury");

        vm.warp(start);
        vm.prank(alice);
        presale.contribute{value: 6 ether}();
        vm.prank(bob);
        presale.contribute{value: 4 ether}();

        presale.finalize();
        assertTrue(presale.finalized(), "finalized");

        ArchToken token = ArchToken(payable(address(presale.token())));
        address pool = presale.pair();
        assertTrue(token.isMarketPair(pool), "launch pool taxed");
        assertGt(token.balanceOf(pool), 0, "liquidity seeded into the pool");

        vm.prank(alice);
        presale.claim();
        assertGt(token.balanceOf(alice), 0, "contributor claimed tokens");
    }

    /// @dev Flat creation fees from three services all land in the treasury.
    function test_flatFeesReachTreasury() public {
        _mkToken(alice, 300); // FACTORY_FEE

        uint64 start = uint64(block.timestamp + 1);
        uint64 end = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        launchpad.createPresale{value: LISTING_FEE}(
            ArchPresale.TokenConfig({
                name: "P",
                symbol: "P",
                totalSupply: 1_000_000e18,
                taxBps: 300,
                stock: IERC20(address(stock)),
                creatorFeeBps: 0
            }),
            ArchPresale.SaleConfig({
                softCap: 5 ether,
                hardCap: 10 ether,
                start: start,
                end: end,
                perWalletCap: 0,
                salePct: 50,
                lpPct: 40,
                poolFee: FEE_TIER,
                lpLockDuration: 365 days,
                teamCliff: end + 90 days,
                teamEnd: end + 365 days
            })
        ); // LISTING_FEE

        vm.prank(alice);
        stakingFactory.createPool{value: STAKING_FEE}(IERC20(address(stock)), IERC20(address(usdc)), 30 days, 0); // STAKING_FEE

        assertEq(address(treasury).balance, FACTORY_FEE + LISTING_FEE + STAKING_FEE, "all flat fees pooled in treasury");
    }
}
