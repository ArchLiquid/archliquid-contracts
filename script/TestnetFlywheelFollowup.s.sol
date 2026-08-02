// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArchToken} from "@archliquid/token/ArchToken.sol";
import {MockERC20, MockV3Router} from "../test/mocks/Mocks.sol";

/// @notice Completes the flywheel probe after createToken has mined. The token
///         address must come from the TokenCreated receipt because its CREATE2
///         salt deliberately includes mined-block entropy.
contract TestnetFlywheelFollowup is Script {
    address constant TREASURY = 0x87CA96aB726c47c8adbb7DB5D33837FF9ba495b9;
    MockV3Router constant ROUTER = MockV3Router(0xA5b1B00589946696261EE3cD71cAf572D8EC8Cb0);
    address constant NFPM = 0x4EF971e9Ca21A62bF819Da44072c7227c74E357e;
    address constant WETH = 0xd931563004Fe99487ffe4A9DFdE3c537015145fB;
    MockERC20 constant STOCK = MockERC20(0xb218923aB06c3f1dA7d78DD8A018360Ef5B08bcE);
    uint24 constant FEE = 3000;

    function _pool(address token) internal view returns (address p) {
        (address a, address b) = token < WETH ? (token, WETH) : (WETH, token);
        bytes32 key = keccak256(abi.encode(a, b, FEE));
        (bool ok, bytes memory ret) = NFPM.staticcall(abi.encodeWithSignature("poolOf(bytes32)", key));
        require(ok, "poolOf failed");
        p = abi.decode(ret, (address));
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address gov = vm.addr(pk);
        ArchToken token = ArchToken(payable(vm.envAddress("PROBE_TOKEN")));
        address pool = _pool(address(token));

        require(address(token).code.length > 0, "flywheel: token missing");
        require(token.isMarketPair(pool), "flywheel: pool not wired");
        require(token.balanceOf(gov) == 800_000e18, "flywheel: creator balance");

        vm.startBroadcast(pk);

        require(token.transfer(pool, 100_000e18), "flywheel: sell transfer");
        require(token.balanceOf(address(token)) > 0, "flywheel: tax accrued");

        (bool ok,) = WETH.call{value: 0.0003 ether}("");
        require(ok, "flywheel: weth fund");
        ROUTER.setNextOut(WETH, 0.001 ether);
        ROUTER.setNextOut(address(STOCK), 500e18);

        uint256 treBefore = TREASURY.balance;
        token.processDistribution(0, 0);
        require(TREASURY.balance - treBefore == 0.0001 ether, "flywheel: treasury split");
        require(token.totalDistributed() == 500e18, "flywheel: stock distributed");

        uint256 owed = token.withdrawableDividendOf(gov);
        require(owed > 0, "flywheel: holder not credited");
        uint256 stockBefore = STOCK.balanceOf(gov);
        token.claim();
        require(STOCK.balanceOf(gov) - stockBefore == owed, "flywheel: claim mismatch");

        vm.stopBroadcast();
        console2.log("FLYWHEEL FOLLOWUP PASSED");
        console2.log("Token", address(token));
        console2.log("Pool", pool);
    }
}
