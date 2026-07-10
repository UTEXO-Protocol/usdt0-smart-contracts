# Utexo USDT0 Contracts — Tron

Tron-side deployment of `UtexoSourceEntrypoint` for the Utexo bridge. Same Solidity sources as `ethereum/src/UtexoSourceEntrypoint.sol`, copied here so the Tron toolchain (TronBox) can build and deploy them independently of the Foundry-based EVM setup.

For protocol architecture, payload format and the overall flow (source chain → USDT0 OFT → Arbitrum `UtexoLZAdapter` → `Bridge`), see the [top-level README](../README.md). This document only covers Tron-specific operations.

## Contracts

```
contracts/
├── UtexoSourceEntrypoint.sol            — production entrypoint (1:1 copy of ethereum/src/…)
├── interfaces/IUtexoSourceEntrypoint.sol
└── mocks/                                — test-only stubs
    ├── MockERC20.sol
    └── MockOFT.sol
```

`UtexoSourceEntrypoint` constructor takes four routing parameters plus an initial owner — exact same semantics as on EVM source chains:

| Param | Description |
|---|---|
| `token` | TRC20 USDT (mainnet: `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`) |
| `oft` | USDT0 OFT on Tron (mainnet: `TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt`) |
| `dstEid` | LayerZero V2 destination endpoint id (Arbitrum: `30110`) |
| `lzAdapter` | `UtexoLZAdapter` on Arbitrum, encoded as `bytes32` |
| `initialOwner` | Initial owner of the entrypoint; use the operational multisig in production |

The configured initial owner can differ from the deployer and can pause or resume deposits. Ownership
transfers use OpenZeppelin's two-step flow, so the pending owner must call
`acceptOwnership()`. Ownership renunciation is disabled to ensure the emergency
pause controls always remain recoverable.

## Toolchain

- **TronBox 4.7.1** — pinned in `package.json`. Newer/older versions may break npm-package resolution.
- **solc 0.8.20** with `viaIR: true` and `evmVersion: 'paris'`. The `paris` setting is mandatory: Tron's TVM does not implement the `PUSH0` opcode, so Shanghai-emitting builds would fail at runtime.
- **Dependencies** (`@openzeppelin/contracts`, `@layerzerolabs/lz-evm-*`) are installed via npm and resolved directly from `node_modules/` by TronBox.

## Prerequisites

- Node.js ≥ 18
- (For tests) Docker — to run [Tron Quickstart / TRE](https://hub.docker.com/r/tronbox/tre)

## Setup

```sh
cd tron
npm install
```

## Compile

```sh
npx tronbox compile
```

Artifacts land in `build/contracts/UtexoSourceEntrypoint.json`.

## Test

Tests live in `test/UtexoSourceEntrypoint.test.js` (Mocha + chai under `tronbox test`). They mirror the Foundry tests in `ethereum/test/UtexoSourceEntrypoint.t.sol` and exercise the entrypoint against `MockERC20` and `MockOFT` stubs deployed inside a local Tron node.

Start a local Tron node (one-time):

```sh
docker run -d --name tre -p 9090:9090 tronbox/tre
```

Then:

```sh
npx tronbox test --network development
```

## Deploy

Deployer keys are read from `.env` — copy the template:

```sh
cp .env.example .env
```

Fill in the relevant `PRIVATE_KEY_<NETWORK>` (`MAINNET`, `SHASTA` or `NILE`).

Run the migration with the four `--flag=value` parameters declared by `migrations/1_deploy_entrypoint.js`:

```sh
npx tronbox migrate --network shasta \
  --token=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t \
  --oft=TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt \
  --dst-eid=30110 \
  --lz-adapter=0x0000000000000000000000001234567890abcdef1234567890abcdef12345678 \
  --owner=<initial-owner-address>
```

Notes on the flags:

- `--token` and `--oft` accept Tron `T...` base58 form (TronBox / TronWeb auto-convert internally).
- `--lz-adapter` is the **destination-chain** `UtexoLZAdapter` address. Pass the full `bytes32` form (`0x` + 64 hex chars) — i.e. the 20-byte EVM address left-padded with 12 zero bytes.
- `--owner` is independent from the deployer; use the operational multisig address in production.

The `development` network is intentionally skipped by the migration — that path is owned by the test suite.

## Post-deployment checklist

1. **Verify immutables** via Tronscan or `tronWeb.contract(abi, addr).method().call()`: `token`, `oft`, `dstEid`, `lzAdapter` match what you passed.
2. **Verify emergency controls** — check that `owner()` is the expected account and `paused()` is `false`.
3. **Rotate ownership if needed** — call `transferOwnership(newOwner)`, then have the pending owner call `acceptOwnership()`.
4. **Federation registration on Arbitrum** — the deployed entrypoint must be added to the trusted set on the destination chain. The value federation passes into `LZAdapter.setTrustedEntrypoint(bytes32, true)` is the Tron entrypoint's 20-byte EVM address left-padded to `bytes32` (i.e. `tronWeb.address.toHex(entrypointBase58).replace(/^41/, '')` left-padded). This goes through `MultisigProxy.proposeAdminExecuteAdapter` → timelock → `executeProposal`.
5. **Backend updates** — the Utexo backend must add the Tron `block.chainid` to its `CommissionManager` route keys on Arbitrum so commissions are quoted correctly for Tron→destination deposits.
6. **Smoke test** with a small `deposit()` on Shasta/Nile before exercising mainnet flow.

## Project structure

```
tron/
├── contracts/                       — Solidity sources + mocks
├── migrations/
│   └── 1_deploy_entrypoint.js       — TronBox migration (CLI flags)
├── test/
│   └── UtexoSourceEntrypoint.test.js
├── tronbox-config.js                — networks + compiler settings
├── package.json                     — npm deps, tronbox pinned to 4.7.1
└── .env.example                     — deployer keys template
```
