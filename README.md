# Utexo USDT0 Contracts

Smart contracts for the USDT0/LayerZero integration layer of the Utexo bridge. This repository covers the **source-chain side** of cross-chain deposits: user-facing entrypoints that accept USDT (or USDT0) on chains such as Ethereum, OP, and Base, and forward them to Arbitrum via the USDT0 OFT and LayerZero V2.

The Arbitrum hub contracts (`Bridge`, `RouteRegistry`, per-route `FinalityVerifier` + `SettlementModule` plugins, `MultisigProxy`, `BtcRelay`) live in a separate repository, included here as a git submodule at `lib/bridge-smart-contracts`.

## Repository structure

```
ethereum/   — EVM contracts (Solidity, Foundry)
lib/
  bridge-smart-contracts/   — core bridge repo (git submodule)
```

## Architecture

```
  Source chain (Ethereum / OP / Base / …)
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   User ──► UtexoSourceEntrypoint ──► USDT0 OFT               │
  │                                           │                  │
  └───────────────────────────────────────────┼──────────────────┘
                                              │ LayerZero V2
                                              ▼
  Arbitrum
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   UtexoLZAdapter ──► Bridge ◀── MultisigProxy (TEE + Fed)    │
  │                          │                                   │
  │                   CommissionManager                          │
  │                          ▲                                   │
  │                       BtcRelay                               │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

### Flow

1. The user calls `UtexoSourceEntrypoint.deposit()` on the source chain, paying the LayerZero native fee. The caller supplies a `bytes payload` shaped as `abi.encode(uint256 destinationChainId, string destinationAddress, uint256 operationId, bytes settlementData)`.
2. The entrypoint decodes `payload` on the source chain (a malformed blob reverts here, before any LZ fee is paid), then re-encodes the actual `composeMsg` as `abi.encode(block.chainid, destinationChainId, destinationAddress, operationId, settlementData)` and forwards the tokens into the USDT0 OFT via `OFT.send()`. The `sourceChainId` half is captured from `block.chainid` and is therefore non-spoofable by the caller.
3. LayerZero delivers the tokens to Arbitrum and triggers `UtexoLZAdapter.lzCompose()`. The adapter checks that `composeFrom` (the source-chain `UtexoSourceEntrypoint` address, packed into the OFT message header by LayerZero itself) is in its `trustedEntrypoints` allowlist; an unknown source reverts before any Bridge interaction.
4. `UtexoLZAdapter` calls the adapter-only overload of `Bridge.fundsIn()` on Arbitrum (6-arg: `amount, sourceChainId, destinationChainId, destinationAddress, operationId, settlementData`), threading `sourceChainId` through for commission routing and `settlementData` through to the destination route's `ISettlementModule.onFundsIn`. If `Bridge.fundsIn` reverts (paused, route disabled, duplicate `operationId`, settlement module rejects, native-value mismatch, …) the inbound payload is parked on the adapter and recoverable via federation governance — see [Stuck funds](#stuck-funds).

### `settlementData`

An opaque blob plumbed end-to-end (`deposit` payload → `composeMsg` → `Bridge.fundsIn` → destination route's `SettlementModule`). The source-chain pipeline is route-agnostic: neither `UtexoSourceEntrypoint` nor `UtexoLZAdapter` inspects the bytes — the destination route's `SettlementModule` does. For LZ-adapter inbound routes currently registered with `NullSettlementModule` on the Bridge (e.g. EVM-source → Arbitrum → RGB), callers pass `""`. Routes whose module consumes settlement data start populating the blob once they go live; no contract change is required.

## Contracts

### `UtexoSourceEntrypoint` (`ethereum/src/UtexoSourceEntrypoint.sol`)

Deployed once per source chain. Non-upgradeable — all routing parameters are immutable:

| Immutable | Description |
|---|---|
| `token` | ERC-20 pulled from the user (canonical USDT on Ethereum; USDT0 on other chains) |
| `oft` | USDT0 OFT (adapter or native) on this source chain |
| `dstEid` | LayerZero endpoint id of the destination chain (Arbitrum = 30110) |
| `lzAdapter` | `UtexoLZAdapter` address on the destination chain, encoded as `bytes32` |

Key properties:
- Re-quotes the LayerZero fee on-chain — protects against stale off-chain quotes.
- Surplus `msg.value` is refunded to the caller.
- The owner can pause and resume deposits; fee quotes remain available while paused.
- Ownership transfers use a two-step flow: the pending owner must call `acceptOwnership()`.
- Ownership cannot be renounced, preserving access to the emergency pause controls.
- Upgrade = redeploy.

### `UtexoLZAdapter` (`ethereum/src/UtexoLZAdapter.sol`)

Deployed once on Arbitrum. Non-upgradeable — all five participating addresses (`endpoint`, `oft`, `token`, `bridge`, `multisigProxy`) are immutable. To repoint any of them the adapter must be redeployed and the reference rotated through `MultisigProxy` federation governance.

Two flows:

- **Inbound (`lzCompose`)** — invoked by the LayerZero endpoint when a USDT0 OFT message addressed to the adapter arrives on Arbitrum. The adapter first validates `composeFrom` against `trustedEntrypoints` (unknown sources revert `UntrustedComposeSource` before any token movement), then approves the `Bridge` and forwards the deposit into the 6-arg `Bridge.fundsIn`. The call is wrapped in `try/catch`: on revert the funds are stored on the adapter and a `ComposeFundsInFailed` event is emitted (see [Stuck funds](#stuck-funds)). The adapter's outer call always returns successfully so the LayerZero endpoint clears its compose queue.
- **Outbound (`sendOut`)** — restricted to `MultisigProxy`. Called from a TEE-signed `executeBatch` immediately after `Bridge.fundsOut(recipient = adapter)`. Re-quotes the LayerZero fee on-chain; any surplus `msg.value` is refunded to `tx.origin` (the backend relayer EOA that submitted the batch — `MultisigProxy` has no `receive()` and would reject a refund).

#### Trusted entrypoints

`UtexoLZAdapter` keeps a per-source-chain allowlist of `UtexoSourceEntrypoint` addresses (`mapping(bytes32 => bool) trustedEntrypoints`) and rejects any inbound `lzCompose` whose `composeFrom` is not in it. LayerZero itself packs the source-side OApp address into the OFT message header, so this gate is independent of `payload` contents — it stops a malicious OFT-compatible contract on any source chain from impersonating an entrypoint.

The allowlist is mutated by `setTrustedEntrypoint(bytes32 entrypoint, bool trusted)`, gated on `MultisigProxy`. Until at least one entrypoint is trusted after deployment, every inbound `lzCompose` reverts and the LZ compose queue stalls — see the [Post-deployment checklist](#post-deployment-checklist).

#### Stuck funds

When `Bridge.fundsIn` reverts inside `lzCompose`, the parked payload is recorded under `_stuckFunds[guid]`:

| Field | Description |
|---|---|
| `amountLD` | USDT0 minted onto the adapter by the OFT |
| `nativeValue` | Native (wei) the LayerZero Executor forwarded into `lzCompose` (non-zero for NATIVE-currency commission routes, 0 for TOKEN routes) |
| `sourceChainId` | EVM `block.chainid` of the source chain, captured by `UtexoSourceEntrypoint` at deposit time |
| `operationId`, `destinationChainId`, `destinationAddress` | Business fields copied from the decoded `composeMsg` for off-chain diagnostics |
| `settlementData` | Opaque blob from the original `composeMsg`, captured for off-chain debugging only — `refundStuckFunds` does not consume it (refunds are not retried as `fundsIn`) |

Read a record via `getStuckFunds(guid) returns (StuckFunds memory)`. `amountLD == 0` means "no record".

Release path — `refundStuckFunds(bytes32 guid, address recipient)`:

- Callable only by `multisigProxy` (federation governance gates this on its M-of-N timelock flow).
- Transfers `amountLD` USDT0 and any `nativeValue` to `recipient`, deletes the stored record, emits `StuckFundsRefunded`.
- Atomic: a failing native transfer reverts the entire call, so the record stays recoverable.

There is no on-chain retry — by the time `Bridge.fundsIn` reverts the inbound parameters are user-supplied and re-issuing the same call would deterministically fail again. The federation refunds out to a custodian address; the Utexo backend reimburses the original user off-chain from that custodian.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge + cast)
- Git

## Setup

```sh
# Clone with submodules
git clone --recurse-submodules https://github.com/UTEXO-Protocol/utexo-usdt0-contracts.git
cd utexo-usdt0-contracts

# Install Foundry dependencies
cd ethereum && forge install
```

If you already cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

## Commands

```sh
cd ethereum

forge build                                                          # compile
forge test                                                           # run all tests
forge test --match-path "test/UtexoSourceEntrypoint.t.sol" -vvv    # run one file with traces
forge coverage                                                        # coverage report
forge clean                                                           # delete out/ + cache/
```

## Deployment

Two scripts, one per contract. Both read `RPC_URL` + `PRIVATE_KEY` from the environment — point them at the chain you are deploying to (source chain for the entrypoint, Arbitrum for the adapter).

Copy `.env.example` to `.env` and fill in the values for whichever script you are about to run.

### `UtexoSourceEntrypoint` (source chain)

| Variable | Description |
|---|---|
| `TOKEN_ADDRESS` | ERC-20 pulled from users (canonical USDT on Ethereum; USDT0 on chains where it is native) |
| `OFT_ADDRESS` | USDT0 OFT (adapter or native) on this source chain |
| `DST_EID` | LayerZero endpoint id of the destination chain (Arbitrum One = 30110) |
| `LZ_ADAPTER` | `UtexoLZAdapter` address on the destination chain, left-padded to `bytes32` |
| `OWNER_ADDRESS` | Initial owner of the entrypoint; use the operational multisig in production |

```sh
forge script script/deploy/DeployUtexoSourceEntrypoint.s.sol \
  --rpc-url $RPC_URL --broadcast --verify
```

The initial owner is configured independently from the deployer through `OWNER_ADDRESS`. For production, set it directly to the operational multisig. Any later rotation uses `transferOwnership(newOwner)` followed by `acceptOwnership()` from the pending owner.

### `UtexoLZAdapter` (Arbitrum)

| Variable | Description |
|---|---|
| `LZ_ENDPOINT_ADDRESS` | LayerZero V2 EndpointV2 on Arbitrum |
| `OFT_ADDRESS` | USDT0 OFT on Arbitrum |
| `TOKEN_ADDRESS` | USDT0 token on Arbitrum |
| `BRIDGE_ADDRESS` | Utexo `Bridge` on Arbitrum |
| `MULTISIG_PROXY_ADDRESS` | Utexo `MultisigProxy` on Arbitrum |

```sh
forge script script/deploy/DeployUtexoLZAdapter.s.sol \
  --rpc-url $RPC_URL --broadcast --verify
```

The adapter has no owner. Mutable state (`trustedEntrypoints`, stuck-funds map) is gated on `MultisigProxy`.

## Post-deployment checklist

### `UtexoSourceEntrypoint`

1. Verify immutables: `token`, `oft`, `dstEid`, `lzAdapter` match expected values.
2. Verify `owner` is the expected account and `paused()` is `false`.
3. If ownership must be rotated, start the transfer and accept it from the pending owner.
4. Call `quote(params)` to confirm the OFT is reachable and returns a non-zero fee.
5. Do a test `deposit()` with a small amount on testnet to confirm token flow and event emission.

### `UtexoLZAdapter`

1. Verify immutables: `endpoint`, `oft`, `token`, `bridge`, `multisigProxy` match expected values.
2. From `MultisigProxy`, set `lzAdapter` on `Bridge` to the new adapter address (via the bridge-smart-contracts admin scripts). Until that rotation lands, the adapter-only `Bridge.fundsIn` overload reverts `NotLZAdapter` and inbound deposits get stuck.
3. From `MultisigProxy`, whitelist each source-chain `UtexoSourceEntrypoint` via `setTrustedEntrypoint(bytes32 entrypoint, true)`. The argument is the entrypoint address left-padded to 32 bytes — same shape as `LZ_ADAPTER` on the source side. **Until at least one entrypoint is trusted, every inbound `lzCompose` reverts `UntrustedComposeSource` and the LZ compose queue stalls.**
4. End-to-end smoke test: deposit a small amount on testnet from one of the whitelisted entrypoints and verify the `ComposeFundsIn` event fires on the adapter and `Bridge.fundsIn` lands the funds.
