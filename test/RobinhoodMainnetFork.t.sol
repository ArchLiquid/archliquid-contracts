// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStockSwapExecutor} from "@archliquid/core/ArchStockSwapExecutor.sol";
import {INonfungiblePositionManager, ISwapRouter, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {MockERC20} from "./mocks/Mocks.sol";

interface IRobinhoodV3PeripheryState {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface IRobinhoodSwapRouterState is IRobinhoodV3PeripheryState {
    function positionManager() external view returns (address);
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

    bool internal forkEnabled;

    function setUp() public {
        string memory rpc = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forkEnabled = true;
    }

    function test_productionPeripheryWiring() public view {
        if (!forkEnabled) return;

        assertEq(IRobinhoodV3PeripheryState(NFPM).factory(), V3_FACTORY);
        assertEq(IRobinhoodV3PeripheryState(NFPM).WETH9(), WETH);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).factory(), V3_FACTORY);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).positionManager(), NFPM);
        assertEq(IRobinhoodSwapRouterState(SWAP_ROUTER).WETH9(), WETH);
    }

    function test_swapRouter02SevenFieldExactInputSingleExecutes() public {
        if (!forkEnabled) return;

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
        if (!forkEnabled) return;

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
        if (!forkEnabled) return;

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
        if (!forkEnabled) return;

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
}
