// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchLiquidityLocker} from "@archliquid/lockers/ArchLiquidityLocker.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {ArchUserLiquidityProvisioner} from "@archliquid/launchpad/ArchUserLiquidityProvisioner.sol";
import {ArchV2LaunchLiquidityAdapter} from "@archliquid/launchpad/ArchV2LaunchLiquidityAdapter.sol";
import {IArchLaunchLiquidityAdapter} from "@archliquid/launchpad/interfaces/IArchLaunchLiquidityAdapter.sol";
import {IUniswapV2Factory} from "@archliquid/launchpad/interfaces/IUniswapV2.sol";

/// @notice Phase two consumes only a token address already confirmed onchain.
contract CanaryV2AddLiquidity is Script {
    ArchV2LaunchLiquidityAdapter private constant ADAPTER =
        ArchV2LaunchLiquidityAdapter(0x050F2cF78d3D33e73777Db3BF0A6B476DB668A66);
    ArchUserLiquidityProvisioner private constant PROVISIONER =
        ArchUserLiquidityProvisioner(payable(0xad16a8806EdF001c053A856bD625cbd720335CeA));
    ArchAdapterTokenFactory private constant TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0xCB5756CAC20427a3d6536A7A55CC72B44dA9C1A7));
    ArchLiquidityLocker private constant LOCKER = ArchLiquidityLocker(0xb92D2c218bBb51C0F21fc12a6141596EafD98Def);
    IUniswapV2Factory private constant V2_FACTORY = IUniswapV2Factory(0x3d51588C41586Bc391A989156fBE6a7ceEd51446);
    address private constant WETH = 0x61293a735E35d76E8980Bf17715b37A0C4196512;
    address private constant SIGNER = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    uint256 private constant FIRST_TOKEN = 100_000e18;
    uint256 private constant FIRST_ETH = 0.001 ether;
    uint256 private constant SECOND_TOKEN = 10_000e18;
    uint256 private constant SECOND_ETH = 0.0001 ether;

    function run() external {
        require(block.chainid == 46630, "canary add: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(privateKey) == SIGNER, "canary add: wrong signer");
        ArchToken token = ArchToken(payable(vm.envAddress("CANARY_TOKEN")));
        require(address(token).code.length > 0, "canary add: token not mined");
        require(token.FACTORY() == address(TOKEN_FACTORY), "canary add: wrong factory");
        require(token.wired() && token.marketPairCount() == 0, "canary add: token state");
        require(token.liquidityProvisioner() == address(PROVISIONER), "canary add: provisioner");
        require(token.isTaxExempt(address(ADAPTER)), "canary add: exemption");
        require(token.balanceOf(SIGNER) >= FIRST_TOKEN + SECOND_TOKEN, "canary add: balance");

        uint256 lockBefore = LOCKER.lockCount();
        vm.startBroadcast(privateKey);
        token.approve(address(PROVISIONER), FIRST_TOKEN + SECOND_TOKEN);
        IArchLaunchLiquidityAdapter.SeedResult memory first =
            PROVISIONER.addLiquidity{value: FIRST_ETH}(token, FIRST_TOKEN, address(0), 30 days, false);
        IArchLaunchLiquidityAdapter.SeedResult memory second =
            PROVISIONER.addLiquidity{value: SECOND_ETH}(token, SECOND_TOKEN, first.market, 31 days, false);
        vm.stopBroadcast();

        address canonicalPair = V2_FACTORY.getPair(address(token), WETH);
        require(first.market == canonicalPair && second.market == canonicalPair, "canary add: pair");
        require(token.marketPairCount() == 1 && token.isMarketPair(canonicalPair), "canary add: registration");
        require(token.balanceOf(address(token)) == 0, "canary add: trade tax");
        require(token.balanceOf(address(PROVISIONER)) == 0, "canary add: token residue");
        require(IERC20(WETH).balanceOf(address(PROVISIONER)) == 0, "canary add: weth residue");
        require(token.allowance(SIGNER, address(PROVISIONER)) == 0, "canary add: signer allowance");
        require(token.allowance(address(PROVISIONER), address(ADAPTER)) == 0, "canary add: token allowance");
        require(IERC20(WETH).allowance(address(PROVISIONER), address(ADAPTER)) == 0, "canary add: weth allowance");
        require(first.lockId == lockBefore && second.lockId == lockBefore + 1, "canary add: lock sequence");

        ArchLiquidityLocker.Lock memory firstLock = LOCKER.getLock(first.lockId);
        ArchLiquidityLocker.Lock memory secondLock = LOCKER.getLock(second.lockId);
        require(firstLock.owner == SIGNER && secondLock.owner == SIGNER, "canary add: lock owner");
        require(firstLock.token == canonicalPair && secondLock.token == canonicalPair, "canary add: lock asset");
        require(firstLock.amount == first.positionIdOrAmount, "canary add: first amount");
        require(secondLock.amount == second.positionIdOrAmount, "canary add: second amount");

        console2.log("CanaryToken", address(token));
        console2.log("CanonicalPair", canonicalPair);
        console2.log("FirstLockId", first.lockId);
        console2.log("SecondLockId", second.lockId);
    }
}
