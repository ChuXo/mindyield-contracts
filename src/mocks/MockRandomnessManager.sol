// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IRandomnessManager.sol";

/**
 * @title MockRandomnessManager
 * @notice Test double for IRandomnessManager.
 *
 * Stores VRF requests and allows tests to manually deliver a random word,
 * simulating Chainlink VRF fulfillment without any off-chain infrastructure.
 *
 * Supports both single-word and multi-word requests.
 *
 * Usage in tests:
 *   1. Pass address(mockRM) to NoLossLottery constructor.
 *   2. Call lottery.performUpkeep("") → records the request.
 *   3. Call mockRM.deliverRandomness(address(lottery), randomWord) → triggers
 *      lottery.fulfillRandomness(randomWord) with msg.sender == address(mockRM).
 */
contract MockRandomnessManager is IRandomnessManager {
    uint256 public nextRequestId = 1;

    struct Request {
        address requester;
        bytes32 key;
        bool    pending;
        bool    fulfilled;
        uint256 randomWord;
        uint32  numWords;
    }

    mapping(uint256 => Request)    public requests;
    mapping(bytes32 => uint256)    public keyToRequestId;
    mapping(bytes32 => uint256[])  public keyToRandomWords;

    // ─── IRandomnessManager ───────────────────────────────────────────────────

    function requestRandomness(bytes32 key) external override returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = Request({
            requester:  msg.sender,
            key:        key,
            pending:    true,
            fulfilled:  false,
            randomWord: 0,
            numWords:   1
        });
        keyToRequestId[key] = requestId;
        emit RandomnessRequested(requestId, msg.sender, key);
    }

    function requestRandomnessMulti(bytes32 key, uint32 _numWords) external override returns (uint256 requestId) {
        require(_numWords > 0 && _numWords <= 10, "MockRM: invalid numWords");
        requestId = nextRequestId++;
        requests[requestId] = Request({
            requester:  msg.sender,
            key:        key,
            pending:    true,
            fulfilled:  false,
            randomWord: 0,
            numWords:   _numWords
        });
        keyToRequestId[key] = requestId;
        emit RandomnessRequested(requestId, msg.sender, key);
    }

    function getRandomWord(bytes32 key) external view override returns (uint256) {
        uint256 reqId = keyToRequestId[key];
        return requests[reqId].randomWord;
    }

    function getRandomWords(bytes32 key) external view override returns (uint256[] memory) {
        return keyToRandomWords[key];
    }

    function isRequestPending(bytes32 key) external view override returns (bool) {
        uint256 reqId = keyToRequestId[key];
        return requests[reqId].pending;
    }

    function isRequestFulfilled(bytes32 key) external view override returns (bool) {
        uint256 reqId = keyToRequestId[key];
        return requests[reqId].fulfilled;
    }

    /// @notice Test double for the VRF-stall recovery path. Clears the
    ///         in-flight request so the requester can re-submit a fresh one.
    function resetFailedRequest(bytes32 key) external override {
        uint256 reqId = keyToRequestId[key];
        require(reqId != 0, "MockRM: no request");
        require(
            msg.sender == requests[reqId].requester,
            "MockRM: not authorized"
        );
        delete keyToRequestId[key];
        delete requests[reqId];
    }

    // ─── Access control stubs (called by ContestFactoryV2 during creation) ────

    mapping(address => bool) public authorizedFactories;
    mapping(address => bool) public allowedRequesters;

    function setAuthorizedFactory(address factory, bool authorized) external {
        authorizedFactories[factory] = authorized;
    }

    function addAllowedRequester(address requester) external {
        allowedRequesters[requester] = true;
    }

    function removeAllowedRequester(address requester) external {
        allowedRequesters[requester] = false;
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Deliver a single random word to the lottery, simulating VRF callback.
     */
    function deliverRandomness(address lottery, uint256 randomWord) external {
        (bool ok, bytes memory err) = lottery.call(
            abi.encodeWithSignature("fulfillRandomness(uint256)", randomWord)
        );
        if (!ok) {
            if (err.length > 0) assembly { revert(add(err, 32), mload(err)) }
            revert("MockRM: fulfillRandomness failed");
        }
    }

    /**
     * @notice Deliver multiple random words for a specific request key.
     *         Stores the words and calls fulfillRandomness with the first word.
     */
    function deliverRandomnessMulti(
        address lottery,
        bytes32 key,
        uint256[] calldata randomWords
    ) external {
        uint256 reqId = keyToRequestId[key];
        require(reqId != 0, "MockRM: no request for key");
        Request storage req = requests[reqId];
        require(!req.fulfilled, "MockRM: already fulfilled");
        require(randomWords.length == req.numWords, "MockRM: word count mismatch");

        req.randomWord = randomWords[0];
        req.fulfilled = true;
        req.pending = false;
        keyToRandomWords[key] = randomWords;

        (bool ok, bytes memory err) = lottery.call(
            abi.encodeWithSignature("fulfillRandomness(uint256)", randomWords[0])
        );
        if (!ok) {
            if (err.length > 0) assembly { revert(add(err, 32), mload(err)) }
            revert("MockRM: fulfillRandomness failed");
        }
    }
}

/**
 * @dev Test double that always reverts on resetFailedRequest.
 *      Used to simulate MAX_RETRIES exhaustion in the cancelDraw tests.
 */
contract MockAlwaysRevertRM is IRandomnessManager {
    uint256 private _nonce;
    function requestRandomness(bytes32) external override returns (uint256) { return ++_nonce; }
    function requestRandomnessMulti(bytes32, uint32) external override returns (uint256) { return ++_nonce; }
    function getRandomWord(bytes32) external pure override returns (uint256) { return 0; }
    function getRandomWords(bytes32) external pure override returns (uint256[] memory) { return new uint256[](0); }
    function isRequestPending(bytes32) external pure override returns (bool) { return true; }
    function isRequestFulfilled(bytes32) external pure override returns (bool) { return false; }
    function resetFailedRequest(bytes32) external pure override { revert("MockAlwaysRevertRM: max retries exceeded"); }
}
