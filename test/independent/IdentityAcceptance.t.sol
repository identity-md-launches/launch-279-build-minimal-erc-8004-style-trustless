// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryFixture} from "./RegistryFixture.sol";
import {IAgentIdentityRegistry} from "../../src/IAgentIdentityRegistry.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract IndependentIdentityAcceptanceTest is RegistryFixture {
    function test_RegistrationSequenceMetadataAndEvent() public {
        assertEq(agent, 1);
        assertEq(otherAgent, 2);
        assertEq(identity.name(), "Agent Identity");
        assertEq(identity.symbol(), "AGENT");
        assertEq(identity.ownerOf(agent), OWNER);
        vm.expectEmit(true, true, false, true, address(identity));
        emit IAgentIdentityRegistry.Registered(3, CLIENT, "x");
        vm.prank(CLIENT);
        assertEq(identity.register("x"), 3);
        assertEq(identity.tokenURI(3), "x");
        assertEq(identity.totalAgents(), 3);
    }

    function test_TransferFromMovesAllControl() public {
        _transferAndCheck(0);
    }

    function test_SafeTransferFromMovesAllControl() public {
        _transferAndCheck(1);
    }

    function test_SafeTransferFromWithDataMovesAllControl() public {
        _transferAndCheck(2);
    }

    function _transferAndCheck(uint256 mode) internal {
        _grant();
        // Exercise all three pre-transfer authorities and URI event contents.
        address[3] memory authorities = [OWNER, APPROVED, OPERATOR];
        for (uint256 i; i < authorities.length; ++i) {
            vm.expectEmit(true, false, false, true, address(identity));
            emit IAgentIdentityRegistry.AgentURIUpdated(agent, "before");
            vm.prank(authorities[i]);
            identity.setAgentURI(agent, "before");
        }
        vm.prank(APPROVED);
        if (mode == 0) identity.transferFrom(OWNER, NEXT_OWNER, agent);
        else if (mode == 1) identity.safeTransferFrom(OWNER, NEXT_OWNER, agent);
        else identity.safeTransferFrom(OWNER, NEXT_OWNER, agent, hex"123456");

        assertEq(identity.ownerOf(agent), NEXT_OWNER);
        assertEq(identity.getApproved(agent), address(0));
        assertEq(identity.tokenURI(agent), "before");
        for (uint256 i; i < authorities.length; ++i) {
            assertFalse(identity.isAuthorized(agent, authorities[i]));
            vm.expectRevert(
                abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, agent, authorities[i])
            );
            vm.prank(authorities[i]);
            identity.setAgentURI(agent, "stale authority");
        }
        vm.prank(NEXT_OWNER);
        identity.setAgentURI(agent, "after");
        assertEq(identity.tokenURI(agent), "after");
        // New approvals must work, even if the same addresses were approved by the old owner.
        vm.startPrank(NEXT_OWNER);
        identity.approve(APPROVED, agent);
        identity.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        vm.prank(APPROVED);
        identity.setAgentURI(agent, "new approval");
        vm.prank(OPERATOR);
        identity.setAgentURI(agent, "new operator");
        assertEq(identity.tokenURI(agent), "new operator");
    }

    function test_ReceiverCallbackSeesNewOwnerAndClearedApproval() public {
        _grant();
        ControlCheckingReceiver receiver = new ControlCheckingReceiver(identity, reputation, validation, false);
        vm.prank(OPERATOR);
        identity.safeTransferFrom(OWNER, address(receiver), agent, hex"aabbcc");
        assertTrue(receiver.called());
        assertEq(receiver.dataHash(), keccak256(hex"aabbcc"));
        assertEq(identity.ownerOf(agent), address(receiver));
        assertEq(identity.tokenURI(agent), "callback URI");
        assertEq(validation.request(receiver.requestId()).requester, address(receiver));
        assertEq(reputation.feedbackCount(agent), 0);
    }

    function test_RejectingReceiverRollsBackCrossRegistryWritesAndApprovalClear() public {
        _grant();
        ControlCheckingReceiver receiver = new ControlCheckingReceiver(identity, reputation, validation, true);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        vm.prank(APPROVED);
        identity.safeTransferFrom(OWNER, address(receiver), agent);
        assertFalse(receiver.called());
        assertEq(identity.ownerOf(agent), OWNER);
        assertEq(identity.getApproved(agent), APPROVED);
        assertEq(identity.tokenURI(agent), "ipfs://first");
        assertEq(validation.requestCount(agent), 0);
        assertEq(reputation.feedbackCount(agent), 0);
        vm.prank(APPROVED);
        identity.setAgentURI(agent, "still approved");
    }

    function test_RevokingApprovalsImmediatelyRemovesURIControl() public {
        _grant();
        vm.startPrank(OWNER);
        identity.approve(address(0), agent);
        identity.setApprovalForAll(OPERATOR, false);
        vm.stopPrank();
        address[2] memory stale = [APPROVED, OPERATOR];
        for (uint256 i; i < stale.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, agent, stale[i]));
            vm.prank(stale[i]);
            identity.setAgentURI(agent, "forbidden");
        }
        assertEq(identity.tokenURI(agent), "ipfs://first");
    }

    function testFuzz_URIByteBoundariesAndFailedRegistrationDoesNotConsumeId(uint16 seed) public {
        uint256 length = uint256(seed) % 515;
        string memory uri = _text(length);
        bool valid = length > 0 && length <= 512;
        vm.startPrank(CLIENT);
        if (!valid) vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, length));
        uint256 id = identity.register(uri);
        if (valid) {
            assertEq(id, 3);
            assertEq(identity.tokenURI(id), uri);
        } else {
            assertEq(identity.register("retry"), 3);
        }
        vm.stopPrank();
        vm.prank(OWNER);
        if (!valid) vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, length));
        identity.setAgentURI(agent, uri);
        assertEq(identity.tokenURI(agent), valid ? uri : "ipfs://first");
    }

    function test_URILimitsCountUTF8Bytes() public {
        bytes memory utf8 = new bytes(512);
        for (uint256 i; i < 512; i += 2) {
            utf8[i] = 0xc3;
            utf8[i + 1] = 0xa9;
        }
        vm.prank(OWNER);
        identity.setAgentURI(agent, string(utf8));
        assertEq(bytes(identity.tokenURI(agent)), utf8);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, 514));
        vm.prank(OWNER);
        identity.setAgentURI(agent, string(bytes.concat(utf8, hex"c3a9")));
    }
}

/// @dev Uses the agent inside the ERC-721 hook; optionally rejects the completed transfer.
contract ControlCheckingReceiver is IERC721Receiver {
    AgentIdentityRegistry private immutable identity;
    AgentReputationRegistry private immutable reputation;
    AgentValidationRegistry private immutable validation;
    bool private immutable rejectTransfer;
    bool public called;
    bytes32 public requestId;
    bytes32 public dataHash;

    constructor(AgentIdentityRegistry i, AgentReputationRegistry r, AgentValidationRegistry v, bool reject_) {
        identity = i;
        reputation = r;
        validation = v;
        rejectTransfer = reject_;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata data) external returns (bytes4) {
        require(msg.sender == address(identity), "unexpected token");
        require(identity.ownerOf(id) == address(this), "ownership not moved before callback");
        require(identity.getApproved(id) == address(0), "approval not cleared before callback");
        require(!identity.isAuthorized(id, from), "old owner still authorized");
        identity.setAgentURI(id, "callback URI");
        requestId = validation.requestValidation(id, address(this), "", keccak256("callback request"));
        (bool ok, bytes memory reason) = address(reputation)
            .call(abi.encodeCall(reputation.giveFeedback, (id, bytes32(0), 50, bytes32(0), bytes32(0), "", bytes32(0))));
        require(!ok, "receiver self-rated");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(AgentReputationRegistry.SelfFeedback.selector, id, address(this))),
            "unexpected feedback rejection"
        );
        called = true;
        dataHash = keccak256(data);
        return rejectTransfer ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
}
