# Adversarial review

Scope: `src/AgentIdentityRegistry.sol`, `src/AgentReputationRegistry.sol`,
`src/AgentValidationRegistry.sol`, `script/Deploy.s.sol`, and the test suite, at the state committed
with this document. The review was performed by the same contributor who wrote the code, so it is a
self-review against the questions an attacker asks, not an independent audit. Work that will be relied
on by third parties should get a separate adversarial review before release.

Each item states the question, what the code does, and whether a concrete failing input was found.

## 1. Who can call what

| Function | Allowed caller | Check location | Finding |
| --- | --- | --- | --- |
| `register` | anyone | n/a | none: minting to self is the intended open path |
| `setAgentURI` | owner / approved / operator | `_isAuthorized(_requireOwned(id), msg.sender, id)` | none |
| ERC-721 `approve`, `setApprovalForAll`, `transferFrom`, `safeTransferFrom` | OpenZeppelin rules | inherited | none; no overrides that could weaken them |
| `giveFeedback` | anyone **not** authorized for the agent | `identityRegistry.isAuthorized` | none |
| `revokeFeedback` | the client who wrote the entry | mapping keyed by `msg.sender` | none: another address gets `UnknownFeedback` |
| `requestValidation` | owner / approved / operator | `identityRegistry.isAuthorized` | none |
| `submitResponse` | the named validator | `msg.sender != r.validator` | none |
| any `owner()`, `pause()`, `upgradeTo` | n/a | not present | none; tests assert the selectors are absent |

No initialiser, no proxy, no `selfdestruct`, no `delegatecall`, no fallback or receive function.

**Point-in-time authorization (accepted by specification).** `SelfFeedback` is evaluated when
`giveFeedback` runs. An owner who transfers the agent to a second wallet, rates it from the first, and
transfers it back has produced a "non-self" rating. Equally, a fresh address costs nothing. This is
the behaviour the specification asks for and is documented as a limitation in `docs/DESIGN.md`; it is
not a permission bypass. No fix is proposed that would change the agreed design.

## 2. Value in and out

There is no value. No function is `payable`, no contract has `receive` or `fallback`, and the tests
confirm a plain ETH transfer to each contract reverts. There are no token transfers, so
fee-on-transfer, rebasing and return-value questions do not arise.

**Reentrancy.** The only external calls are:

- `identityRegistry.isAuthorized` and `identityRegistry.ownerOf` (both `view`, called through a
  `STATICCALL`) from the reputation and validation registries;
- the ERC-721 receiver hook inside `safeTransferFrom`, inherited from OpenZeppelin and executed after
  ownership has been updated.

`register` uses `_mint`, not `_safeMint`, so the registration path has no external call at all.
There is no path where a callee can re-enter with state half-written.

## 3. Arithmetic and limits

- `_nextId` is pre-incremented; ids start at 1 and cannot wrap in practice.
- `summary.sum` is bounded by `100 * count`; `count` is bounded by distinct (client, job) pairs. No
  overflow is reachable. `revokeFeedback` decrements only after confirming the entry exists and is not
  yet revoked, so `count -= 1` and `sum -= score` cannot underflow.
- Floor average: `sum / count` with `count > 0`, otherwise `0`. Tested with `(1 + 2) / 2 == 1`.
- `uint8` bounds for `score` and `response` are checked explicitly against `100`.
- URI lengths are capped at 512 bytes on every write; the maximum accepted and the first rejected
  length are both tested.
- There are no loops over user-controlled data on chain. The handler and unit tests loop, the
  contracts do not.

## 4. Time, ordering and randomness

No timestamps, block numbers, block hashes or randomness are read anywhere.

**Front-running.** A `requestValidation` transaction in the mempool reveals `(agentId, requestHash)`;
only an address authorized for that agent can produce the same id, so a stranger cannot squat it. Two
authorized addresses for the same agent racing on the same hash is a self-inflicted collision. A
client's `giveFeedback` can be front-run only by the same client for the same job, which is again
self-inflicted. No exploitable ordering dependence was found.

## 5. Signatures and identity

No signatures, no `ecrecover`, no `tx.origin`, no permit. Identity is the ERC-721 token and nothing
else.

## 6. External dependencies

- **OpenZeppelin Contracts v5.4.0**, vendored verbatim under `lib/`. The identity registry inherits
  `ERC721` and overrides only `tokenURI` and `supportsInterface`. `_update` is not overridden, so
  transfer semantics (including clearing the per-token approval) are exactly the audited upstream
  behaviour. No `ERC721Burnable`, `ERC721Pausable` or `Ownable` mix-ins are included, so no burn,
  pause or owner surface leaks in.
- **The identity registry address** is `immutable` in both dependent contracts and validated non-zero
  in the constructor. It is a trusted dependency by design; see the assumption in `docs/DESIGN.md`.
- **forge-std v1.11.0** is test-only.

## 7. Specification conformance checked line by line

| Requirement | Where enforced | Tests |
| --- | --- | --- |
| ids from 1, minted to caller, URI 1-512 bytes, `Registered` event | `register` | `test_Register_*`, `testFuzz_Register_AnyValidURI` |
| `setAgentURI` for owner / approved / operator, `AgentURIUpdated` event | `setAgentURI` | `test_SetAgentURI_*`, `testFuzz_SetAgentURI_OnlyAuthorized` |
| after `transferFrom` / `safeTransferFrom` old owner and old approved lose control, new owner gains it, approval cleared | inherited `_update` | `test_TransferFrom_*`, `test_SafeTransferFrom_*`, `_assertControlMovedTo` |
| no burn | no burn function inherited or written | `test_NoBurnFunctionExposed` |
| score 0-100, URI 0-512, empty URI only with zero hash | `giveFeedback` | boundary and revert tests |
| one entry per (agent, client, job), `DuplicateFeedback`; same client, other job OK | `entry.exists` | `test_GiveFeedback_RevertsOnDuplicate`, `..._SameClientDifferentJobs` |
| authorized addresses revert `SelfFeedback`, including new owner after transfer | `isAuthorized` | five `test_SelfFeedback_*` tests |
| revoke once by the client, kept in storage, out of summary | `revokeFeedback` | `test_Revoke_*` |
| `feedbackCount` counts all; `summary` counts non-revoked, floor average, 0 when empty | views | `test_Summary_FloorAverage`, `testFuzz_SummaryMatchesRecomputation`, invariant |
| validator and hash non-zero; id = `keccak256(abi.encode(agentId, requestHash))`; duplicate reverts | `requestValidation` | `test_Request_*` |
| only named validator, response 0-100, only while Pending, `None -> Pending -> Responded` | `submitResponse` | `test_Respond_*`, `testFuzz_Respond_OnlyNamedValidator`, invariant |
| request survives agent transfer | no re-check of requester | `test_Respond_RequestSurvivesAgentTransfer` |
| reads on unregistered agent revert | `_requireOwned` / `_requireAgent` | `test_Reads_RevertOnUnregisteredId`, `test_Views_RevertOnUnregisteredAgent`, `test_Counters_RevertOnUnregisteredAgent` |
| no owner / admin / pause / upgrade / ETH | absence | `test_NoOwnerOrPauseSurface`, `test_RejectsPlainEther`, `invariant_IdentityIsConsistent` |

## 8. Findings

No concrete input was found that violates the requested behaviour or lets an unauthorized address
change state. Two observations are recorded so that they are not mistaken for oversights:

1. **Self-named validators are permitted.** `requestValidation(agentId, msg.sender, ...)` by the agent
   owner succeeds, and the owner then answers their own request. The specification does not forbid
   it and it is documented; a consumer must weigh validators by address. Expected versus actual: as
   specified.
2. **Revoked feedback permanently blocks the (agent, client, job) slot.** A client who revokes cannot
   write a corrected entry for the same job. This is the strict reading of "one entry per triple" and
   is tested (`test_GiveFeedback_RevertsOnDuplicateEvenAfterRevoke`). If a product later wants
   corrections, the change is a design change, not a bug fix.

## 9. What the tests do not cover

Read as an attacker, these are the edges the suite leaves open:

- **Alternative identity registries.** Every test wires the dependent contracts to this repository's
  `AgentIdentityRegistry`. Behaviour against a registry whose `isAuthorized` lies, reverts
  unexpectedly, or returns malformed data is not tested. It is a stated trust assumption.
- **Sybil and collusion patterns** (transfer, rate, transfer back; many fresh clients) are not tested
  because the contract intentionally does not defend against them.
- **Gas at the caps.** A 512-byte URI is tested for acceptance, but no test asserts a gas ceiling for
  `register`, `giveFeedback` or `requestValidation` at maximum input size.
- **Upstream ERC-721 paths** such as `safeTransferFrom` to a rejecting receiver, approval to the
  current owner, or transfers from the wrong owner are relied on from OpenZeppelin and not
  re-tested here beyond one accepting receiver and one clearing-of-approval check.
- **Invariant depth.** The invariant suite runs 32 sequences of depth 64 with three agents, six actors
  and four job ids so that it finishes in seconds. It is a smoke test of the accounting, not an
  exhaustive exploration.
- **Event contents** are asserted on the success paths for every event; they are not asserted after
  every revert path (reverts emit nothing, which Foundry checks implicitly through `expectRevert`).

## 10. Verdict

The three contracts implement the specified shapes, expose no privileged role, hold no value, and
the tests exercise both success and failure of every requirement in the acceptance list. The
remaining risk is in the trust assumptions listed above, not in the code paths. An independent
review is still required before anything depends on these registries.
