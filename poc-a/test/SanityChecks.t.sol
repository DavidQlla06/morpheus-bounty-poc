// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20, IDepositPool, IDistributor, IChainLinkDataConsumer, IAggregator} from "../src/Interfaces.sol";

/// @notice Sanity / negative-result checks for slice A. Fork: Ethereum @ 26460436.
contract SanityChecksTest is Test {

    /// USDT-style tokens return no bool from approve; use low-level call.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }
    uint256 constant FORK_BLOCK = 26460436;
    string constant RPC = "https://ethereum-rpc.publicnode.com";

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant DEPOSIT_POOL_IMPL = 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670;
    address constant CHAINLINK_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;


    /// Same fork-artifact workaround as DonationAttack: re-serve fork answers with fresh updatedAt.
    function _refreshChainlink() internal {
        address[6] memory feeds = [
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8,
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23,
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c,
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) =
                IAggregator(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
            );
        }
    }

    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);
    }

    /// Implementation must reject init (initializers disabled in constructor).
    function test_ImplCannotBeInitialized() public {
        vm.expectRevert();
        IDepositPool(DEPOSIT_POOL_IMPL).DepositPool_init(USDT, DISTRIBUTOR);
    }

    /// Live proxy must reject re-init.
    function test_ProxyCannotBeReinitialized() public {
        vm.expectRevert();
        IDepositPool(USDT_POOL).DepositPool_init(USDT, DISTRIBUTOR);
    }

    /// At the fork block every configured feed is within its allowed delay.
    /// After warping past the 3600s allowance with no new Chainlink round (fork artifact:
    /// live feeds keep updating), the consumer returns 0 and distributeRewards reverts,
    /// which blocks stake/withdraw/claim. Live impact is a temporary freeze only.
    function test_ChainlinkStalenessWindow() public {
        IChainLinkDataConsumer consumer = IChainLinkDataConsumer(CHAINLINK_CONSUMER);
        string[5] memory paths = ["stETH/USD", "wETH/USD", "wBTC/BTC,BTC/USD", "USDC/USD", "USDT/USD"];
        for (uint256 i = 0; i < paths.length; i++) {
            bytes32 id = consumer.getPathId(paths[i]);
            uint256 price = consumer.getChainLinkDataFeedLatestAnswer(id);
            console2.log(paths[i], "price:", price);
            assertGt(price, 0, "feed must be fresh at fork block");
            address feed = consumer.dataFeeds(id, 0);
            (, , , uint256 updatedAt, ) = IAggregator(feed).latestRoundData();
            console2.log("  feed0 age (s):", block.timestamp - updatedAt, "allowed:", consumer.allowedPriceUpdateDelay(feed));
        }

        vm.warp(block.timestamp + 3700);
        bytes32 stethId = consumer.getPathId("stETH/USD");
        assertEq(consumer.getChainLinkDataFeedLatestAnswer(stethId), 0, "stale after 3700s without update");
        vm.expectRevert(bytes("DR: price for pair is zero"));
        IDistributor(DISTRIBUTOR).distributeRewards(0);
    }

    /// Informational: self-referral. Staker sets referrer == self.
    /// Measures the +1% staker multiplier and referrer-tier virtual stake.
    /// Expected verdict: intended referral incentive, not an invariant break.
    function test_SelfReferralMeasurement() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        deal(USDT, alice, 100_000e6);
        deal(USDT, bob, 100_000e6);

        vm.startPrank(alice);
        _approve(USDT, DISTRIBUTOR, type(uint256).max);
        IDepositPool(USDT_POOL).stake(0, 10_000e6, 0, alice); // self-referral
        vm.stopPrank();

        vm.startPrank(bob);
        _approve(USDT, DISTRIBUTOR, type(uint256).max);
        IDepositPool(USDT_POOL).stake(0, 10_000e6, 0, address(0)); // no referrer
        vm.stopPrank();

        (, , , , , , uint256 aliceVirtual, , ) = IDepositPool(USDT_POOL).usersData(alice, 0);
        (, , , , , , uint256 bobVirtual, , ) = IDepositPool(USDT_POOL).usersData(bob, 0);
        console2.log("alice (self-ref) virtual:", aliceVirtual);
        console2.log("bob (no ref) virtual:", bobVirtual);
        assertEq(aliceVirtual, (10_000e6 * 101) / 100, "self-ref gives +1% staker multiplier");

        vm.warp(block.timestamp + 86_401);
        _refreshChainlink();
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 aliceRefReward = IDepositPool(USDT_POOL).getLatestReferrerReward(0, alice);
        console2.log("alice referrer-tier pending MOR (wei):", aliceRefReward);
    }
}
