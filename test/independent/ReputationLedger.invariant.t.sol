// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";

/// @dev All expected authorization, existence, revocation and scores come from this model.
///      No production feedback or identity view is used to choose an action's expected result.
contract IndependentReputationHandler is Test {
    struct Entry {
        uint256 agentId;
        address client;
        bytes32 jobId;
        uint8 score;
        bool revoked;
    }

    AgentIdentityRegistry private immutable identity;
    AgentReputationRegistry private immutable reputation;
    uint256 public constant MAX_AGENTS = 5;
    uint256 public constant JOBS = 5;
    address[6] public actors =
        [address(0x1100), address(0x2200), address(0x3300), address(0x4400), address(0x5500), address(0x6600)];
    uint256[] public touchedAgents;
    Entry[] private ledger;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) private entryIndexPlusOne;

    mapping(uint256 => address) public ghostOwner;
    mapping(uint256 => address) public ghostApproved;
    mapping(address => mapping(address => bool)) public ghostOperator;
    mapping(uint256 => uint256) public ghostGiven;
    mapping(uint256 => uint256) public ghostRevoked;
    mapping(uint256 => uint256) public ghostSum;

    constructor(AgentIdentityRegistry identity_, AgentReputationRegistry reputation_) {
        identity = identity_;
        reputation = reputation_;
        for (uint256 i; i < 3; ++i) {
            registerAgent(i);
        }
    }

    function registerAgent(uint256 actorSeed) public {
        if (touchedAgents.length == MAX_AGENTS) return;
        address owner = _actor(actorSeed);
        vm.prank(owner);
        uint256 id = identity.register("ipfs://invariant");
        assertEq(id, touchedAgents.length + 1, "sequential registration");
        touchedAgents.push(id);
        ghostOwner[id] = owner;
    }

    function transfer(uint256 agentSeed, uint256 actorSeed, bool safe) external {
        uint256 id = _agent(agentSeed);
        address from = ghostOwner[id];
        address to = _actor(actorSeed);
        vm.prank(from);
        if (safe) identity.safeTransferFrom(from, to, id);
        else identity.transferFrom(from, to, id);
        ghostOwner[id] = to;
        ghostApproved[id] = address(0); // Includes transfers back to the same owner.
    }

    function approve(uint256 agentSeed, uint256 actorSeed, bool clear) external {
        uint256 id = _agent(agentSeed);
        address approved = clear ? address(0) : _actor(actorSeed);
        vm.prank(ghostOwner[id]);
        identity.approve(approved, id);
        ghostApproved[id] = approved;
    }

    function setOperator(uint256 ownerSeed, uint256 operatorSeed, bool enabled) external {
        address owner = _actor(ownerSeed);
        address operator = _actor(operatorSeed);
        vm.prank(owner);
        identity.setApprovalForAll(operator, enabled);
        ghostOperator[owner][operator] = enabled;
    }

    function give(uint256 agentSeed, uint256 actorSeed, uint256 jobSeed, uint8 score) external {
        uint256 id = _agent(agentSeed);
        address client = _actor(actorSeed);
        bytes32 job = bytes32(jobSeed % JOBS);
        if (score > 100) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidScore.selector, score));
        } else if (modelAuthorized(id, client)) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, id, client));
        } else if (entryIndexPlusOne[id][client][job] != 0) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.DuplicateFeedback.selector, id, client, job));
        } else {
            vm.prank(client);
            reputation.giveFeedback(id, job, score, 0, 0, "", 0);
            ledger.push(Entry(id, client, job, score, false));
            entryIndexPlusOne[id][client][job] = ledger.length;
            ghostGiven[id]++;
            ghostSum[id] += score;
            return;
        }
        vm.prank(client);
        reputation.giveFeedback(id, job, score, 0, 0, "", 0);
    }

    function revoke(uint256 agentSeed, uint256 actorSeed, uint256 jobSeed) external {
        _revoke(_agent(agentSeed), _actor(actorSeed), bytes32(jobSeed % JOBS));
    }

    /// @dev Ensures revocations also target populated slots instead of mostly missing triples.
    function revokeKnown(uint256 entrySeed) external {
        if (ledger.length == 0) return;
        Entry memory entry = ledger[entrySeed % ledger.length];
        _revoke(entry.agentId, entry.client, entry.jobId);
    }

    function _revoke(uint256 id, address client, bytes32 job) private {
        uint256 index = entryIndexPlusOne[id][client][job];
        if (index == 0) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, id, client, job));
        } else if (ledger[index - 1].revoked) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.AlreadyRevoked.selector, id, client, job));
        } else {
            vm.prank(client);
            reputation.revokeFeedback(id, job);
            Entry storage entry = ledger[index - 1];
            entry.revoked = true;
            ghostRevoked[id]++;
            ghostSum[id] -= entry.score; // The submitted score, never a score read from production storage.
            return;
        }
        vm.prank(client);
        reputation.revokeFeedback(id, job);
    }

    function modelAuthorized(uint256 id, address client) public view returns (bool) {
        return client != address(0)
            && (client == ghostOwner[id] || client == ghostApproved[id] || ghostOperator[ghostOwner[id]][client]);
    }

    function touchedCount() external view returns (uint256) {
        return touchedAgents.length;
    }

    function entryCount() external view returns (uint256) {
        return ledger.length;
    }

    function entryAt(uint256 index) external view returns (Entry memory) {
        return ledger[index];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _agent(uint256 seed) private view returns (uint256) {
        return touchedAgents[seed % touchedAgents.length];
    }
}

contract IndependentReputationInvariantTest is Test {
    AgentIdentityRegistry internal identity;
    AgentReputationRegistry internal reputation;
    IndependentReputationHandler internal handler;

    function setUp() public {
        identity = new AgentIdentityRegistry();
        reputation = new AgentReputationRegistry(address(identity));
        handler = new IndependentReputationHandler(identity, reputation);
        // Deterministic live and revoked entries prevent vacuous success in short campaigns.
        handler.give(0, 3, 0, 10);
        handler.give(0, 4, 1, 0);
        handler.give(1, 3, 0, 100);
        handler.revoke(0, 3, 0);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.registerAgent.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.setOperator.selector;
        selectors[4] = handler.give.selector;
        selectors[5] = handler.revoke.selector;
        selectors[6] = handler.revokeKnown.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SummariesEqualGivenMinusRevokedAndIndependentLedger() public view {
        uint256 agents = handler.touchedCount();
        uint256[] memory given = new uint256[](agents + 1);
        uint256[] memory revoked = new uint256[](agents + 1);
        uint256[] memory sums = new uint256[](agents + 1);
        uint256 entries = handler.entryCount();
        for (uint256 i; i < entries; ++i) {
            IndependentReputationHandler.Entry memory entry = handler.entryAt(i);
            given[entry.agentId]++;
            if (entry.revoked) revoked[entry.agentId]++;
            else sums[entry.agentId] += entry.score;

            AgentReputationRegistry.Feedback memory actual =
                reputation.feedback(entry.agentId, entry.client, entry.jobId);
            assertTrue(actual.exists, "entry disappeared");
            assertEq(actual.revoked, entry.revoked, "entry revocation");
            assertEq(actual.score, entry.score, "original submitted score");
            assertEq(actual.tag1, bytes32(0));
            assertEq(actual.tag2, bytes32(0));
            assertEq(actual.evidenceHash, bytes32(0));
            assertEq(actual.evidenceURI, "");
        }
        for (uint256 i; i < agents; ++i) {
            uint256 id = handler.touchedAgents(i);
            assertEq(handler.ghostGiven(id), given[id], "given ledger");
            assertEq(handler.ghostRevoked(id), revoked[id], "revoked ledger");
            assertEq(handler.ghostSum(id), sums[id], "sum ledger");
            (uint256 count, uint256 sum, uint256 average) = reputation.summary(id);
            assertEq(count, handler.ghostGiven(id) - handler.ghostRevoked(id), "given minus revoked");
            assertEq(sum, sums[id], "sum of live submitted scores");
            uint256 live = given[id] - revoked[id];
            assertEq(average, live == 0 ? 0 : sums[id] / live, "floor average");
            assertEq(reputation.feedbackCount(id), given[id], "lifetime count");
        }
    }

    function invariant_AuthorizationMatchesIndependentOwnershipModel() public view {
        assertEq(identity.totalAgents(), handler.touchedCount());
        for (uint256 i; i < handler.touchedCount(); ++i) {
            uint256 id = handler.touchedAgents(i);
            assertEq(identity.ownerOf(id), handler.ghostOwner(id));
            assertEq(identity.getApproved(id), handler.ghostApproved(id));
            assertFalse(identity.isAuthorized(id, address(0)));
            for (uint256 a; a < 6; ++a) {
                address actor = handler.actors(a);
                assertEq(identity.isAuthorized(id, actor), handler.modelAuthorized(id, actor));
            }
        }
    }

    function test_HandlerExercisesDuplicateRevocationAndAuthorizationTransitions() public {
        handler.give(0, 3, 0, 20); // Duplicate of a revoked entry.
        handler.revokeKnown(0); // Double revoke.
        handler.give(0, 0, 2, 50); // Owner self-feedback.
        handler.approve(0, 3, false);
        handler.give(0, 3, 2, 50); // Approved self-feedback.
        handler.setOperator(0, 4, true);
        handler.give(0, 4, 2, 50); // Operator self-feedback.
        handler.transfer(0, 3, true);
        handler.give(0, 3, 2, 50); // New owner self-feedback.
        handler.give(0, 0, 2, 50); // Former owner can rate.
        handler.give(0, 4, 2, 51); // Former owner's operator can rate.
        handler.revokeKnown(4);
        handler.registerAgent(5);
        handler.give(3, 0, 0, 100);
        handler.give(3, 0, 1, 255); // Invalid score never enters the ledger.
        assertEq(handler.ghostGiven(1), 4);
        assertEq(handler.ghostRevoked(1), 2);
        assertEq(handler.ghostSum(1), 50);
        invariant_SummariesEqualGivenMinusRevokedAndIndependentLedger();
        invariant_AuthorizationMatchesIndependentOwnershipModel();
    }
}
