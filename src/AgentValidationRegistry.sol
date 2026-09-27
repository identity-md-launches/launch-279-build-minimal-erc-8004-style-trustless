// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentIdentityRegistry} from "./IAgentIdentityRegistry.sol";

/// @title AgentValidationRegistry
/// @notice Minimal ERC-8004-style validation registry. An address authorized for an agent asks a named validator
///         to check some work; the validator answers exactly once with a 0-100 response. Requests belong to the
///         agent id, not to the requester, so they survive a transfer of the agent. Lists are read from events;
///         only per-agent counters are kept on chain. No owner, admin, pause or upgrade path; never holds ETH.
contract AgentValidationRegistry {
    enum Status {
        None,
        Pending,
        Responded
    }

    struct Request {
        uint256 agentId;
        address requester;
        address validator;
        Status status;
        uint8 response;
        bytes32 requestHash;
        bytes32 responseHash;
        string requestURI;
        string responseURI;
    }

    uint8 public constant MAX_RESPONSE = 100;
    uint256 public constant MAX_URI_LENGTH = 512;

    IAgentIdentityRegistry public immutable identityRegistry;

    mapping(bytes32 requestId => Request) private _requests;
    mapping(uint256 agentId => uint256) private _requestCount;
    mapping(uint256 agentId => uint256) private _responseCount;

    event ValidationRequested(
        bytes32 indexed requestId,
        uint256 indexed agentId,
        address indexed validator,
        address requester,
        string requestURI,
        bytes32 requestHash
    );
    event ValidationResponded(
        bytes32 indexed requestId,
        uint256 indexed agentId,
        address indexed validator,
        uint8 response,
        string responseURI,
        bytes32 responseHash
    );

    error ZeroAddress();
    error ZeroHash();
    error InvalidURI(uint256 length);
    error InvalidResponse(uint8 response);
    error NotAuthorized(uint256 agentId, address caller);
    error DuplicateRequest(bytes32 requestId);
    error UnknownRequest(bytes32 requestId);
    error NotValidator(bytes32 requestId, address caller);
    error NotPending(bytes32 requestId, Status status);

    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0)) revert ZeroAddress();
        identityRegistry = IAgentIdentityRegistry(identityRegistry_);
    }

    /// @notice Opens a validation request for `agentId` addressed to `validator`.
    /// @dev Caller must be authorized for the agent at call time (reverts for an unregistered agent). The id is
    ///      keccak256(abi.encode(agentId, requestHash)), so hashes are scoped per agent and a repeat reverts.
    function requestValidation(uint256 agentId, address validator, string calldata requestURI, bytes32 requestHash)
        external
        returns (bytes32 requestId)
    {
        if (validator == address(0)) revert ZeroAddress();
        if (requestHash == bytes32(0)) revert ZeroHash();
        _checkURI(requestURI);
        if (!identityRegistry.isAuthorized(agentId, msg.sender)) revert NotAuthorized(agentId, msg.sender);

        requestId = keccak256(abi.encode(agentId, requestHash));
        Request storage r = _requests[requestId];
        if (r.status != Status.None) revert DuplicateRequest(requestId);

        r.agentId = agentId;
        r.requester = msg.sender;
        r.validator = validator;
        r.status = Status.Pending;
        r.requestHash = requestHash;
        r.requestURI = requestURI;
        _requestCount[agentId] += 1;

        emit ValidationRequested(requestId, agentId, validator, msg.sender, requestURI, requestHash);
    }

    /// @notice Answers a pending request. Only the named validator may call, and only once.
    function submitResponse(bytes32 requestId, uint8 response, string calldata responseURI, bytes32 responseHash)
        external
    {
        if (response > MAX_RESPONSE) revert InvalidResponse(response);
        _checkURI(responseURI);

        Request storage r = _requests[requestId];
        if (r.status == Status.None) revert UnknownRequest(requestId);
        if (msg.sender != r.validator) revert NotValidator(requestId, msg.sender);
        if (r.status != Status.Pending) revert NotPending(requestId, r.status);

        r.status = Status.Responded;
        r.response = response;
        r.responseHash = responseHash;
        r.responseURI = responseURI;
        _responseCount[r.agentId] += 1;

        emit ValidationResponded(requestId, r.agentId, msg.sender, response, responseURI, responseHash);
    }

    /// @notice Full record for `requestId`. Reverts for an unknown id.
    function request(bytes32 requestId) external view returns (Request memory) {
        Request memory r = _requests[requestId];
        if (r.status == Status.None) revert UnknownRequest(requestId);
        return r;
    }

    /// @notice Pure helper mirroring the on-chain id derivation.
    function computeRequestId(uint256 agentId, bytes32 requestHash) external pure returns (bytes32) {
        return keccak256(abi.encode(agentId, requestHash));
    }

    /// @notice Number of requests ever opened for `agentId`. Reverts for an unregistered agent.
    function requestCount(uint256 agentId) external view returns (uint256) {
        _requireAgent(agentId);
        return _requestCount[agentId];
    }

    /// @notice Number of requests for `agentId` that have been answered. Reverts for an unregistered agent.
    function responseCount(uint256 agentId) external view returns (uint256) {
        _requireAgent(agentId);
        return _responseCount[agentId];
    }

    function _requireAgent(uint256 agentId) private view {
        // ownerOf reverts with ERC721NonexistentToken for an unregistered id; only the revert matters here.
        // forge-lint: disable-next-line(unused-return)
        identityRegistry.ownerOf(agentId);
    }

    function _checkURI(string calldata uri) private pure {
        uint256 length = bytes(uri).length;
        if (length > MAX_URI_LENGTH) revert InvalidURI(length);
    }
}
