// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../src/AgentValidationRegistry.sol";

/// @title DeployRegistries
/// @notice Deploys the identity registry and wires the reputation and validation registries to it. There are no
///         constructor parameters other than that wiring, and no post-deploy configuration: none of the contracts
///         has an owner or any privileged role. This script is reviewable reference only; the assignment does not
///         deploy anywhere.
contract DeployRegistries is Script {
    struct Deployment {
        AgentIdentityRegistry identity;
        AgentReputationRegistry reputation;
        AgentValidationRegistry validation;
    }

    /// @notice Pure deployment logic, called directly by the tests. Does not read the environment.
    function deployAll() public returns (Deployment memory d) {
        d.identity = new AgentIdentityRegistry();
        d.reputation = new AgentReputationRegistry(address(d.identity));
        d.validation = new AgentValidationRegistry(address(d.identity));
    }

    /// @notice Entry point for `forge script`. Broadcasts with whatever signer the operator passes on the CLI.
    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        d = deployAll();
        vm.stopBroadcast();
    }
}
