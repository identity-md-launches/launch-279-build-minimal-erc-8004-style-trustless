// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IAgentIdentityRegistry
/// @notice Minimal ERC-8004-style agent identity registry interface. Every agent is an ERC-721 token; the
///         token's owner, its per-token approved address and its operators control the agent.
interface IAgentIdentityRegistry is IERC721 {
    /// @notice Emitted when a new agent is registered.
    event Registered(uint256 indexed agentId, address indexed owner, string agentURI);
    /// @notice Emitted when an agent's URI is replaced.
    event AgentURIUpdated(uint256 indexed agentId, string agentURI);

    /// @notice The URI is empty or longer than 512 bytes.
    error InvalidAgentURI(uint256 length);
    /// @notice The caller is neither the owner, the approved address nor an operator of the agent.
    error NotAuthorized(uint256 agentId, address caller);

    /// @notice Mints the next agent id (starting at 1) to `msg.sender` and stores `agentURI`.
    function register(string calldata agentURI) external returns (uint256 agentId);

    /// @notice Replaces the URI of `agentId`. Only the owner, the approved address or an operator may call.
    function setAgentURI(uint256 agentId, string calldata agentURI) external;

    /// @notice Returns true when `account` is the owner, the approved address or an operator of `agentId`.
    ///         Reverts when `agentId` was never registered.
    function isAuthorized(uint256 agentId, address account) external view returns (bool);

    /// @notice Total number of agents registered so far (ids run from 1 to this value).
    function totalAgents() external view returns (uint256);
}
