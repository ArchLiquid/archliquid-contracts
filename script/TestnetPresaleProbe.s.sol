// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchPresale} from "@archliquid/launchpad/ArchPresale.sol";
import {ArchToken} from "@archliquid/token/ArchToken.sol";

/// @dev Runs the timestamp-sensitive presale flow atomically so the configured
///      start cannot drift between Foundry's simulation and mined transactions.
contract PresaleProbeRunner {
    function run(ArchLaunchpad launchpad, IERC20 stock, address beneficiary)
        external
        payable
        returns (address presaleAddr, address tokenAddr)
    {
        uint256 listingFee = launchpad.FEE();
        uint128 contribution = 0.003 ether;
        require(msg.value == listingFee + contribution, "probe: wrong value");

        uint64 start = uint64(block.timestamp);
        uint64 end = start + 1 hours;
        presaleAddr = launchpad.createPresale{value: listingFee}(
            ArchPresale.TokenConfig({
                name: "Presale Probe",
                symbol: "PPRB",
                totalSupply: 1_000_000e18,
                taxBps: 300,
                stock: stock,
                creatorFeeBps: 0
            }),
            ArchPresale.SaleConfig({
                softCap: 0.002 ether,
                hardCap: contribution,
                start: start,
                end: end,
                perWalletCap: 0,
                salePct: 50,
                lpPct: 40,
                poolFee: 3000,
                lpLockDuration: 365 days,
                teamCliff: end + 90 days,
                teamEnd: end + 365 days
            })
        );

        ArchPresale presale = ArchPresale(presaleAddr);
        presale.contribute{value: contribution}();
        presale.finalize();
        require(presale.finalized(), "probe: not finalized");

        ArchToken token = ArchToken(payable(address(presale.token())));
        tokenAddr = address(token);
        require(token.balanceOf(presale.pair()) > 0, "probe: no liquidity");

        presale.claim();
        uint256 claimed = token.balanceOf(address(this));
        require(claimed > 0, "probe: no claim");
        require(token.transfer(beneficiary, claimed), "probe: claim transfer");
    }
}

contract TestnetPresaleProbe is Script {
    ArchLaunchpad constant LAUNCHPAD = ArchLaunchpad(0x258A96ee9deB484Fb49C34eFA75AF308aA3dC2bc);
    IERC20 constant STOCK = IERC20(0xb218923aB06c3f1dA7d78DD8A018360Ef5B08bcE);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address gov = vm.addr(pk);
        uint256 value = LAUNCHPAD.FEE() + 0.003 ether;

        vm.startBroadcast(pk);
        PresaleProbeRunner runner = new PresaleProbeRunner();
        (address presale, address token) = runner.run{value: value}(LAUNCHPAD, STOCK, gov);
        vm.stopBroadcast();

        console2.log("PRESALE PROBE PASSED");
        console2.log("Presale", presale);
        console2.log("Token", token);
    }
}
