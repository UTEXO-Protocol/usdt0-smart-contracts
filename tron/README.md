# Utexo USDT0 Contracts — Tron

Tron build of `UtexoSourceEntrypoint`. It sends source tokens through the Tron USDT0
OFT to the Utexo adapter on Arbitrum. The contract uses the same deposit ABI as the
Ethereum entrypoint, with Solidity 0.8.26 and TVM dependencies resolved through npm.

See the [root README](../README.md) for payload encoding, native fees and recovery.

## Setup

Use Node.js 20, as in CI, and install the locked dependencies:

```sh
cd tron
npm ci
npm run compile
```

`package-lock.json` resolves TronBox 4.8.0. `tronbox-config.js` selects compiler 0.8.26,
optimizer runs 200, `viaIR: true` and the Paris EVM target. Build artifacts are written
to `build/contracts/`. The Paris target excludes Shanghai's `PUSH0`, preserving
compatibility with TVM nodes that do not support that opcode.

## Local tests

`npm test` connects to the `development` network at `http://127.0.0.1:9095` by default.
For a TRE container listening on port 9090:

```sh
docker run -d --name usdt0-tron-dev -p 127.0.0.1:9095:9090 tronbox/tre
npm test
```

`HOST_PORT` changes the host port used by TronBox. The development network uses the
TRE fixture key unless `PRIVATE_KEY_DEVELOPMENT` is supplied. The migration skips
this network because the tests deploy their own contracts and mocks.

## Deployment

Copy the environment example and fill the inputs for the selected network. Token,
OFT and owner addresses must belong to that Tron network; `LZ_ADAPTER` is the adapter
on the destination Arbitrum network. The command below uses mainnet; testnet
deployments need the matching destination testnet EID and adapter.

```sh
cp .env.example .env
set -a
source .env
set +a

npx tronbox migrate --network mainnet \
  --token="$TOKEN_ADDRESS" \
  --oft="$OFT_ADDRESS" \
  --dst-eid="$DST_EID" \
  --lz-adapter="$LZ_ADAPTER" \
  --owner="$OWNER_ADDRESS"
```

Network keys are `PRIVATE_KEY_SHASTA`, `PRIVATE_KEY_NILE` and `PRIVATE_KEY_MAINNET`.
The migration requires all five flags:

| Flag | Value |
| --- | --- |
| `--token` | Source TRC-20 token |
| `--oft` | Source OFT whose `token()` equals `--token` |
| `--dst-eid` | Destination LayerZero EID; Arbitrum One uses 30110 |
| `--lz-adapter` | `0x` + 64 hex digits: twelve zero bytes followed by the nonzero Arbitrum address |
| `--owner` | Initial Tron owner, independent of the deployer |

`--token`, `--oft` and `--owner` accept Tron base58 addresses. The owner can pause
deposits and rotate ownership through `transferOwnership` and `acceptOwnership`.
Ownership cannot be renounced; routing parameters are immutable.

### Mainnet reference addresses

| Contract | Tron mainnet address |
| --- | --- |
| TRC-20 USDT | `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` |
| USDT0 OFT | `TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt` |

See [Tether's supported protocols](https://tether.to/en/supported-protocols/) and the
[USDT0 deployment registry](https://docs.usdt0.to/technical-documentation/deployments).
These addresses are for mainnet; use the selected testnet's contracts for test deployments.

## Registering the source on Arbitrum

The adapter registration method is:

```solidity
setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId)
```

Use the Tron LayerZero source EID and the `block.chainid` reported by the selected
Tron network. To encode a Tron entrypoint for `entrypoint`, remove the `41` network
prefix from its hex form and left-pad the remaining twenty bytes:

```js
const addressHex = tronWeb.address.toHex(entrypointBase58);
const entrypointBytes32 = '0x' + addressHex.replace(/^41/, '').padStart(64, '0');
```

Register the binding through `MultisigProxy.proposeAdminExecuteAdapter`, then execute
the proposal after its timelock. Configure the matching Bridge route and commission
policy on Arbitrum, and verify a complete deposit with the chosen source network.

## Files

```text
contracts/                  Entrypoint, interface and test mocks
migrations/                 Deployment migration
test/                      Local-node tests
tronbox-config.js           Networks and compiler settings
.env.example                Network keys and migration inputs
```
