// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryFixture} from "./RegistryFixture.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";

contract IndependentValidationAcceptanceTest is RegistryFixture {
    function test_OnlyNamedValidatorRespondsOnceWithFullRecordsAndEvents() public {
        bytes32 expectedId = keccak256(abi.encode(agent, HASH));
        vm.expectEmit(true, true, true, true, address(validation));
        emit AgentValidationRegistry.ValidationRequested(expectedId, agent, VALIDATOR, OWNER, "ipfs://request", HASH);
        vm.prank(OWNER);
        bytes32 id = validation.requestValidation(agent, VALIDATOR, "ipfs://request", HASH);
        assertEq(id, expectedId);
        AgentValidationRegistry.Request memory pending = validation.request(id);
        assertEq(pending.agentId, agent);
        assertEq(pending.requester, OWNER);
        assertEq(pending.validator, VALIDATOR);
        assertEq(pending.requestHash, HASH);
        assertEq(pending.requestURI, "ipfs://request");
        assertEq(uint8(pending.status), uint8(AgentValidationRegistry.Status.Pending));
        assertEq(pending.response, 0);
        assertEq(pending.responseHash, bytes32(0));
        assertEq(pending.responseURI, "");
        assertEq(validation.requestCount(agent), 1);
        assertEq(validation.responseCount(agent), 0);

        _grant();
        address[5] memory forbidden = [OWNER, APPROVED, OPERATOR, CLIENT, NEXT_OWNER];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotValidator.selector, id, forbidden[i]));
            vm.prank(forbidden[i]);
            validation.submitResponse(id, 99, "forged", HASH);
            assertEq(keccak256(abi.encode(validation.request(id))), keccak256(abi.encode(pending)));
        }

        vm.expectEmit(true, true, true, true, address(validation));
        emit AgentValidationRegistry.ValidationResponded(id, agent, VALIDATOR, 0, "ipfs://response", JOB);
        vm.prank(VALIDATOR);
        validation.submitResponse(id, 0, "ipfs://response", JOB);
        AgentValidationRegistry.Request memory responded = validation.request(id);
        assertEq(responded.agentId, pending.agentId);
        assertEq(responded.requester, pending.requester);
        assertEq(responded.validator, pending.validator);
        assertEq(responded.requestHash, pending.requestHash);
        assertEq(responded.requestURI, pending.requestURI);
        assertEq(uint8(responded.status), uint8(AgentValidationRegistry.Status.Responded));
        assertEq(responded.response, 0); // Zero is a completed response, not Pending.
        assertEq(responded.responseURI, "ipfs://response");
        assertEq(responded.responseHash, JOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentValidationRegistry.NotPending.selector, id, AgentValidationRegistry.Status.Responded
            )
        );
        vm.prank(VALIDATOR);
        validation.submitResponse(id, 100, "overwrite", HASH);
        assertEq(keccak256(abi.encode(validation.request(id))), keccak256(abi.encode(responded)));
        assertEq(validation.responseCount(agent), 1);
    }

    function testFuzz_RequestIdIsAgentScopedAndCannotBeSquatted(bytes32 hash) public {
        if (hash == bytes32(0)) hash = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, NEXT_OWNER));
        vm.prank(NEXT_OWNER);
        validation.requestValidation(agent, VALIDATOR, "squat", hash);
        vm.prank(NEXT_OWNER);
        bytes32 other = validation.requestValidation(otherAgent, CLIENT, "", hash);
        vm.prank(OWNER);
        bytes32 id = validation.requestValidation(agent, VALIDATOR, "", hash);
        assertEq(id, keccak256(abi.encode(agent, hash)));
        assertEq(other, keccak256(abi.encode(otherAgent, hash)));
        assertNotEq(id, other);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.DuplicateRequest.selector, id));
        vm.prank(OWNER);
        validation.requestValidation(agent, CLIENT, "replace validator", hash);
        assertEq(validation.request(id).validator, VALIDATOR);
        vm.prank(VALIDATOR);
        validation.submitResponse(id, 100, "", 0);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.DuplicateRequest.selector, id));
        vm.prank(OWNER);
        validation.requestValidation(agent, CLIENT, "after response", hash);
        assertEq(validation.requestCount(agent), 1);
        assertEq(validation.requestCount(otherAgent), 1);
        assertEq(validation.responseCount(otherAgent), 0);
    }

    function test_ApprovedAndOperatorRequestsSurviveTransferFrom() public {
        _requestsSurviveTransfer(false);
    }

    function test_ApprovedAndOperatorRequestsSurviveSafeTransferFrom() public {
        _requestsSurviveTransfer(true);
    }

    function _requestsSurviveTransfer(bool safe) internal {
        _grant();
        address[3] memory requesters = [OWNER, APPROVED, OPERATOR];
        bytes32[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            vm.prank(requesters[i]);
            ids[i] = validation.requestValidation(agent, VALIDATOR, "", bytes32(i + 1));
        }
        vm.prank(OWNER);
        if (safe) identity.safeTransferFrom(OWNER, NEXT_OWNER, agent);
        else identity.transferFrom(OWNER, NEXT_OWNER, agent);

        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, requesters[i])
            );
            vm.prank(requesters[i]);
            validation.requestValidation(agent, VALIDATOR, "", HASH);
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.DuplicateRequest.selector, ids[i]));
            vm.prank(NEXT_OWNER);
            validation.requestValidation(agent, CLIENT, "retarget old request", bytes32(i + 1));
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotValidator.selector, ids[i], NEXT_OWNER));
            vm.prank(NEXT_OWNER);
            validation.submitResponse(ids[i], 1, "", 0);
            vm.prank(VALIDATOR);
            validation.submitResponse(ids[i], 100, "", 0);
            assertEq(validation.request(ids[i]).requester, requesters[i]);
            assertEq(validation.request(ids[i]).agentId, agent);
            assertEq(uint8(validation.request(ids[i]).status), uint8(AgentValidationRegistry.Status.Responded));
        }
        vm.prank(NEXT_OWNER);
        validation.requestValidation(agent, VALIDATOR, "new owner request", HASH);
        assertEq(validation.requestCount(agent), 4);
        assertEq(validation.responseCount(agent), 3);
    }

    function test_ZeroValidatorAndZeroHashDoNotReserveARequest() public {
        vm.startPrank(OWNER);
        vm.expectRevert(AgentValidationRegistry.ZeroAddress.selector);
        validation.requestValidation(agent, address(0), "", HASH);
        vm.expectRevert(AgentValidationRegistry.ZeroHash.selector);
        validation.requestValidation(agent, VALIDATOR, "", 0);
        assertEq(validation.requestCount(agent), 0);
        bytes32 id = validation.requestValidation(agent, VALIDATOR, "", HASH);
        vm.stopPrank();
        assertEq(id, keccak256(abi.encode(agent, HASH)));
        assertEq(validation.requestCount(agent), 1);
    }

    function test_UnknownRequestCannotBeReadOrAnswered() public {
        bytes32 id = keccak256(abi.encode(agent, HASH));
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.UnknownRequest.selector, id));
        validation.request(id);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.UnknownRequest.selector, id));
        vm.prank(VALIDATOR);
        validation.submitResponse(id, 0, "", 0);
        assertEq(validation.requestCount(agent), 0);
        assertEq(validation.responseCount(agent), 0);
    }

    function testFuzz_ResponseRangeAndRetryAfterInvalidScore(uint8 response) public {
        vm.prank(OWNER);
        bytes32 id = validation.requestValidation(agent, VALIDATOR, "", HASH);
        if (response > 100) {
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.InvalidResponse.selector, response));
            vm.prank(VALIDATOR);
            validation.submitResponse(id, response, "", 0);
            assertEq(uint8(validation.request(id).status), uint8(AgentValidationRegistry.Status.Pending));
            assertEq(validation.responseCount(agent), 0);
            response = 100;
        }
        vm.prank(VALIDATOR);
        validation.submitResponse(id, response, "", 0);
        assertEq(validation.request(id).response, response);
        assertEq(uint8(validation.request(id).status), uint8(AgentValidationRegistry.Status.Responded));
        assertEq(validation.responseCount(agent), 1);
    }
}
