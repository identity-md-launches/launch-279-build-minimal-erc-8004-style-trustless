# Independent registry tests and review

Reviewed the three registry implementations and their identity interface against the assignment,
using the installed Solidity 0.8.26 and vendored OpenZeppelin/forge-std dependencies. No external
draft was used as a specification. Source, existing tests, libraries, scripts and configuration
remain unchanged. The new fixture deploys the contracts directly and does not inherit existing
tests or invoke deployment scripts.

## Acceptance coverage

| Requirement | Independent checks |
| --- | --- |
| Identity moves after either transfer overload | `IdentityAcceptance.t.sol`: separate `transferFrom`, three-argument and four-argument `safeTransferFrom` cases; previous owner, approved address and operator lose control; new owner and new approvals can edit |
| ERC-721 receiver boundaries | Callback can edit metadata and request validation but cannot self-rate; rejecting callback rolls back identity, approval clearing and the cross-registry request |
| Registration and URI bounds | Sequential ids, metadata/events, fuzzed byte lengths, invalid registration retry, and multibyte UTF-8 length checks |
| Unique feedback triples | Same triple rejected before and after revocation; different job, client and agent succeed; original score and lifetime count preserved |
| No current authority can self-rate | Owner, approved address and operator denied; revoking approval changes eligibility immediately; both transfers change eligibility; new approvals denied |
| Revocation semantics | Only the client revokes, once; entry contents and event retained; missing and repeated revocations preserve totals; a client who becomes owner may still revoke historical feedback |
| Scores and summaries | Full `uint8` score fuzzing, rejected write retry, 16-score fuzzed averages checked after every write and arbitrary subsets/orders of revocation, zero-score live entry versus empty summary |
| Validation state machine | All request/response fields and events; owner/approved/operator requests; unauthorized caller, zero validator/hash, nonexistent request, duplicate Pending/Responded request, non-validator response and repeated response failures |
| Agent-scoped validation ids | Fuzzed hashes compared to independent `keccak256(abi.encode(agentId, hash))`; another agent may use the hash, but its owner cannot squat the target agent's hash |
| Validation survives transfer | Requests by all three authorities survive both transfer methods, retain historical requester, reject retargeting and new-owner responses, and accept the original validator's response |
| Validation response range | Full `uint8` response fuzzing, zero as a completed response, invalid response leaves Pending and permits a valid retry |
| Unknown agents and ordinary ETH transfers | Zero, next id, maximum id and fuzzed unknown ids; all agent state getters/counters revert; valid-input writes to unknown agents revert; plain ETH transfers fail |

## Independent invariant model

`ReputationLedger.invariant.t.sol` explicitly targets seven handler actions: register, transfer,
approve/clear approval, enable/disable operator, give feedback, revoke an arbitrary triple, and
revoke a known ledger entry. It uses up to five dynamically registered agents, six actors and five
jobs. Both transfer methods and self-transfers are exercised. Expected failures use exact revert
data; unexpected reverts are not swallowed.

The handler predicts authorization from its own ownership/approval model and predicts duplicate
and revocation errors from its own ledger. It never reads production feedback records to choose
an outcome or obtain the score to subtract. Only successful expected operations update the model.
An additional invariant compares the authorization model with actual identity state.

For every touched agent, the accounting invariant independently recomputes totals from submitted
scores and revocation flags, then verifies:

- `summary.count == ghostGiven - ghostRevoked`;
- `summary.sum == sum of non-revoked ledger scores == ghostSum`;
- the average is the floor quotient, or zero for an empty summary;
- `feedbackCount == all ledger entries`, including revoked entries;
- each stored entry retains its submitted score and expected revocation flag.

Initial live, zero-score and revoked entries prevent vacuous success. A deterministic handler test
also forces duplicate/repeated-revoke failures, owner/approval/operator self-feedback, transfer,
former-authority feedback, a new agent, and invalid scores. The configured campaign is finite
(32 runs, depth 64 per invariant); this is not an exhaustive proof.

## Finding: additional validation URI restrictions (low)

`AgentValidationRegistry._checkURI`, line 151, rejects request and response URIs longer than 512
bytes. The assignment specifies this bound for identity and reputation only. The validation shape
does not impose it. Both otherwise-valid 513-byte validation calls fail with `InvalidURI(513)`.
This is an input-compatibility defect, not an unauthorized-write or fund-loss finding.

The structured report is in the explicitly requested root `.imd-findings.json`. Existing tests
that assert these extra validation caps were left untouched; no new passing test endorses them.
The following two success-expecting tests were executed in scratch and both failed. They are
provided here for reproduction, outside the passing regression suite, pending an implementation
fix. Save this block as `test/scratch/ValidationURIShape.t.sol` and run:

```sh
forge test --match-contract ValidationURIShapeReproduction --out test/scratch/out --cache-path test/scratch/cache -vv
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";

contract ValidationURIShapeReproduction is Test {
    AgentIdentityRegistry identity;
    AgentValidationRegistry validation;
    uint256 agent;

    function setUp() public {
        identity = new AgentIdentityRegistry();
        validation = new AgentValidationRegistry(address(identity));
        agent = identity.register("a");
    }

    function longURI() internal pure returns (string memory) {
        bytes memory uri = new bytes(513);
        for (uint256 i; i < uri.length; ++i) uri[i] = "a";
        return string(uri);
    }

    function test_RequestURIHasNoSpecifiedCap() public {
        bytes32 id = validation.requestValidation(agent, address(this), longURI(), bytes32(uint256(1)));
        assertEq(validation.request(id).requestURI, longURI());
    }

    function test_ResponseURIHasNoSpecifiedCap() public {
        bytes32 id = validation.requestValidation(agent, address(this), "", bytes32(uint256(1)));
        validation.submitResponse(id, 50, longURI(), bytes32(0));
        assertEq(validation.request(id).responseURI, longURI());
    }
}
```

## Review limits

Authorization and arithmetic use the supplied identity registry. Malicious replacements for that
immutable dependency, exhaustive upstream ERC-721 compliance, event-indexer integration and gas
ceilings were not tested. The pure `computeRequestId` helper computes a hash without reading agent
state; unknown-agent checks cover the state-reading endpoints. Source inspection found no owner,
admin, pause, upgrade or burn path. Ordinary ETH transfers are rejected; these tests do not claim
that contracts can prevent unsolicited forced ETH balances. Point-in-time authorization intentionally
allows former owners to rate after transfer and does not provide Sybil resistance.

## Local verification

Build artifacts and caches are placed in disposable scratch, with no configuration changes:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

Result: build succeeded; the full suite passed 128 tests with zero failures or skips, including
32 new independent checks. Both new invariants completed 32 runs of 64 calls with zero unexpected
reverts. Fuzz tests used the configured 256 runs. The two reported defect reproductions separately
failed with `InvalidURI(513)`, as documented above.

No new dependencies, network access, environment mutation, deployment or broadcasts are required.
