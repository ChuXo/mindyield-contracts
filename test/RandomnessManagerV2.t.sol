// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RandomnessManagerV2.sol";

/// @notice Mock requester that records callbacks. Mirrors GoodRequester
///         from RandomnessManager.edge.t.sol but binds to V2.
contract V2GoodRequester {
    RandomnessManagerV2 public rm;
    uint256 public lastRandomWord;
    bool    public callbackReceived;

    constructor(address _rm) { rm = RandomnessManagerV2(_rm); }

    function requestRandomness(bytes32 contestId) external returns (uint256) {
        return rm.requestRandomness(contestId);
    }

    function fulfillRandomness(uint256 randomWord) external {
        lastRandomWord = randomWord;
        callbackReceived = true;
    }
}

contract RandomnessManagerV2Test is Test {
    // Mirror events from RandomnessManagerV2 so vm.expectEmit can match them.
    event VRFRequestSent(uint256 indexed internalId, uint256 indexed vrfRequestId);
    event VRFRequestFailed(uint256 indexed internalId, bytes32 indexed contestId);
    event VRFRequestRetried(uint256 indexed internalId, uint256 indexed vrfRequestId, uint256 attempt);
    event CallbackFailed(uint256 indexed requestId, bytes32 indexed contestId, bytes reason);

    RandomnessManagerV2 rm;
    V2GoodRequester     requester;

    address owner          = address(1);
    address vrfCoordinator = address(2);
    address anyone         = address(99);

    bytes32 constant KEY_HASH = keccak256("test-key-hash");
    uint256 constant SUB_ID   = 1;
    bytes32 constant CONTEST_1 = keccak256("contest-1");

    /// Selector used by the RM to call the coordinator. Mocking targets this exact signature.
    bytes constant COORDINATOR_SELECTOR_V25 = abi.encodeWithSignature(
        "requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"
    );

    function setUp() public {
        vm.startPrank(owner);
        rm = new RandomnessManagerV2(vrfCoordinator, KEY_HASH, SUB_ID);
        requester = new V2GoodRequester(address(rm));
        rm.addAllowedRequester(address(requester));
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    /// @dev Mock the coordinator to *succeed* with a given vrfRequestId. Note
    ///      that mockCall matches by the calldata prefix (function selector +
    ///      partial args); we mock on selector alone so any args match.
    function _mockVRFSuccess(uint256 vrfRequestId) internal {
        vm.mockCall(
            vrfCoordinator,
            abi.encodeWithSignature("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"),
            abi.encode(vrfRequestId)
        );
    }

    /// @dev Mock the coordinator to *revert*, simulating a sub-out-of-LINK or
    ///      similar coordinator-side rejection. The RM swallows the revert
    ///      via low-level `.call` and emits `VRFRequestFailed`.
    function _mockVRFRevert() internal {
        vm.mockCallRevert(
            vrfCoordinator,
            abi.encodeWithSignature("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"),
            "InsufficientBalance()"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Initial request
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initialRequest_emitsVRFRequestSent_onSuccess() public {
        _mockVRFSuccess(42);
        vm.expectEmit(true, true, false, false, address(rm));
        emit VRFRequestSent(1, 42);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);
        assertEq(rm.vrfToInternalId(42), 1);
    }

    function test_initialRequest_emitsVRFRequestFailed_onCoordinatorRevert() public {
        _mockVRFRevert();
        vm.expectEmit(true, true, false, false, address(rm));
        emit VRFRequestFailed(1, CONTEST_1);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);
        // Internal request exists but no vrfToInternalId mapping for any vrfRequestId
        (, , , bool fulfilled, bool exists, ) = rm.requests(1);
        assertTrue(exists);
        assertFalse(fulfilled);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  retryRequest
    // ═══════════════════════════════════════════════════════════════════════════

    function test_retryRequest_revertsBeforeTimeout() public {
        _mockVRFRevert();
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        vm.warp(block.timestamp + 1 hours); // < VRF_TIMEOUT (2h)
        vm.expectRevert(RandomnessManagerV2.RequestStillFresh.selector);
        rm.retryRequest(CONTEST_1);
    }

    function test_retryRequest_revertsForUnknownContest() public {
        vm.expectRevert(RandomnessManagerV2.RequestNotFound.selector);
        rm.retryRequest(keccak256("nonexistent"));
    }

    function test_retryRequest_succeedsAfterTimeout_resumesAfterCoordinatorRevert() public {
        _mockVRFRevert();
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        // Coordinator was rejecting — now sub is funded, accepts.
        vm.warp(block.timestamp + 2 hours);
        _mockVRFSuccess(7777);

        vm.expectEmit(true, true, false, true, address(rm));
        emit VRFRequestRetried(1, 7777, 1);
        vm.prank(anyone); // PERMISSIONLESS
        rm.retryRequest(CONTEST_1);

        assertEq(rm.vrfToInternalId(7777), 1);
        assertEq(rm.retryCount(CONTEST_1), 1);
    }

    function test_retryRequest_revertsAfterMaxRetries() public {
        _mockVRFRevert();
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        // Track timestamp explicitly — `vm.warp(block.timestamp + …)` inside a
        // tight loop hits a Foundry-cached-timestamp quirk where the second
        // read of `block.timestamp` doesn't reflect the warp until after the
        // next external call. Use an explicit ts variable instead.
        uint256 ts = block.timestamp;
        for (uint256 i = 1; i <= 5; i++) {
            ts += 2 hours + 1;
            vm.warp(ts);
            vm.prank(anyone);
            rm.retryRequest(CONTEST_1);
        }

        // 6th retry must revert with MaxRetriesExceeded.
        ts += 2 hours + 1;
        vm.warp(ts);
        vm.expectRevert(RandomnessManagerV2.MaxRetriesExceeded.selector);
        rm.retryRequest(CONTEST_1);
    }

    function test_retryRequest_eventualSuccessLandsRandomWord() public {
        // Original coordinator call succeeds, VRF stalls.
        _mockVRFSuccess(100);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        // After VRF_TIMEOUT, retry. Coordinator gives a NEW vrfRequestId.
        vm.warp(block.timestamp + 2 hours);
        _mockVRFSuccess(101);
        vm.prank(anyone);
        rm.retryRequest(CONTEST_1);

        // VRF (eventually) responds to the RETRY's request with a random word.
        uint256[] memory words = new uint256[](1);
        words[0] = 0xDEADBEEF;
        vm.prank(vrfCoordinator);
        rm.rawFulfillRandomWords(101, words);

        assertEq(rm.getRandomWord(CONTEST_1), 0xDEADBEEF);
        assertEq(requester.lastRandomWord(), 0xDEADBEEF);
        assertTrue(requester.callbackReceived());
    }

    function test_retryRequest_lateOriginalCallback_isBenign() public {
        // Original succeeds (vrfId=100), retry succeeds (vrfId=101).
        _mockVRFSuccess(100);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        vm.warp(block.timestamp + 2 hours);
        _mockVRFSuccess(101);
        vm.prank(anyone);
        rm.retryRequest(CONTEST_1);

        // Retry's VRF lands FIRST.
        uint256[] memory wordsRetry = new uint256[](1);
        wordsRetry[0] = 7;
        vm.prank(vrfCoordinator);
        rm.rawFulfillRandomWords(101, wordsRetry);
        assertEq(requester.lastRandomWord(), 7);

        // Original VRF lands LATER. Should emit CallbackFailed but NOT revert
        // (so the coordinator doesn't log a consumer-revert).
        uint256[] memory wordsOriginal = new uint256[](1);
        wordsOriginal[0] = 99;
        vm.expectEmit(true, true, false, false, address(rm));
        emit CallbackFailed(1, CONTEST_1, "");
        vm.prank(vrfCoordinator);
        rm.rawFulfillRandomWords(100, wordsOriginal);

        // Random word in storage is still the FIRST one (7), not overwritten.
        assertEq(requester.lastRandomWord(), 7);
    }

    function test_retryRequest_revertsWhenAlreadyFulfilled() public {
        _mockVRFSuccess(50);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        // Fulfill via VRF callback.
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(vrfCoordinator);
        rm.rawFulfillRandomWords(50, words);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(RandomnessManagerV2.AlreadyFulfilled.selector);
        rm.retryRequest(CONTEST_1);
    }

    function test_retryRequest_revertsIfSubscriptionZero() public {
        // Deploy a separate RM with sub=0 (anvil-mode).
        vm.prank(owner);
        RandomnessManagerV2 rmNoSub = new RandomnessManagerV2(vrfCoordinator, KEY_HASH, 0);
        vm.prank(owner);
        rmNoSub.addAllowedRequester(address(this));

        rmNoSub.requestRandomness(CONTEST_1);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(RandomnessManagerV2.SubscriptionMissing.selector);
        rmNoSub.retryRequest(CONTEST_1);
    }

    /// @dev Stub: this contract is the requester for the sub=0 test, so it
    ///      needs a fulfillRandomness shape too.
    function fulfillRandomness(uint256) external {}

    // ═══════════════════════════════════════════════════════════════════════════
    //  manualFulfill is gone — verify nobody can call it
    // ═══════════════════════════════════════════════════════════════════════════

    function test_manualFulfill_doesNotExist() public {
        // Encoding the V1 selector into a low-level call against the V2 contract
        // should hit the fallback (or revert) — not execute manualFulfill.
        bytes memory data = abi.encodeWithSignature("manualFulfill(uint256,uint256)", 1, 42);
        (bool success, ) = address(rm).call(data);
        assertFalse(success); // selector not in V2's dispatcher → revert
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  resetFailedRequest still works for requester (legacy)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_resetFailedRequest_byRequester_clearsSlot() public {
        _mockVRFRevert();
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(requester));
        rm.resetFailedRequest(CONTEST_1);

        // Slot is cleared — a new request for the same contestId works.
        _mockVRFSuccess(900);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);
        assertEq(rm.vrfToInternalId(900), 2); // new internal id
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Finding 2 — reset escape hatch is NOT blocked by exhausted retries
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Regression: previously `resetFailedRequest` shared `retryCount` with
    ///      `retryRequest` and reverted once retries were exhausted, permanently
    ///      bricking the contestId (NoLossLottery.cancelDraw could never clear the
    ///      RM slot → every future performUpkeep reverted RequestAlreadyExists).
    ///      The reset hatch must always work when the request is genuinely failed,
    ///      and must zero the retry budget so a fresh request can retry again.
    function test_resetFailedRequest_worksEvenAfterMaxRetries() public {
        _mockVRFRevert();
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);

        // Exhaust all 5 retries while the coordinator keeps failing.
        uint256 ts = block.timestamp;
        for (uint256 i = 1; i <= 5; i++) {
            ts += 2 hours + 1;
            vm.warp(ts);
            vm.prank(anyone);
            rm.retryRequest(CONTEST_1);
        }
        assertEq(rm.retryCount(CONTEST_1), 5);

        // retryRequest is now blocked...
        ts += 2 hours + 1;
        vm.warp(ts);
        vm.expectRevert(RandomnessManagerV2.MaxRetriesExceeded.selector);
        rm.retryRequest(CONTEST_1);

        // ...but the requester's reset escape hatch STILL works.
        vm.prank(address(requester));
        rm.resetFailedRequest(CONTEST_1);

        // Slot cleared AND retry budget reset to 0.
        assertEq(rm.retryCount(CONTEST_1), 0);
        (, , , , bool exists, ) = rm.requests(1);
        assertFalse(exists);

        // A fresh request for the same contestId works again.
        _mockVRFSuccess(123);
        vm.prank(address(requester));
        rm.requestRandomness(CONTEST_1);
        assertEq(rm.vrfToInternalId(123), 2);
    }
}
