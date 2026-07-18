// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {Roulette} from "../src/Roulette.sol";

/// @title DeployRoulette
/// @notice Deploys {Roulette} wired to Chainlink VRF v2.5 on Sepolia.
/// @dev Prerequisites (one-time, via https://vrf.chain.link on the Sepolia network):
///        1. Create a VRF v2.5 subscription and fund it with test LINK (and/or native ETH).
///        2. After this script prints the deployed address, add it as a consumer on that
///           subscription so the coordinator will call fulfillRandomWords back into it.
///      The subscription id is read from the VRF_SUBSCRIPTION_ID env var (a uint256 — v2.5
///      ids are large 256-bit numbers, not the small uint64 ids from VRF v2).
///
///      Run:
///        forge script script/DeployRoulette.s.sol:DeployRoulette \
///          --rpc-url $SEPOLIA_RPC_URL --account <keystore> --broadcast --verify
contract DeployRoulette is Script {
    /// @notice Chainlink VRF v2.5 coordinator on Sepolia.
    /// @dev https://docs.chain.link/vrf/v2-5/supported-networks#sepolia-testnet
    address public constant SEPOLIA_VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;

    /// @notice Deploys the contract using VRF_SUBSCRIPTION_ID from the environment.
    /// @return roulette The deployed Roulette instance.
    function run() external returns (Roulette roulette) {
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");

        vm.startBroadcast();
        roulette = new Roulette(SEPOLIA_VRF_COORDINATOR, subscriptionId);
        vm.stopBroadcast();

        console2.log("Roulette deployed at:", address(roulette));
        console2.log("VRF coordinator:      ", SEPOLIA_VRF_COORDINATOR);
        console2.log("VRF subscription id:  ", subscriptionId);
        console2.log("Next step: add this address as a consumer on the subscription at https://vrf.chain.link");
    }
}
