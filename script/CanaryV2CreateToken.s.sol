// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchAdapterTokenFactory} from "@archliquid/launchpad/ArchAdapterTokenFactory.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";

/// @notice Phase one of the mined canary. It intentionally stops after token
///         creation because the factory salt includes live block data; phase
///         two must consume the address confirmed by the mined receipt.
contract CanaryV2CreateToken is Script {
    ArchAdapterTokenFactory private constant TOKEN_FACTORY =
        ArchAdapterTokenFactory(payable(0xCB5756CAC20427a3d6536A7A55CC72B44dA9C1A7));
    IERC20 private constant STOCK = IERC20(0x1c80aC86447c8EEa5D0D70DCa78c632b7A249bEE);
    address private constant SIGNER = 0x6a51C3672B6C4d5d556f23A18918983390a832C8;
    address private constant PROVISIONER = 0xad16a8806EdF001c053A856bD625cbd720335CeA;
    address private constant ADAPTER = 0x050F2cF78d3D33e73777Db3BF0A6B476DB668A66;
    uint256 private constant FACTORY_FEE = 0.00015 ether;
    uint256 private constant SUPPLY = 1_000_000e18;

    function run() external {
        require(block.chainid == 46630, "canary create: wrong chain");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(privateKey) == SIGNER, "canary create: wrong signer");

        vm.startBroadcast(privateKey);
        ArchToken token = ArchToken(
            payable(TOKEN_FACTORY.createToken{value: FACTORY_FEE}(
                    ArchAdapterTokenFactory.TokenParams({
                        name: "ArchLiquid V2 Liquidity Canary",
                        symbol: "ALCANARY",
                        totalSupply: SUPPLY,
                        taxBps: 300,
                        stock: STOCK,
                        creatorFeeBps: 0
                    }),
                    ArchAdapterTokenFactory.LiquidityParams({
                        enabled: false, lpPct: 0, poolFee: 0, burnLp: false, lockDuration: 0
                    })
                ))
        );
        vm.stopBroadcast();

        require(token.wired(), "canary create: not wired");
        require(token.marketPairCount() == 0, "canary create: unexpected market");
        require(token.liquidityProvisioner() == PROVISIONER, "canary create: provisioner");
        require(token.isTaxExempt(ADAPTER), "canary create: adapter exemption");
        require(token.balanceOf(SIGNER) == SUPPLY, "canary create: signer balance");
        console2.log("CanaryToken", address(token));
    }
}
