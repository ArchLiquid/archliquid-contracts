// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ArchV4PositionLocker} from "@archliquid/lockers/ArchV4PositionLocker.sol";
import {IUniswapV4PositionManager, PoolKey} from "@archliquid/lockers/interfaces/IUniswapV4.sol";

/// @dev Opt-in fork checks for the V4 stack currently present on Robinhood
///      testnet. Passing them does not imply that Uniswap documents this
///      deployment or that ArchLiquid has enabled V4 in production.
contract RobinhoodTestnetV4ForkTest is Test {
    address internal constant OFFICIAL_V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant OFFICIAL_V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 internal constant TESTNET_POSITION_MANAGER_CODEHASH =
        0xf3a0edb689229fa4bf135a728f2ec2eb4a2fbee2e41e3e74ffadb7b4c56e8a6d;
    bytes32 internal constant MAINNET_POSITION_MANAGER_CODEHASH =
        0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2;
    uint256 internal constant EVIDENCE_TOKEN_ID = 793;

    bool internal forkEnabled;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("RH_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forkEnabled = true;
    }

    function test_officialV2AddressesAreAbsent() public view {
        if (!forkEnabled) return;
        assertEq(OFFICIAL_V2_FACTORY.code.length, 0);
        assertEq(OFFICIAL_V2_ROUTER.code.length, 0);
    }

    function test_v4StackIsFunctionalButPositionManagerDiffersFromMainnet() public view {
        if (!forkEnabled) return;

        assertEq(V4_POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);
        assertEq(V4_POSITION_MANAGER.codehash, TESTNET_POSITION_MANAGER_CODEHASH);
        assertNotEq(V4_POSITION_MANAGER.codehash, MAINNET_POSITION_MANAGER_CODEHASH);

        IUniswapV4PositionManager manager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        assertEq(manager.poolManager(), V4_POOL_MANAGER);
        assertGt(manager.nextTokenId(), EVIDENCE_TOKEN_ID);
        assertNotEq(manager.ownerOf(EVIDENCE_TOKEN_ID), address(0));
        (PoolKey memory key,) = manager.getPoolAndPositionInfo(EVIDENCE_TOKEN_ID);
        assertNotEq(key.currency0, key.currency1);
        assertNotEq(key.hooks, address(0));
        assertGt(manager.getPositionLiquidity(EVIDENCE_TOKEN_ID), 0);
    }

    function test_dedicatedLockerLifecycleAgainstLiveTestnetManager() public {
        if (!forkEnabled) return;

        IUniswapV4PositionManager manager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        (uint256 tokenId, address positionOwner, uint128 liquidity) = _latestHooklessPosition(manager);
        ArchV4PositionLocker locker = new ArchV4PositionLocker(0, payable(address(0xBEEF)), manager, address(this));

        vm.prank(positionOwner);
        manager.approve(address(locker), tokenId);
        vm.prank(positionOwner);
        uint256 lockId = locker.lock(tokenId, uint64(block.timestamp + 30 days), positionOwner);

        assertEq(manager.ownerOf(tokenId), address(locker));
        assertEq(locker.getLock(lockId).removedSubscriber, address(0));
        vm.prank(positionOwner);
        locker.collectFees(lockId, address(this), "");
        assertEq(manager.getPositionLiquidity(tokenId), liquidity);

        vm.warp(block.timestamp + 30 days);
        vm.prank(positionOwner);
        locker.withdraw(lockId);
        assertEq(manager.ownerOf(tokenId), positionOwner);
    }

    function _latestHooklessPosition(IUniswapV4PositionManager manager)
        internal
        view
        returns (uint256 tokenId, address positionOwner, uint128 liquidity)
    {
        uint256 nextId = manager.nextTokenId();
        uint256 attempts = nextId > 256 ? 256 : nextId;
        for (uint256 offset = 1; offset <= attempts; ++offset) {
            uint256 candidate = nextId - offset;
            try manager.ownerOf(candidate) returns (address currentOwner) {
                if (currentOwner == address(0) || currentOwner.code.length != 0) continue;
                try manager.subscriber(candidate) returns (address currentSubscriber) {
                    if (currentSubscriber != address(0)) continue;
                } catch {
                    continue;
                }
                try manager.getPositionLiquidity(candidate) returns (uint128 candidateLiquidity) {
                    if (candidateLiquidity == 0) continue;
                    (PoolKey memory key,) = manager.getPoolAndPositionInfo(candidate);
                    if (key.hooks != address(0)) continue;
                    return (candidate, currentOwner, candidateLiquidity);
                } catch {}
            } catch {}
        }
        revert("fork: no compatible V4 position near head");
    }
}
