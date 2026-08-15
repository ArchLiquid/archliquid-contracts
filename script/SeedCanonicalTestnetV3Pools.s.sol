// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, IWETH9} from "@archliquid/core/interfaces/IUniswapV3.sol";
import {UniV3} from "@archliquid/core/lib/UniV3.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Seeds the promoted stock/WETH markets through the canonical
///         Uniswap V3 factory and position manager deployed on testnet.
contract SeedCanonicalTestnetV3Pools is Script {
    uint256 private constant CHAIN_ID = 46630;
    uint24 private constant FEE_TIER = 3000;
    uint256 private constant STOCK_SEED = 20 ether;
    uint256 private constant WETH_SEED = 0.005 ether;

    address private constant GOVERNANCE = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IUniswapV3Factory private constant FACTORY = IUniswapV3Factory(0xe138C58a8f5FB97A52bf17966Ad1c68bD4B52979);
    INonfungiblePositionManager private constant MANAGER =
        INonfungiblePositionManager(0xD1e800aD30B2249977921ce5aFb8d69f773590Ec);
    IWETH9 private constant WETH = IWETH9(0x61293a735E35d76E8980Bf17715b37A0C4196512);

    address private constant M_NVDAX = 0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE;
    address private constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address private constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address private constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address private constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address private constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;

    function run() external {
        require(block.chainid == CHAIN_ID, "canonical v3: wrong chain");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == GOVERNANCE, "canonical v3: wrong signer");

        address[6] memory stocks = [M_NVDAX, TSLA, AMD, AMZN, NFLX, PLTR];
        _validateBefore(stocks);

        address[6] memory pools;
        uint256[6] memory positionIds;
        uint128[6] memory liquidities;

        vm.startBroadcast(key);
        WETH.deposit{value: WETH_SEED * stocks.length}();
        for (uint256 i; i < stocks.length; ++i) {
            (pools[i], positionIds[i], liquidities[i]) = _seed(IERC20Metadata(stocks[i]));
        }
        vm.stopBroadcast();

        _validateAfter(stocks, pools, positionIds, liquidities);
        for (uint256 i; i < stocks.length; ++i) {
            console2.log(IERC20Metadata(stocks[i]).symbol(), stocks[i]);
            console2.log("pool", pools[i]);
            console2.log("position", positionIds[i]);
            console2.log("liquidity", liquidities[i]);
        }
    }

    function _validateBefore(address[6] memory stocks) private view {
        require(address(FACTORY).code.length > 0, "canonical v3: factory missing");
        require(address(MANAGER).code.length > 0, "canonical v3: manager missing");
        require(address(WETH).code.length > 0, "canonical v3: weth missing");
        require(GOVERNANCE.balance >= 0.05 ether, "canonical v3: insufficient native balance");

        for (uint256 i; i < stocks.length; ++i) {
            IERC20Metadata stock = IERC20Metadata(stocks[i]);
            require(stocks[i].code.length > 0, "canonical v3: token missing");
            require(stock.decimals() == 18, "canonical v3: decimals");
            require(stock.balanceOf(GOVERNANCE) >= STOCK_SEED, "canonical v3: stock balance");
            require(FACTORY.getPool(stocks[i], address(WETH), FEE_TIER) == address(0), "canonical v3: pool exists");
        }
    }

    function _seed(IERC20Metadata stock) private returns (address pool, uint256 tokenId, uint128 liquidity) {
        (address token0, address token1) = UniV3.sortTokens(address(stock), address(WETH));
        (uint256 amount0, uint256 amount1) =
            token0 == address(stock) ? (STOCK_SEED, WETH_SEED) : (WETH_SEED, STOCK_SEED);

        pool =
            MANAGER.createAndInitializePoolIfNecessary(token0, token1, FEE_TIER, UniV3.sqrtPriceX96(amount0, amount1));
        require(stock.approve(address(MANAGER), STOCK_SEED), "canonical v3: stock approve");
        require(IERC20(address(WETH)).approve(address(MANAGER), WETH_SEED), "canonical v3: weth approve");

        (int24 tickLower, int24 tickUpper) = UniV3.fullRangeTicks(FEE_TIER);
        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: DEAD,
                deadline: block.timestamp + 20 minutes
            })
        );
        require(liquidity > 0 && used0 > 0 && used1 > 0, "canonical v3: empty mint");
        require(used0 <= amount0 && used1 <= amount1, "canonical v3: excess mint");

        require(stock.approve(address(MANAGER), 0), "canonical v3: stock reset");
        require(IERC20(address(WETH)).approve(address(MANAGER), 0), "canonical v3: weth reset");
    }

    function _validateAfter(
        address[6] memory stocks,
        address[6] memory pools,
        uint256[6] memory positionIds,
        uint128[6] memory liquidities
    ) private view {
        for (uint256 i; i < stocks.length; ++i) {
            address pool = FACTORY.getPool(stocks[i], address(WETH), FEE_TIER);
            require(pool == pools[i] && pool.code.length > 0, "canonical v3: pool mismatch");
            require(IERC20(stocks[i]).balanceOf(pool) > 0, "canonical v3: stock reserve");
            require(IERC20(address(WETH)).balanceOf(pool) > 0, "canonical v3: weth reserve");
            require(MANAGER.ownerOf(positionIds[i]) == DEAD, "canonical v3: position custody");
            require(liquidities[i] > 0, "canonical v3: zero liquidity");
            require(IERC20(stocks[i]).allowance(GOVERNANCE, address(MANAGER)) == 0, "canonical v3: stock allowance");
            require(IERC20(address(WETH)).allowance(GOVERNANCE, address(MANAGER)) == 0, "canonical v3: weth allowance");
        }
    }
}
