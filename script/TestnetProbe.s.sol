// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArchLaunchpad} from "@archliquid/launchpad/ArchLaunchpad.sol";
import {ArchBondingCurve} from "@archliquid/launchpad/ArchBondingCurve.sol";
import {ArchStakingFactory} from "@archliquid/staking/ArchStakingFactory.sol";
import {ArchStakingPool} from "@archliquid/staking/ArchStakingPool.sol";
import {ArchVesting} from "@archliquid/vesting/ArchVesting.sol";
import {ArchCErc20, IERC3156FlashBorrower} from "@archliquid/lending/ArchCErc20.sol";
import {MockERC20, MockFlashBorrower} from "../test/mocks/Mocks.sol";

/// @notice On-chain functional probe of the live testnet deployment's staking,
///         vesting, flash-loan and curve services. The flywheel and presale use
///         separate two-stage/atomic probes because their child-token addresses
///         incorporate mined-block entropy.
contract TestnetProbe is Script {
    // canonical low-fee QA instance (chain 46630, deployed 2026-07-20)
    ArchLaunchpad constant LAUNCHPAD = ArchLaunchpad(0x258A96ee9deB484Fb49C34eFA75AF308aA3dC2bc);
    ArchStakingFactory constant STAKING = ArchStakingFactory(0x34E6F0a8Fd06b138FaEf692819A2e8122422cB19);
    ArchVesting constant VESTING = ArchVesting(0xe4063b967C1E6b6b120C4Fc9E63B34B796bB1fEf);
    ArchCErc20 constant cUSDG = ArchCErc20(0x85F38E0D7318C42b93d3bF39dcfe2b2A1Ef1697B);
    address constant TREASURY = 0x87CA96aB726c47c8adbb7DB5D33837FF9ba495b9;
    MockERC20 constant STOCK = MockERC20(0xb218923aB06c3f1dA7d78DD8A018360Ef5B08bcE);
    MockERC20 constant USDG = MockERC20(0xf9F325FB1d6Dc9c587Cd0Cd78b2B0B0DCa5bcaB9);

    uint24 constant FEE = 3000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address gov = vm.addr(pk);
        vm.startBroadcast(pk);

        _staking(gov);
        _vesting(gov);
        _flashLoan(gov);
        _curve(gov);
        // presale has a start/end window that can't survive sim->broadcast
        // timestamp drift in one script; exercised separately via cast.

        vm.stopBroadcast();
        console2.log("ALL PROBES PASSED");
    }

    /* 2. staking: pool -> stake -> fund rewards -> 2% fee to treasury */
    function _staking(address) internal {
        uint256 fee = STAKING.FEE();
        uint256 treStart = TREASURY.balance;
        address p = STAKING.createPool{value: fee}(IERC20(address(STOCK)), IERC20(address(USDG)), 7 days, 0);
        require(TREASURY.balance - treStart == fee, "staking: pool fee");
        ArchStakingPool pool = ArchStakingPool(p);

        STOCK.approve(p, 1_000e18);
        pool.stake(1_000e18);

        uint256 treBefore = TREASURY.balance;
        USDG.approve(p, 1_000e18);
        pool.notifyRewardAmount(1_000e18); // 2% skim
        require(USDG.balanceOf(TREASURY) >= 20e18, "staking: 2% reward fee");
        require(TREASURY.balance == treBefore, "staking: no eth moved");
        console2.log("2. staking OK; reward fee to treasury (USDG):", USDG.balanceOf(TREASURY));
    }

    /* 3. vesting: create a schedule, fee to treasury */
    function _vesting(address gov) internal {
        uint256 fee = VESTING.FEE();
        uint256 treStart = TREASURY.balance;
        uint64 start = uint64(block.timestamp + 1);
        STOCK.approve(address(VESTING), 100e18);
        VESTING.createSchedule{value: fee}(IERC20(address(STOCK)), gov, 100e18, start, start, start + 30 days);
        require(TREASURY.balance - treStart == fee, "vesting: fee");
        console2.log("3. vesting OK");
    }

    /* 4. flash loan: supply, borrow+repay atomically, fee to reserves */
    function _flashLoan(address) internal {
        USDG.approve(address(cUSDG), 10_000e18);
        require(cUSDG.mint(10_000e18) == 0, "flash: supply");
        MockFlashBorrower borrower = new MockFlashBorrower();
        uint256 amount = 1_000e18;
        uint256 fee = cUSDG.flashFee(address(USDG), amount);
        USDG.mint(address(borrower), fee); // borrower must cover the fee
        uint256 resBefore = cUSDG.totalReserves();
        cUSDG.flashLoan(IERC3156FlashBorrower(address(borrower)), address(USDG), amount, "");
        require(cUSDG.totalReserves() - resBefore == fee, "flash: fee to reserves");
        console2.log("4. flash loan OK; fee to reserves (USDG):", fee);
    }

    /* 6. curve: create -> buy across graduation */
    function _curve(address gov) internal {
        uint256 fee = LAUNCHPAD.FEE();
        uint256 treStart = TREASURY.balance;
        address cAddr = LAUNCHPAD.createCurve{value: fee}(
            ArchBondingCurve.TokenConfig({
                name: "CurveProbe",
                symbol: "CPRB",
                totalSupply: 1_000_000e18,
                taxBps: 300,
                stock: IERC20(address(STOCK)),
                creatorFeeBps: 0
            }),
            // Keep the repeatable testnet probe inexpensive while exercising
            // the same graduation and liquidity-seeding path.
            ArchBondingCurve.CurveConfig({curvePct: 80, virtualEth: 0.0004 ether, gradEth: 0.001 ether, poolFee: FEE})
        );
        require(TREASURY.balance - treStart >= fee, "curve: listing fee");
        ArchBondingCurve curve = ArchBondingCurve(cAddr);
        curve.buy{value: 0.0012 ether}(0); // crosses graduation
        require(curve.graduated(), "curve: graduated");
        require(IERC20(address(curve.token())).balanceOf(gov) > 0, "curve: buyer holds tokens");
        console2.log("6. curve OK");
    }
}
