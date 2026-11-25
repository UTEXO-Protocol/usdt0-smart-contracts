// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {UtexoSourceEntrypoint} from "../../src/UtexoSourceEntrypoint.sol";

/// @title DeployUtexoSourceEntrypoint
/// @notice Deploys a source entrypoint with the configured initial owner.
/// @dev Inputs: `PRIVATE_KEY`, `TOKEN_ADDRESS`, `OFT_ADDRESS`, `DST_EID`, `LZ_ADAPTER`,
///      `OWNER_ADDRESS`. The adapter is an Arbitrum address encoded as bytes32.
contract DeployUtexoSourceEntrypoint is Script {
    function run() external returns (UtexoSourceEntrypoint entrypoint) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address oft = vm.envAddress("OFT_ADDRESS");
        uint32 dstEid = uint32(vm.envUint("DST_EID"));
        bytes32 lzAdapter = vm.envBytes32("LZ_ADAPTER");
        address owner = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast(pk);
        entrypoint = new UtexoSourceEntrypoint(token, oft, dstEid, lzAdapter, owner);
        vm.stopBroadcast();

        console2.log("UtexoSourceEntrypoint deployed at:", address(entrypoint));
        console2.log("Token:     ", entrypoint.token());
        console2.log("OFT:       ", entrypoint.oft());
        console2.log("DstEid:    ", entrypoint.dstEid());
        console2.log("Owner:     ", entrypoint.owner());
        console2.log("LZAdapter: ");
        console2.logBytes32(entrypoint.lzAdapter());
    }
}
