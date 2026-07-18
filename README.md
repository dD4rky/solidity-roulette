# Roulette

An on-chain **American roulette** game (38 pockets: `0`, `00`, and `1`–`36`) whose
spins are resolved with **Chainlink VRF v2.5** for provably fair randomness. Built
with [Foundry](https://book.getfoundry.sh/).

Players fund an internal balance and place bets against the wheel; the owner spins each
round. When Chainlink returns the random pocket, every pending bet is settled in one shot
and winnings are credited to player balances for withdrawal.

## How it works

```
deposit()  ->  bet()  ->  roll()  ->  [Chainlink VRF]  ->  fulfillRandomWords()  ->  withdraw()
  fund       stake       request       random word          settle all bets         cash out
 balance    a wager     randomness                          credit winnings
```

1. **`deposit()`** — send ETH to credit your internal `balance`. This is the only way for a
   player to add funds; bets and payouts both flow through this balance.
2. **`bet(betType, number, amount)`** — stake `amount` from your balance on a wager. The stake
   is debited immediately. Multiple bets per round are allowed, up to a per-round cap.
3. **`roll()`** — request a random pocket from Chainlink VRF. **Owner only**; reverts while a
   previous request is still pending.
4. **`fulfillRandomWords(...)`** — the VRF callback. Derives the winning pocket
   (`randomWord % 38`, where `37` = `00`), settles **all** players' pending bets against it,
   credits winnings, and clears the round.
5. **`withdraw()`** — cash your entire balance out to your address.

Payout multipliers **include the returned stake** — because the stake is removed from your
balance when the bet is placed, a winning bet credits back `amount × multiplier` and a losing
bet credits nothing.

## Bet types & payouts

| `BetType` | `number` means | Wins when | Payout (incl. stake) |
|-----------|----------------|-----------|----------------------|
| `Number`  | pocket `0`–`37` (`37` = `00`) | pocket matches exactly | `36×` (35:1) |
| `Sector`  | dozen `0`/`1`/`2` (1–12 / 13–24 / 25–36) | winning pocket in that dozen | `3×` (2:1) |
| `Row`     | street `0`–`11` (three consecutive numbers) | winning pocket in that street | `12×` (11:1) |
| `Color`   | `0` = Red, `1` = Black | color matches | `2×` (1:1) |
| `OddEven` | `0` = Even, `1` = Odd | parity matches | `2×` (1:1) |
| `HighLow` | `0` = Low (1–18), `1` = High (19–36) | range matches | `2×` (1:1) |

The `0` and `00` pockets lose every wager **except** a straight `Number` bet placed on that
exact pocket.

## Design notes

- **Provably fair** — the winning pocket comes only from Chainlink VRF; no party (including the
  owner) can influence a spin's outcome.
- **Bounded settlement** — settlement happens inside the VRF callback, which runs under a fixed
  gas budget. `MAX_BETS_PER_ROUND` caps how many bets a round can hold so the callback is
  guaranteed to finish; without it a round could accumulate enough bets to run the callback out
  of gas and strand every stake.
- **Deposit / bet split** — bets are drawn from a pre-funded internal balance rather than
  `msg.value`, so wagers are always backed by real deposits and the balance ledger stays
  consistent across deposits, stakes, winnings, and withdrawals.
- **House reserve** — a winning round can owe more than the deposits backing it (a single 35:1
  Number bet pays 36× its stake). The house tops up the payout reserve by sending ETH directly
  to the contract (`receive()`), which accepts ETH **without** crediting any player balance.
- **Per-window bet limit** — `betLimit` caps how much a single player may wager within each
  `LIMIT_PERIOD` (1 day) window; the owner adjusts it with `setBetLimit`.
- **Owner-controlled spins** — only the owner can call `roll()`, so the house decides when a
  round closes and settles. Betting, depositing, and withdrawing remain open to all players.
- **Safe withdrawals** — `withdraw()` follows checks-effects-interactions (balance zeroed before
  transfer) and uses a low-level `call`, reverting if the recipient rejects the ETH.

## Project layout

```
src/Roulette.sol                 The game contract
script/DeployRoulette.s.sol      Sepolia deployment script
test/RoulleteTest.t.sol          Foundry test suite (23 tests)
foundry.toml                     Build, RPC, and Etherscan config
.env.example                     Template for deployment env vars
```

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```shell
$ forge install     # fetch dependencies (Chainlink, forge-std)
$ forge build       # compile
$ forge test        # run the test suite
$ forge fmt         # format
```

The tests use `VRFCoordinatorV2_5Mock` to simulate Chainlink locally, so no live network or
API key is needed to run them.

## Deploy to Sepolia

The contract needs a Chainlink VRF v2.5 subscription. One-time setup at
[vrf.chain.link](https://vrf.chain.link) (Sepolia network):

1. Create a VRF v2.5 subscription and fund it with test LINK and/or native ETH.
2. Copy `.env.example` to `.env` and fill in `SEPOLIA_RPC_URL`,
   `VRF_SUBSCRIPTION_ID`, and `ETHERSCAN_API_KEY`.

Deploy and verify (using a Foundry keystore account — safer than a raw private key):

```shell
$ source .env
$ forge script script/DeployRoulette.s.sol:DeployRoulette \
    --rpc-url sepolia --account <keystore> --broadcast --verify
```

3. Take the printed contract address and add it as a **consumer** on the VRF
   subscription, so the coordinator can call `fulfillRandomWords` back into it.

> The `keyHash` in the contract is the Sepolia 500 gwei gas lane. Deploying to a different
> network requires updating that constant and the coordinator address in the deploy script.

## Status

⚠️ **Educational / testnet project — not audited.** Do not use with real funds on mainnet.
