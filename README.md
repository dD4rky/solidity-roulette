## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy to Sepolia

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

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
