// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";

contract AgentReputationRegistryTest is Test {
    AgentIdentityRegistry internal identity;
    AgentReputationRegistry internal reputation;

    address internal alice = makeAddr("alice"); // agent owner
    address internal bob = makeAddr("bob"); // later owner
    address internal approved = makeAddr("approved");
    address internal operator = makeAddr("operator");
    address internal client1 = makeAddr("client1");
    address internal client2 = makeAddr("client2");

    uint256 internal agent;
    bytes32 internal constant JOB1 = keccak256("job-1");
    bytes32 internal constant JOB2 = keccak256("job-2");
    bytes32 internal constant TAG1 = bytes32("quality");
    bytes32 internal constant TAG2 = bytes32("speed");
    bytes32 internal constant HASH = keccak256("evidence");
    string internal constant EVIDENCE = "ipfs://evidence";

    function setUp() public {
        identity = new AgentIdentityRegistry();
        reputation = new AgentReputationRegistry(address(identity));
        vm.prank(alice);
        agent = identity.register("ipfs://agent");
    }

    // ---------------------------------------------------------------- constructor

    function test_Constructor_StoresRegistry() public view {
        assertEq(address(reputation.identityRegistry()), address(identity));
        assertEq(reputation.MAX_SCORE(), 100);
        assertEq(reputation.MAX_URI_LENGTH(), 512);
    }

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(AgentReputationRegistry.ZeroAddress.selector);
        new AgentReputationRegistry(address(0));
    }

    // ---------------------------------------------------------------- giveFeedback: success

    function test_GiveFeedback_StoresEntryEmitsAndUpdatesSummary() public {
        vm.prank(client1);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit AgentReputationRegistry.FeedbackGiven(agent, client1, JOB1, 80, TAG1, TAG2, EVIDENCE, HASH);
        reputation.giveFeedback(agent, JOB1, 80, TAG1, TAG2, EVIDENCE, HASH);

        AgentReputationRegistry.Feedback memory f = reputation.feedback(agent, client1, JOB1);
        assertTrue(f.exists);
        assertFalse(f.revoked);
        assertEq(f.score, 80);
        assertEq(f.tag1, TAG1);
        assertEq(f.tag2, TAG2);
        assertEq(f.evidenceHash, HASH);
        assertEq(f.evidenceURI, EVIDENCE);

        assertEq(reputation.feedbackCount(agent), 1);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 1);
        assertEq(sum, 80);
        assertEq(avg, 80);
    }

    function test_GiveFeedback_BoundaryScoresAccepted() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 0, 0, 0, "", 0);
        vm.prank(client2);
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 2);
        assertEq(sum, 100);
        assertEq(avg, 50);
    }

    function test_GiveFeedback_EmptyURIWithZeroHashAllowed() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 50, 0, 0, "", bytes32(0));
        assertTrue(reputation.feedback(agent, client1, JOB1).exists);
    }

    function test_GiveFeedback_URIWithZeroHashAllowed() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 50, 0, 0, EVIDENCE, bytes32(0));
        assertEq(reputation.feedback(agent, client1, JOB1).evidenceURI, EVIDENCE);
    }

    function test_GiveFeedback_MaxLengthURIAllowed() public {
        string memory uri = _uriOfLength(512);
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 50, 0, 0, uri, HASH);
        assertEq(bytes(reputation.feedback(agent, client1, JOB1).evidenceURI).length, 512);
    }

    function test_GiveFeedback_SameClientDifferentJobs() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agent, JOB1, 40, 0, 0, "", 0);
        reputation.giveFeedback(agent, JOB2, 60, 0, 0, "", 0);
        vm.stopPrank();
        assertEq(reputation.feedbackCount(agent), 2);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 2);
        assertEq(sum, 100);
        assertEq(avg, 50);
    }

    function test_GiveFeedback_SameJobDifferentClientsAndAgents() public {
        vm.prank(bob);
        uint256 agent2 = identity.register("ipfs://agent-2");

        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 10, 0, 0, "", 0);
        vm.prank(client2);
        reputation.giveFeedback(agent, JOB1, 20, 0, 0, "", 0);
        vm.prank(client1);
        reputation.giveFeedback(agent2, JOB1, 30, 0, 0, "", 0);

        assertEq(reputation.feedbackCount(agent), 2);
        assertEq(reputation.feedbackCount(agent2), 1);
        (, uint256 sum1,) = reputation.summary(agent);
        (, uint256 sum2,) = reputation.summary(agent2);
        assertEq(sum1, 30);
        assertEq(sum2, 30);
    }

    function test_Summary_FloorAverage() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 1, 0, 0, "", 0);
        vm.prank(client2);
        reputation.giveFeedback(agent, JOB1, 2, 0, 0, "", 0);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 2);
        assertEq(sum, 3);
        assertEq(avg, 1); // floor(3 / 2)
    }

    function test_OldOwnerCanRateAfterTransfer() public {
        vm.prank(alice);
        identity.transferFrom(alice, bob, agent);
        // alice is no longer authorized, so she is an ordinary client now.
        vm.prank(alice);
        reputation.giveFeedback(agent, JOB1, 90, 0, 0, "", 0);
        assertEq(reputation.feedbackCount(agent), 1);
    }

    // ---------------------------------------------------------------- giveFeedback: failures

    function test_GiveFeedback_RevertsOnDuplicate() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        vm.expectRevert(
            abi.encodeWithSelector(AgentReputationRegistry.DuplicateFeedback.selector, agent, client1, JOB1)
        );
        reputation.giveFeedback(agent, JOB1, 10, 0, 0, "", 0);
        // A different job by the same client still works.
        reputation.giveFeedback(agent, JOB2, 10, 0, 0, "", 0);
        vm.stopPrank();
        assertEq(reputation.feedbackCount(agent), 2);
    }

    function test_GiveFeedback_RevertsOnDuplicateEvenAfterRevoke() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        reputation.revokeFeedback(agent, JOB1);
        vm.expectRevert(
            abi.encodeWithSelector(AgentReputationRegistry.DuplicateFeedback.selector, agent, client1, JOB1)
        );
        reputation.giveFeedback(agent, JOB1, 10, 0, 0, "", 0);
        vm.stopPrank();
    }

    function test_GiveFeedback_RevertsOnScoreAbove100() public {
        vm.prank(client1);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidScore.selector, 101));
        reputation.giveFeedback(agent, JOB1, 101, 0, 0, "", 0);
    }

    function test_GiveFeedback_RevertsOnOversizedURI() public {
        string memory uri = _uriOfLength(513);
        vm.prank(client1);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidEvidenceURI.selector, 513));
        reputation.giveFeedback(agent, JOB1, 50, 0, 0, uri, HASH);
    }

    function test_GiveFeedback_RevertsOnEmptyURIWithHash() public {
        vm.prank(client1);
        vm.expectRevert(AgentReputationRegistry.EvidenceHashWithoutURI.selector);
        reputation.giveFeedback(agent, JOB1, 50, 0, 0, "", HASH);
    }

    function test_GiveFeedback_RevertsOnUnregisteredAgent() public {
        vm.prank(client1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        reputation.giveFeedback(99, JOB1, 50, 0, 0, "", 0);
    }

    function test_SelfFeedback_OwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, alice));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
    }

    function test_SelfFeedback_ApprovedReverts() public {
        vm.prank(alice);
        identity.approve(approved, agent);
        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, approved));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
    }

    function test_SelfFeedback_OperatorReverts() public {
        vm.prank(alice);
        identity.setApprovalForAll(operator, true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, operator));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
    }

    function test_SelfFeedback_NewOwnerAndItsApprovalsRevertAfterTransfer() public {
        vm.prank(alice);
        identity.transferFrom(alice, bob, agent);
        vm.startPrank(bob);
        identity.approve(approved, agent);
        identity.setApprovalForAll(operator, true);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, bob));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
        vm.stopPrank();

        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, approved));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, agent, operator));
        reputation.giveFeedback(agent, JOB1, 100, 0, 0, "", 0);
    }

    function test_SelfFeedback_OperatorOfOtherOwnerCanRate() public {
        // operator is authorized for bob's tokens only; agent belongs to alice.
        vm.prank(bob);
        identity.setApprovalForAll(operator, true);
        vm.prank(operator);
        reputation.giveFeedback(agent, JOB1, 70, 0, 0, "", 0);
        assertEq(reputation.feedbackCount(agent), 1);
    }

    // ---------------------------------------------------------------- revokeFeedback

    function test_Revoke_DropsEntryFromSummaryButKeepsIt() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 80, TAG1, TAG2, EVIDENCE, HASH);
        vm.prank(client2);
        reputation.giveFeedback(agent, JOB1, 40, 0, 0, "", 0);

        vm.prank(client1);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit AgentReputationRegistry.FeedbackRevoked(agent, client1, JOB1);
        reputation.revokeFeedback(agent, JOB1);

        AgentReputationRegistry.Feedback memory f = reputation.feedback(agent, client1, JOB1);
        assertTrue(f.exists);
        assertTrue(f.revoked);
        assertEq(f.score, 80);
        assertEq(f.evidenceURI, EVIDENCE);

        assertEq(reputation.feedbackCount(agent), 2, "feedbackCount counts revoked entries");
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 1);
        assertEq(sum, 40);
        assertEq(avg, 40);
    }

    function test_Revoke_LastEntryYieldsZeroSummary() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        reputation.revokeFeedback(agent, JOB1);
        vm.stopPrank();
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 0);
        assertEq(sum, 0);
        assertEq(avg, 0);
        assertEq(reputation.feedbackCount(agent), 1);
    }

    function test_Revoke_SecondRevokeReverts() public {
        vm.startPrank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        reputation.revokeFeedback(agent, JOB1);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.AlreadyRevoked.selector, agent, client1, JOB1));
        reputation.revokeFeedback(agent, JOB1);
        vm.stopPrank();
    }

    function test_Revoke_UnknownEntryReverts() public {
        vm.prank(client1);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, agent, client1, JOB1));
        reputation.revokeFeedback(agent, JOB1);
    }

    function test_Revoke_UnregisteredAgentReverts() public {
        // No entry can exist for an id that was never minted, so the revoke fails as unknown.
        vm.prank(client1);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, 99, client1, JOB1));
        reputation.revokeFeedback(99, JOB1);
    }

    function test_Revoke_OnlyAuthorReverts_OthersCannotRevoke() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        // The agent owner cannot revoke a client's feedback; the mapping is keyed by msg.sender.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, agent, alice, JOB1));
        reputation.revokeFeedback(agent, JOB1);
        vm.prank(client2);
        vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.UnknownFeedback.selector, agent, client2, JOB1));
        reputation.revokeFeedback(agent, JOB1);
        assertFalse(reputation.feedback(agent, client1, JOB1).revoked);
    }

    function test_Revoke_WorksAfterAgentTransfer() public {
        vm.prank(client1);
        reputation.giveFeedback(agent, JOB1, 80, 0, 0, "", 0);
        vm.prank(alice);
        identity.transferFrom(alice, bob, agent);
        vm.prank(client1);
        reputation.revokeFeedback(agent, JOB1);
        (uint256 count,,) = reputation.summary(agent);
        assertEq(count, 0);
    }

    // ---------------------------------------------------------------- views on unregistered agents revert

    function test_Views_RevertOnUnregisteredAgent() public {
        bytes memory err = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42);
        vm.expectRevert(err);
        reputation.feedback(42, client1, JOB1);
        vm.expectRevert(err);
        reputation.feedbackCount(42);
        vm.expectRevert(err);
        reputation.summary(42);
    }

    function test_Views_RegisteredAgentWithoutFeedbackReturnsZeros() public view {
        AgentReputationRegistry.Feedback memory f = reputation.feedback(agent, client1, JOB1);
        assertFalse(f.exists);
        assertEq(reputation.feedbackCount(agent), 0);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, 0);
        assertEq(sum, 0);
        assertEq(avg, 0);
    }

    function test_RejectsPlainEther() public {
        vm.deal(client1, 1 ether);
        vm.prank(client1);
        (bool ok,) = address(reputation).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- fuzz / invariant-style

    function testFuzz_GiveFeedback_ScoreBounds(uint8 score) public {
        vm.prank(client1);
        if (score > 100) {
            vm.expectRevert(abi.encodeWithSelector(AgentReputationRegistry.InvalidScore.selector, score));
        }
        reputation.giveFeedback(agent, JOB1, score, 0, 0, "", 0);
    }

    /// @dev Summary equals the recomputed sum over the non-revoked entries, whatever the revoke pattern.
    function testFuzz_SummaryMatchesRecomputation(uint8[8] memory scores, uint8 revokeMask) public {
        uint256 expectedCount;
        uint256 expectedSum;
        for (uint256 i = 0; i < scores.length; i++) {
            uint8 s = scores[i] % 101;
            address client = address(uint160(0x1000 + i));
            vm.prank(client);
            reputation.giveFeedback(agent, JOB1, s, 0, 0, "", 0);
            if (revokeMask & (1 << i) != 0) {
                vm.prank(client);
                reputation.revokeFeedback(agent, JOB1);
            } else {
                expectedCount++;
                expectedSum += s;
            }
        }
        assertEq(reputation.feedbackCount(agent), scores.length);
        (uint256 count, uint256 sum, uint256 avg) = reputation.summary(agent);
        assertEq(count, expectedCount);
        assertEq(sum, expectedSum);
        assertEq(avg, expectedCount == 0 ? 0 : expectedSum / expectedCount);
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
