// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRegistries} from "../script/Deploy.s.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../src/AgentValidationRegistry.sol";

/// @dev Calls the script's pure deployment function directly (no environment, no broadcast) and runs one
///      end-to-end scenario across the three registries.
contract DeployTest is Test {
    DeployRegistries.Deployment internal d;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal client = makeAddr("client");
    address internal validator = makeAddr("validator");

    function setUp() public {
        d = new DeployRegistries().deployAll();
    }

    function test_DeployAll_WiresRegistries() public view {
        assertTrue(address(d.identity) != address(0));
        assertEq(address(d.reputation.identityRegistry()), address(d.identity));
        assertEq(address(d.validation.identityRegistry()), address(d.identity));
        assertEq(d.identity.totalAgents(), 0);
        assertEq(d.identity.name(), "Agent Identity");
        assertEq(d.identity.symbol(), "AGENT");
    }

    function test_EndToEnd_RegisterRateValidateTransfer() public {
        AgentIdentityRegistry identity = d.identity;
        AgentReputationRegistry reputation = d.reputation;
        AgentValidationRegistry validation = d.validation;

        vm.prank(alice);
        uint256 agent = identity.register("ipfs://agent");

        // A client rates the agent; the owner cannot.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, alice));
        reputation.giveFeedback(agent, bytes32("job"), 100, 0, 0, "", 0);
        vm.prank(client);
        reputation.giveFeedback(agent, bytes32("job"), 75, 0, 0, "ipfs://e", keccak256("e"));

        // The owner requests validation; the validator answers once.
        vm.prank(alice);
        bytes32 req = validation.requestValidation(agent, validator, "ipfs://r", keccak256("r"));
        vm.prank(validator);
        validation.submitResponse(req, 90, "", 0);

        // Transfer: control moves, history stays.
        vm.prank(alice);
        identity.safeTransferFrom(alice, bob, agent);
        vm.prank(bob);
        identity.setAgentURI(agent, "ipfs://agent-v2");
        assertEq(identity.tokenURI(agent), "ipfs://agent-v2");

        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 1);
        assertEq(sum, 75);
        assertEq(avg, 75);
        assertEq(validation.request(req).response, 90);
        assertEq(validation.request(req).requester, alice);

        // The new owner is now the one who cannot self-rate, and the old owner can.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, bob));
        reputation.giveFeedback(agent, bytes32("job-2"), 100, 0, 0, "", 0);
        vm.prank(alice);
        reputation.giveFeedback(agent, bytes32("job-2"), 25, 0, 0, "", 0);
        (count, sum, avg) = reputation.summary(agent);
        assertEq(count, 2);
        assertEq(sum, 100);
        assertEq(avg, 50);
    }
}
