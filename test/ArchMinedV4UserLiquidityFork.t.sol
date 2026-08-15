// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {ArchAdapterLaunchpad} from "@archliquid/launchpad/ArchAdapterLaunchpad.sol";
import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchV4LaunchLiquidityAdapter} from "@archliquid/launchpad/ArchV4LaunchLiquidityAdapter.sol";
import {ArchV4UserLiquidityProvisioner} from "@archliquid/launchpad/ArchV4UserLiquidityProvisioner.sol";
import {IUniswapV4PositionManager, IUniswapV4StateView} from "@archliquid/launchpad/interfaces/IUniswapV4.sol";

interface IV4UserLiquidityCanary {
    function TOKEN() external view returns (ArchToken);
    function POOL_ID() external view returns (bytes32);
    function TIMED_POSITION() external view returns (uint256);
    function LOCK_ID() external view returns (uint256);
    function PERMANENT_POSITION() external view returns (uint256);
}

/// @notice Read-only reconciliation of the mined V4 user-liquidity release and
///         its atomic two-position canary. Run on a Robinhood testnet fork.
contract ArchMinedV4UserLiquidityForkTest is Test {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant RELEASE_APPROVER = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    address private constant WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;
    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    ArchV4LaunchLiquidityAdapter private constant ADAPTER =
        ArchV4LaunchLiquidityAdapter(0x7694D631107fea145d872A6003f40a2021F99343);
    ArchV4UserLiquidityProvisioner private constant PROVISIONER =
        ArchV4UserLiquidityProvisioner(payable(0xba8cB9EE1Ea1126535C22d13805ec5cC22613775));
    ArchAdapterTokenFactory private constant TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0x897cd8ac993184d6dd3B549A5FbEc04f697C107c));
    ArchAdapterLaunchpad private constant LAUNCHPAD = ArchAdapterLaunchpad(0x45f7497ff12De39924905d9820A2E1CC60707302);
    ArchV4PositionLocker private constant LOCKER = ArchV4PositionLocker(0x8A1bC51e25b8799a5da57ff55f0262A405Ed2b98);
    IUniswapV4PositionManager private constant POSITION_MANAGER =
        IUniswapV4PositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IUniswapV4StateView private constant STATE_VIEW = IUniswapV4StateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    IV4UserLiquidityCanary private constant CANARY = IV4UserLiquidityCanary(0x0B5a48E52D8F0f529115A3bbE5737EF84B083312);

    bytes32 private constant CANARY_POOL_ID = 0x8eef3c93c9a68ec64e3b3769e215496f6c07e40088487ca2748c30171a912e92;
    address private constant CANARY_TOKEN = 0xc85e410547Be1E4a98A2b2915ed014b305D10f0A;

    function setUp() public {
        vm.skip(address(ADAPTER).code.length == 0, "requires Robinhood testnet fork");
    }

    function test_minedReleaseBindingsAreFrozenAndExact() public view {
        assertTrue(ADAPTER.launchersBound());
        assertEq(ADAPTER.liquidityProvisioner(), address(PROVISIONER));
        assertEq(ADAPTER.tokenFactory(), address(TOKEN_FACTORY));
        assertEq(address(ADAPTER.launchpad()), address(LAUNCHPAD));
        assertEq(address(ADAPTER.POOL_MANAGER()), POOL_MANAGER);
        assertEq(address(PROVISIONER.ADAPTER()), address(ADAPTER));
        assertEq(address(PROVISIONER.WETH()), WETH);
        assertEq(address(TOKEN_FACTORY.LIQUIDITY_ADAPTER()), address(ADAPTER));
        assertEq(address(LAUNCHPAD.LIQUIDITY_ADAPTER()), address(ADAPTER));
        assertTrue(LOCKER.feeExempt(address(ADAPTER)));
    }

    function test_atomicCanaryCreatedRegisteredLockedAndBurnedPositionsWithoutResidue() public view {
        ArchToken token = CANARY.TOKEN();
        bytes32 poolId = CANARY.POOL_ID();
        uint256 timedPosition = CANARY.TIMED_POSITION();
        uint256 lockId = CANARY.LOCK_ID();
        uint256 permanentPosition = CANARY.PERMANENT_POSITION();

        assertEq(address(token), CANARY_TOKEN);
        assertEq(poolId, CANARY_POOL_ID);
        assertEq(timedPosition, 1001);
        assertEq(lockId, 3);
        assertEq(permanentPosition, 1002);
        assertTrue(token.wired());
        assertEq(token.liquidityProvisioner(), address(PROVISIONER));
        assertEq(token.marketPairCount(), 1);
        assertTrue(token.isMarketPair(POOL_MANAGER));
        assertTrue(token.isTaxExempt(address(ADAPTER)));

        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0);
        assertGt(POSITION_MANAGER.getPositionLiquidity(timedPosition), 0);
        assertGt(POSITION_MANAGER.getPositionLiquidity(permanentPosition), 0);
        assertEq(POSITION_MANAGER.ownerOf(timedPosition), address(LOCKER));
        assertEq(POSITION_MANAGER.ownerOf(permanentPosition), DEAD);

        ArchV4PositionLocker.Lock memory lock = LOCKER.getLock(lockId);
        assertEq(lock.tokenId, timedPosition);
        assertEq(lock.owner, RELEASE_APPROVER);
        assertEq(lock.hooks, address(0));
        assertFalse(lock.withdrawn);

        assertEq(token.allowance(address(CANARY), address(PROVISIONER)), 0);
        assertEq(token.balanceOf(address(PROVISIONER)), 0);
        assertEq(IERC20(WETH).balanceOf(address(PROVISIONER)), 0);
        assertEq(token.balanceOf(address(ADAPTER)), 0);
        assertEq(IERC20(WETH).balanceOf(address(ADAPTER)), 0);
    }
}
