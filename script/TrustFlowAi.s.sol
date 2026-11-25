// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {TrustFlowEscrow} from "../src/TrustFlowai.sol";

contract TrustFlowAiScript is Script {
    TrustFlowEscrow public trustFlowEscrow;

    function run() public {
        uint256 feeBps = vm.envUint("FEE_BPS");
        require(feeBps <= 1_500, "Fee exceeds maximum");

        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address agentWallet = vm.envAddress("AGENT_WALLET");
        address resolverAddress = vm.envAddress("RESOLVER_ADDRESS");
        address treasuryAddress = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();
        trustFlowEscrow =
            new TrustFlowEscrow(usdcAddress, agentWallet, resolverAddress, treasuryAddress, uint16(feeBps));
        vm.stopBroadcast();
    }
}
