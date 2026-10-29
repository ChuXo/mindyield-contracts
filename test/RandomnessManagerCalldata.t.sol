// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Non-fork regression test for the RM calldata-encoding bug.
 *
 * @dev Pair with `RandomnessManagerCalldataBug.fork.t.sol` (which proves the
 *      bug against the real Base mainnet coordinator). This file uses a strict
 *      mock that mirrors the V2.5 signature exactly, so the bug is also
 *      catchable in CI without an RPC.
 *
 *      What we assert:
 *        - The (patched) _fireVRF path successfully invokes the mock
 *          coordinator and increments its request counter.
 *        - The mock's RandomWordsRequested event carries the same fields RM
 *          passed in (keyHash, subId, msg.sender, etc.), so an arity mismatch
 *          in `abi.encodeWithSignature` would be caught here.
 *        - As a belt-and-suspenders check, a hand-crafted FLAT-args calldata
 *          (the buggy pattern) is shown to revert at the mock — same way it
 *          reverts at the real coordinator.
 */

import "forge-std/Test.sol";
import "../src/RandomnessManagerV2.sol";
import "../src/mocks/MockVRFCoordinator.sol";

contract RandomnessManagerCalldataTest is Test {
    MockVRFCoordinator coord;
    RandomnessManagerV2 rm;

    // Dummy keyHash + subId — never reaches Chainlink in this test, just has to be non-zero.
    bytes32 constant KEY_HASH = keccak256("test-key-hash");
    uint256 constant SUB_ID = 12345;

    address constant LOTTERY = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        coord = new MockVRFCoordinator();
        rm = new RandomnessManagerV2(
            address(coord),
            KEY_HASH,
            SUB_ID
        );
        coord.setRandomnessManager(address(rm));
        // Authorize the lottery as a requester so requestRandomness() doesn't revert.
        rm.addAllowedRequester(LOTTERY);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // (1) The patched _fireVRF correctly invokes the strict V2.5 mock.
    //     Before the fix, this would silently emit VRFRequestFailed.
    //     After the fix, the coordinator increments its counter + emits
    //     RandomWordsRequested with the right msg.sender.
    // ──────────────────────────────────────────────────────────────────────────

    function test_PatchedFireVRFReachesCoordinator() public {
        vm.recordLogs();
        vm.prank(LOTTERY);
        rm.requestRandomness(keccak256("contestA"));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawRandomWordsRequested;
        for (uint256 i = 0; i < logs.length; i++) {
            // sig of RandomWordsRequested(bytes32 indexed,uint256 indexed,address indexed,uint256,uint16,uint32,uint32,bytes)
            if (logs[i].emitter == address(coord)) {
                sawRandomWordsRequested = true;
                // Indexed args: keyHash, subId, requester
                assertEq(logs[i].topics[1], KEY_HASH, "keyHash mismatch");
                assertEq(uint256(logs[i].topics[2]), SUB_ID, "subId mismatch");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(rm), "requester should be RM (not lottery)");
            }
        }
        assertTrue(sawRandomWordsRequested, "Coordinator should emit RandomWordsRequested after fixed _fireVRF");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // (2) Belt-and-suspenders: the OLD flat-args encoding reverts at the strict
    //     mock too. If anyone ever reintroduces `abi.encodeWithSignature(...)`
    //     with spread args, this test catches it without needing a fork.
    // ──────────────────────────────────────────────────────────────────────────

    function test_FlatArgsEncodingRevertsAtStrictMock() public {
        bytes4 EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));
        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

        // Buggy pattern: separate args, no struct wrap.
        bytes memory flatCalldata = abi.encodeWithSignature(
            "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))",
            KEY_HASH,
            SUB_ID,
            uint16(3),
            uint32(200_000),
            uint32(1),
            extraArgs
        );

        (bool success, ) = address(coord).call(flatCalldata);
        assertFalse(success, "Strict V2.5 mock must reject flat-args calldata");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // (3) The patched calldata is acceptable in isolation too — equivalent to
    //     what _fireVRF now emits internally.
    // ──────────────────────────────────────────────────────────────────────────

    function test_TupleEncodingAcceptedAtStrictMock() public {
        bytes4 EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));
        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

        MockVRFCoordinator.RandomWordsRequest memory req = MockVRFCoordinator.RandomWordsRequest({
            keyHash:              KEY_HASH,
            subId:                SUB_ID,
            requestConfirmations: 3,
            callbackGasLimit:     200_000,
            numWords:             1,
            extraArgs:            extraArgs
        });

        uint256 requestId = coord.requestRandomWords(req);
        assertGt(requestId, 0, "Mock should return non-zero requestId");
    }
}
