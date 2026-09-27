// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentIdentityRegistry} from "./IAgentIdentityRegistry.sol";

/// @title AgentReputationRegistry
/// @notice Minimal ERC-8004-style reputation registry. Any address that is not authorized for an agent may leave
///         one scored feedback entry per (agent, client, job). Entries can be revoked once by the client that
///         wrote them; revoked entries stay in storage but leave the summary. No owner, admin, pause or upgrade
///         path; the contract never holds ETH.
contract AgentReputationRegistry {
    struct Feedback {
        bool exists;
        bool revoked;
        uint8 score;
        bytes32 tag1;
        bytes32 tag2;
        bytes32 evidenceHash;
        string evidenceURI;
    }

    struct Summary {
        uint256 count;
        uint256 sum;
    }

    uint8 public constant MAX_SCORE = 100;
    uint256 public constant MAX_URI_LENGTH = 512;

    IAgentIdentityRegistry public immutable identityRegistry;

    mapping(uint256 agentId => mapping(address client => mapping(bytes32 jobId => Feedback))) private _feedback;
    mapping(uint256 agentId => uint256) private _feedbackCount;
    mapping(uint256 agentId => Summary) private _summary;

    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed client,
        bytes32 indexed jobId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string evidenceURI,
        bytes32 evidenceHash
    );
    event FeedbackRevoked(uint256 indexed agentId, address indexed client, bytes32 indexed jobId);

    error ZeroAddress();
    error InvalidScore(uint8 score);
    error InvalidEvidenceURI(uint256 length);
    error EvidenceHashWithoutURI();
    error DuplicateFeedback(uint256 agentId, address client, bytes32 jobId);
    error SelfFeedback(uint256 agentId, address client);
    error UnknownFeedback(uint256 agentId, address client, bytes32 jobId);
    error AlreadyRevoked(uint256 agentId, address client, bytes32 jobId);

    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0)) revert ZeroAddress();
        identityRegistry = IAgentIdentityRegistry(identityRegistry_);
    }

    /// @notice Records one feedback entry for `agentId` from `msg.sender` about `jobId`.
    /// @dev Reverts when the agent is unregistered (bubbled from the identity registry), when the caller is
    ///      authorized for the agent at call time, on a duplicate (agent, client, job), on a score above 100,
    ///      on a URI longer than 512 bytes, or on an empty URI paired with a non-zero hash.
    function giveFeedback(
        uint256 agentId,
        bytes32 jobId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string calldata evidenceURI,
        bytes32 evidenceHash
    ) external {
        if (score > MAX_SCORE) revert InvalidScore(score);
        uint256 uriLength = bytes(evidenceURI).length;
        if (uriLength > MAX_URI_LENGTH) revert InvalidEvidenceURI(uriLength);
        if (uriLength == 0 && evidenceHash != bytes32(0)) revert EvidenceHashWithoutURI();

        // Reverts for an unregistered agent id.
        if (identityRegistry.isAuthorized(agentId, msg.sender)) revert SelfFeedback(agentId, msg.sender);

        Feedback storage entry = _feedback[agentId][msg.sender][jobId];
        if (entry.exists) revert DuplicateFeedback(agentId, msg.sender, jobId);

        entry.exists = true;
        entry.score = score;
        entry.tag1 = tag1;
        entry.tag2 = tag2;
        entry.evidenceHash = evidenceHash;
        entry.evidenceURI = evidenceURI;

        _feedbackCount[agentId] += 1;
        Summary storage s = _summary[agentId];
        s.count += 1;
        s.sum += score;

        emit FeedbackGiven(agentId, msg.sender, jobId, score, tag1, tag2, evidenceURI, evidenceHash);
    }

    /// @notice Marks the caller's entry for (agentId, jobId) as revoked. The entry stays readable but no longer
    ///         counts toward the summary. A second revoke reverts.
    function revokeFeedback(uint256 agentId, bytes32 jobId) external {
        Feedback storage entry = _feedback[agentId][msg.sender][jobId];
        if (!entry.exists) revert UnknownFeedback(agentId, msg.sender, jobId);
        if (entry.revoked) revert AlreadyRevoked(agentId, msg.sender, jobId);

        entry.revoked = true;
        Summary storage s = _summary[agentId];
        s.count -= 1;
        s.sum -= entry.score;

        emit FeedbackRevoked(agentId, msg.sender, jobId);
    }

    /// @notice Returns the stored entry. Reverts for an unregistered agent; returns an all-zero record with
    ///         `exists == false` when the agent exists but no such entry does.
    function feedback(uint256 agentId, address client, bytes32 jobId) external view returns (Feedback memory) {
        _requireAgent(agentId);
        return _feedback[agentId][client][jobId];
    }

    /// @notice Number of entries ever written for `agentId`, including revoked ones.
    function feedbackCount(uint256 agentId) external view returns (uint256) {
        _requireAgent(agentId);
        return _feedbackCount[agentId];
    }

    /// @notice Non-revoked entry count, sum of their scores and the floor average (0 when count is 0).
    function summary(uint256 agentId) external view returns (uint256 count, uint256 sum, uint256 average) {
        _requireAgent(agentId);
        Summary storage s = _summary[agentId];
        count = s.count;
        sum = s.sum;
        average = count == 0 ? 0 : sum / count;
    }

    function _requireAgent(uint256 agentId) private view {
        // ownerOf reverts with ERC721NonexistentToken for an unregistered id; only the revert matters here.
        // forge-lint: disable-next-line(unused-return)
        identityRegistry.ownerOf(agentId);
    }
}
