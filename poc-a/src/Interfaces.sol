// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function DepositPool_init(address depositToken_, address distributor_) external;
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function aavePoolAddressesProvider() external view returns (address);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveAddressesProvider {
    function getPool() external view returns (address);
}

interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

interface IRewardPool {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IChainLinkDataConsumer {
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
    function getPathId(string memory path_) external pure returns (bytes32);
    function allowedPriceUpdateDelay(address feed_) external view returns (uint64);
    function dataFeeds(bytes32, uint256) external view returns (address);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
