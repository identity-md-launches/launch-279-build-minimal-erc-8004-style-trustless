// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentReputationRegistry} from "../../src/AgentReputationRegistry.sol";
import {AgentValidationRegistry} from "../../src/AgentValidationRegistry.sol";

/// @dev Fresh deployments; no inheritance from the implementation contributor's tests.
abstract contract RegistryFixture is Test {
    AgentIdentityRegistry internal identity;
    AgentReputationRegistry internal reputation;
    AgentValidationRegistry internal validation;

    address internal constant OWNER = address(0xA11CE);
    address internal constant NEXT_OWNER = address(0xB0B);
    address internal constant APPROVED = address(0xA990);
    address internal constant OPERATOR = address(0x0900);
    address internal constant CLIENT = address(0xC11E);
    address internal constant CLIENT_TWO = address(0xC122);
    address internal constant VALIDATOR = address(0xDA7A);
    bytes32 internal constant JOB = keccak256("independent job");
    bytes32 internal constant HASH = keccak256("independent evidence");

    uint256 internal agent;
    uint256 internal otherAgent;

    function setUp() public virtual {
        identity = new AgentIdentityRegistry();
        reputation = new AgentReputationRegistry(address(identity));
        validation = new AgentValidationRegistry(address(identity));
        vm.prank(OWNER);
        agent = identity.register("ipfs://first");
        vm.prank(NEXT_OWNER);
        otherAgent = identity.register("ipfs://second");
    }

    function _give(address client, uint256 id, bytes32 job, uint8 score) internal {
        vm.prank(client);
        reputation.giveFeedback(id, job, score, 0, 0, "", 0);
    }

    function _summary(uint256 id, uint256 expectedCount, uint256 expectedSum) internal view {
        (uint256 count, uint256 sum, uint256 average) = reputation.summary(id);
        assertEq(count, expectedCount, "live count");
        assertEq(sum, expectedSum, "live sum");
        assertEq(average, expectedCount == 0 ? 0 : expectedSum / expectedCount, "floor average");
    }

    function _grant() internal {
        vm.startPrank(OWNER);
        identity.approve(APPROVED, agent);
        identity.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
    }

    function _text(uint256 length) internal pure returns (string memory) {
        bytes memory raw = new bytes(length);
        for (uint256 i; i < length; ++i) {
            raw[i] = "a";
        }
        return string(raw);
    }
}
