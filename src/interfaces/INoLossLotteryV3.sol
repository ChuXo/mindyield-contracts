// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title INoLossLotteryV3
 * @notice Interface for factory interaction with NoLossLotteryV3 clones.
 */
interface INoLossLotteryV3 {
    function initialize(
        address _depositToken,
        address _aaveStrategy,
        address _randomnessManager,
        uint256 _roundDuration,
        address _feeRecipient,
        uint256 _protocolFeeBps,
        uint8   _numberOfTiers,
        uint256[5] calldata _tierBps,
        uint8   _poolType,
        address _receiptToken
    ) external;

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimPrize(uint256 roundId) external;

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata) external;
    function fulfillRandomness(uint256 randomWord) external;

    function setDelegate(address delegate) external;
    function setAutoCompound(bool enabled) external;

    // View
    function poolType() external view returns (uint8);
    function currentRoundId() external view returns (uint256);
    function participantCount() external view returns (uint256);
    function totalDeposited() external view returns (uint256);
    function getCurrentPrizePool() external view returns (uint256);
    function getWinProbability(address participant) external view returns (uint256);
    function getStreakInfo(address user) external view returns (uint16 streak, uint16 multiplier);
    function getEffectiveWeight(address user) external view returns (uint256);

    // Owner
    function setRoundDuration(uint256 newDuration) external;
    function setProtocolFee(uint256 newFeeBps) external;
    function setTierConfig(uint8 _numberOfTiers, uint256[5] calldata _tierBps) external;
    function setStreakConfig(uint16[5] calldata _thresholds, uint16[5] calldata _multipliers) external;
    function transferOwnership(address newOwner) external;
}
