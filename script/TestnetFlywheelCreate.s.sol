// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchTokenFactory} from "@archliquid/token/ArchTokenFactory.sol";

/// @notice First stage of the flywheel probe. After this transaction mines,
///         read the actual child address from TokenCreated (or allTokens) and
///         pass it as PROBE_TOKEN to TestnetFlywheelFollowup.
contract TestnetFlywheelCreate is Script {
    ArchTokenFactory constant FACTORY = ArchTokenFactory(0x44024204E7fDD8036836D6Ae2959A63411f9eCaD);
    IERC20 constant STOCK = IERC20(0xb218923aB06c3f1dA7d78DD8A018360Ef5B08bcE);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 fee = FACTORY.FEE();

        vm.startBroadcast(pk);
        FACTORY.createToken{value: fee + 0.002 ether}(
            ArchTokenFactory.TokenParams({
                name: "Probe", symbol: "PRB", totalSupply: 1_000_000e18, taxBps: 300, stock: STOCK, creatorFeeBps: 0
            }),
            ArchTokenFactory.LiquidityParams({enabled: true, lpPct: 20, poolFee: 3000, burnLp: true, lockDuration: 0})
        );
        vm.stopBroadcast();

        console2.log("FLYWHEEL CREATE MINED; READ TokenCreated RECEIPT BEFORE FOLLOWUP");
    }
}
