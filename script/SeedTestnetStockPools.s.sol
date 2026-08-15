// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchStockRegistry} from "@archliquid/core/ArchStockRegistry.sol";
import {INonfungiblePositionManager, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";

interface IArchTestnetV3Manager is INonfungiblePositionManager {
    function router() external view returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IArchTestnetV3Pool {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Permanently seeds the five selected Robinhood testnet stock assets
///         against WETH on the promoted reserve-backed V3 fixture. Registry
///         approval happens only after every pool has non-zero verified reserves.
contract SeedTestnetStockPools is Script {
    uint256 private constant CHAIN_ID = 46630;
    uint24 private constant FEE_TIER = 3000;
    uint256 private constant STOCK_SEED = 40 ether;
    uint256 private constant WETH_SEED = 0.01 ether;

    address private constant GOVERNANCE = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant EXPECTED_ROUTER = 0xa4077D7D9924e6eA879b1FB149d4eD13115068B6;

    IArchTestnetV3Manager private constant MANAGER = IArchTestnetV3Manager(0xe99f57922C22856845d282E319DB2B758F93f942);
    IWETH9 private constant WETH = IWETH9(0x61293a735E35d76E8980Bf17715b37A0C4196512);
    ArchStockRegistry private constant REGISTRY = ArchStockRegistry(0xADB4b0D5908C179C97ce5A5b2879Ba3E8497Bd64);

    address private constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address private constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address private constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address private constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address private constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;

    function run() external {
        require(block.chainid == CHAIN_ID, "stock pools: wrong chain");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == GOVERNANCE, "stock pools: wrong signer");

        address[5] memory stocks = [TSLA, AMD, AMZN, NFLX, PLTR];
        _validateBefore(stocks);

        address[5] memory pools;
        uint256[5] memory positionIds;

        vm.startBroadcast(key);
        WETH.deposit{value: WETH_SEED * stocks.length}();
        for (uint256 i; i < stocks.length; ++i) {
            (pools[i], positionIds[i]) = _seed(IERC20Metadata(stocks[i]));
        }
        for (uint256 i; i < stocks.length; ++i) {
            REGISTRY.setApproved(stocks[i], true);
        }
        vm.stopBroadcast();

        _validateAfter(stocks, pools, positionIds);
        for (uint256 i; i < stocks.length; ++i) {
            console2.log(IERC20Metadata(stocks[i]).symbol(), stocks[i]);
            console2.log("pool", pools[i]);
            console2.log("position", positionIds[i]);
        }
    }

    function _validateBefore(address[5] memory stocks) private view {
        require(address(MANAGER).code.length > 0, "stock pools: manager missing");
        require(address(WETH).code.length > 0, "stock pools: weth missing");
        require(address(REGISTRY).code.length > 0, "stock pools: registry missing");
        require(MANAGER.router() == EXPECTED_ROUTER, "stock pools: router mismatch");
        require(REGISTRY.owner() == GOVERNANCE, "stock pools: registry owner");
        require(GOVERNANCE.balance >= 0.1 ether, "stock pools: insufficient native balance");

        for (uint256 i; i < stocks.length; ++i) {
            IERC20Metadata stock = IERC20Metadata(stocks[i]);
            require(stocks[i].code.length > 0, "stock pools: token missing");
            require(stock.decimals() == 18, "stock pools: decimals");
            require(stock.balanceOf(GOVERNANCE) >= STOCK_SEED, "stock pools: stock balance");
            require(MANAGER.getPool(stocks[i], address(WETH), FEE_TIER) == address(0), "stock pools: pool exists");
            require(!REGISTRY.isApproved(stocks[i]), "stock pools: already approved");
        }
    }

    function _seed(IERC20Metadata stock) private returns (address pool, uint256 tokenId) {
        (address token0, address token1) = UniV3.sortTokens(address(stock), address(WETH));
        (uint256 amount0, uint256 amount1) =
            token0 == address(stock) ? (STOCK_SEED, WETH_SEED) : (WETH_SEED, STOCK_SEED);

        pool =
            MANAGER.createAndInitializePoolIfNecessary(token0, token1, FEE_TIER, UniV3.sqrtPriceX96(amount0, amount1));
        require(stock.approve(address(MANAGER), STOCK_SEED), "stock pools: stock approve");
        require(IERC20(address(WETH)).approve(address(MANAGER), WETH_SEED), "stock pools: weth approve");

        (int24 tickLower, int24 tickUpper) = UniV3.fullRangeTicks(FEE_TIER);
        (tokenId,,,) = MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: amount0,
                amount1Min: amount1,
                recipient: DEAD,
                deadline: type(uint256).max
            })
        );

        require(stock.approve(address(MANAGER), 0), "stock pools: stock reset");
        require(IERC20(address(WETH)).approve(address(MANAGER), 0), "stock pools: weth reset");
    }

    function _validateAfter(address[5] memory stocks, address[5] memory pools, uint256[5] memory positionIds)
        private
        view
    {
        for (uint256 i; i < stocks.length; ++i) {
            address pool = MANAGER.getPool(stocks[i], address(WETH), FEE_TIER);
            require(pool == pools[i] && pool.code.length > 0, "stock pools: pool mismatch");
            require(IERC20(stocks[i]).balanceOf(pool) == STOCK_SEED, "stock pools: stock reserve");
            require(IERC20(address(WETH)).balanceOf(pool) == WETH_SEED, "stock pools: weth reserve");
            (uint112 reserve0, uint112 reserve1,) = IArchTestnetV3Pool(pool).getReserves();
            require(reserve0 > 0 && reserve1 > 0, "stock pools: empty reserves");
            require(MANAGER.ownerOf(positionIds[i]) == DEAD, "stock pools: position not permanent");
            require(IERC20(stocks[i]).allowance(GOVERNANCE, address(MANAGER)) == 0, "stock pools: stock allowance");
            require(IERC20(address(WETH)).allowance(GOVERNANCE, address(MANAGER)) == 0, "stock pools: weth allowance");
            require(REGISTRY.isApproved(stocks[i]), "stock pools: registry approval");
        }
    }
}
