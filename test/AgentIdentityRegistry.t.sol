// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {IAgentIdentityRegistry} from "../src/IAgentIdentityRegistry.sol";

contract Receiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AgentIdentityRegistryTest is Test {
    AgentIdentityRegistry internal identity;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal approved = makeAddr("approved");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    string internal constant URI1 = "ipfs://agent-1";
    string internal constant URI2 = "https://example.com/agent.json";

    function setUp() public {
        identity = new AgentIdentityRegistry();
    }

    // ---------------------------------------------------------------- metadata

    function test_NameSymbolAndInterfaces() public view {
        assertEq(identity.name(), "Agent Identity");
        assertEq(identity.symbol(), "AGENT");
        assertTrue(identity.supportsInterface(type(IERC721).interfaceId));
        assertTrue(identity.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(identity.supportsInterface(type(IERC165).interfaceId));
        assertTrue(identity.supportsInterface(type(IAgentIdentityRegistry).interfaceId));
        assertFalse(identity.supportsInterface(0xffffffff));
        assertEq(identity.totalAgents(), 0);
    }

    // ---------------------------------------------------------------- register

    function test_Register_MintsSequentialIdsFromOne() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(identity));
        emit IAgentIdentityRegistry.Registered(1, alice, URI1);
        uint256 id1 = identity.register(URI1);

        vm.prank(bob);
        uint256 id2 = identity.register(URI2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(identity.ownerOf(1), alice);
        assertEq(identity.ownerOf(2), bob);
        assertEq(identity.tokenURI(1), URI1);
        assertEq(identity.tokenURI(2), URI2);
        assertEq(identity.balanceOf(alice), 1);
        assertEq(identity.totalAgents(), 2);
    }

    function test_Register_SameAddressCanRegisterManyAgents() public {
        vm.startPrank(alice);
        identity.register(URI1);
        identity.register(URI2);
        vm.stopPrank();
        assertEq(identity.balanceOf(alice), 2);
        assertEq(identity.ownerOf(2), alice);
    }

    function test_Register_AcceptsMaxLengthURI() public {
        string memory uri = _uriOfLength(512);
        vm.prank(alice);
        uint256 id = identity.register(uri);
        assertEq(bytes(identity.tokenURI(id)).length, 512);
    }

    function test_Register_RevertsOnEmptyURI() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, 0));
        identity.register("");
    }

    function test_Register_RevertsOnOversizedURI() public {
        string memory uri = _uriOfLength(513);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, 513));
        identity.register(uri);
    }

    function test_Register_ContractWithoutReceiverCanRegister() public {
        // The registry uses _mint on purpose: the caller chose to register, so no hook is required.
        NoReceiver caller = new NoReceiver(identity);
        uint256 id = caller.go(URI1);
        assertEq(identity.ownerOf(id), address(caller));
    }

    // ---------------------------------------------------------------- setAgentURI

    function test_SetAgentURI_ByOwner() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(identity));
        emit IAgentIdentityRegistry.AgentURIUpdated(id, URI2);
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI2);
    }

    function test_SetAgentURI_ByApproved() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        identity.approve(approved, id);
        vm.prank(approved);
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI2);
    }

    function test_SetAgentURI_ByOperator() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        identity.setApprovalForAll(operator, true);
        vm.prank(operator);
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI2);
    }

    function test_SetAgentURI_RevertsForStranger() public {
        uint256 id = _register(alice, URI1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, stranger));
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI1);
    }

    function test_SetAgentURI_RevertsForApprovedOfOtherToken() public {
        uint256 id1 = _register(alice, URI1);
        uint256 id2 = _register(alice, URI2);
        vm.prank(alice);
        identity.approve(approved, id1);
        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id2, approved));
        identity.setAgentURI(id2, URI1);
    }

    function test_SetAgentURI_RevertsAfterApprovalRevoked() public {
        uint256 id = _register(alice, URI1);
        vm.startPrank(alice);
        identity.approve(approved, id);
        identity.approve(address(0), id);
        identity.setApprovalForAll(operator, true);
        identity.setApprovalForAll(operator, false);
        vm.stopPrank();

        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, approved));
        identity.setAgentURI(id, URI2);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, operator));
        identity.setAgentURI(id, URI2);
    }

    function test_SetAgentURI_RevertsOnUnregisteredId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        identity.setAgentURI(7, URI2);
    }

    function test_SetAgentURI_RevertsOnEmptyOrOversizedURI() public {
        uint256 id = _register(alice, URI1);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, 0));
        identity.setAgentURI(id, "");
        string memory big = _uriOfLength(513);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.InvalidAgentURI.selector, 513));
        identity.setAgentURI(id, big);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- transfers: identity follows the token

    function test_TransferFrom_NewOwnerControls_OldOwnerAndApprovedDoNot() public {
        uint256 id = _register(alice, URI1);
        vm.startPrank(alice);
        identity.approve(approved, id);
        identity.transferFrom(alice, bob, id);
        vm.stopPrank();

        _assertControlMovedTo(id, bob);
    }

    function test_SafeTransferFrom_NewOwnerControls_OldOwnerAndApprovedDoNot() public {
        uint256 id = _register(alice, URI1);
        vm.startPrank(alice);
        identity.approve(approved, id);
        identity.safeTransferFrom(alice, bob, id);
        vm.stopPrank();

        _assertControlMovedTo(id, bob);
    }

    function test_SafeTransferFrom_ToContractReceiver() public {
        uint256 id = _register(alice, URI1);
        Receiver receiver = new Receiver();
        vm.prank(alice);
        identity.safeTransferFrom(alice, address(receiver), id, "");
        assertEq(identity.ownerOf(id), address(receiver));
        assertTrue(identity.isAuthorized(id, address(receiver)));
        assertFalse(identity.isAuthorized(id, alice));
    }

    function test_Transfer_OldOwnersOperatorLosesControlOfTransferredToken() public {
        uint256 id = _register(alice, URI1);
        vm.startPrank(alice);
        identity.setApprovalForAll(operator, true);
        identity.transferFrom(alice, bob, id);
        vm.stopPrank();

        // Operator approval is per-owner, and alice no longer owns the token.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, operator));
        identity.setAgentURI(id, URI2);
        assertFalse(identity.isAuthorized(id, operator));
    }

    function test_Transfer_NewOwnersExistingOperatorGainsControl() public {
        uint256 id = _register(alice, URI1);
        vm.prank(bob);
        identity.setApprovalForAll(operator, true);
        vm.prank(alice);
        identity.transferFrom(alice, bob, id);

        vm.prank(operator);
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI2);
    }

    function test_Transfer_ByApprovedMovesControl() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        identity.approve(approved, id);
        vm.prank(approved);
        identity.transferFrom(alice, bob, id);
        _assertControlMovedTo(id, bob);
    }

    function test_Transfer_URIIsPreserved() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        identity.transferFrom(alice, bob, id);
        assertEq(identity.tokenURI(id), URI1);
    }

    // ---------------------------------------------------------------- reads on unknown ids revert

    function test_Reads_RevertOnUnregisteredId() public {
        _register(alice, URI1);
        bytes memory err = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2);
        vm.expectRevert(err);
        identity.tokenURI(2);
        vm.expectRevert(err);
        identity.ownerOf(2);
        vm.expectRevert(err);
        identity.isAuthorized(2, alice);
        vm.expectRevert(err);
        identity.getApproved(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        identity.tokenURI(0);
    }

    function test_IsAuthorized_ZeroAddressNeverAuthorized() public {
        uint256 id = _register(alice, URI1);
        assertFalse(identity.isAuthorized(id, address(0)));
        assertTrue(identity.isAuthorized(id, alice));
        assertFalse(identity.isAuthorized(id, stranger));
    }

    // ---------------------------------------------------------------- no burn / no admin surface

    function test_NoBurnFunctionExposed() public {
        uint256 id = _register(alice, URI1);
        vm.prank(alice);
        (bool ok,) = address(identity).call(abi.encodeWithSignature("burn(uint256)", id));
        assertFalse(ok);
        assertEq(identity.ownerOf(id), alice);
    }

    function test_NoOwnerOrPauseSurface() public {
        (bool ok,) = address(identity).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(identity).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(identity).call(abi.encodeWithSignature("paused()"));
        assertFalse(ok);
    }

    function test_RejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(identity).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(identity).balance, 0);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_Register_AnyValidURI(bytes calldata raw) public {
        vm.assume(raw.length > 0 && raw.length <= 512);
        vm.prank(alice);
        uint256 id = identity.register(string(raw));
        assertEq(bytes(identity.tokenURI(id)), raw);
    }

    function testFuzz_SetAgentURI_OnlyAuthorized(address caller) public {
        vm.assume(caller != alice && caller != address(0));
        uint256 id = _register(alice, URI1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, caller));
        identity.setAgentURI(id, URI2);
    }

    // ---------------------------------------------------------------- helpers

    function _register(address who, string memory uri) internal returns (uint256 id) {
        vm.prank(who);
        id = identity.register(uri);
    }

    function _assertControlMovedTo(uint256 id, address newOwner) internal {
        assertEq(identity.ownerOf(id), newOwner);
        assertEq(identity.getApproved(id), address(0), "per-token approval must clear on transfer");
        assertTrue(identity.isAuthorized(id, newOwner));
        assertFalse(identity.isAuthorized(id, alice));
        assertFalse(identity.isAuthorized(id, approved));

        vm.prank(newOwner);
        identity.setAgentURI(id, URI2);
        assertEq(identity.tokenURI(id), URI2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, alice));
        identity.setAgentURI(id, URI1);

        vm.prank(approved);
        vm.expectRevert(abi.encodeWithSelector(IAgentIdentityRegistry.NotAuthorized.selector, id, approved));
        identity.setAgentURI(id, URI1);

        // The old owner can no longer approve anyone for the token either.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, alice));
        identity.approve(stranger, id);
    }

    function _uriOfLength(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = "a";
        }
        return string(b);
    }
}

contract NoReceiver {
    AgentIdentityRegistry internal immutable identity;

    constructor(AgentIdentityRegistry identity_) {
        identity = identity_;
    }

    function go(string calldata uri) external returns (uint256) {
        return identity.register(uri);
    }
}
