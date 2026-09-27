// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAgentIdentityRegistry} from "./IAgentIdentityRegistry.sol";

/// @title AgentIdentityRegistry
/// @notice ERC-721 "Agent Identity" (AGENT). Each token is one agent. Identity follows the token: whoever owns
///         the token (plus its per-token approval and operators) controls the agent. There is no owner, admin,
///         pause, upgrade or burn path, and the contract never holds ETH.
contract AgentIdentityRegistry is ERC721, IAgentIdentityRegistry {
    uint256 public constant MAX_URI_LENGTH = 512;

    uint256 private _nextId;
    mapping(uint256 agentId => string) private _agentURIs;

    constructor() ERC721("Agent Identity", "AGENT") {}

    /// @inheritdoc IAgentIdentityRegistry
    function register(string calldata agentURI) external returns (uint256 agentId) {
        _checkURI(agentURI);
        agentId = ++_nextId;
        _agentURIs[agentId] = agentURI;
        // Plain _mint: the recipient is the caller, who chose to register, so no receiver hook (and therefore no
        // external call or reentrancy) is needed.
        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(msg.sender, agentId);
        emit Registered(agentId, msg.sender, agentURI);
    }

    /// @inheritdoc IAgentIdentityRegistry
    function setAgentURI(uint256 agentId, string calldata agentURI) external {
        _checkURI(agentURI);
        if (!_isAuthorized(_requireOwned(agentId), msg.sender, agentId)) {
            revert NotAuthorized(agentId, msg.sender);
        }
        _agentURIs[agentId] = agentURI;
        emit AgentURIUpdated(agentId, agentURI);
    }

    /// @inheritdoc IAgentIdentityRegistry
    function isAuthorized(uint256 agentId, address account) external view returns (bool) {
        return _isAuthorized(_requireOwned(agentId), account, agentId);
    }

    /// @inheritdoc IAgentIdentityRegistry
    function totalAgents() external view returns (uint256) {
        return _nextId;
    }

    /// @notice Returns the stored agent URI. Reverts for an unregistered id.
    function tokenURI(uint256 agentId) public view override returns (string memory) {
        _requireOwned(agentId);
        return _agentURIs[agentId];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IAgentIdentityRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    function _checkURI(string calldata uri) private pure {
        uint256 length = bytes(uri).length;
        if (length == 0 || length > MAX_URI_LENGTH) revert InvalidAgentURI(length);
    }
}
