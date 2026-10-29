// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRandomnessManager
 * @notice Interface for managing VRF randomness requests
 */
interface IRandomnessManager {
    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed requester,
        bytes32 indexed contestId
    );

    event RandomnessFulfilled(
        uint256 indexed requestId,
        bytes32 indexed contestId,
        uint256 randomWord
    );

    function requestRandomness(bytes32 contestId) external returns (uint256 requestId);

    /// @notice Request randomness with a specific number of words.
    function requestRandomnessMulti(bytes32 contestId, uint32 _numWords) external returns (uint256 requestId);

    function getRandomWord(bytes32 contestId) external view returns (uint256);

    /// @notice Get all random words for a contest (for multi-word requests).
    function getRandomWords(bytes32 contestId) external view returns (uint256[] memory);

    function isRequestPending(bytes32 contestId) external view returns (bool);

    function isRequestFulfilled(bytes32 contestId) external view returns (bool);

    /// @notice Reset a failed request so a new one can be made for the same
    ///         contestId. Callable by the owner or the original requester.
    ///         Used by `NoLossLotteryV3.cancelDraw` to clear a stuck VRF
    ///         request after `VRF_TIMEOUT` has elapsed.
    function resetFailedRequest(bytes32 contestId) external;
}
