// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryFixture} from "./RegistryFixture.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";

contract IndependentReputationAcceptanceTest is RegistryFixture {
    function test_FeedbackEventAndFullRecordSurviveRevocation() public {
        bytes32 tag1 = keccak256("quality");
        bytes32 tag2 = keccak256("speed");
        vm.expectEmit(true, true, true, true, address(reputation));
        emit AgentReputationRegistry.FeedbackGiven(agent, CLIENT, JOB, 71, tag1, tag2, "ipfs://proof", HASH);
        vm.prank(CLIENT);
        reputation.giveFeedback(agent, JOB, 71, tag1, tag2, "ipfs://proof", HASH);
        _summary(agent, 1, 71);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit AgentReputationRegistry.FeedbackRevoked(agent, CLIENT, JOB);
        vm.prank(CLIENT);
        reputation.revokeFeedback(agent, JOB);

        AgentReputationRegistry.Feedback memory entry = reputation.feedback(agent, CLIENT, JOB);
        assertTrue(entry.exists);
        assertTrue(entry.revoked);
        assertEq(entry.score, 71);
        assertEq(entry.tag1, tag1);
        assertEq(entry.tag2, tag2);
        assertEq(entry.evidenceURI, "ipfs://proof");
        assertEq(entry.evidenceHash, HASH);
        _summary(agent, 0, 0);
        assertEq(reputation.feedbackCount(agent), 1);
    }

    function test_DuplicateCannotOverwriteLiveOrRevokedEntryButOtherKeysWork() public {
        _give(CLIENT, agent, JOB, 100);
        _duplicate(CLIENT, agent, JOB);
        assertEq(reputation.feedback(agent, CLIENT, JOB).score, 100);
        _summary(agent, 1, 100);

        _give(CLIENT, agent, bytes32(0), 1); // Same client, different job (zero is a valid job id).
        _give(CLIENT_TWO, agent, JOB, 2); // Same agent/job, different client.
        _give(CLIENT, otherAgent, JOB, 3); // Same client/job, different agent.
        _summary(agent, 3, 103);
        _summary(otherAgent, 1, 3);
        vm.prank(CLIENT);
        reputation.revokeFeedback(agent, JOB);
        _duplicate(CLIENT, agent, JOB);
        _summary(agent, 2, 3);
        assertEq(reputation.feedbackCount(agent), 3);
        assertTrue(reputation.feedback(agent, CLIENT, JOB).revoked);
    }

    function test_OwnerApprovedAndOperatorCannotSelfRate() public {
        _grant();
        _selfFeedback(OWNER);
        _selfFeedback(APPROVED);
        _selfFeedback(OPERATOR);
        assertEq(reputation.feedbackCount(agent), 0);
        _summary(agent, 0, 0);

        // Removing authorization immediately makes the same attempted keys eligible.
        vm.startPrank(OWNER);
        identity.approve(address(0), agent);
        identity.setApprovalForAll(OPERATOR, false);
        vm.stopPrank();
        _give(APPROVED, agent, JOB, 17);
        _give(OPERATOR, agent, JOB, 23);
        _summary(agent, 2, 40);
    }

    function test_TransferFromChangesSelfFeedbackEligibility() public {
        _transferEligibility(false);
    }

    function test_SafeTransferFromChangesSelfFeedbackEligibility() public {
        _transferEligibility(true);
    }

    function _transferEligibility(bool safe) internal {
        _grant();
        _give(NEXT_OWNER, agent, JOB, 42);
        vm.prank(OWNER);
        if (safe) identity.safeTransferFrom(OWNER, NEXT_OWNER, agent);
        else identity.transferFrom(OWNER, NEXT_OWNER, agent);
        // Existing feedback remains; only future writes use current authorization.
        _summary(agent, 1, 42);
        _selfFeedback(NEXT_OWNER);
        _give(OWNER, agent, JOB, 10);
        _give(APPROVED, agent, JOB, 20);
        _give(OPERATOR, agent, JOB, 30);
        vm.startPrank(NEXT_OWNER);
        identity.approve(APPROVED, agent);
        identity.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        _selfFeedback(APPROVED);
        _selfFeedback(OPERATOR);
        // Becoming the owner does not remove a client's ability to revoke its earlier entry.
        vm.prank(NEXT_OWNER);
        reputation.revokeFeedback(agent, JOB);
        _summary(agent, 3, 60);
        assertEq(reputation.feedbackCount(agent), 4);
    }

    function test_OnlyClientRevokesOnceAndFailuresPreserveSummary() public {
        _give(CLIENT, agent, JOB, 99);
        _give(CLIENT_TWO, agent, JOB, 0);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, agent, OWNER, JOB));
        vm.prank(OWNER);
        reputation.revokeFeedback(agent, JOB);
        vm.expectRevert(
            abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, agent, CLIENT, bytes32(0))
        );
        vm.prank(CLIENT);
        reputation.revokeFeedback(agent, bytes32(0));
        _summary(agent, 2, 99);
        vm.prank(CLIENT);
        reputation.revokeFeedback(agent, JOB);
        _summary(agent, 1, 0); // One live zero score is not an empty summary.
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.AlreadyRevoked.selector, agent, CLIENT, JOB));
        vm.prank(CLIENT);
        reputation.revokeFeedback(agent, JOB);
        _summary(agent, 1, 0);
        vm.prank(CLIENT_TWO);
        reputation.revokeFeedback(agent, JOB);
        _summary(agent, 0, 0);
        assertEq(reputation.feedbackCount(agent), 2);
    }

    function test_EvidenceBoundariesAndRejectedWritesDoNotReserveKeys() public {
        vm.startPrank(CLIENT);
        vm.expectRevert(AgentReputationRegistry.EvidenceHashWithoutURI.selector);
        reputation.giveFeedback(agent, JOB, 50, 0, 0, "", HASH);
        string memory tooLong = _text(513);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidEvidenceURI.selector, 513));
        reputation.giveFeedback(agent, JOB, 50, 0, 0, tooLong, 0);
        assertEq(reputation.feedbackCount(agent), 0);
        assertFalse(reputation.feedback(agent, CLIENT, JOB).exists);
        reputation.giveFeedback(agent, JOB, 0, 0, 0, "", 0);
        reputation.giveFeedback(agent, bytes32(uint256(1)), 100, 0, 0, _text(512), HASH);
        reputation.giveFeedback(agent, bytes32(uint256(2)), 50, 0, 0, "x", 0);
        vm.stopPrank();
        assertEq(bytes(reputation.feedback(agent, CLIENT, bytes32(uint256(1))).evidenceURI).length, 512);
        _summary(agent, 3, 150);
    }

    function testFuzz_ScoresAcceptExactlyZeroThroughOneHundred(uint8 score) public {
        if (score > 100) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidScore.selector, score));
            _give(CLIENT, agent, JOB, score);
            assertFalse(reputation.feedback(agent, CLIENT, JOB).exists);
            _summary(agent, 0, 0);
            assertEq(reputation.feedbackCount(agent), 0);
            _give(CLIENT, agent, JOB, 100);
            _summary(agent, 1, 100);
        } else {
            _give(CLIENT, agent, JOB, score);
            assertEq(reputation.feedback(agent, CLIENT, JOB).score, score);
            _summary(agent, 1, score);
            vm.prank(CLIENT);
            reputation.revokeFeedback(agent, JOB);
            _summary(agent, 0, 0);
        }
    }

    function testFuzz_AverageAfterEveryWriteAndArbitrarilyOrderedRevocations(
        uint8[16] memory rawScores,
        uint16 revokeMask,
        uint8 orderSeed
    ) public {
        uint256 expectedCount;
        uint256 expectedSum;
        for (uint256 i; i < rawScores.length; ++i) {
            uint8 score = rawScores[i] % 101;
            _give(i % 2 == 0 ? CLIENT : CLIENT_TWO, agent, bytes32(i), score);
            expectedCount++;
            expectedSum += score;
            _summary(agent, expectedCount, expectedSum);
        }
        // Multiplication by an odd number permutes the 16 indices; seed rotates the order.
        for (uint256 step; step < rawScores.length; ++step) {
            uint256 i = (step * 5 + uint256(orderSeed)) % rawScores.length;
            if ((uint256(revokeMask) >> i) & 1 == 0) continue;
            vm.prank(i % 2 == 0 ? CLIENT : CLIENT_TWO);
            reputation.revokeFeedback(agent, bytes32(i));
            expectedCount--;
            expectedSum -= rawScores[i] % 101;
            _summary(agent, expectedCount, expectedSum);
            assertEq(reputation.feedbackCount(agent), 16);
        }
        _summary(otherAgent, 0, 0);
    }

    function _duplicate(address client, uint256 id, bytes32 job) internal {
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.DuplicateFeedback.selector, id, client, job));
        _give(client, id, job, 0);
    }

    function _selfFeedback(address client) internal {
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, client));
        _give(client, agent, keccak256("fresh self-feedback attempt"), 100);
    }
}
