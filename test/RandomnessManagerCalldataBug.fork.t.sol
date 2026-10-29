// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RandomnessManager calldata-encoding bug - Base mainnet fork reproducer
 *
 * @notice Reproduces the bug that has kept NoLossLotteryV3 weekly round 1 stuck
 *         since 2026-05-14. Tests run only when FORK_URL is set to a Base mainnet
 *         RPC; otherwise they short-circuit (so CI without RPC access still passes).
 *
 *         The bug:
 *           RandomnessManagerV2._fireVRF builds the coordinator call as
 *               abi.encodeWithSignature(
 *                   "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))",
 *                   keyHash, subscriptionId, ..., extraArgs
 *               )
 *           Solidity's `abi.encodeWithSignature` does NOT auto-wrap separate args
 *           into the declared tuple - it encodes them flat. The coordinator's
 *           ABI decoder then reads `keyHash` as the struct offset, jumps to a
 *           garbage location in calldata, and reverts immediately at ~295 gas.
 *
 *         What this test proves:
 *           1. The flat-args calldata (the pattern RM uses today) reverts.
 *           2. A properly tuple-wrapped calldata succeeds against the same coordinator
 *              and same subscription, with the same RM as msg.sender.
 *
 *         Together those two assertions establish that the issue is encoding,
 *         not gas, not subscription state, not consumer registration. The fix
 *         is a one-line change in the source.
 *
 *         Run with:
 *           FORK_URL=https://mainnet.base.org forge test \
 *               --match-path test/RandomnessManagerCalldataBug.fork.t.sol -vvv
 *
 *         Pin a block for determinism (state changes won't shift the result -
 *         this is purely about calldata decoding at the coordinator):
 *           FORK_URL=https://mainnet.base.org FORK_BLOCK=46172000 forge test ...
 */

import "forge-std/Test.sol";

contract RandomnessManagerCalldataBugTest is Test {
    // -- On-chain references -------------------------------------------------
    address constant COORD = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634; // Base mainnet VRF V2.5
    address constant RM    = 0x9C420Dd94F30Ebd1C62eCb946120274CdaeA40D2; // deployed RandomnessManagerV2

    // From RM state (verified via `cast call` against the deployed RM)
    uint256 constant SUB_ID = 98397291530899779103573314778875781854807528402738620777254440293959725029875;
    bytes32 constant KEY_HASH = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;
    uint16  constant CONFS = 3;
    uint32  constant CB_GAS = 200_000;
    uint32  constant NUM_WORDS = 1;

    // Standard Chainlink VRF V2.5 ExtraArgsV1 - same constant RM uses internally.
    bytes4  constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    // Local re-declaration of Chainlink's RandomWordsRequest tuple so we can
    // produce the correct tuple-wrapped calldata without importing the SDK.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16  requestConfirmations;
        uint32  callbackGasLimit;
        uint32  numWords;
        bytes   extraArgs;
    }

    bool internal hasFork;

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;

        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock != 0) {
            vm.createSelectFork(url, forkBlock);
        } else {
            vm.createSelectFork(url);
        }

        if (block.chainid != 8453) return; // only meaningful on Base mainnet
        hasFork = true;
    }

    // --------------------------------------------------------------------------
    // The bug: flat-args calldata reverts at the coordinator
    // --------------------------------------------------------------------------

    function test_FlatArgsEncodingRevertsAtCoordinator() public {
        if (!hasFork) {
            emit log("FORK_URL not set or not Base mainnet - skipping");
            return;
        }

        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

        // Exact pattern from RandomnessManagerV2._fireVRF - args passed flat to
        // abi.encodeWithSignature, which does NOT wrap them in the declared tuple.
        bytes memory flatCalldata = abi.encodeWithSignature(
            "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))",
            KEY_HASH,
            SUB_ID,
            CONFS,
            CB_GAS,
            NUM_WORDS,
            extraArgs
        );

        vm.prank(RM); // coordinator's consumer check looks up msg.sender -> must be RM
        (bool success, ) = COORD.call(flatCalldata);

        assertFalse(success, "BUG REPRODUCED: flat-args calldata is accepted by coordinator (unexpected - was this fixed?)");
    }

    // --------------------------------------------------------------------------
    // The fix: tuple-wrapped calldata succeeds
    // --------------------------------------------------------------------------

    function test_TupleWrappedEncodingSucceedsAtCoordinator() public {
        if (!hasFork) {
            emit log("FORK_URL not set or not Base mainnet - skipping");
            return;
        }

        bytes memory extraArgs = abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, false);

        RandomWordsRequest memory req = RandomWordsRequest({
            keyHash:              KEY_HASH,
            subId:                SUB_ID,
            requestConfirmations: CONFS,
            callbackGasLimit:     CB_GAS,
            numWords:             NUM_WORDS,
            extraArgs:            extraArgs
        });

        // abi.encodeWithSelector + a struct value DOES produce the correct
        // tuple-wrapped encoding (with the 0x20 offset prefix).
        bytes memory tupleCalldata = abi.encodeWithSelector(
            bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))")),
            req
        );

        vm.prank(RM);
        (bool success, bytes memory returnData) = COORD.call(tupleCalldata);

        assertTrue(success, "Tuple-wrapped calldata unexpectedly failed (regression in coordinator?)");
        assertGe(returnData.length, 32, "coordinator should return uint256 vrfRequestId");

        uint256 vrfRequestId = abi.decode(returnData, (uint256));
        assertGt(vrfRequestId, 0, "vrfRequestId should be non-zero");
        emit log_named_uint("coordinator returned vrfRequestId", vrfRequestId);
    }

    // --------------------------------------------------------------------------
    // Sanity assertions on the on-chain state that frames this bug
    // --------------------------------------------------------------------------

    function test_OnChainStateSanity() public {
        if (!hasFork) return;

        // 1. RM at this address responds to V2-only signatures and not V1's manualFulfill.
        //    (V1 had `MANUAL_FULFILL_DELAY`; V2 removed both that constant and `manualFulfill`.)
        (bool okMfd, ) = RM.staticcall(abi.encodeWithSignature("MANUAL_FULFILL_DELAY()"));
        assertFalse(okMfd, "MANUAL_FULFILL_DELAY should not exist on V2");

        (bool okVrft, bytes memory vrftRet) = RM.staticcall(abi.encodeWithSignature("VRF_TIMEOUT()"));
        assertTrue(okVrft, "VRF_TIMEOUT() should respond");
        assertEq(abi.decode(vrftRet, (uint256)), 2 hours, "VRF_TIMEOUT should be 2h");

        // 2. RM is registered as a consumer on the subscription and the sub is funded
        //    with LINK - so the failures we see at the coordinator are NOT a balance
        //    or consumer-registration issue.
        (bool okSub, bytes memory subRet) = COORD.staticcall(
            abi.encodeWithSignature("getSubscription(uint256)", SUB_ID)
        );
        assertTrue(okSub, "getSubscription should respond");
        (uint96 linkBalance, /*native*/, /*reqCount*/, /*owner*/, address[] memory consumers) =
            abi.decode(subRet, (uint96, uint96, uint64, address, address[]));
        assertGt(linkBalance, 0, "subscription should have LINK funding");
        bool rmIsConsumer = false;
        for (uint256 i = 0; i < consumers.length; i++) {
            if (consumers[i] == RM) { rmIsConsumer = true; break; }
        }
        assertTrue(rmIsConsumer, "RM should be a registered consumer on the sub");
    }
}
