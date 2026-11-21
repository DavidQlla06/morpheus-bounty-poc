# Morpheus Slice A PoCs (Capital Protocol)

Foundry fork tests against deployed Appendix A addresses. No privileged pranks;
attacker is a fresh EOA funded with `deal`.

## Run

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd poc-a
forge test -vv
```

Requires network access to public RPCs (Ethereum `https://ethereum-rpc.publicnode.com`,
Arbitrum `https://arb1.arbitrum.io/rpc`). Fork blocks are pinned in each test:
Ethereum `26460436`, Arbitrum `526108148`.

## Tests

- `test/DonationAttack.t.sol` — **A-01 (SUBMITTABLE)**: donating yield tokens to the
  Distributor (Aave `supply` with `onBehalfOf = Distributor`) inflates a small pool's
  yield share and buys MOR emission below cost. Two tests: single-day and 3-day repeatable.
  Fork artifact handling: stETH rebases / Aave accrual do not auto-apply on a fork, so the
  test injects one day of natural yield at live on-chain APYs for the non-target pools, and
  re-serves fork-block Chainlink answers with fresh `updatedAt` after warps (live feeds
  update hourly; prices unchanged).
- `test/SanityChecks.t.sol` — impl/proxy re-init reverts; Chainlink staleness window;
  self-referral measurement (informational).
- `test/L2ReceiverChecks.t.sol` — Arbitrum `L2MessageReceiver` negative tests
  (unauthorized `lzReceive` / `nonblockingLzReceive` / `retryMessage` revert).

Expected: **10 passed, 0 failed** (forge 1.0.0, solc 0.8.20, evm cancun for fork
compatibility with the 2026 fork blocks).

Note: `lib/forge-std` is vendored at v1.9.7 to match forge 1.0.0.
