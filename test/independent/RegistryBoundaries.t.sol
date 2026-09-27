// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryFixture} from "./RegistryFixture.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract IndependentRegistryBoundariesTest is RegistryFixture {
    function test_ZeroRegistryConstructorsRevert() public {
        vm.expectRevert(AgentReputationRegistry.ZeroAddress.selector);
        new AgentReputationRegistry(address(0));
        vm.expectRevert(AgentValidationRegistry.ZeroAddress.selector);
        new AgentValidationRegistry(address(0));
    }

    function test_UnregisteredZeroAndNextIdReadsRevert() public {
        _unknownAgent(0);
        _unknownAgent(3);
        _unknownAgent(type(uint256).max);
    }

    function testFuzz_UnregisteredAgentReadsAndWritesRevert(uint256 id) public {
        if (id == agent || id == otherAgent) id = 0;
        _unknownAgent(id);
        bytes memory reason = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id);
        vm.expectRevert(reason);
        vm.prank(OWNER);
        identity.setAgentURI(id, "valid URI");
        vm.expectRevert(reason);
        _give(CLIENT, id, JOB, 50);
        vm.expectRevert(reason);
        vm.prank(OWNER);
        validation.requestValidation(id, VALIDATOR, "", HASH);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, id, CLIENT, JOB));
        vm.prank(CLIENT);
        reputation.revokeFeedback(id, JOB);
    }

    function _unknownAgent(uint256 id) internal {
        bytes memory reason = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id);
        vm.expectRevert(reason);
        identity.ownerOf(id);
        vm.expectRevert(reason);
        identity.getApproved(id);
        vm.expectRevert(reason);
        identity.tokenURI(id);
        vm.expectRevert(reason);
        identity.isAuthorized(id, CLIENT);
        vm.expectRevert(reason);
        reputation.feedback(id, CLIENT, JOB);
        vm.expectRevert(reason);
        reputation.feedbackCount(id);
        vm.expectRevert(reason);
        reputation.summary(id);
        vm.expectRevert(reason);
        validation.requestCount(id);
        vm.expectRevert(reason);
        validation.responseCount(id);
    }

    function test_AllRegistriesRejectOrdinaryEtherTransfers() public {
        vm.deal(CLIENT, 3 ether);
        address[3] memory targets = [address(identity), address(reputation), address(validation)];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(CLIENT);
            (bool ok,) = targets[i].call{value: 1 wei}("");
            assertFalse(ok);
            assertEq(targets[i].balance, 0);
        }
    }
}
