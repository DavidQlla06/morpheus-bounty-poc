// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

interface IL2MessageReceiver {
    function lzReceive(uint16, bytes memory, uint64, bytes memory) external;
    function retryMessage(uint16, bytes memory, uint64, bytes memory) external;
    function nonblockingLzReceive(uint16, bytes memory, bytes memory) external;
    function config() external view returns (address gateway, address sender, uint16 senderChainId);
    function rewardToken() external view returns (address);
}

/// @notice Negative tests: unprivileged callers cannot mint MOR via L2MessageReceiver.
///         Fork: Arbitrum One @ 526108148.
contract L2ReceiverChecksTest is Test {
    uint256 constant FORK_BLOCK = 526108148;
    string constant RPC = "https://arb1.arbitrum.io/rpc";
    address constant L2MR = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant L1_SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);
    }

    function test_ConfigMatchesL1Sender() public view {
        (address gateway, address sender, uint16 chainId) = IL2MessageReceiver(L2MR).config();
        console2.log("gateway:", gateway);
        console2.log("sender:", sender);
        console2.log("senderChainId:", chainId);
        assertEq(sender, L1_SENDER, "sender must be L1SenderV2");
        assertEq(chainId, 101, "LZ v1 Ethereum id");
        assertEq(IL2MessageReceiver(L2MR).rewardToken(), 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86);
    }

    function test_DirectLzReceiveReverts() public {
        bytes memory payload = abi.encode(address(this), uint256(1e18));
        bytes memory remote = abi.encodePacked(L1_SENDER, L2MR);
        vm.expectRevert(bytes("L2MR: invalid gateway"));
        IL2MessageReceiver(L2MR).lzReceive(101, remote, 1, payload);
    }

    function test_DirectNonblockingReverts() public {
        bytes memory payload = abi.encode(address(this), uint256(1e18));
        bytes memory remote = abi.encodePacked(L1_SENDER, L2MR);
        vm.expectRevert(bytes("L2MR: invalid caller"));
        IL2MessageReceiver(L2MR).nonblockingLzReceive(101, remote, payload);
    }

    function test_RetryWithoutStoredMessageReverts() public {
        bytes memory payload = abi.encode(address(this), uint256(1e18));
        bytes memory remote = abi.encodePacked(L1_SENDER, L2MR);
        vm.expectRevert(bytes("L2MR: no stored message"));
        IL2MessageReceiver(L2MR).retryMessage(101, remote, 1, payload);
    }
}
