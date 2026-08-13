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

1. The user calls `UtexoSourceEntrypoint.deposit()` on the source chain, paying the LayerZero native fee. The caller supplies a `bytes payload` shaped as `abi.encode(uint256 destinationChainId, string destinationAddress, bytes settlementData)`.
2. The entrypoint decodes `payload` on the source chain, then builds `composeMsg` from `block.chainid`, the authenticated `msg.sender`, the destination fields and `expectedComposeValue`, and forwards the tokens through the source-chain USDT0 OFT.
3. LayerZero delivers the tokens to Arbitrum and triggers `UtexoLZAdapter.lzCompose()`. The adapter uses the protocol-stamped `srcEid` to select the expected Arbitrum OFT from `oftByEid`, then validates both `_from` and the source entrypoint binding before any Bridge interaction. This permits native and legacy USDT0 meshes to coexist without trusting an OFT for the wrong source EID.
4. `UtexoLZAdapter` calls the adapter-only overload of `Bridge.fundsIn()` on Arbitrum with the credited amount, source chain/sender, destination fields and settlement data. If the Bridge call reverts, the inbound payload is parked on the adapter and recoverable via federation governance — see [Stuck funds](#stuck-funds).

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

Deployed once on Arbitrum. Non-upgradeable — `endpoint`, `token`, `bridge`, and `multisigProxy` are immutable. Local OFTs are stored per LayerZero EID in `oftByEid`; federation governance can add, replace, or revoke routes with `setOftRoute`. A non-zero route is accepted only if the OFT exposes the same immutable token and has a non-zero peer for that EID.

Two flows:

- **Inbound (`lzCompose`)** — invoked by the LayerZero endpoint when a USDT0 OFT message addressed to the adapter arrives on Arbitrum. The adapter selects the expected local OFT by `srcEid`, validates `_from`, then checks `composeFrom` against the entrypoint bound to that EID. It approves the `Bridge` and forwards the deposit into `Bridge.fundsIn`. A Bridge revert is parked under the message guid and emits `ComposeFundsInFailed` (see [Stuck funds](#stuck-funds)).
- **Outbound (`sendOut`)** — restricted to `MultisigProxy`. Called from a TEE-signed `executeBatch` immediately after `Bridge.fundsOut(recipient = adapter)`. The adapter selects the local OFT by `dstEid`, re-quotes the LayerZero fee on-chain, and sends through that route. Any surplus `msg.value` is refunded to `tx.origin`.

#### Trusted entrypoints

`UtexoLZAdapter` keeps a transport-bound registry (`mapping(uint32 => bytes32) trustedEntrypoints`) and rejects any inbound `lzCompose` whose `composeFrom` does not match the entrypoint registered for its `srcEid`. The business `sourceChainId` is stored alongside it in `eidToChainId` and checked against the payload.

The binding is mutated by `setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId)`, gated on `MultisigProxy`. Passing a zero entrypoint revokes both the entrypoint and chain-id binding.

#### Stuck funds

When `Bridge.fundsIn` reverts inside `lzCompose`, the parked payload is recorded under `_stuckFunds[guid]`:

| Field | Description |
|---|---|
| `amountLD` | USDT0 minted onto the adapter by the OFT |
| `nativeValue` | Native (wei) the LayerZero Executor forwarded into `lzCompose` (non-zero for NATIVE-currency commission routes, 0 for TOKEN routes) |
| `sourceChainId` | EVM `block.chainid` of the source chain, captured by `UtexoSourceEntrypoint` at deposit time |
| `sourceSender`, `destinationChainId`, `destinationAddress` | Authenticated sender and destination fields copied from the decoded `composeMsg` for off-chain diagnostics |
| `settlementData` | Opaque blob from the original `composeMsg`, captured for off-chain debugging only — `refundStuckFunds` does not consume it (refunds are not retried as `fundsIn`) |

Read a record via `getStuckFunds(guid) returns (StuckFunds memory)`. `amountLD == 0` means "no record".

Release path — `refundStuckFunds(bytes32 guid, address recipient)`:

- Callable only by `multisigProxy` (federation governance gates this on its M-of-N timelock flow).
- Transfers `amountLD` USDT0 and any `nativeValue` to `recipient`, deletes the stored record, emits `StuckFundsRefunded`.
- Atomic: a failing native transfer reverts the entire call, so the record stays recoverable.

There is no on-chain retry — by the time `Bridge.fundsIn` reverts the inbound parameters are user-supplied and re-issuing the same call would deterministically fail again. The federation refunds out to a custodian address; the Utexo backend reimburses the original user off-chain from that custodian.

If the OFT credited tokens but `lzCompose` failed before a guid record could be created (for example, an OFT-route mismatch), `recoverUntrackedToken` can recover only the adapter balance above `totalRecordedStuckToken`. Therefore this incident path cannot consume funds reserved by live stuck records.

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
| `OFT_EIDS` | Comma-separated LayerZero EIDs served by the adapter |
| `OFT_ADDRESSES` | Comma-separated Arbitrum OFTs corresponding positionally to `OFT_EIDS` |
| `TOKEN_ADDRESS` | USDT0 token on Arbitrum |
| `BRIDGE_ADDRESS` | Utexo `Bridge` on Arbitrum |
| `MULTISIG_PROXY_ADDRESS` | Utexo `MultisigProxy` on Arbitrum |

```sh
forge script script/deploy/DeployUtexoLZAdapter.s.sol \
  --rpc-url $RPC_URL --broadcast --verify
```

The adapter has no owner. Governance methods for OFT routes, trusted entrypoints and recovery are gated on `MultisigProxy`.

## Post-deployment checklist

### `UtexoSourceEntrypoint`

1. Verify immutables: `token`, `oft`, `dstEid`, `lzAdapter` match expected values.
2. Verify `owner` is the expected account and `paused()` is `false`.
3. If ownership must be rotated, start the transfer and accept it from the pending owner.
4. Call `quote(params)` to confirm the OFT is reachable and returns a non-zero fee.
5. Do a test `deposit()` with a small amount on testnet to confirm token flow and event emission.

### `UtexoLZAdapter`

1. Verify immutables (`endpoint`, `token`, `bridge`, `multisigProxy`) and every `oftByEid` route. Confirm each local OFT has the expected remote peer for its EID.
2. From `MultisigProxy`, set `lzAdapter` on `Bridge` to the new adapter address (via the bridge-smart-contracts admin scripts). Until that rotation lands, the adapter-only `Bridge.fundsIn` overload reverts `NotLZAdapter` and inbound deposits get stuck.
3. From `MultisigProxy`, bind each source EID via `setTrustedEntrypoint(srcEid, entrypoint, chainId)`. The entrypoint is left-padded to 32 bytes. Until the binding exists, inbound compose for that EID reverts `UntrustedComposeSource`.
4. End-to-end smoke test: deposit a small amount on testnet from one of the whitelisted entrypoints and verify the `ComposeFundsIn` event fires on the adapter and `Bridge.fundsIn` lands the funds.
