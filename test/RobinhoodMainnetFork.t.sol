// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {IUniswapV2Factory as LockerV2Factory} from "@archliquid/lockers/interfaces/IUniswapV2.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "@archliquid/launchpad/interfaces/IUniswapV2.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {IUniswapV4PositionManager, PoolKey} from "@archliquid/launchpad/interfaces/IUniswapV4.sol";
import {MockERC20} from "./mocks/Mocks.sol";

interface IRobinhoodV3PeripheryState {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface IRobinhoodSwapRouterState is IRobinhoodV3PeripheryState {
    function positionManager() external view returns (address);
}

interface IRobinhoodV2RouterState {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IRobinhoodV4StateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IRobinhoodPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IRobinhoodV4Writer {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24 tick);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IRobinhoodNFPMIncrease {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @dev Opt-in fork checks for the production Robinhood V3 deployment. Run with:
///      RH_MAINNET_RPC_URL=<rpc> forge test --match-contract RobinhoodMainnetForkTest
///      --evm-version cancun -vv
contract RobinhoodMainnetForkTest is Test {
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant NFPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    address internal constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address internal constant V2_WETH_USDG_PAIR = 0x8803c117ccae7B5146297876c2A25DF135141C4d;

    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant V4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 internal constant V4_SQRT_LOWER_X96 = 4306310044;
    uint160 internal constant V4_SQRT_UPPER_X96 = 1457652066949847389937902910258958406565750968363;

    bool internal forkEnabled;

    function setUp() public {
        if (block.chainid == 4663) {
            forkEnabled = true;
            return;
        }
        string memory rpc = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "RH_MAINNET_RPC_URL is required");
        vm.createSelectFork(rpc);
        forkEnabled = true;
    }

    function test_productionPeripheryWiring() public view {
        assertEq(IRobinhoodV3PeripheryState(NFPM).factory(), V3_FACTORY);
        assertEq(IRobinhoodV3PeripheryState(NFPM).WETH9(), WETH);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).factory(), V3_FACTORY);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).positionManager(), NFPM);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).WETH9(), WETH);
    }

    /// @dev This is a live V2-compatible deployment observed on Robinhood. It
    ///      is not included in Uniswap's official Robinhood address registry.
    function test_observedThirdPartyV2DeploymentAndLiveWethUsdgPair() public view {
        assertGt(V2_FACTORY.code.length, 0);
        assertGt(V2_ROUTER.code.length, 0);
        assertEq(IRobinhoodV2RouterState(V2_ROUTER).factory(), V2_FACTORY);
        assertEq(IRobinhoodV2RouterState(V2_ROUTER).WETH(), WETH);
        assertGt(IUniswapV2Factory(V2_FACTORY).allPairsLength(), 29_000);

        address pair = IUniswapV2Factory(V2_FACTORY).getPair(WETH, USDG);
        assertEq(pair, V2_WETH_USDG_PAIR);
        assertGt(pair.code.length, 0);
        assertEq(IUniswapV2Pair(pair).factory(), V2_FACTORY);
        assertEq(IUniswapV2Pair(pair).token0(), WETH);
        assertEq(IUniswapV2Pair(pair).token1(), USDG);
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        assertGt(reserve0, 0);
        assertGt(reserve1, 0);
        assertGt(IUniswapV2Pair(pair).totalSupply(), 0);
    }

    function test_v2LockerCustodiesObservedLivePairToken() public {
        ArchLiquidityLocker locker =
            new ArchLiquidityLocker(0, payable(address(0xBEEF)), LockerV2Factory(V2_FACTORY), address(this));
        deal(V2_WETH_USDG_PAIR, address(this), 1e12);
        IERC20(V2_WETH_USDG_PAIR).approve(address(locker), 1e12);
        uint256 id = locker.lock(IERC20(V2_WETH_USDG_PAIR), 1e12, uint64(block.timestamp + 30 days), address(this));

        assertEq(locker.getLock(id).token, V2_WETH_USDG_PAIR);
        assertEq(locker.getLock(id).amount, 1e12);
        assertEq(IERC20(V2_WETH_USDG_PAIR).balanceOf(address(locker)), 1e12);
    }

    function test_v4DeploymentWiringAndLivePositionState() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0);
        assertGt(V4_POSITION_MANAGER.code.length, 0);
        assertGt(V4_QUOTER.code.length, 0);
        assertGt(V4_STATE_VIEW.code.length, 0);
        assertGt(V4_UNIVERSAL_ROUTER.code.length, 0);

        IUniswapV4PositionManager manager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        assertEq(manager.poolManager(), V4_POOL_MANAGER);
        assertGt(manager.nextTokenId(), 0);
        (uint256 tokenId, PoolKey memory key, uint128 liquidity) = _latestLiveV4Position(manager);
        assertNotEq(manager.ownerOf(tokenId), address(0));
        assertNotEq(key.currency0, key.currency1);
        assertGt(liquidity, 0);

        (uint160 sqrtPriceX96,,,) = IRobinhoodV4StateView(V4_STATE_VIEW).getSlot0(keccak256(abi.encode(key)));
        assertGt(sqrtPriceX96, 0);
    }

    function test_v4OfficialPositionManagerMintsAndIncreasesWithExplicitLiquidityOnFork() public {
        MockERC20 localToken = new MockERC20("Fork V4 Token", "FV4");
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.03 ether}();
        localToken.mint(address(this), 0.03 ether);

        (address currency0, address currency1) =
            address(localToken) < WETH ? (address(localToken), WETH) : (WETH, address(localToken));
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: address(0)});
        uint128 amountMax = 0.01 ether;
        uint256 liquidity = _fullRangeLiquidity(uint160(1 << 96), amountMax, amountMax);
        uint256 tokenId = IUniswapV4PositionManager(V4_POSITION_MANAGER).nextTokenId();

        IERC20(currency0).approve(PERMIT2, amountMax);
        IERC20(currency1).approve(PERMIT2, amountMax);
        IRobinhoodPermit2(PERMIT2)
            .approve(currency0, V4_POSITION_MANAGER, amountMax, uint48(block.timestamp + 20 minutes));
        IRobinhoodPermit2(PERMIT2)
            .approve(currency1, V4_POSITION_MANAGER, amountMax, uint48(block.timestamp + 20 minutes));

        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] =
            abi.encode(key, int24(-887220), int24(887220), liquidity, amountMax, amountMax, address(this), bytes(""));
        mintParams[1] = abi.encode(currency0, currency1);
        bytes memory unlockData = abi.encode(abi.encodePacked(uint8(0x02), uint8(0x0d)), mintParams);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IRobinhoodV4Writer.initializePool, (key, uint160(1 << 96)));
        calls[1] = abi.encodeCall(IRobinhoodV4Writer.modifyLiquidities, (unlockData, block.timestamp));
        IRobinhoodV4Writer(V4_POSITION_MANAGER).multicall(calls);

        IUniswapV4PositionManager manager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        assertEq(manager.ownerOf(tokenId), address(this));
        assertEq(manager.getPositionLiquidity(tokenId), liquidity);
        (uint160 remaining0, uint48 expiry0,) =
            IRobinhoodPermit2(PERMIT2).allowance(address(this), currency0, V4_POSITION_MANAGER);
        (uint160 remaining1, uint48 expiry1,) =
            IRobinhoodPermit2(PERMIT2).allowance(address(this), currency1, V4_POSITION_MANAGER);
        assertLt(remaining0, amountMax);
        assertLt(remaining1, amountMax);
        assertEq(expiry0, uint48(block.timestamp + 20 minutes));
        assertEq(expiry1, uint48(block.timestamp + 20 minutes));

        // Mirrors the UI's explicit reset/replace approval sequence before a
        // second action; no unlimited ERC-20 or Permit2 authority is granted.
        IERC20(currency0).approve(PERMIT2, 0);
        IERC20(currency1).approve(PERMIT2, 0);
        IERC20(currency0).approve(PERMIT2, amountMax);
        IERC20(currency1).approve(PERMIT2, amountMax);
        IRobinhoodPermit2(PERMIT2)
            .approve(currency0, V4_POSITION_MANAGER, amountMax, uint48(block.timestamp + 20 minutes));
        IRobinhoodPermit2(PERMIT2)
            .approve(currency1, V4_POSITION_MANAGER, amountMax, uint48(block.timestamp + 20 minutes));

        uint256 minimumAddedLiquidity = liquidity * 9950 / 10_000;
        bytes[] memory increaseParams = new bytes[](2);
        increaseParams[0] = abi.encode(tokenId, minimumAddedLiquidity, amountMax, amountMax, bytes(""));
        increaseParams[1] = abi.encode(currency0, currency1);
        bytes memory increaseData = abi.encode(abi.encodePacked(uint8(0x00), uint8(0x0d)), increaseParams);
        IRobinhoodV4Writer(V4_POSITION_MANAGER).modifyLiquidities(increaseData, block.timestamp);

        assertEq(manager.ownerOf(tokenId), address(this));
        assertEq(manager.getPositionLiquidity(tokenId), liquidity + minimumAddedLiquidity);
    }

    function _fullRangeLiquidity(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256)
    {
        uint256 intermediate = Math.mulDiv(sqrtPriceX96, V4_SQRT_UPPER_X96, 1 << 96);
        uint256 liquidity0 = Math.mulDiv(amount0, intermediate, V4_SQRT_UPPER_X96 - sqrtPriceX96);
        uint256 liquidity1 = Math.mulDiv(amount1, 1 << 96, sqrtPriceX96 - V4_SQRT_LOWER_X96);
        return Math.min(liquidity0, liquidity1);
    }

    /// @dev V4 position IDs can be burned shortly after minting. Select a
    ///      currently owned, nonzero-liquidity position from the bounded live
    ///      head instead of pinning a token that can disappear between runs.
    function _latestLiveV4Position(IUniswapV4PositionManager manager)
        internal
        view
        returns (uint256 tokenId, PoolKey memory key, uint128 liquidity)
    {
        uint256 nextId = manager.nextTokenId();
        uint256 attempts = nextId > 64 ? 64 : nextId;
        for (uint256 offset = 1; offset <= attempts; ++offset) {
            uint256 candidate = nextId - offset;
            try manager.ownerOf(candidate) returns (address currentOwner) {
                if (currentOwner == address(0)) continue;
                try manager.getPositionLiquidity(candidate) returns (uint128 candidateLiquidity) {
                    if (candidateLiquidity == 0) continue;
                    (PoolKey memory candidateKey,) = manager.getPoolAndPositionInfo(candidate);
                    return (candidate, candidateKey, candidateLiquidity);
                } catch {}
            } catch {}
        }
        revert("fork: no live V4 position near head");
    }

    function test_swapRouter02SevenFieldExactInputSingleExecutes() public {
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.001 ether}();
        IWETH9(WETH).approve(SWAP_ROUTER, 0.001 ether);

        uint256 usdgBefore = IERC20(USDG).balanceOf(address(this));
        uint256 amountOut = ISwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDG,
                fee: 100,
                recipient: address(this),
                amountIn: 0.001 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
            );

        assertGt(amountOut, 0);
        assertEq(IERC20(USDG).balanceOf(address(this)) - usdgBefore, amountOut);
    }

    function test_constrainedExecutorExecutesAgainstLiveLiquidity() public {
        ArchStockSwapExecutor executor = new ArchStockSwapExecutor(IERC20(WETH), SWAP_ROUTER);
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.001 ether}();
        IWETH9(WETH).approve(address(executor), 0.001 ether);

        bytes memory data = abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDG,
                    fee: 100,
                    recipient: address(executor),
                    amountIn: 0.001 ether,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                }))
        );

        uint256 usdgBefore = IERC20(USDG).balanceOf(address(this));
        uint256 amountOut = executor.swapExactWethForStock(USDG, 0.001 ether, 1, data);

        assertGt(amountOut, 0);
        assertEq(IERC20(USDG).balanceOf(address(this)) - usdgBefore, amountOut);
        assertEq(IERC20(WETH).allowance(address(executor), SWAP_ROUTER), 0);
    }

    function test_constrainedExecutorBuysLiveStockThroughWethUsdgRoute() public {
        ArchStockSwapExecutor executor = new ArchStockSwapExecutor(IERC20(WETH), SWAP_ROUTER);
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.001 ether}();
        IWETH9(WETH).approve(address(executor), 0.001 ether);

        bytes memory data = abi.encodeCall(
            ISwapRouter.exactInput,
            (ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(WETH, uint24(100), USDG, uint24(10000), AAPL),
                    recipient: address(executor),
                    amountIn: 0.001 ether,
                    amountOutMinimum: 1
                }))
        );

        uint256 stockBefore = IERC20(AAPL).balanceOf(address(this));
        uint256 amountOut = executor.swapExactWethForStock(AAPL, 0.001 ether, 1, data);

        assertGt(amountOut, 0);
        assertEq(IERC20(AAPL).balanceOf(address(this)) - stockBefore, amountOut);
    }

    function test_nfpmCreatesPoolAndMintsPositionOnFork() public {
        MockERC20 localToken = new MockERC20("Fork Token", "FORK");
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        localToken.mint(address(this), 0.01 ether);

        (address token0, address token1) =
            address(localToken) < WETH ? (address(localToken), WETH) : (WETH, address(localToken));
        address pool = INonfungiblePositionManager(NFPM)
            .createAndInitializePoolIfNecessary(token0, token1, 3000, uint160(1 << 96));

        IERC20(token0).approve(NFPM, 0.01 ether);
        IERC20(token1).approve(NFPM, 0.01 ether);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(NFPM)
            .mint(
                INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 0.01 ether,
                amount1Desired: 0.01 ether,
                amount0Min: 1,
                amount1Min: 1,
                recipient: address(this),
                deadline: block.timestamp
            })
            );

        assertGt(pool.code.length, 0);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(tokenId), address(this));
    }

    function test_nfpmAddsLiquidityToExistingPositionOnFork() public {
        MockERC20 localToken = new MockERC20("Fork Increase Token", "FINC");
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.03 ether}();
        localToken.mint(address(this), 0.03 ether);

        (address token0, address token1) =
            address(localToken) < WETH ? (address(localToken), WETH) : (WETH, address(localToken));
        INonfungiblePositionManager manager = INonfungiblePositionManager(NFPM);
        manager.createAndInitializePoolIfNecessary(token0, token1, 3000, uint160(1 << 96));
        IERC20(token0).approve(NFPM, type(uint256).max);
        IERC20(token1).approve(NFPM, type(uint256).max);

        (uint256 tokenId, uint128 initialLiquidity,,) = manager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 0.01 ether,
                amount1Desired: 0.01 ether,
                amount0Min: 0.0099 ether,
                amount1Min: 0.0099 ether,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        (uint128 addedLiquidity, uint256 amount0, uint256 amount1) = IRobinhoodNFPMIncrease(NFPM)
            .increaseLiquidity(
                IRobinhoodNFPMIncrease.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 0.01 ether,
                amount1Desired: 0.01 ether,
                amount0Min: 0.0099 ether,
                amount1Min: 0.0099 ether,
                deadline: block.timestamp
            })
            );

        (,,,,,,, uint128 finalLiquidity,,,,) = manager.positions(tokenId);
        assertGt(addedLiquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(finalLiquidity, initialLiquidity + addedLiquidity);
        assertEq(manager.ownerOf(tokenId), address(this));
    }

    function test_nfpmIncreaseLiquidityHonorsMinimumsOnFork() public {
        MockERC20 localToken = new MockERC20("Fork Slippage Token", "FSLP");
        vm.deal(address(this), 1 ether);
        IWETH9(WETH).deposit{value: 0.02 ether}();
        localToken.mint(address(this), 0.02 ether);

        (address token0, address token1) =
            address(localToken) < WETH ? (address(localToken), WETH) : (WETH, address(localToken));
        INonfungiblePositionManager manager = INonfungiblePositionManager(NFPM);
        manager.createAndInitializePoolIfNecessary(token0, token1, 3000, uint160(1 << 96));
        IERC20(token0).approve(NFPM, type(uint256).max);
        IERC20(token1).approve(NFPM, type(uint256).max);
        (uint256 tokenId,,,) = manager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 0.01 ether,
                amount1Desired: 0.01 ether,
                amount0Min: 1,
                amount1Min: 1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        vm.expectRevert();
        IRobinhoodNFPMIncrease(NFPM)
            .increaseLiquidity(
                IRobinhoodNFPMIncrease.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 0.001 ether,
                amount1Desired: 0.001 ether,
                amount0Min: 0.002 ether,
                amount1Min: 0.002 ether,
                deadline: block.timestamp
            })
            );
    }
}
