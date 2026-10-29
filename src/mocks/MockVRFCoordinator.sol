// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockVRFCoordinator
 * @notice Mock Chainlink VRF V2.5 Coordinator for testing.
 *
 * @dev SIGNATURE MUST MATCH REAL V2.5 EXACTLY. The historic mock here used
 *      the OLD VRF V2 signature (five flat args with `uint64 subId`), which
 *      silently masked a calldata-encoding bug in RandomnessManager(V2)._fireVRF
 *      — the unit tests passed locally because the mock accepted RM's flat-args
 *      calldata, but the real V2.5 coordinator on Base mainnet expects a single
 *      RandomWordsRequest tuple and rejected every request. Result: lottery
 *      round 1 stuck since 2026-05-14.
 *
 *      The struct + selector below mirror Chainlink's real V2.5 coordinator
 *      exactly, so any production-bound RM that builds the wrong calldata will
 *      now fail at the mock too.
 */
contract MockVRFCoordinator {
    /// Mirrors Chainlink VRF V2.5 `VRFV2PlusClient.RandomWordsRequest`.
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16  requestConfirmations;
        uint32  callbackGasLimit;
        uint32  numWords;
        bytes   extraArgs;
    }

    uint256 private _requestIdCounter;
    address public randomnessManager;

    struct Request {
        address requester;
        bool fulfilled;
    }

    mapping(uint256 => Request) public requests;

    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 indexed subId,
        address indexed requester,
        uint256 requestId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs
    );

    function setRandomnessManager(address _randomnessManager) external {
        randomnessManager = _randomnessManager;
    }

    /// @notice V2.5 signature. Takes a SINGLE tuple-typed parameter — Solidity
    ///         encodes this with a leading 0x20 offset prefix; any caller that
    ///         passes flat args will fail to decode here just like on mainnet.
    function requestRandomWords(RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        requestId = ++_requestIdCounter;
        requests[requestId] = Request({
            requester: msg.sender,
            fulfilled: false
        });
        emit RandomWordsRequested(
            req.keyHash,
            req.subId,
            msg.sender,
            requestId,
            req.requestConfirmations,
            req.callbackGasLimit,
            req.numWords,
            req.extraArgs
        );
    }

    function fulfillRandomWords(uint256 requestId, uint256 randomWord) external {
        require(!requests[requestId].fulfilled, "Already fulfilled");
        requests[requestId].fulfilled = true;

        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = randomWord;

        // Call back to RandomnessManager
        (bool success,) = randomnessManager.call(
            abi.encodeWithSignature(
                "rawFulfillRandomWords(uint256,uint256[])",
                requestId,
                randomWords
            )
        );
        require(success, "Callback failed");
    }
}
