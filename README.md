# Morpheus Bug Bounty PoCs

Foundry fork PoCs supporting two reports submitted to the Morpheus bug bounty program (mor.org/bug-bounty).

## A-01 — Distributor yield-donation emission (`poc-a/`)
`Distributor.distributeRewards()` measures yield purely from yield-token balance growth, so anyone can fake instant yield (transfer / Aave supply onBehalfOf the Distributor) and harvest MOR emissions far above their natural share, repeatably, with no locked capital.

Run: `cd poc-a && forge test --match-test testDonationAttack -vv` (ETH fork, pinned block — see foundry.toml).

## C-01 — Lumerin direct-payment reward lock (`poc-c/`)
In the Lumerin diamond, `_rewardUserAfterClose` deducts the full reward from the user refund while `_claimForProvider` only pays `min(reward, stake - limitPeriodEarned)`; the difference is paid to no one and no facet function can release it — permanently locked.

Run: `cd poc-c && forge test --match-test testDirectPaymentLock -vv` (Base fork, pinned block — see foundry.toml).
