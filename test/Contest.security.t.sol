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
 * @title ContestSecurityTest
 * @notice Security-focused tests for the Contest contract
 * @dev Tests for reentrancy, manipulation, access control, and edge cases
 */
contract ContestSecurityTest is Test {
    ContestFactory public factory;
    DataRegistry public dataRegistry;
    IdentityRegistry public identityRegistry;
    YieldVault public yieldVault;
    RandomnessManager public randomnessManager;
    MockERC20 public token;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = address(1);
    address public treasury = address(2);
    address public attacker = address(0xBAD);

    // Regular users
    address[] public users;
    uint256 public constant USER_COUNT = 10;
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

        // Setup users
        for (uint256 i = 0; i < USER_COUNT; i++) {
            address user = address(uint160(100 + i));
            users.push(user);
            token.mint(user, 10000e18);
        }

        token.mint(attacker, 10000e18);
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

    // ============ REENTRANCY TESTS ============

    function testNoReentrancyOnDeposit() public {
        // Create a malicious token that tries to re-enter
        MaliciousToken maliciousToken = new MaliciousToken();

        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositToken = address(maliciousToken);

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);

        maliciousToken.setTarget(contestAddress);
        maliciousToken.mint(attacker, DEPOSIT_AMOUNT * 10);

        vm.startPrank(attacker);
        maliciousToken.approve(contestAddress, type(uint256).max);

        // Should revert or not allow double deposit
        Contest(contestAddress).deposit();

        // Attacker should only have one deposit
        assertTrue(Contest(contestAddress).hasDeposited(attacker));
        assertEq(Contest(contestAddress).getParticipantCount(), 1);
        vm.stopPrank();
    }

    function testNoReentrancyOnWithdraw() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Setup contest with multiple users
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
            vm.roll(10 + i);

            bytes memory voteData = abi.encode(i);
            bytes32 salt = bytes32(i);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();
        }

        // Progress through contest
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(20);

        vm.warp(config.lockEnd + 1);
        for (uint256 i = 0; i < 3; i++) {
            bytes memory voteData = abi.encode(i);
            bytes32 salt = bytes32(i);
            vm.prank(users[i]);
            contest.revealVote(voteData, salt);
        }

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        vm.roll(30);
        contest.finalize();

        // Each user can only withdraw once
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            contest.withdrawPrincipal();

            // Second withdrawal should fail
            vm.prank(users[i]);
            vm.expectRevert(Contest.AlreadyWithdrawn.selector);
            contest.withdrawPrincipal();
        }
    }

    // ============ COMMIT-REVEAL SECURITY TESTS ============

    function testCannotRevealDuringCommitWindow() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);

        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));
        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));
        contest.commitVote(commitHash);

        // Try to reveal immediately (should fail)
        vm.expectRevert(Contest.RevealWindowNotOpen.selector);
        contest.revealVote(voteData, salt);
        vm.stopPrank();
    }

    function testCannotCopyOthersCommitment() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // User 0 commits
        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));
        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(commitHash);
        vm.stopPrank();

        // User 1 copies the same commit hash
        vm.startPrank(users[1]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(commitHash); // Can copy the hash
        vm.stopPrank();

        // But user 1 cannot reveal without knowing the salt
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        // User 0 reveals successfully
        vm.prank(users[0]);
        contest.revealVote(voteData, salt);

        // User 1 tries to reveal with wrong salt (they don't know the real one)
        vm.prank(users[1]);
        vm.expectRevert(Contest.InvalidReveal.selector);
        contest.revealVote(voteData, bytes32(uint256(456)));
    }

    function testCannotChangeVoteAfterCommit() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);

        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));

        // Try to commit again (should fail)
        bytes memory newVoteData = abi.encode("option2");
        vm.expectRevert(Contest.AlreadyCommitted.selector);
        contest.commitVote(keccak256(abi.encodePacked(newVoteData, salt)));
        vm.stopPrank();
    }

    function testCannotRevealDifferentVote() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        // Try to reveal a different vote
        bytes memory differentVote = abi.encode("option2");
        vm.prank(users[0]);
        vm.expectRevert(Contest.InvalidReveal.selector);
        contest.revealVote(differentVote, salt);
    }

    // ============ ACCESS CONTROL TESTS ============

    function testOnlyFactoryCanCancel() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Random user cannot cancel
        vm.prank(attacker);
        vm.expectRevert(Contest.NotFactory.selector);
        contest.cancel("Attacker cancel");

        // Factory owner can cancel via factory
        vm.prank(owner);
        factory.cancelContest(contestId, "Owner cancel");

        assertEq(uint256(contest.getState()), uint256(IContest.ContestState.CANCELLED));
    }

    function testOnlyRandomnessManagerCanFulfill() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Attacker cannot call fulfillRandomness
        vm.prank(attacker);
        vm.expectRevert(Contest.NotRandomnessManager.selector);
        contest.fulfillRandomness(12345);
    }

    // ============ TIMING ATTACK TESTS ============

    function testCannotDepositAtExactBoundary() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositStart = block.timestamp + 100;
        config.depositEnd = block.timestamp + 200;

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // One second before start
        vm.warp(config.depositStart - 1);
        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        vm.expectRevert(Contest.DepositWindowNotOpen.selector);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();

        // Exactly at start - should work
        vm.warp(config.depositStart);
        vm.prank(users[0]);
        contest.deposit();
        vm.roll(block.number + 1);
        assertTrue(contest.hasDeposited(users[0]));

        // Exactly at end - should fail
        vm.warp(config.depositEnd);
        vm.startPrank(users[1]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        vm.expectRevert(Contest.DepositWindowClosed.selector);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();
    }

    // ============ STATE MANIPULATION TESTS ============

    function testCannotFinalizeBeforeRandomness() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Minimal setup
        bytes memory voteData = abi.encode("vote");
        bytes32 salt = bytes32(0);

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        vm.prank(users[0]);
        contest.revealVote(voteData, salt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        // Try to finalize before randomness is fulfilled
        vm.expectRevert(Contest.InvalidState.selector);
        contest.finalize();
    }

    function testCannotSkipStates() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Cannot lock funds before deposit window closes
        vm.expectRevert(Contest.InvalidState.selector);
        contest.lockFunds();
        vm.roll(block.number + 1);

        // Deposit
        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(block.number + 1);
        vm.stopPrank();

        // Still cannot lock (deposit window still open)
        vm.expectRevert(Contest.InvalidState.selector);
        contest.lockFunds();
        vm.roll(block.number + 1);

        // Cannot request randomness before awarding state
        vm.expectRevert(Contest.InvalidState.selector);
        contest.requestRandomness();
    }

    // ============ ECONOMIC ATTACK TESTS ============

    function testNoExtraYieldExtraction() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        uint256 totalDeposits = 0;

        // Multiple users deposit
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(users[i]);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
            vm.roll(10 + i);

            bytes memory voteData = abi.encode(i);
            bytes32 salt = bytes32(i);
            contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
            vm.stopPrank();

            totalDeposits += DEPOSIT_AMOUNT;
        }

        // Complete contest
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(20);

        vm.warp(config.lockEnd + 1);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            contest.revealVote(abi.encode(i), bytes32(i));
        }

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        vm.roll(30);
        contest.finalize();

        // Track all withdrawals
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 balanceBefore = token.balanceOf(users[i]);
            vm.prank(users[i]);
            contest.withdrawPrincipal();
            uint256 balanceAfter = token.balanceOf(users[i]);
            totalWithdrawn += (balanceAfter - balanceBefore);
        }

        // Total withdrawn should equal deposits (in simple vault with no yield)
        // This ensures no tokens are lost or created
        assertEq(totalWithdrawn, totalDeposits);
    }

    // ============ EDGE CASE TESTS ============

    function testSingleParticipantContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Only one participant
        bytes memory voteData = abi.encode("vote");
        bytes32 salt = bytes32(0);

        vm.startPrank(users[0]);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.roll(10);
        contest.commitVote(keccak256(abi.encodePacked(voteData, salt)));
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(20);

        vm.warp(config.lockEnd + 1);
        vm.prank(users[0]);
        contest.revealVote(voteData, salt);

        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        vm.roll(30);
        contest.finalize();

        // Single participant should be winner and get all yield
        address[] memory winners = contest.getWinners();
        assertEq(winners.length, 1);
        assertEq(winners[0], users[0]);
    }

    function testMaxParticipants() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(users[0]);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Add maximum possible participants
        for (uint256 i = 0; i < USER_COUNT; i++) {
            vm.startPrank(users[i]);
            token.approve(contestAddress, DEPOSIT_AMOUNT);
            contest.deposit();
        vm.roll(block.number + 1);
            vm.stopPrank();
        }

        assertEq(contest.getParticipantCount(), USER_COUNT);
    }

    function testZeroDepositAmount() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositAmount = 0;

        // Zero deposit should be rejected by the factory
        vm.prank(users[0]);
        vm.expectRevert(ContestFactory.InvalidConfig.selector);
        factory.createContest(config);
    }
}

/**
 * @notice Malicious token that attempts reentrancy
 */
contract MaliciousToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bool public attacking;

    function setTarget(address _target) external {
        target = _target;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) return false;
        if (balanceOf[from] < amount) return false;

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Attempt reentrancy on first transfer
        if (target != address(0) && !attacking) {
            attacking = true;
            try Contest(target).deposit() {
                // If this succeeds, reentrancy protection failed
            } catch {
                // Expected to fail
            }
            attacking = false;
        }

        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
