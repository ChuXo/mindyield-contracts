// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestFactory.sol";
import "../src/Contest.sol";
import "../src/DataRegistry.sol";
import "../src/IdentityRegistry.sol";
import "../src/YieldVault.sol";
import "../src/RandomnessManager.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockVRFCoordinator.sol";

/**
 * @title ContestFuzzTest
 * @notice Fuzz testing for Contest contract to find edge cases
 */
contract ContestFuzzTest is Test {
    ContestFactory public factory;
    DataRegistry public dataRegistry;
    IdentityRegistry public identityRegistry;
    YieldVault public yieldVault;
    RandomnessManager public randomnessManager;
    MockERC20 public token;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = address(1);
    address public treasury = address(2);

    function setUp() public {
        vm.startPrank(owner);

        token = new MockERC20("USDC", "USDC", 18);
        vrfCoordinator = new MockVRFCoordinator();
        dataRegistry = new DataRegistry(address(this));
        identityRegistry = new IdentityRegistry();
        yieldVault = new YieldVault();
        randomnessManager = new RandomnessManager(
            address(vrfCoordinator),
            bytes32(0),
            1
        );

        vrfCoordinator.setRandomnessManager(address(randomnessManager));

        factory = new ContestFactory(
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            address(dataRegistry),
            treasury
        );

        yieldVault.addStrategy(address(0));

        // Register factory as authorized to call randomnessManager.addAllowedRequester()
        randomnessManager.setAuthorizedFactory(address(factory), true);

        vm.stopPrank();
    }

    // ============ FUZZ TESTS ============

    /**
     * @notice Fuzz test deposit amounts
     * @dev Tests that deposits work correctly for any valid amount
     */
    function testFuzz_DepositAmount(uint256 amount) public {
        // Bound to reasonable amounts (1 wei to 1 trillion tokens)
        amount = bound(amount, 1, 1e30);

        address user = address(uint160(1000));
        token.mint(user, amount);

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(user);
        token.approve(contestAddress, amount);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();

        assertTrue(contest.hasDeposited(user));
        assertEq(token.balanceOf(contestAddress), amount);
    }

    /**
     * @notice Fuzz test timing windows
     * @dev Tests various timing configurations
     */
    function testFuzz_TimingWindows(
        uint256 depositDuration,
        uint256 lockDuration,
        uint256 revealDuration
    ) public {
        // Bound to reasonable durations (1 minute to 120 days each)
        // Total must not exceed MAX_CONTEST_DURATION (365 days)
        depositDuration = bound(depositDuration, 60, 120 days);
        lockDuration = bound(lockDuration, 60, 120 days);
        revealDuration = bound(revealDuration, 60, 120 days);

        address user = address(uint160(2000));
        uint256 amount = 100e18;
        token.mint(user, amount);

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + depositDuration,
            lockEnd: block.timestamp + depositDuration + lockDuration,
            revealEnd: block.timestamp + depositDuration + lockDuration + revealDuration,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Deposit works during deposit window
        vm.startPrank(user);
        token.approve(contestAddress, amount);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();

        assertTrue(contest.hasDeposited(user));
    }

    /**
     * @notice Fuzz test commit hashes
     * @dev Tests that any valid commit hash is accepted
     */
    function testFuzz_CommitHash(bytes32 voteDataHash, bytes32 salt) public {
        vm.assume(voteDataHash != bytes32(0) || salt != bytes32(0));

        address user = address(uint160(3000));
        uint256 amount = 100e18;
        token.mint(user, amount);

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(user);
        token.approve(contestAddress, amount);
        contest.deposit();
        vm.roll(block.number + 1);

        // Any commit hash should work
        bytes32 commitHash = keccak256(abi.encodePacked(voteDataHash, salt));
        contest.commitVote(commitHash);
        vm.stopPrank();

        assertTrue(contest.hasCommitted(user));
    }

    /**
     * @notice Fuzz test reveal with matching hash
     * @dev Tests that reveal works with any matching data/salt combo
     */
    function testFuzz_MatchingReveal(bytes memory voteData, bytes32 salt) public {
        vm.assume(voteData.length > 0);
        vm.assume(voteData.length < 10000); // Reasonable size

        address user = address(uint160(4000));
        uint256 amount = 100e18;
        token.mint(user, amount);

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));

        vm.startPrank(user);
        token.approve(contestAddress, amount);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(commitHash);
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        vm.prank(user);
        contest.revealVote(voteData, salt);

        assertTrue(contest.hasRevealed(user));
    }

    /**
     * @notice Fuzz test reveal with non-matching data fails
     */
    function testFuzz_NonMatchingRevealFails(
        bytes memory voteData,
        bytes32 salt,
        bytes memory wrongData
    ) public {
        vm.assume(voteData.length > 0 && voteData.length < 10000);
        vm.assume(wrongData.length > 0 && wrongData.length < 10000);
        vm.assume(keccak256(voteData) != keccak256(wrongData));

        address user = address(uint160(5000));
        uint256 amount = 100e18;
        token.mint(user, amount);

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));

        vm.startPrank(user);
        token.approve(contestAddress, amount);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(commitHash);
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        vm.prank(user);
        vm.expectRevert(Contest.InvalidReveal.selector);
        contest.revealVote(wrongData, salt);
    }

    /**
     * @notice Fuzz test participant counts
     */
    function testFuzz_ParticipantCount(uint8 participantCount) public {
        // Bound to reasonable participant count
        participantCount = uint8(bound(participantCount, 1, 50));

        uint256 amount = 100e18;

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(address(uint160(100)));
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Add participants
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(1000 + i));
            token.mint(user, amount);

            vm.startPrank(user);
            token.approve(contestAddress, amount);
            contest.deposit();
        vm.roll(block.number + 1);
            vm.stopPrank();
        }

        assertEq(contest.getParticipantCount(), participantCount);
    }

    /**
     * @notice Fuzz test random word selection
     */
    function testFuzz_RandomWinnerSelection(uint256 randomWord, uint8 participantCount) public {
        // Ensure randomWord is not 0 (contract uses 0 to check if randomness was fulfilled)
        randomWord = bound(randomWord, 1, type(uint256).max);
        participantCount = uint8(bound(participantCount, 1, 20));

        uint256 amount = 100e18;

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(address(uint160(100)));
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Add participants who commit and reveal (all vote for same option)
        bytes memory voteData = abi.encode("winningOption");
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(2000 + i));
            token.mint(user, amount);

            vm.startPrank(user);
            token.approve(contestAddress, amount);
            contest.deposit();
        vm.roll(block.number + 1);

            bytes32 salt = bytes32(i);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();
        }

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(2000 + i));
            vm.prank(user);
            contest.revealVote(voteData, bytes32(i));
        }

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, randomWord);

        contest.finalize();

        // Should have exactly one winner
        address[] memory winners = contest.getWinners();
        assertEq(winners.length, 1);

        // Winner should be a participant
        bool isParticipant = false;
        for (uint256 i = 0; i < participantCount; i++) {
            if (winners[0] == address(uint160(2000 + i))) {
                isParticipant = true;
                break;
            }
        }
        assertTrue(isParticipant);
    }

    /**
     * @notice Fuzz test TOP_N prize model
     */
    function testFuzz_TopNPrizeModel(uint8 n, uint8 participantCount) public {
        participantCount = uint8(bound(participantCount, 1, 20));
        n = uint8(bound(n, 1, participantCount));

        uint256 amount = 100e18;

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: 0,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.TOP_N,
            prizeModelParam: n,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(address(uint160(100)));
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // All participants vote for the same option so they're all "correct"
        bytes memory voteData = abi.encode("winningOption");
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(3000 + i));
            token.mint(user, amount);

            vm.startPrank(user);
            token.approve(contestAddress, amount);
            contest.deposit();
        vm.roll(block.number + 1);
            bytes32 salt = bytes32(i);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();
        }

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(3000 + i));
            vm.prank(user);
            contest.revealVote(voteData, bytes32(i));
        }

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        contest.finalize();

        // Should have n winners (or participantCount if n > participantCount)
        uint256 expectedWinners = n > participantCount ? participantCount : n;
        address[] memory winners = contest.getWinners();
        assertEq(winners.length, expectedWinners);
    }

    /**
     * @notice Fuzz test tier requirements
     */
    function testFuzz_TierRequirement(uint8 requiredTier, uint8 userTier) public {
        requiredTier = uint8(bound(requiredTier, 0, 5));
        userTier = uint8(bound(userTier, 0, 5));

        address user = address(uint160(6000));
        uint256 amount = 100e18;
        token.mint(user, amount);

        if (userTier > 0) {
            vm.prank(owner);
            identityRegistry.setTier(user, userTier);
        }

        IContest.ContestConfig memory config = IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: amount,
            depositStart: block.timestamp,
            depositEnd: block.timestamp + 1 days,
            lockEnd: block.timestamp + 2 days,
            revealEnd: block.timestamp + 3 days,
            contestType: IContest.ContestType.VOTE,
            tierRequired: requiredTier,
            yieldStrategyId: 0,
            prizeModel: IContest.PrizeModel.SINGLE_WINNER,
            prizeModelParam: 1,
            metadataHash: bytes32(0),
            metadataUri: ""
        });

        vm.prank(user);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(user);
        token.approve(contestAddress, amount);

        if (userTier >= requiredTier) {
            contest.deposit();
        vm.roll(block.number + 1);
            assertTrue(contest.hasDeposited(user));
        } else {
            vm.expectRevert(Contest.InsufficientTier.selector);
            contest.deposit();
        vm.roll(block.number + 1);
        }
        vm.stopPrank();
    }
}
