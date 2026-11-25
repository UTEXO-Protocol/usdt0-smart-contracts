// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {UtexoLZAdapter} from "../../src/UtexoLZAdapter.sol";

/// @title DeployUtexoLZAdapter
/// @notice Deploys the Arbitrum adapter and its initial EID-to-OFT routes.
/// @dev Inputs: `PRIVATE_KEY`, `LZ_ENDPOINT_ADDRESS`, `TOKEN_ADDRESS`, `BRIDGE_ADDRESS`,
///      `MULTISIG_PROXY_ADDRESS`, `OFT_EIDS`, `OFT_ADDRESSES`.
///      Governance configures Bridge, MultisigProxy and trusted source bindings separately.
contract DeployUtexoLZAdapter is Script {
    function run() external returns (UtexoLZAdapter adapter) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address endpoint = vm.envAddress("LZ_ENDPOINT_ADDRESS");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address multisigProxy = vm.envAddress("MULTISIG_PROXY_ADDRESS");
        uint256[] memory rawEids = vm.envUint("OFT_EIDS", ",");
        address[] memory ofts = vm.envAddress("OFT_ADDRESSES", ",");

        uint32[] memory eids = new uint32[](rawEids.length);
        for (uint256 i; i < rawEids.length; ++i) {
            require(rawEids[i] <= type(uint32).max, "OFT_EID exceeds uint32");
            eids[i] = uint32(rawEids[i]);
        }

        vm.startBroadcast(pk);
        adapter = new UtexoLZAdapter(endpoint, token, bridge, multisigProxy, eids, ofts);
        vm.stopBroadcast();

        console2.log("UtexoLZAdapter deployed at:", address(adapter));
        console2.log("Endpoint:      ", adapter.endpoint());
        console2.log("Token:         ", adapter.token());
        console2.log("Bridge:        ", adapter.bridge());
        console2.log("MultisigProxy: ", adapter.multisigProxy());
        for (uint256 i; i < eids.length; ++i) {
            console2.log("OFT route EID: ", uint256(eids[i]));
            console2.log("OFT address:   ", adapter.oftByEid(eids[i]));
        }
    }
}
