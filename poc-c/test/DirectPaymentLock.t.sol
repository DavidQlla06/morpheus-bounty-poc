// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IDiamond {
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] memory tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getProviderMinimumStake() external view returns (uint256);
}

/// @notice PoC: direct-payment session where provider reward exceeds provider stake cap.
///         User refund is reduced by the FULL reward, provider is paid only up to its
///         stake (limiter), the difference stays in the diamond with no recovery path.
contract DirectPaymentLockTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 60185060;

    uint256 providerKey = 0xA11CE;
    address provider;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        provider = vm.addr(providerKey);
    }

    function _sign(bytes memory payload) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testDirectPaymentRewardLockedInDiamond() public {
        IDiamond diamond = IDiamond(DIAMOND);
        IERC20 mor = IERC20(MOR);

        uint256 minStake = diamond.getProviderMinimumStake(); // 0.2 MOR on-chain
        uint256 userStake = 10_000 ether;

        // Fund test accounts from the on-chain funding account (fork-only test setup,
        // equivalent to deal(); avoids forge-std/forge version mismatch in deal()).
        address funding = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;
        vm.startPrank(funding);
        mor.transfer(provider, 10 ether);
        mor.transfer(user, userStake);
        vm.stopPrank();

        // Provider registers with minimum stake, registers a model, posts a bid.
        vm.startPrank(provider);
        mor.approve(DIAMOND, type(uint256).max);
        diamond.providerRegister(provider, minStake, "https://provider.example");
        bytes32 baseModelId = keccak256("poc-base-model");
        string[] memory tags = new string[](0);
        diamond.modelRegister(provider, baseModelId, bytes32(uint256(1)), 0, 0.1 ether, "poc-model", tags);
        bytes32 modelId = diamond.getModelId(provider, baseModelId);
        uint256 pricePerSecond = 1e14; // 0.0001 MOR/s, within [1e10, 1e16]
        bytes32 bidId = diamond.postModelBid(provider, modelId, pricePerSecond);
        vm.stopPrank();

        uint256 stipend = diamond.stakeToStipend(userStake, uint128(block.timestamp));
        emit log_named_uint("stipend (wei)", stipend);
        emit log_named_uint("provider stake cap (wei)", minStake);
        assertGt(stipend, minStake, "precondition: reward exceeds provider stake");

        // User opens a DIRECT-PAYMENT session.
        bytes memory approval = abi.encode(bidId, block.chainid, user, uint128(block.timestamp));
        bytes memory approvalSig = _sign(approval);

        uint256 diamondBefore = mor.balanceOf(DIAMOND);
        uint256 providerBefore = mor.balanceOf(provider);

        vm.startPrank(user);
        mor.approve(DIAMOND, type(uint256).max);
        bytes32 sessionId = diamond.openSession(user, userStake, true, approval, approvalSig);
        vm.stopPrank();

        IDiamond.Session memory session = diamond.getSession(sessionId);
        uint256 fullReward = (uint256(session.endsAt) - uint256(session.openedAt)) * pricePerSecond;
        emit log_named_uint("full provider reward deducted from user (wei)", fullReward);
        assertGt(fullReward, minStake, "reward must exceed cap");

        // Session runs to completion; close with valid provider receipt.
        vm.warp(uint256(session.endsAt) + 1);
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
        bytes memory receiptSig = _sign(receipt);

        vm.prank(user);
        diamond.closeSession(receipt, receiptSig);

        uint256 providerPaid = mor.balanceOf(provider) - providerBefore;
        emit log_named_uint("provider actually paid (wei)", providerPaid);
        assertEq(providerPaid, minStake, "provider capped at stake");

        // Recover the 1-day on-hold portion after it matures.
        vm.warp(block.timestamp + 2 days);
        uint256 userBeforeWithdraw = mor.balanceOf(user);
        vm.prank(user);
        diamond.withdrawUserStakes(user, 10);
        uint256 userRecoveredTotal = mor.balanceOf(user) - 0; // user started with exactly userStake, all staked
        emit log_named_uint("user recovered total (wei)", userRecoveredTotal);
        emit log_named_uint("user staked (wei)", userStake);

        uint256 lockedForever = userStake - userRecoveredTotal - providerPaid;
        emit log_named_uint("LOCKED FOREVER in diamond (wei)", lockedForever);
        emit log_named_uint("diamond balance delta (wei)", mor.balanceOf(DIAMOND) - diamondBefore);

        // The user was charged fullReward, provider got minStake, remainder is stranded.
        assertEq(lockedForever, fullReward - minStake, "stranded = fullReward - capped payment");
        assertGt(lockedForever, 20 ether, "material permanent lock");
        assertEq(userBeforeWithdraw + (userRecoveredTotal - userBeforeWithdraw), userRecoveredTotal);
    }
}
