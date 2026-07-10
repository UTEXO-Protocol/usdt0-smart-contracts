// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script, console2 } from 'forge-std/Script.sol';
import { UtexoSourceEntrypoint } from '../../src/UtexoSourceEntrypoint.sol';

/// @title DeployUtexoSourceEntrypoint
/// @notice Deploys `UtexoSourceEntrypoint` on a source chain (Ethereum, OP, Base, …).
///         The contract is non-upgradeable and has owner-controlled emergency pause.
///         To update a routing parameter, redeploy and point the frontend to the new address.
///
/// Env:
///   PRIVATE_KEY          — deployer private key
///   TOKEN_ADDRESS        — ERC-20 pulled from users (canonical USDT on Ethereum;
///                          USDT0 token on chains where it is native)
///   OFT_ADDRESS          — USDT0 OFT (adapter or native) on this source chain
///   DST_EID              — LayerZero endpoint id of the destination chain
///                          (Arbitrum = 30110)
///   LZ_ADAPTER           — UtexoLZAdapter address on the destination chain,
///                          left-padded to 32 bytes (bytes32)
///                          e.g. 0x000000000000000000000000<UtexoLZAdapter address>
///   OWNER_ADDRESS        — initial owner of the entrypoint
///
/// Usage:
///   forge script script/deploy/DeployUtexoSourceEntrypoint.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployUtexoSourceEntrypoint is Script {
    function run() external returns (UtexoSourceEntrypoint entrypoint) {
        uint256 pk         = vm.envUint('PRIVATE_KEY');
        address token      = vm.envAddress('TOKEN_ADDRESS');
        address oft        = vm.envAddress('OFT_ADDRESS');
        uint32  dstEid     = uint32(vm.envUint('DST_EID'));
        bytes32 lzAdapter  = vm.envBytes32('LZ_ADAPTER');
        address owner      = vm.envAddress('OWNER_ADDRESS');

        vm.startBroadcast(pk);
        entrypoint = new UtexoSourceEntrypoint(token, oft, dstEid, lzAdapter, owner);
        vm.stopBroadcast();

        console2.log('UtexoSourceEntrypoint deployed at:', address(entrypoint));
        console2.log('Token:     ', entrypoint.token());
        console2.log('OFT:       ', entrypoint.oft());
        console2.log('DstEid:    ', entrypoint.dstEid());
        console2.log('Owner:     ', entrypoint.owner());
        console2.log('LZAdapter: ');
        console2.logBytes32(entrypoint.lzAdapter());
    }
}
