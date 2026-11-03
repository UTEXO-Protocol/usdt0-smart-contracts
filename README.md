# Utexo USDT0 Contracts

Source entrypoints and the Arbitrum adapter for Utexo deposits and withdrawals through
USDT0 OFT and LayerZero V2. Ethereum and Tron have separate entrypoint builds.

The hub contracts, including `Bridge`, `MultisigProxy`, `CommissionManager` and
`RouteRegistry`, are provided by the pinned `lib/bridge-smart-contracts` submodule.

## Repository layout

```text
ethereum/
  src/                 EVM entrypoint, Arbitrum adapter and interfaces
  script/deploy/       Foundry deployment scripts
  test/                Foundry tests and mocks
  lib/                 Foundry dependencies
tron/
  contracts/           Tron entrypoint, interface and mocks
  migrations/          TronBox deployment migration
  test/                Tests against a local Tron node
lib/bridge-smart-contracts/
                       Hub contracts and route plugins
```

## Deposit flow

```text
Source chain: caller -> UtexoSourceEntrypoint -> source OFT
                                                  |
                                              LayerZero
                                                  |
Arbitrum: destination OFT -> UtexoLZAdapter -> Bridge -> route settlement module
```

1. The caller approves the source token and calls `deposit` with a token amount,
   destination payload and LayerZero execution options.
2. The entrypoint adds the source `block.chainid` and caller address to the compose
   payload, quotes the LayerZero fee and submits the OFT send.
3. The destination OFT credits tokens to the Arbitrum adapter and queues a compose
   message. Token credit and compose execution occur in separate transactions.
4. The endpoint invokes `lzCompose`. The adapter checks the local OFT, source
   entrypoint, source chain id and native value, then calls `Bridge.fundsIn`.
5. The selected Bridge route handles the settlement payload. A successful deposit
   emits `ComposeFundsIn` with the operation id returned by Bridge.

LayerZero EIDs identify transport endpoints; chain ids identify Bridge networks.
They are different values:

| Network | Chain id | LayerZero EID |
| --- | --- | --- |
| Ethereum mainnet | 1 | 30101 |
| Arbitrum One | 42161 | 30110 |
| RGB | 827166 | Not used by the source-to-Arbitrum transport |

### Deposit parameters

`DepositParams` contains:

| Field | Meaning |
| --- | --- |
| `amountLD` | Requested source token amount, in local token decimals; must be nonzero |
| `minAmountLD` | Minimum destination amount accepted by the OFT after its fees or rounding |
| `extraOptions` | LayerZero executor options, combined with options enforced by the source OFT |
| `payload` | Final destination and settlement data, encoded as shown below |
| `refundTo` | Source-chain native-surplus recipient and OFT refund address; zero selects the caller |
| `expectedComposeValue` | Exact native value expected by the Arbitrum compose call, in wei |

The payload is:

```solidity
abi.encode(uint256 destinationChainId, string destinationAddress, bytes settlementData)
```

The chain id must be nonzero. The entrypoint limits `destinationAddress` to 512 bytes
and `settlementData` to 128 bytes. These bounds are also enforced by the adapter.

For the canonical RGB settlement module, use network id `827166`, an empty
`destinationAddress`, and the mint OpId encoded in settlement data:

```solidity
abi.encode(uint256(827166), "", abi.encode(uint256(rgbOpId)))
```

The RGB destination address is carried in the consignment. Other routes define their
own settlement data; use empty settlement data for a route with `NullSettlementModule`.

The entrypoint constructs the compose message as:

```solidity
abi.encode(
    block.chainid,
    bytes32(uint256(uint160(msg.sender))),
    destinationChainId,
    destinationAddress,
    settlementData,
    expectedComposeValue
)
```

### Native fees

The caller supplies the LayerZero fee in source-chain native currency. The entrypoint
re-quotes immediately before the send and refunds surplus to `refundTo`, or the caller
when `refundTo` is zero. A failed surplus refund reverts the source transaction.

On Arbitrum, `expectedComposeValue` must equal the value delivered to `lzCompose`.
Set the executor options accordingly, including any enforced options on the source
OFT. The entrypoint does not inspect these options; a value mismatch reverts compose
before a recovery record is created. The forwarded value is used by `Bridge.fundsIn`,
including any native commission required by the route.

`quote` uses the same compose encoding and remains available while deposits are
paused. It rejects zero amounts and zero destination chain ids, but does not check
the caller's balance, allowance or the destination route's current state.

## Arbitrum adapter

`endpoint`, `token`, `bridge` and `multisigProxy` are immutable. The adapter has no owner;
its administrative methods accept calls only from the configured MultisigProxy.

`oftByEid` selects a local Arbitrum OFT for each remote LayerZero EID. A configured OFT
must contain code, report the adapter token through `token()`, and have a nonzero
peer for that EID. `setOftRoute(eid, address(0))` revokes the route.

`setTrustedEntrypoint(uint32 srcEid, bytes32 entrypoint, uint256 chainId)` binds the
source entrypoint and source chain id to a transport EID. A zero entrypoint revokes
both values. Route and source-binding changes also affect messages awaiting compose.

### Outbound transfers

`MultisigProxy.lzFundsOutCall` uses enclave signatures to authorize a Bridge release
to the adapter, then calls `sendOut` with the amount the adapter actually received.
Both steps are atomic. The adapter selects the OFT by destination EID and submits a
token-only send with an empty compose message. Native surplus is refunded to
`tx.origin`, not to MultisigProxy.

OFT route changes, source bindings and recovery calls use federation governance through
`proposeAdminExecuteAdapter` followed by `executeProposal` after the timelock.

### Failed deposits and recovery

If the business payload cannot be decoded, the adapter records the OFT-credited token
amount and native value, leaving the unknown business fields at their defaults. If
`Bridge.fundsIn` reverts and allowance cleanup succeeds, the adapter records the
full decoded deposit and revert data. A recorded failure emits `ComposeFundsInFailed`
and completes the compose call.

Authentication, payload-size, source-chain and compose-value checks revert without
recording a failure. A failed allowance cleanup or record write also reverts compose.
These messages remain pending at the endpoint and can be retried.

`getStuckFunds(guid)` reads a record. `refundStuckFunds(guid, recipient)` requires a
positive recorded token amount and transfers it, together with any recorded native
value, to the selected Arbitrum recipient. A failed transfer restores the record and
reserve counter. Recorded deposits are refunded rather than retried through the adapter.

`totalRecordedStuckToken` reserves tokens for recorded failures. `sendOut` and
`recoverUntrackedToken` cannot consume this reserve. However, the balance above it
also includes OFT credits whose compose has not executed. Confirm which messages
are pending before recovering that balance; unreserved does not mean unused.

## Build and test

```sh
git clone --recurse-submodules https://github.com/UTEXO-Protocol/usdt0-smart-contracts.git
cd usdt0-smart-contracts/ethereum
forge build
forge test
forge fmt --check
```

For an existing checkout, initialize the pinned dependencies from the repository root:

```sh
git submodule update --init --recursive
```

See [Tron setup and deployment](tron/README.md) for the TVM build and local-node tests.
CI runs the Foundry suite and compiles the Tron contracts; it does not run Tron
integration tests.

## Deployment

From `ethereum/`, copy `.env.example` to `.env` and set values for the selected script.
The same `TOKEN_ADDRESS` variable means the source token for an entrypoint deployment
and the Arbitrum token for an adapter deployment.

```sh
cp .env.example .env
set -a
source .env
set +a

# Source chain
forge script script/deploy/DeployUtexoSourceEntrypoint.s.sol \
  --rpc-url "$RPC_URL" --broadcast --verify

# Arbitrum, using its own RPC and configuration
forge script script/deploy/DeployUtexoLZAdapter.s.sol \
  --rpc-url "$RPC_URL" --broadcast --verify
```

The entrypoint constructor checks that `oft.token()` matches `TOKEN_ADDRESS` and that
`LZ_ADAPTER` is a nonzero EVM address left-padded with twelve zero bytes. Its initial
owner comes from `OWNER_ADDRESS`. The owner can pause deposits, transfer ownership
in two steps, and cannot renounce ownership. Routing changes require a new entrypoint.

Before accepting deposits:

1. Verify deployed addresses, entrypoint ownership, EID/OFT routes and remote peers.
2. Configure the adapter on Bridge with `setLZAdapter`, and on MultisigProxy through
   `proposeUpdateLZAdapter` and proposal execution.
3. Register each source entrypoint with its LayerZero EID and actual source chain id
   through the adapter governance lane.
4. Enable the Bridge route with the intended settlement module, configure execution
   options, and verify the complete deposit flow on the selected test networks.
