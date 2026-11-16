// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PayeeRegistry} from "../src/PayeeRegistry.sol";
import {InvoiceBook} from "../src/InvoiceBook.sol";
import {AgentMandate} from "../src/AgentMandate.sol";
import {MockUSD8} from "../test/MockUSD8.sol";

// Minimal script cheatcodes (avoids a forge-std dependency).
interface ScriptVm {
    function envUint(string calldata) external returns (uint256);
    function envOr(string calldata, address) external returns (address);
    function envOr(string calldata, bool) external returns (bool);
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

/// @notice Deploys PayeeGuard (PayeeRegistry + InvoiceBook + AgentMandate) and wires the
/// mandate contract into the book.
/// Env:
///   DEPLOYER_PRIVATE_KEY  (required) payer/owner key
///   TUSD8_ADDRESS         (optional) defaults to the real Aevum tUSD8
///   DEPLOY_MOCK_TOKEN     (optional, local rehearsal only) deploy MockUSD8 instead
/// Usage (testnet):
///   DEPLOYER_PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url aevum --broadcast
/// The deployed addresses are printed in the broadcast log (broadcast/Deploy.s.sol/<chainId>/run-latest.json)
/// and copied into deployments.json by the operator / agent tooling.
contract Deploy {
    ScriptVm internal vm = ScriptVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address internal constant REAL_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (address registry, address book, address mandate, address token) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        bool mock = vm.envOr("DEPLOY_MOCK_TOKEN", false);
        token = vm.envOr("TUSD8_ADDRESS", REAL_TUSD8);

        vm.startBroadcast(pk);
        if (mock) {
            token = address(new MockUSD8());
        }
        PayeeRegistry reg = new PayeeRegistry();
        InvoiceBook bk = new InvoiceBook(address(reg), token);
        AgentMandate md = new AgentMandate();
        bk.setMandateContract(address(md));
        vm.stopBroadcast();

        return (address(reg), address(bk), address(md), token);
    }
}
