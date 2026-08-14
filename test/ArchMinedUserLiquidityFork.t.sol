// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchAdapterLaunchpad} from "@archliquid/launchpad/ArchAdapterLaunchpad.sol";
import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchUserLiquidityProvisioner} from "@archliquid/launchpad/ArchUserLiquidityProvisioner.sol";
import {ArchV2LaunchLiquidityAdapter} from "@archliquid/launchpad/ArchV2LaunchLiquidityAdapter.sol";
import {IArchLaunchLiquidityAdapter} from "@archliquid/launchpad/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Factory} from "@archliquid/launchpad/interfaces/IUniswapV2.sol";

/// @notice Local-fork lifecycle against the exact r1 user-liquidity addresses.
///         The default unit run records this suite as skipped; invoke it with
///         `--fork-url robinhood_testnet` for meaningful execution.
contract ArchMinedUserLiquidityForkTest is Test {
    ArchV2LaunchLiquidityAdapter private constant ADAPTER =
        ArchV2LaunchLiquidityAdapter(0x050F2cF78d3D33e73777Db3BF0A6B476DB668A66);
    ArchUserLiquidityProvisioner private constant PROVISIONER =
        ArchUserLiquidityProvisioner(payable(0xad16a8806EdF001c053A856bD625cbd720335CeA));
    ArchAdapterTokenFactory private constant TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0xCB5756CAC20427a3d6536A7A55CC72B44dA9C1A7));
    ArchAdapterLaunchpad private constant LAUNCHPAD = ArchAdapterLaunchpad(0x3FD6651939A2138A5ecD4E17ba741e3ee0D6dfa6);
    ArchLiquidityLocker private constant LOCKER = ArchLiquidityLocker(0xb92D2c218bBb51C0F21fc12a6141596EafD98Def);
    IUniswapV2Factory private constant V2_FACTORY = IUniswapV2Factory(0x3d51588C41586Bc391A989156fBE6a7ceEd51446);
    IERC20 private constant STOCK = IERC20(0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE);
    address private constant WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;

    uint256 private constant FACTORY_FEE = 0.00015 ether;
    uint256 private constant SUPPLY = 1_000_000e18;
    address private creator = makeAddr("r1-liquidity-creator");

    function setUp() public {
        vm.skip(address(TOKEN_FACTORY).code.length == 0, "requires Robinhood testnet fork");
        vm.deal(creator, 10 ether);
    }

    function test_minedBindingsAreFrozenAndFresh() public view {
        assertTrue(ADAPTER.launchersBound());
        assertEq(ADAPTER.liquidityProvisioner(), address(PROVISIONER));
        assertEq(ADAPTER.tokenFactory(), address(TOKEN_FACTORY));
        assertEq(address(ADAPTER.launchpad()), address(LAUNCHPAD));
        assertEq(address(PROVISIONER.ADAPTER()), address(ADAPTER));
        assertEq(address(PROVISIONER.WETH()), WETH);
        assertEq(address(TOKEN_FACTORY.LIQUIDITY_ADAPTER()), address(ADAPTER));
        assertEq(address(LAUNCHPAD.LIQUIDITY_ADAPTER()), address(ADAPTER));
        assertTrue(LOCKER.feeExempt(address(ADAPTER)));
    }

    function test_minedNoPoolTokenCreatesFirstPairThenAddsMoreLiquidity() public {
        ArchAdapterTokenFactory.TokenParams memory tokenParams = ArchAdapterTokenFactory.TokenParams({
            name: "Fork Deferred Liquidity",
            symbol: "FDL",
            totalSupply: SUPPLY,
            taxBps: 300,
            stock: STOCK,
            creatorFeeBps: 0
        });
        ArchAdapterTokenFactory.LiquidityParams memory noLiquidity = ArchAdapterTokenFactory.LiquidityParams({
            enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
        });

        vm.prank(creator);
        ArchToken token = ArchToken(payable(TOKEN_FACTORY.createToken{value: FACTORY_FEE}(tokenParams, noLiquidity)));
        assertTrue(token.wired());
        assertEq(token.marketPairCount(), 0);
        assertEq(token.liquidityProvisioner(), address(PROVISIONER));
        assertTrue(token.isTaxExempt(address(ADAPTER)));

        uint256 lockIdBefore = LOCKER.lockCount();
        vm.startPrank(creator);
        token.approve(address(PROVISIONER), 110_000e18);
        IArchLaunchLiquidityAdapter.SeedResult memory first =
            PROVISIONER.addLiquidity{value: 1 ether}(token, 100_000e18, address(0), 180 days, false);
        IArchLaunchLiquidityAdapter.SeedResult memory second =
            PROVISIONER.addLiquidity{value: 0.1 ether}(token, 10_000e18, first.market, 365 days, false);
        vm.stopPrank();

        address canonicalPair = V2_FACTORY.getPair(address(token), WETH);
        assertEq(first.market, canonicalPair);
        assertEq(second.market, canonicalPair);
        assertEq(token.marketPairCount(), 1);
        assertTrue(token.isMarketPair(canonicalPair));
        assertEq(token.balanceOf(address(token)), 0, "liquidity path accrued trade tax");
        assertEq(token.balanceOf(address(PROVISIONER)), 0);
        assertEq(IERC20(WETH).balanceOf(address(PROVISIONER)), 0);
        assertEq(token.allowance(address(PROVISIONER), address(ADAPTER)), 0);
        assertEq(IERC20(WETH).allowance(address(PROVISIONER), address(ADAPTER)), 0);

        ArchLiquidityLocker.Lock memory firstLock = LOCKER.getLock(lockIdBefore);
        ArchLiquidityLocker.Lock memory secondLock = LOCKER.getLock(lockIdBefore + 1);
        assertEq(firstLock.owner, creator);
        assertEq(secondLock.owner, creator);
        assertEq(firstLock.token, canonicalPair);
        assertEq(secondLock.token, canonicalPair);
        assertEq(firstLock.amount, first.positionIdOrAmount);
        assertEq(secondLock.amount, second.positionIdOrAmount);
        assertGt(IERC20(canonicalPair).balanceOf(address(LOCKER)), firstLock.amount + secondLock.amount - 1);
    }
}
