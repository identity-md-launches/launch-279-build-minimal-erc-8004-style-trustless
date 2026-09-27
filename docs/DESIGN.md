# Design, assumptions and operations

## 1. Design decisions

### Identity follows the token
Authorization everywhere is one question: is `account` the owner of the agent token, its per-token
approved address, or an operator of the owner? That is OpenZeppelin's `_isAuthorized`, exposed through
`IAgentIdentityRegistry.isAuthorized(agentId, account)`. The reputation and validation registries call
that view rather than re-implementing the rule, so a transfer, an `approve`, or a `setApprovalForAll`
changes who may act on an agent in all three contracts at once. Because ERC-721 clears the per-token
approval inside `_update`, an old approved address loses control the moment the token moves.

### Why `_mint` and not `_safeMint` in `register`
The token is minted to `msg.sender`, who chose to call `register`. Using `_safeMint` would add an
external call (the receiver hook) inside the registration path for no protective gain, and would stop
contract wallets that do not implement `IERC721Receiver` from registering. Plain `_mint` keeps
`register` free of external calls. `safeTransferFrom` still performs the receiver check as usual.

### Reputation entries are keyed by (agent, client, job)
`jobId` is an opaque `bytes32` chosen by the client. The contract enforces uniqueness only; it has no
opinion on what a job is. A revoked entry keeps its slot, so the same client cannot re-rate the same
job after revoking. That is deliberate: "one entry per triple" means one, ever.

### Summary is maintained incrementally
`summary` is O(1): a running count and sum of non-revoked scores, adjusted on give and revoke. The sum
cannot overflow (each score is at most 100 and the count is bounded by the number of distinct
triples). The floor average is computed on read.

### Validation ids are per agent
`requestId = keccak256(abi.encode(agentId, requestHash))`. Two agents can use the same `requestHash`
without colliding, and nobody can pre-register another agent's hash because `requestValidation` is
gated on being authorized for that agent. Duplicate detection is `status != None`; a request that has
already been answered still blocks a repeat.

### Requests belong to the agent id
`Request.requester` is recorded for history and events, but nothing later checks it. After a transfer
the pending request stays valid and the named validator can still respond. The new owner cannot cancel
it: there is no cancel path by specification (`None -> Pending -> Responded` only).

### Reads on unregistered agents revert
Every view that takes an `agentId` first calls `identityRegistry.ownerOf(agentId)`, which reverts
with `ERC721NonexistentToken(agentId)` for an id that was never minted. Since there is no burn, "never
minted" and "does not exist" are the same thing. `request(requestId)` reverts with `UnknownRequest`.

### No privileged roles, no ETH
None of the contracts inherits `Ownable`, `Pausable` or any proxy pattern. No function is `payable`
and there is no `receive` or `fallback`, so plain transfers of ETH revert. The identity registry
address in the two dependent contracts is `immutable`.

## 2. Assumptions

- **The identity registry is honest.** Both dependent registries trust `isAuthorized` and `ownerOf`
  from the address passed to their constructor. Deploy them against the `AgentIdentityRegistry` from
  this repository (the script does exactly that). Pointing them at a different contract changes the
  security model entirely.
- **Sybil resistance is out of scope.** `SelfFeedback` blocks the addresses that control an agent *at
  call time*. It cannot stop an operator from rating their own agent from a fresh address, or from
  transferring the agent away, rating, and taking it back. Consumers of `summary` must apply their own
  weighting (stake, allow-lists, validator attestations) off chain or in a higher-level contract.
- **Clients choose `jobId`.** A client can write an unbounded number of entries for one agent by
  picking new job ids. `feedbackCount` and `summary` therefore measure volume, not distinct clients.
- **Validators are trusted by whoever named them.** The contract does not check that the validator is
  independent of the agent. An agent owner can name themselves and self-attest; consumers should judge
  validators by address, not by the fact that a response exists.
- **URIs and hashes are opaque.** The contracts store bytes; they do not fetch, parse or verify any
  URI or that a hash matches the content behind it.
- **URI length caps** (512 bytes) exist to bound storage cost and event size, not for security.
- **Compiler**: Solidity 0.8.26 exactly, as pinned in `foundry.toml`, EVM target `cancun`.

## 3. Deployment parameters

There is exactly one parameter: the identity registry address handed to the two dependent
constructors. `script/Deploy.s.sol` does the wiring:

| Contract | Constructor arguments | Post-deploy configuration |
| --- | --- | --- |
| `AgentIdentityRegistry` | none | none |
| `AgentReputationRegistry` | `identityRegistry` (must be non-zero) | none |
| `AgentValidationRegistry` | `identityRegistry` (must be non-zero) | none |

`DeployRegistries.deployAll()` contains the whole procedure and is exercised by `test/Deploy.t.sol`.
`run()` wraps it in `vm.startBroadcast()` / `vm.stopBroadcast()` and reads nothing from the
environment; the signer, RPC and chain are chosen entirely by the operator's `forge script` flags.

This assignment does not deploy. When a deployment is decided on, the remaining choices are
operational: which chain, which deployer key, and whether to verify sources on an explorer. None of
them changes the contract behaviour, and the deployer address retains no power afterward.

## 4. Operational responsibilities

Because there is no admin role, most operational duties fall on integrators and users rather than on a
contract operator.

- **Agent owners** keep the private keys that own the token. Loss of the key is loss of the agent;
  there is no recovery path. Owners should review `approve` and `setApprovalForAll` grants, since
  those addresses can change the agent URI and open validation requests.
- **Clients** hold the ability to revoke their own feedback. Nobody else can remove an entry.
- **Validators** are responsible for responding; a pending request that is never answered stays
  pending forever. Integrators should treat `Pending` as "unknown", not as "failed".
- **Indexers** rebuild lists from events: `Registered`, `AgentURIUpdated`, `Transfer`,
  `FeedbackGiven`, `FeedbackRevoked`, `ValidationRequested`, `ValidationResponded`. The on-chain
  counters (`totalAgents`, `feedbackCount`, `requestCount`, `responseCount`) let an indexer check that
  it has not missed anything.
- **Upgrades** are redeployments. A new version means new addresses and a migration handled off
  chain; nothing here can be paused or pointed elsewhere.
- **Incident response** is limited to publishing advisories. There is no kill switch by design; that
  is a trade the specification makes in favour of neutrality and must be understood before launch.

## 5. Known limitations (not bugs against the specification)

1. Reputation can be inflated or deflated by anyone willing to spend gas from fresh addresses.
2. A pending validation request cannot be cancelled or expired.
3. Self-named validators are allowed.
4. There is no on-chain enumeration of feedback entries or requests per agent, by specification.
5. The 512-byte URI cap is fixed at compile time.
