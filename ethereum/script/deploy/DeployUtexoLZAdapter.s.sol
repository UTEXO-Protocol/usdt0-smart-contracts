// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script, console2 } from 'forge-std/Script.sol';
import { UtexoLZAdapter }   from '../../src/UtexoLZAdapter.sol';

/// @title DeployUtexoLZAdapter
/// @notice Deploys `UtexoLZAdapter` on the destination chain (Arbitrum). The
///         contract is non-upgradeable. Core wire addresses are immutable,
///         while local OFTs are routed per LayerZero EID and can be rotated by
///         `MultisigProxy` governance to support concurrent USDT0 meshes.
///
/// Env:
///   PRIVATE_KEY              — deployer private key
///   LZ_ENDPOINT_ADDRESS      — LayerZero V2 EndpointV2 on Arbitrum
///   OFT_EIDS                 — comma-separated LayerZero EIDs
///   OFT_ADDRESSES            — comma-separated local USDT0 OFTs, same order
///   TOKEN_ADDRESS            — USDT0 token on Arbitrum
///   BRIDGE_ADDRESS           — Utexo `Bridge` on Arbitrum
///   MULTISIG_PROXY_ADDRESS   — Utexo `MultisigProxy` on Arbitrum
///
/// Usage:
///   forge script script/deploy/DeployUtexoLZAdapter.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
///
/// Post-deployment:
///   1. Verify the four immutables and every EID/OFT route logged below.
///   2. On the Bridge side, set `lzAdapter` to the new address via
///      `MultisigProxy` (until that is done the adapter-only `Bridge.fundsIn`
///      overload reverts `NotLZAdapter`).
///   3. Bind each source EID to its source-chain `UtexoSourceEntrypoint` and
///      business chain id via `setTrustedEntrypoint` from `MultisigProxy`.
contract DeployUtexoLZAdapter is Script {
    function run() external returns (UtexoLZAdapter adapter) {
        uint256 pk             = vm.envUint('PRIVATE_KEY');
        address endpoint       = vm.envAddress('LZ_ENDPOINT_ADDRESS');
        address token          = vm.envAddress('TOKEN_ADDRESS');
        address bridge         = vm.envAddress('BRIDGE_ADDRESS');
        address multisigProxy  = vm.envAddress('MULTISIG_PROXY_ADDRESS');
        uint256[] memory rawEids = vm.envUint('OFT_EIDS', ',');
        address[] memory ofts    = vm.envAddress('OFT_ADDRESSES', ',');

        uint32[] memory eids = new uint32[](rawEids.length);
        for (uint256 i; i < rawEids.length; ++i) {
            require(rawEids[i] <= type(uint32).max, 'OFT_EID exceeds uint32');
            eids[i] = uint32(rawEids[i]);
        }

        vm.startBroadcast(pk);
        adapter = new UtexoLZAdapter(endpoint, token, bridge, multisigProxy, eids, ofts);
        vm.stopBroadcast();

        console2.log('UtexoLZAdapter deployed at:', address(adapter));
        console2.log('Endpoint:      ', adapter.endpoint());
        console2.log('Token:         ', adapter.token());
        console2.log('Bridge:        ', adapter.bridge());
        console2.log('MultisigProxy: ', adapter.multisigProxy());
        for (uint256 i; i < eids.length; ++i) {
            console2.log('OFT route EID: ', uint256(eids[i]));
            console2.log('OFT address:   ', adapter.oftByEid(eids[i]));
        }
    }
}
