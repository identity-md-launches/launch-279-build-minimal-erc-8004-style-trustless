// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentValidationRegistry} from "../src/AgentValidationRegistry.sol";

contract AgentValidationRegistryTest is Test {
    AgentIdentityRegistry internal identity;
    AgentValidationRegistry internal validation;

    address internal alice = makeAddr("alice"); // agent owner
    address internal bob = makeAddr("bob"); // later owner
    address internal approved = makeAddr("approved");
    address internal operator = makeAddr("operator");
    address internal validator = makeAddr("validator");
    address internal otherValidator = makeAddr("otherValidator");
    address internal stranger = makeAddr("stranger");

    uint256 internal agent;
    bytes32 internal constant REQ_HASH = keccak256("request");
    bytes32 internal constant REQ_HASH2 = keccak256("request-2");
    bytes32 internal constant RESP_HASH = keccak256("response");
    string internal constant REQ_URI = "ipfs://request";
    string internal constant RESP_URI = "ipfs://response";

    function setUp() public {
        identity = new AgentIdentityRegistry();
        validation = new AgentValidationRegistry(address(identity));
        vm.prank(alice);
        agent = identity.register("ipfs://agent");
    }

    // ---------------------------------------------------------------- constructor

    function test_Constructor_StoresRegistry() public view {
        assertEq(address(validation.identityRegistry()), address(identity));
        assertEq(validation.MAX_RESPONSE(), 100);
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(AgentValidationRegistry.ZeroAddress.selector);
        new AgentValidationRegistry(address(0));
    }

    // ---------------------------------------------------------------- requestValidation: success

    function test_Request_ByOwner_StoresRecordAndEmits() public {
        bytes32 expectedId = keccak256(abi.encode(agent, REQ_HASH));
        assertEq(validation.computeRequestId(agent, REQ_HASH), expectedId);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(validation));
        emit AgentValidationRegistry.ValidationRequested(expectedId, agent, validator, alice, REQ_URI, REQ_HASH);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        assertEq(id, expectedId);

        AgentValidationRegistry.Request memory r = validation.request(id);
        assertEq(r.agentId, agent);
        assertEq(r.requester, alice);
        assertEq(r.validator, validator);
        assertEq(uint8(r.status), uint8(AgentValidationRegistry.Status.Pending));
        assertEq(r.response, 0);
        assertEq(r.requestHash, REQ_HASH);
        assertEq(r.responseHash, bytes32(0));
        assertEq(r.requestURI, REQ_URI);
        assertEq(r.responseURI, "");

        assertEq(validation.requestCount(agent), 1);
        assertEq(validation.responseCount(agent), 0);
    }

    function test_Request_ByApprovedAndOperator() public {
        vm.startPrank(alice);
        identity.approve(approved, agent);
        identity.setApprovalForAll(operator, true);
        vm.stopPrank();

        vm.prank(approved);
        bytes32 id1 = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(operator);
        bytes32 id2 = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH2);

        assertEq(validation.request(id1).requester, approved);
        assertEq(validation.request(id2).requester, operator);
        assertEq(validation.requestCount(agent), 2);
    }

    function test_Request_EmptyURIAllowed() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, "", REQ_HASH);
        assertEq(validation.request(id).requestURI, "");
    }

    function test_Request_SameHashDifferentAgentsGetDifferentIds() public {
        vm.prank(bob);
        uint256 agent2 = identity.register("ipfs://agent-2");

        vm.prank(alice);
        bytes32 id1 = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        // bob cannot squat alice's hash: the id is scoped by agent id.
        vm.prank(bob);
        bytes32 id2 = validation.requestValidation(agent2, validator, REQ_URI, REQ_HASH);

        assertTrue(id1 != id2);
        assertEq(validation.request(id1).agentId, agent);
        assertEq(validation.request(id2).agentId, agent2);
    }

    // ---------------------------------------------------------------- requestValidation: failures

    function test_Request_RevertsForUnauthorizedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, stranger));
        validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
    }

    function test_Request_RevertsForValidatorItselfWhenNotAuthorized() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, validator));
        validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
    }

    function test_Request_RevertsForUnregisteredAgent() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        validation.requestValidation(99, validator, REQ_URI, REQ_HASH);
    }

    function test_Request_RevertsOnZeroValidator() public {
        vm.prank(alice);
        vm.expectRevert(AgentValidationRegistry.ZeroAddress.selector);
        validation.requestValidation(agent, address(0), REQ_URI, REQ_HASH);
    }

    function test_Request_RevertsOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert(AgentValidationRegistry.ZeroHash.selector);
        validation.requestValidation(agent, validator, REQ_URI, bytes32(0));
    }

    function test_Request_RevertsOnOversizedURI() public {
        string memory uri = _uriOfLength(513);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.InvalidURI.selector, 513));
        validation.requestValidation(agent, validator, uri, REQ_HASH);
    }

    function test_Request_RevertsOnDuplicateId() public {
        vm.startPrank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.DuplicateRequest.selector, id));
        validation.requestValidation(agent, otherValidator, "other", REQ_HASH);
        vm.stopPrank();
        // The original record is untouched.
        assertEq(validation.request(id).validator, validator);
        assertEq(validation.requestCount(agent), 1);
    }

    function test_Request_RevertsOnDuplicateIdAfterResponse() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(validator);
        validation.submitResponse(id, 90, RESP_URI, RESP_HASH);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.DuplicateRequest.selector, id));
        validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
    }

    function test_Request_OldOwnerCannotRequestAfterTransfer() public {
        vm.prank(alice);
        identity.approve(approved, agent);
        vm.prank(alice);
        identity.transferFrom(alice, bob, agent);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, alice));
        validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotAuthorized.selector, agent, approved));
        validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);

        vm.prank(bob);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        assertEq(validation.request(id).requester, bob);
    }

    // ---------------------------------------------------------------- submitResponse: success

    function test_Respond_ByValidator_StoresAndEmits() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);

        vm.prank(validator);
        vm.expectEmit(true, true, true, true, address(validation));
        emit AgentValidationRegistry.ValidationResponded(id, agent, validator, 87, RESP_URI, RESP_HASH);
        validation.submitResponse(id, 87, RESP_URI, RESP_HASH);

        AgentValidationRegistry.Request memory r = validation.request(id);
        assertEq(uint8(r.status), uint8(AgentValidationRegistry.Status.Responded));
        assertEq(r.response, 87);
        assertEq(r.responseURI, RESP_URI);
        assertEq(r.responseHash, RESP_HASH);
        // Request side unchanged.
        assertEq(r.requester, alice);
        assertEq(r.validator, validator);
        assertEq(r.requestHash, REQ_HASH);
        assertEq(r.requestURI, REQ_URI);
        assertEq(validation.requestCount(agent), 1);
        assertEq(validation.responseCount(agent), 1);
    }

    function test_Respond_BoundaryValuesAndEmptyURI() public {
        vm.startPrank(alice);
        bytes32 id0 = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        bytes32 id100 = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH2);
        vm.stopPrank();
        vm.startPrank(validator);
        validation.submitResponse(id0, 0, "", bytes32(0));
        validation.submitResponse(id100, 100, "", bytes32(0));
        vm.stopPrank();
        assertEq(validation.request(id0).response, 0);
        assertEq(validation.request(id100).response, 100);
        assertEq(validation.responseCount(agent), 2);
    }

    function test_Respond_RequestSurvivesAgentTransfer() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(alice);
        identity.transferFrom(alice, bob, agent);

        AgentValidationRegistry.Request memory r = validation.request(id);
        assertEq(uint8(r.status), uint8(AgentValidationRegistry.Status.Pending));
        assertEq(r.requester, alice, "requester is historical, not re-derived");

        vm.prank(validator);
        validation.submitResponse(id, 55, RESP_URI, RESP_HASH);
        assertEq(uint8(validation.request(id).status), uint8(AgentValidationRegistry.Status.Responded));
        assertEq(validation.responseCount(agent), 1);
    }

    // ---------------------------------------------------------------- submitResponse: failures

    function test_Respond_RevertsForNonValidator() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);

        address[4] memory callers = [alice, otherValidator, stranger, bob];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotValidator.selector, id, callers[i]));
            validation.submitResponse(id, 50, RESP_URI, RESP_HASH);
        }
        assertEq(uint8(validation.request(id).status), uint8(AgentValidationRegistry.Status.Pending));
    }

    function test_Respond_RevertsOnSecondResponse() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.startPrank(validator);
        validation.submitResponse(id, 50, RESP_URI, RESP_HASH);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentValidationRegistry.NotPending.selector, id, AgentValidationRegistry.Status.Responded
            )
        );
        validation.submitResponse(id, 99, "changed", bytes32(0));
        vm.stopPrank();
        assertEq(validation.request(id).response, 50);
        assertEq(validation.responseCount(agent), 1);
    }

    function test_Respond_RevertsOnUnknownRequest() public {
        bytes32 id = keccak256("nope");
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.UnknownRequest.selector, id));
        validation.submitResponse(id, 50, RESP_URI, RESP_HASH);
    }

    function test_Respond_RevertsOnResponseAbove100() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.InvalidResponse.selector, 101));
        validation.submitResponse(id, 101, RESP_URI, RESP_HASH);
    }

    function test_Respond_RevertsOnOversizedURI() public {
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        string memory uri = _uriOfLength(513);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.InvalidURI.selector, 513));
        validation.submitResponse(id, 50, uri, RESP_HASH);
    }

    // ---------------------------------------------------------------- views

    function test_Request_ViewRevertsOnUnknownId() public {
        bytes32 id = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.UnknownRequest.selector, id));
        validation.request(id);
    }

    function test_Counters_RevertOnUnregisteredAgent() public {
        bytes memory err = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5);
        vm.expectRevert(err);
        validation.requestCount(5);
        vm.expectRevert(err);
        validation.responseCount(5);
    }

    function test_RejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(validation).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_Respond_OnlyNamedValidator(address caller, uint8 response) public {
        vm.assume(caller != validator);
        vm.prank(alice);
        bytes32 id = validation.requestValidation(agent, validator, REQ_URI, REQ_HASH);
        vm.prank(caller);
        if (response > 100) {
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.InvalidResponse.selector, response));
        } else {
            vm.expectRevert(abi.encodeWithSelector(AgentValidationRegistry.NotValidator.selector, id, caller));
        }
        validation.submitResponse(id, response, "", 0);
    }

    function testFuzz_RequestId_IsAgentScoped(uint256 agentA, uint256 agentB, bytes32 hash) public view {
        vm.assume(agentA != agentB);
        assertTrue(validation.computeRequestId(agentA, hash) != validation.computeRequestId(agentB, hash));
    }

    // ---------------------------------------------------------------- helpers

    function _uriOfLength(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = "a";
        }
        return string(b);
    }
}
