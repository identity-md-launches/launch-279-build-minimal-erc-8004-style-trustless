# Trustless Agents registry trio (ERC-8004 style)

Three small, ownerless Solidity contracts that together give autonomous agents an on-chain identity, a
client-written reputation, and a validator-answered validation record. The shapes follow the task
specification, not any particular ERC-8004 draft revision.

| Contract | File | Role |
| --- | --- | --- |
| `AgentIdentityRegistry` | `src/AgentIdentityRegistry.sol` | ERC-721 "Agent Identity" (`AGENT`). One token per agent; the token owner, its approved address and its operators control the agent. |
| `AgentReputationRegistry` | `src/AgentReputationRegistry.sol` | One scored feedback entry per (agent, client, job). Revocable once. Running summary of non-revoked entries. |
| `AgentValidationRegistry` | `src/AgentValidationRegistry.sol` | Agent-scoped validation requests answered exactly once by a named validator. |

Shared interface: `src/IAgentIdentityRegistry.sol`. Reference wiring script: `script/Deploy.s.sol`.

## Toolchain

- Foundry (tested with forge 1.8.3), Solidity pinned to `0.8.26` in `foundry.toml`.
- OpenZeppelin Contracts v5.4.0 and forge-std v1.11.0 are vendored as plain files under `lib/`
  (no git submodules; the verifier runs offline).
- `ffi` is off and `fs_permissions` is empty.

```sh
forge build
forge test
forge fmt --check
```

The test suite (`test/`) contains unit tests per contract, a script/end-to-end test, fuzz tests and a
handler-based invariant suite under `test/invariant/`. Tests read no environment variables and do not
depend on ordering.

## Behaviour summary

**Identity.** `register(agentURI)` mints the next id starting at 1 to the caller, stores the URI
(1-512 bytes) and emits `Registered`. `tokenURI(id)` returns it. `setAgentURI(id, uri)` is allowed for
the owner, the per-token approved address or an operator (OpenZeppelin `_isAuthorized`) and emits
`AgentURIUpdated`. After `transferFrom` or `safeTransferFrom` only the new owner and its approvals
control the agent; the per-token approval is cleared by ERC-721 itself. There is no burn.

**Reputation.** `giveFeedback(agentId, jobId, score, tag1, tag2, evidenceURI, evidenceHash)`:
score 0-100, URI 0-512 bytes, an empty URI is only allowed with a zero hash. One entry per
(agent, caller, job); a repeat reverts `DuplicateFeedback`, even after a revoke. Any caller that is
authorized for the agent at call time reverts `SelfFeedback`. `revokeFeedback(agentId, jobId)` marks the
caller's own entry revoked once; the record stays readable but leaves `summary`. `feedbackCount` counts
every entry ever written. `summary` returns (non-revoked count, their score sum, floor average or 0).

**Validation.** `requestValidation(agentId, validator, requestURI, requestHash)` by an address
authorized for the agent; validator and hash non-zero; returns
`keccak256(abi.encode(agentId, requestHash))`, and a repeat of that id reverts. `submitResponse` only by
the named validator, response 0-100, only while `Pending`; states go `None -> Pending -> Responded`
and nowhere else. A request outlives a transfer of the agent. `request(requestId)` returns the full
record; `requestCount` and `responseCount` are the only per-agent counters. Lists come from events.

**Everywhere.** No owner, admin, pause or upgrade path. No contract accepts ETH. Every read that names
an agent id that was never registered reverts (with OpenZeppelin's `ERC721NonexistentToken`), and
`request(id)` reverts for an unknown request id.

## Documentation

- `docs/DESIGN.md`: assumptions, deployment parameters, operational responsibilities, known
  limitations.
- `docs/REVIEW.md`: adversarial review of the contracts and of what the tests do not cover.

## Status

Local only. Nothing has been deployed and this repository does not authorise a deployment. Tests
passing are not a security audit; see `docs/REVIEW.md` for the review scope and the open items.
