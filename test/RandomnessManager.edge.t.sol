// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RandomnessManager.sol";

/**
 * @title BadRequester
 * @notice Mock requester whose fulfillRandomness callback always reverts.
 *         Used to test that RandomnessManager correctly handles callback failures.
 */
contract BadRequester {
    RandomnessManager public rm;

    constructor(address _rm) {
        rm = RandomnessManager(_rm);
    }

    function requestRandomness(bytes32 contestId) external returns (uint256) {
        return rm.requestRandomness(contestId);
    }

    /// @notice Always reverts when called back by RandomnessManager.
    function fulfillRandomness(uint256) external pure {
        revert("BadRequester: callback failed intentionally");
    }
}

/**
 * @title GoodRequester
 * @notice Mock requester that stores the random word on callback.
 */
contract GoodRequester {
    RandomnessManager public rm;
    uint256 public lastRandomWord;
    bool public callbackReceived;

    constructor(address _rm) {
        rm = RandomnessManager(_rm);
    }

    function requestRandomness(bytes32 contestId) external returns (uint256) {
        return rm.requestRandomness(contestId);
    }

    /// @notice Stores the random word on successful callback.
    function fulfillRandomness(uint256 randomWord) external {
        lastRandomWord = randomWord;
        callbackReceived = true;
    }
}

/**
 * @title RandomnessManagerEdgeTest
 * @notice Edge case tests for RandomnessManager:
 *   - Callback failure behavior (fulfillRandomWords + manualFulfill)
 *   - Request not marked fulfilled after callback failure
 *   - Double fulfillment reverts with AlreadyFulfilled
 *   - Duplicate contestId reverts with RequestAlreadyExists
 *   - Access control: VRF coordinator, owner, allowedRequester, factory
 *   - transferOwnership
 *   - isRequestPending / isRequestFulfilled lifecycle
 */
contract RandomnessManagerEdgeTest is Test {

    // --- Contracts ---
    RandomnessManager rm;
    GoodRequester     goodRequester;
    BadRequester      badRequester;

    // --- Actors ---
    address owner         = address(1);
    address vrfCoordinator = address(2);
    address nobody        = address(3);
    address factory       = address(4);
    address newOwner      = address(5);

    // --- Config ---
    bytes32 constant KEY_HASH = keccak256("test-key-hash");
    uint256 constant SUB_ID   = 1;
    bytes32 constant CONTEST_1 = keccak256("contest-1");
    bytes32 constant CONTEST_2 = keccak256("contest-2");
    bytes32 constant CONTEST_3 = keccak256("contest-3");

    // --- setUp ---
    function setUp() public {
        vm.startPrank(owner);

        rm = new RandomnessManager(vrfCoordinator, KEY_HASH, SUB_ID);
        goodRequester = new GoodRequester(address(rm));
        badRequester  = new BadRequester(address(rm));

        // Authorize both requesters
        rm.addAllowedRequester(address(goodRequester));
        rm.addAllowedRequester(address(badRequester));

        vm.stopPrank();
    }

    // =========================================================================
    // Callback failure: fulfillment succeeds but emits CallbackFailed event
    // =========================================================================

    function test_fulfillRandomWords_emitsCallbackFailedOnBadCallback() public {
        // BadRequester makes a request
        vm.prank(address(badRequester));
        badRequester.requestRandomness(CONTEST_1);

        uint256 requestId = rm.contestRequests(CONTEST_1);
        assertGt(requestId, 0, "request should exist");

        // Manual fulfill — callback fails, request NOT marked fulfilled (allows retry)
        // Warp past MANUAL_FULFILL_DELAY (1 hour)
        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 42);

        // Request should NOT be marked fulfilled when callback fails
        assertFalse(rm.isRequestFulfilled(CONTEST_1), "request should NOT be fulfilled on callback failure");
        // Random word is NOT stored when callback fails (security fix: only persist on success)
        assertEq(rm.getRandomWord(CONTEST_1), 0, "random word should NOT be stored on callback failure");
    }

    // =========================================================================
    // Callback failure: manualFulfill emits CallbackFailed, allows retry
    // =========================================================================

    function test_manualFulfill_emitsCallbackFailedOnBadCallback() public {
        vm.prank(address(badRequester));
        badRequester.requestRandomness(CONTEST_2);

        uint256 requestId = rm.contestRequests(CONTEST_2);

        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 12345);

        // NOT fulfilled — allows owner to retry
        assertFalse(rm.isRequestFulfilled(CONTEST_2), "request should NOT be fulfilled on callback failure");
    }

    // =========================================================================
    // After callback failure, request is NOT fulfilled; owner can retry or reset
    // =========================================================================

    function test_requestFulfilledAfterCallbackFailure_canRetry() public {
        vm.prank(address(badRequester));
        badRequester.requestRandomness(CONTEST_1);

        uint256 requestId = rm.contestRequests(CONTEST_1);

        // First attempt: callback fails, not marked fulfilled
        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 42);

        assertFalse(rm.isRequestFulfilled(CONTEST_1), "request should NOT be fulfilled");
        assertTrue(rm.isRequestPending(CONTEST_1), "request should still be pending");

        // Owner can reset the failed request to allow a completely new one
        vm.prank(owner);
        rm.resetFailedRequest(CONTEST_1);

        assertFalse(rm.isRequestFulfilled(CONTEST_1), "request should be cleared");
        assertFalse(rm.isRequestPending(CONTEST_1), "request should be cleared");
    }

    // =========================================================================
    // Double fulfillment reverts with AlreadyFulfilled
    // =========================================================================

    function test_doubleFulfillment_reverts_manualFulfill_first() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_1);

        uint256 requestId = rm.contestRequests(CONTEST_1);

        // First fulfillment succeeds
        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 777);

        assertTrue(rm.isRequestFulfilled(CONTEST_1));
        assertTrue(goodRequester.callbackReceived());
        assertEq(goodRequester.lastRandomWord(), 777);

        // Second fulfillment reverts
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.AlreadyFulfilled.selector);
        rm.manualFulfill(requestId, 777);
    }

    function test_doubleFulfillment_reverts_manualFulfill() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_2);

        uint256 requestId = rm.contestRequests(CONTEST_2);

        // First manual fulfillment succeeds
        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 888);

        assertTrue(rm.isRequestFulfilled(CONTEST_2));

        // Second manual fulfillment reverts
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.AlreadyFulfilled.selector);
        rm.manualFulfill(requestId, 999);
    }

    // =========================================================================
    // Request for same contestId twice reverts with RequestAlreadyExists
    // =========================================================================

    function test_duplicateContestId_reverts() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_1);

        // Same contestId again
        vm.prank(address(goodRequester));
        vm.expectRevert(RandomnessManager.RequestAlreadyExists.selector);
        goodRequester.requestRandomness(CONTEST_1);
    }

    // =========================================================================
    // Non-VRF-coordinator cannot call rawFulfillRandomWords
    // =========================================================================

    function test_nonVRFCoordinator_cannotFulfill() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_1);

        uint256 requestId = rm.contestRequests(CONTEST_1);

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 42;

        // Owner cannot call rawFulfillRandomWords
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.NotVRFCoordinator.selector);
        rm.rawFulfillRandomWords(requestId, randomWords);

        // Random address cannot call rawFulfillRandomWords
        vm.prank(nobody);
        vm.expectRevert(RandomnessManager.NotVRFCoordinator.selector);
        rm.rawFulfillRandomWords(requestId, randomWords);
    }

    // =========================================================================
    // Non-owner cannot call manualFulfill
    // =========================================================================

    function test_nonOwner_cannotManualFulfill() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_1);

        uint256 requestId = rm.contestRequests(CONTEST_1);

        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        rm.manualFulfill(requestId, 42);

        vm.prank(vrfCoordinator);
        vm.expectRevert("Ownable: caller is not the owner");
        rm.manualFulfill(requestId, 42);
    }

    // =========================================================================
    // Non-allowed requester cannot requestRandomness
    // =========================================================================

    function test_nonAllowedRequester_cannotRequest() public {
        vm.prank(nobody);
        vm.expectRevert(RandomnessManager.NotAllowedRequester.selector);
        rm.requestRandomness(CONTEST_1);
    }

    // =========================================================================
    // Factory-authorized address can addAllowedRequester
    // =========================================================================

    function test_authorizedFactory_canAddRequester() public {
        vm.prank(owner);
        rm.setAuthorizedFactory(factory, true);

        address newRequester = address(0xBEEF);

        vm.prank(factory);
        rm.addAllowedRequester(newRequester);

        assertTrue(rm.allowedRequesters(newRequester), "factory-added requester should be allowed");
    }

    function test_authorizedFactory_cannotRemoveRequester() public {
        vm.prank(owner);
        rm.setAuthorizedFactory(factory, true);

        // removeAllowedRequester is onlyOwner, not onlyOwnerOrFactory
        vm.prank(factory);
        vm.expectRevert("Ownable: caller is not the owner");
        rm.removeAllowedRequester(address(goodRequester));
    }

    // =========================================================================
    // Non-factory non-owner cannot addAllowedRequester
    // =========================================================================

    function test_nonFactoryNonOwner_cannotAddRequester() public {
        vm.prank(nobody);
        vm.expectRevert(RandomnessManager.NotAuthorized.selector);
        rm.addAllowedRequester(address(0xDEAD));
    }

    function test_revokedFactory_cannotAddRequester() public {
        vm.prank(owner);
        rm.setAuthorizedFactory(factory, true);

        // Revoke
        vm.prank(owner);
        rm.setAuthorizedFactory(factory, false);

        vm.prank(factory);
        vm.expectRevert(RandomnessManager.NotAuthorized.selector);
        rm.addAllowedRequester(address(0xDEAD));
    }

    // =========================================================================
    // transferOwnership works, old owner loses access
    // =========================================================================

    function test_transferOwnership_works() public {
        // Ownable2Step: transferOwnership stages a pendingOwner; the new owner
        // must call acceptOwnership() to complete the handoff.
        vm.prank(owner);
        rm.transferOwnership(newOwner);
        assertEq(rm.pendingOwner(), newOwner, "pending set");
        assertEq(rm.owner(), owner, "owner unchanged until accept");

        vm.prank(newOwner);
        rm.acceptOwnership();
        assertEq(rm.owner(), newOwner, "ownership transferred");

        // Old owner can no longer call owner-only functions
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.NotAuthorized.selector);
        rm.addAllowedRequester(address(0xCAFE));

        // New owner can
        vm.prank(newOwner);
        rm.addAllowedRequester(address(0xCAFE));
        assertTrue(rm.allowedRequesters(address(0xCAFE)));
    }

    function test_transferOwnership_toZeroReverts() public {
        // Ownable2Step accepts address(0) and clears the pendingOwner — it does
        // NOT revert. Use renounceOwnership() to relinquish.
        vm.prank(owner);
        rm.transferOwnership(address(0));
        assertEq(rm.pendingOwner(), address(0), "pending cleared");
        assertEq(rm.owner(), owner, "owner unchanged");
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        rm.transferOwnership(newOwner);
    }

    // =========================================================================
    // isRequestPending and isRequestFulfilled through lifecycle
    // =========================================================================

    function test_requestLifecycle_pendingThenFulfilled() public {
        // Before request: neither pending nor fulfilled
        assertFalse(rm.isRequestPending(CONTEST_1), "no request yet");
        assertFalse(rm.isRequestFulfilled(CONTEST_1), "no request yet");

        // After request: pending, not fulfilled
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_1);

        assertTrue(rm.isRequestPending(CONTEST_1), "should be pending after request");
        assertFalse(rm.isRequestFulfilled(CONTEST_1), "should not be fulfilled yet");

        // After fulfillment: not pending, fulfilled
        uint256 requestId = rm.contestRequests(CONTEST_1);
        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 12345);

        assertFalse(rm.isRequestPending(CONTEST_1), "should not be pending after fulfillment");
        assertTrue(rm.isRequestFulfilled(CONTEST_1), "should be fulfilled");

        // Verify the random word is stored
        assertEq(rm.getRandomWord(CONTEST_1), 12345, "random word stored correctly");
        assertEq(rm.contestRandomWords(CONTEST_1), 12345);
    }

    // =========================================================================
    // manualFulfill for non-existent request reverts
    // =========================================================================

    function test_fulfillNonExistentRequest_reverts() public {
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.RequestNotFound.selector);
        rm.manualFulfill(999, 42);
    }

    function test_manualFulfillNonExistentRequest_reverts() public {
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.RequestNotFound.selector);
        rm.manualFulfill(999, 42);
    }

    // =========================================================================
    // GoodRequester receives and stores random word correctly
    // =========================================================================

    function test_goodRequester_receivesRandomWord() public {
        vm.prank(address(goodRequester));
        goodRequester.requestRandomness(CONTEST_3);

        assertFalse(goodRequester.callbackReceived());

        uint256 requestId = rm.contestRequests(CONTEST_3);

        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        rm.manualFulfill(requestId, 42424242);

        assertTrue(goodRequester.callbackReceived(), "callback should have been received");
        assertEq(goodRequester.lastRandomWord(), 42424242, "random word should match");
    }

    // =========================================================================
    // removeAllowedRequester works
    // =========================================================================

    function test_removeAllowedRequester_blocksRequests() public {
        assertTrue(rm.allowedRequesters(address(goodRequester)));

        vm.prank(owner);
        rm.removeAllowedRequester(address(goodRequester));

        assertFalse(rm.allowedRequesters(address(goodRequester)));

        vm.prank(address(goodRequester));
        vm.expectRevert(RandomnessManager.NotAllowedRequester.selector);
        goodRequester.requestRandomness(CONTEST_1);
    }

    // =========================================================================
    // updateVRFConfig only owner
    // =========================================================================

    function test_updateVRFConfig_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        rm.updateVRFConfig(bytes32(0), 200000, 5);

        uint256 originalSub = rm.subscriptionId();

        vm.prank(owner);
        rm.updateVRFConfig(keccak256("new-hash"), 200000, 5);
        // subscriptionId is now immutable — unaffected by updateVRFConfig
        assertEq(rm.subscriptionId(), originalSub);
        assertEq(rm.callbackGasLimit(), 200000);
        assertEq(rm.requestConfirmations(), 5);
    }

    function test_updateVRFConfig_revertsAboveMaxCallbackGas() public {
        uint32 tooHigh = rm.MAX_CALLBACK_GAS_LIMIT() + 1;
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.CallbackGasLimitTooHigh.selector);
        rm.updateVRFConfig(keccak256("k"), tooHigh, 5);
    }

    function test_updateVRFConfig_revertsAboveMaxConfirmations() public {
        uint16 tooHigh = rm.MAX_REQUEST_CONFIRMATIONS() + 1;
        vm.prank(owner);
        vm.expectRevert(RandomnessManager.RequestConfirmationsTooHigh.selector);
        rm.updateVRFConfig(keccak256("k"), 200000, tooHigh);
    }
}
