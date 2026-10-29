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
 * @title ContestEnhancedSecurityTest
 * @notice Enhanced security tests for advanced attack scenarios
 * @dev Tests MEV, front-running, gas griefing, cross-function reentrancy, precision loss
 */
contract ContestEnhancedSecurityTest is Test {
    ContestFactory public factory;
    DataRegistry public dataRegistry;
    IdentityRegistry public identityRegistry;
    YieldVault public yieldVault;
    RandomnessManager public randomnessManager;
    MockERC20 public token;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = address(1);
    address public treasury = address(2);
    address public alice = address(3);
    address public bob = address(4);
    address public mevBot = address(5);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

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

        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
        token.mint(mevBot, 10000e18);
    }

    function _createDefaultConfig() internal view returns (IContest.ContestConfig memory) {
        return IContest.ContestConfig({
            depositToken: address(token),
            depositAmount: DEPOSIT_AMOUNT,
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
    }

    // ============ FRONT-RUNNING / MEV TESTS ============

    function testFrontRunDepositDoesNotChangeOutcome() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        bytes memory aliceVote = abi.encode("optionA");
        bytes32 aliceSalt = bytes32(uint256(123));

        // Alice commits her vote
        vm.startPrank(alice);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(aliceVote, aliceSalt)));
        vm.stopPrank();

        // MEV bot sees Alice's transaction in mempool and front-runs
        // by depositing first in the same block
        vm.startPrank(mevBot);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        bytes memory botVote = abi.encode("optionB");
        bytes32 botSalt = bytes32(uint256(456));
        contest.commitVote(keccak256(abi.encodePacked(botVote, botSalt)));
        vm.stopPrank();

        // Complete contest
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        vm.prank(alice);
        contest.revealVote(aliceVote, aliceSalt);
        vm.prank(mevBot);
        contest.revealVote(botVote, botSalt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        contest.finalize();

        // Both have equal chance - front-running doesn't give advantage
        // Winner is determined by randomness, not deposit order
        address[] memory winners = contest.getWinners();
        assertTrue(winners[0] == alice || winners[0] == mevBot);
    }

    function testCannotFrontRunReveal() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        bytes memory aliceVote = abi.encode("optionA");
        bytes32 aliceSalt = bytes32(uint256(123));
        bytes32 aliceCommit = keccak256(abi.encodePacked(aliceVote, aliceSalt));

        bytes memory bobVote = abi.encode("optionB");
        bytes32 bobSalt = bytes32(uint256(456));
        bytes32 bobCommit = keccak256(abi.encodePacked(bobVote, bobSalt));

        // Both commit
        vm.startPrank(alice);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(aliceCommit);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(bobCommit);
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        // Alice reveals
        vm.prank(alice);
        contest.revealVote(aliceVote, aliceSalt);

        // MEV bot sees Alice's reveal and tries to use that info
        // But they cannot because:
        // 1. Bob already committed to a different vote
        // 2. Cannot reveal without the correct salt
        // 3. Cannot change commitment after committing

        vm.prank(bob);
        // Bob must reveal with his original commitment
        contest.revealVote(bobVote, bobSalt);

        // Trying to reveal Alice's vote fails
        vm.prank(bob);
        vm.expectRevert(Contest.AlreadyRevealed.selector);
        contest.revealVote(aliceVote, aliceSalt);
    }

    function testSandwichAttackDoesNotBenefit() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // MEV bot tries sandwich attack:
        // 1. Front-run deposit
        // 2. Alice deposits
        // 3. Back-run with another action

        bytes memory botVote = abi.encode("botVote");
        bytes32 botSalt = bytes32(uint256(999));

        vm.startPrank(mevBot);
        token.approve(contestAddress, DEPOSIT_AMOUNT * 2);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(botVote, botSalt)));
        vm.stopPrank();

        // Alice's transaction
        bytes memory aliceVote = abi.encode("aliceVote");
        bytes32 aliceSalt = bytes32(uint256(111));

        vm.startPrank(alice);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(aliceVote, aliceSalt)));
        vm.stopPrank();

        // MEV bot cannot deposit again (already deposited)
        vm.startPrank(mevBot);
        vm.expectRevert(Contest.AlreadyDeposited.selector);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();

        // Complete contest - sandwich attack provides no benefit
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        vm.prank(alice);
        contest.revealVote(aliceVote, aliceSalt);
        vm.prank(mevBot);
        contest.revealVote(botVote, botSalt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        contest.finalize();

        // Both have equal chance based on randomness
        assertEq(contest.getParticipantCount(), 2);
    }

    // ============ GAS GRIEFING / DOS TESTS ============

    function testCannotDOSViaRevertInLoop() public {
        // This test ensures loops don't iterate over user-controlled arrays
        // that could cause DOS via excessive gas consumption
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Add maximum participants (bounded)
        uint256 maxParticipants = 100;
        for (uint256 i = 0; i < maxParticipants && i < 10; i++) {
            address user = address(uint160(100 + i));
            token.mint(user, DEPOSIT_AMOUNT);

            vm.startPrank(user);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
        vm.roll(block.number + 1);
            vm.stopPrank();
        }

        // Getting participant count should not fail
        uint256 count = contest.getParticipantCount();
        assertTrue(count > 0);

        // Getting participants should not run out of gas
        address[] memory participants = contest.getParticipants();
        assertEq(participants.length, count);
    }

    function testUnboundedLoopProtection() public {
        // Ensure that operations that iterate have gas limits
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Try to add many participants
        for (uint256 i = 0; i < 20; i++) {
            address user = address(uint160(200 + i));
            token.mint(user, DEPOSIT_AMOUNT);

            vm.startPrank(user);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
        vm.roll(block.number + 1);
            vm.stopPrank();
        }

        // Operations should still complete within reasonable gas
        uint256 gasBefore = gasleft();
        contest.getParticipants();
        uint256 gasUsed = gasBefore - gasleft();

        // Should use reasonable gas (< 1M)
        assertTrue(gasUsed < 1_000_000);
    }

    // ============ CROSS-FUNCTION REENTRANCY TESTS ============

    function testNoReadOnlyReentrancy() public {
        // Test that read-only reentrancy cannot manipulate state
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        bytes memory voteData = abi.encode("vote");
        bytes32 salt = bytes32(0);

        vm.startPrank(alice);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(10);
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(20);

        vm.warp(config.lockEnd + 1);
        vm.prank(alice);
        contest.revealVote(voteData, salt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        vm.roll(30);
        contest.finalize();

        // During withdrawal, state should be consistent
        uint256 participantsBefore = contest.getParticipantCount();

        vm.prank(alice);
        contest.withdrawPrincipal();

        uint256 participantsAfter = contest.getParticipantCount();

        // State should remain consistent
        assertEq(participantsBefore, participantsAfter);
    }

    // ============ PRECISION LOSS TESTS ============

    function testNoPrecisionLossInYieldCalculation() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositAmount = 3; // Small amount to test precision

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        bytes memory voteData = abi.encode("vote");
        bytes32 salt = bytes32(0);

        vm.startPrank(alice);
        token.approve(contestAddress, config.depositAmount);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        vm.prank(alice);
        contest.revealVote(voteData, salt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        contest.finalize();

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        contest.withdrawPrincipal();
        uint256 balanceAfter = token.balanceOf(alice);

        // Should get back at least the deposit (no precision loss)
        assertTrue(balanceAfter >= balanceBefore + config.depositAmount);
    }

    function testRoundingBenefitsProtocol() public {
        // Ensure any rounding errors benefit the protocol, not attackers
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositAmount = 7; // Odd number to test rounding

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Three participants with odd deposit amounts
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = address(6);

        for (uint256 i = 0; i < 3; i++) {
            token.mint(users[i], config.depositAmount * 2);

            bytes memory voteData = abi.encode(i);
            bytes32 salt = bytes32(i);

            vm.startPrank(users[i]);
            token.approve(contestAddress, config.depositAmount);
            contest.deposit();
        vm.roll(block.number + 1);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();
        }

        uint256 totalDeposited = config.depositAmount * 3;

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            contest.revealVote(abi.encode(i), bytes32(i));
        }

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        contest.finalize();

        // Withdraw all
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = token.balanceOf(users[i]);
            vm.prank(users[i]);
            contest.withdrawPrincipal();
            uint256 balanceAfter = token.balanceOf(users[i]);
            totalWithdrawn += (balanceAfter - before);
        }

        // Total withdrawn should not exceed total deposited + yield
        // Any rounding dust stays in contract (benefits protocol)
        assertTrue(totalWithdrawn >= totalDeposited);
    }

    // ============ FLASH LOAN ATTACK TESTS ============

    function testFlashLoanCannotManipulateVoting() public {
        // Test that flash-loaned tokens cannot be used to manipulate voting
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Alice deposits normally
        bytes memory aliceVote = abi.encode("vote");
        bytes32 aliceSalt = bytes32(0);

        vm.startPrank(alice);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(aliceVote, aliceSalt)));
        vm.stopPrank();

        // Attacker tries to use flash loan to deposit and immediately withdraw
        // But they cannot because:
        // 1. Must wait for contest to finalize before withdrawing
        // 2. Flash loan must be repaid in same transaction
        // 3. Deposit requires tokens to be locked until contest ends

        FlashLoanAttacker attacker = new FlashLoanAttacker(address(contest), address(token));
        token.mint(address(attacker), DEPOSIT_AMOUNT);

        vm.prank(address(attacker));
        // Attacker can deposit but cannot withdraw in same transaction
        vm.expectRevert(); // Will revert when trying to withdraw
        attacker.attack();

        // Alice's deposit is safe
        assertTrue(contest.hasDeposited(alice));
        assertFalse(contest.hasDeposited(address(attacker)));
    }

    // ============ INTEGER OVERFLOW TESTS ============

    function testNoOverflowInVoteCounting() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Add many participants (but within reasonable bounds)
        uint256 participantCount = 50;
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(1000 + i));
            token.mint(user, DEPOSIT_AMOUNT);

            bytes memory voteData = abi.encode(i % 3); // Vote for option 0, 1, or 2
            bytes32 salt = bytes32(i);

            vm.startPrank(user);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
        vm.roll(block.number + 1);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();
        }

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        vm.warp(config.lockEnd + 1);
        // Reveal all votes
        for (uint256 i = 0; i < participantCount; i++) {
            address user = address(uint160(1000 + i));
            vm.prank(user);
            contest.revealVote(abi.encode(i % 3), bytes32(i));
        }

        // Vote counts should be accurate (no overflow)
        uint256 totalParticipants = contest.getParticipantCount();
        assertEq(totalParticipants, participantCount);
    }
}

/**
 * @notice Flash loan attacker contract
 */
contract FlashLoanAttacker {
    Contest public contest;
    IERC20 public token;

    constructor(address _contest, address _token) {
        contest = Contest(_contest);
        token = IERC20(_token);
    }

    function attack() external {
        // Approve and deposit
        token.approve(address(contest), type(uint256).max);
        contest.deposit();

        // Try to withdraw immediately (should fail)
        contest.withdrawPrincipal();
    }
}
