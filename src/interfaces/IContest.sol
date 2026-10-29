// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IContest
 * @notice Interface for individual contest contracts
 */
interface IContest {
    enum ContestType { VOTE, RANK, RATE, PREDICT, PAIRWISE }
    enum ContestState {
        CREATED,
        SUBMISSION_OPEN,
        SUBMISSION_CLOSED,
        DEPOSIT_OPEN,
        DEPOSIT_CLOSED,
        LOCKED,
        REVEAL_OPEN,
        RESOLVING,
        FINALIZED,
        CANCELLED
    }
    enum PrizeModel { SINGLE_WINNER, TOP_N, PROPORTIONAL }

    struct ContestConfig {
        address depositToken;
        uint256 depositAmount;
        uint256 depositStart;
        uint256 depositEnd;
        uint256 lockEnd;
        uint256 revealEnd;
        ContestType contestType;
        uint8 tierRequired;
        uint256 yieldStrategyId;
        PrizeModel prizeModel;
        uint256 prizeModelParam; // e.g., N for TOP_N
        bytes32 metadataHash;
        string metadataUri;
    }

    event Deposited(address indexed participant, uint256 amount);
    event VoteCommitted(address indexed participant, bytes32 commitHash);
    event VoteRevealed(address indexed participant, bytes voteData);
    event FundsLocked(uint256 totalAmount, uint256 shares);
    event RandomnessRequested(uint256 requestId);
    event WinnersSelected(address[] winners, uint256[] amounts);
    event Finalized(uint256 yieldGenerated, uint256 protocolFee);
    event PrincipalReturned(address indexed participant, uint256 amount, uint256 principal, uint256 prize);
    event Cancelled(string reason);

    function deposit() external;

    function commitVote(bytes32 commitHash) external;

    function revealVote(bytes calldata voteData, bytes32 salt) external;

    function lockFunds() external;

    function requestRandomness() external;

    function fulfillRandomness(uint256 randomWord) external;

    function finalize() external;

    function cancel(string calldata reason) external;

    function withdrawPrincipal() external;

    function getConfig() external view returns (ContestConfig memory);

    function getState() external view returns (ContestState);

    function getParticipantCount() external view returns (uint256);

    function hasDeposited(address participant) external view returns (bool);

    function hasCommitted(address participant) external view returns (bool);

    function hasRevealed(address participant) external view returns (bool);

    function getWinners() external view returns (address[] memory);
}
