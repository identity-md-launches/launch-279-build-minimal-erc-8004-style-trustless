// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";

/// @dev Bounded random actor over the three registries. Keeps ghost bookkeeping that the invariants compare
///      against the contracts' own counters and summaries.
contract RegistriesHandler is Test {
    AgentIdentityRegistry public identity;
    AgentReputationRegistry public reputation;
    AgentValidationRegistry public validation;

    address[] public actors;
    uint256 public constant AGENTS = 3;
    uint256 public constant JOBS = 4;

    // ghost state: agentId => ...
    mapping(uint256 => uint256) public ghostGiven;
    mapping(uint256 => uint256) public ghostLiveCount;
    mapping(uint256 => uint256) public ghostLiveSum;
    mapping(uint256 => uint256) public ghostRequests;
    mapping(uint256 => uint256) public ghostResponses;
    bytes32[] public knownRequests;
    mapping(bytes32 => bool) public ghostResponded;

    uint256 public transfers;
    uint256 public selfFeedbackRejected;
    uint256 public duplicateRejected;

    constructor(AgentIdentityRegistry i, AgentReputationRegistry r, AgentValidationRegistry v) {
        identity = i;
        reputation = r;
        validation = v;
        for (uint256 k = 0; k < 6; k++) {
            actors.push(address(uint160(0xA000 + k)));
        }
        for (uint256 a = 0; a < AGENTS; a++) {
            vm.prank(actors[a]);
            identity.register("ipfs://agent");
        }
    }

    function transfer(uint256 agentSeed, uint256 toSeed) external {
        uint256 agentId = _agent(agentSeed);
        address owner = identity.ownerOf(agentId);
        address to = actors[toSeed % actors.length];
        vm.prank(owner);
        identity.transferFrom(owner, to, agentId);
        transfers++;
    }

    function approveSomeone(uint256 agentSeed, uint256 toSeed) external {
        uint256 agentId = _agent(agentSeed);
        address owner = identity.ownerOf(agentId);
        vm.prank(owner);
        identity.approve(actors[toSeed % actors.length], agentId);
    }

    function give(uint256 actorSeed, uint256 agentSeed, uint256 jobSeed, uint8 score) external {
        uint256 agentId = _agent(agentSeed);
        address client = actors[actorSeed % actors.length];
        bytes32 jobId = bytes32(jobSeed % JOBS);
        score = score % 101;

        bool authorized = identity.isAuthorized(agentId, client);
        bool exists = reputation.feedback(agentId, client, jobId).exists;

        vm.prank(client);
        if (authorized) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agentId, client));
            reputation.giveFeedback(agentId, jobId, score, 0, 0, "", 0);
            selfFeedbackRejected++;
            return;
        }
        if (exists) {
            vm.expectRevert(
                abi.encodeWithSelector(AgentReputationRegistry.DuplicateFeedback.selector, agentId, client, jobId)
            );
            reputation.giveFeedback(agentId, jobId, score, 0, 0, "", 0);
            duplicateRejected++;
            return;
        }
        reputation.giveFeedback(agentId, jobId, score, 0, 0, "", 0);
        ghostGiven[agentId]++;
        ghostLiveCount[agentId]++;
        ghostLiveSum[agentId] += score;
    }

    function revoke(uint256 actorSeed, uint256 agentSeed, uint256 jobSeed) external {
        uint256 agentId = _agent(agentSeed);
        address client = actors[actorSeed % actors.length];
        bytes32 jobId = bytes32(jobSeed % JOBS);
        AgentReputationRegistry.Feedback memory f = reputation.feedback(agentId, client, jobId);
        if (!f.exists || f.revoked) return;
        vm.prank(client);
        reputation.revokeFeedback(agentId, jobId);
        ghostLiveCount[agentId]--;
        ghostLiveSum[agentId] -= f.score;
    }

    function requestVal(uint256 agentSeed, uint256 validatorSeed, bytes32 hash) external {
        uint256 agentId = _agent(agentSeed);
        if (hash == bytes32(0)) return;
        address owner = identity.ownerOf(agentId);
        address v = actors[validatorSeed % actors.length];
        bytes32 id = validation.computeRequestId(agentId, hash);
        // Skip duplicates rather than assert: the unit tests cover the revert.
        (bool ok,) = address(validation).staticcall(abi.encodeCall(validation.request, (id)));
        if (ok) return;
        vm.prank(owner);
        validation.requestValidation(agentId, v, "", hash);
        ghostRequests[agentId]++;
        knownRequests.push(id);
    }

    function respond(uint256 reqSeed, uint8 response) external {
        if (knownRequests.length == 0) return;
        bytes32 id = knownRequests[reqSeed % knownRequests.length];
        if (ghostResponded[id]) return;
        AgentValidationRegistry.Request memory r = validation.request(id);
        vm.prank(r.validator);
        validation.submitResponse(id, response % 101, "", 0);
        ghostResponded[id] = true;
        ghostResponses[r.agentId]++;
    }

    function knownRequestCount() external view returns (uint256) {
        return knownRequests.length;
    }

    function _agent(uint256 seed) internal pure returns (uint256) {
        return (seed % AGENTS) + 1;
    }
}

contract RegistriesInvariantTest is Test {
    AgentIdentityRegistry internal identity;
    AgentReputationRegistry internal reputation;
    AgentValidationRegistry internal validation;
    RegistriesHandler internal handler;

    function setUp() public {
        identity = new AgentIdentityRegistry();
        reputation = new AgentReputationRegistry(address(identity));
        validation = new AgentValidationRegistry(address(identity));
        handler = new RegistriesHandler(identity, reputation, validation);
        targetContract(address(handler));
    }

    function invariant_SummaryMatchesGhost() public view {
        for (uint256 a = 1; a <= handler.AGENTS(); a++) {
            (uint256 count, uint256 sum, uint256 avg) = reputation.summary(a);
            assertEq(count, handler.ghostLiveCount(a), "live count");
            assertEq(sum, handler.ghostLiveSum(a), "live sum");
            assertEq(avg, count == 0 ? 0 : sum / count, "floor average");
            assertEq(reputation.feedbackCount(a), handler.ghostGiven(a), "total given");
            assertLe(sum, count * 100, "sum bounded by count * MAX_SCORE");
        }
    }

    function invariant_ValidationCountersAndStates() public view {
        for (uint256 a = 1; a <= handler.AGENTS(); a++) {
            assertEq(validation.requestCount(a), handler.ghostRequests(a), "request count");
            assertEq(validation.responseCount(a), handler.ghostResponses(a), "response count");
            assertLe(validation.responseCount(a), validation.requestCount(a), "responses <= requests");
        }
        uint256 n = handler.knownRequestCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.knownRequests(i);
            AgentValidationRegistry.Request memory r = validation.request(id);
            bool responded = handler.ghostResponded(id);
            assertEq(
                uint8(r.status),
                uint8(responded ? AgentValidationRegistry.Status.Responded : AgentValidationRegistry.Status.Pending),
                "state machine"
            );
            assertEq(id, keccak256(abi.encode(r.agentId, r.requestHash)), "id derivation");
        }
    }

    function invariant_IdentityIsConsistent() public view {
        assertEq(identity.totalAgents(), handler.AGENTS());
        for (uint256 a = 1; a <= handler.AGENTS(); a++) {
            address owner = identity.ownerOf(a);
            assertTrue(owner != address(0));
            assertTrue(identity.isAuthorized(a, owner));
        }
        assertEq(address(identity).balance, 0);
        assertEq(address(reputation).balance, 0);
        assertEq(address(validation).balance, 0);
    }
}
