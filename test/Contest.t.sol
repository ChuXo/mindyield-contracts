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

contract ContestTest is Test {
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
    address public charlie = address(5);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock contracts
        token = new MockERC20("USDC", "USDC", 18);
        vrfCoordinator = new MockVRFCoordinator();

        // Deploy core contracts
        dataRegistry = new DataRegistry(address(this));
        identityRegistry = new IdentityRegistry();
        yieldVault = new YieldVault();
        randomnessManager = new RandomnessManager(
            address(vrfCoordinator),
            bytes32(0),
            1
        );

        vrfCoordinator.setRandomnessManager(address(randomnessManager));

        // Deploy factory
        factory = new ContestFactory(
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            address(dataRegistry),
            treasury
        );

        // Add a yield strategy
        yieldVault.addStrategy(address(0)); // Simple hold strategy

        // Register factory as authorized to call randomnessManager.addAllowedRequester()
        randomnessManager.setAuthorizedFactory(address(factory), true);

        vm.stopPrank();

        // Mint tokens to users
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);
        token.mint(charlie, 1000e18);
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

    function testCreateContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);

        assertFalse(contestId == bytes32(0));
        assertFalse(contestAddress == address(0));
        assertEq(factory.getContest(contestId), contestAddress);
        assertEq(factory.getContestCount(), 1);
    }

    function testDeposit() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Bob deposits
        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.stopPrank();

        assertTrue(contest.hasDeposited(bob));
        assertEq(contest.getParticipantCount(), 1);
        assertEq(token.balanceOf(contestAddress), DEPOSIT_AMOUNT);
    }

    function testDepositFailsBeforeWindow() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositStart = block.timestamp + 1 hours;

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        vm.expectRevert(Contest.DepositWindowNotOpen.selector);
        contest.deposit();
        vm.stopPrank();
    }

    function testDepositFailsAfterWindow() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Fast forward past deposit window
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        vm.expectRevert(Contest.DepositWindowClosed.selector);
        contest.deposit();
        vm.stopPrank();
    }

    function testCommitReveal() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Bob deposits
        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();

        // Bob commits vote
        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));
        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));

        contest.commitVote(commitHash);
        assertTrue(contest.hasCommitted(bob));
        vm.stopPrank();

        // Lock funds
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        // Fast forward to reveal window
        vm.warp(config.lockEnd + 1);

        // Bob reveals
        vm.prank(bob);
        contest.revealVote(voteData, salt);
        assertTrue(contest.hasRevealed(bob));
    }

    function testInvalidRevealFails() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();

        bytes memory voteData = abi.encode("option1");
        bytes32 salt = bytes32(uint256(123));
        bytes32 commitHash = keccak256(abi.encodePacked(voteData, salt));
        contest.commitVote(commitHash);
        vm.stopPrank();

        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);
        vm.warp(config.lockEnd + 1);

        // Try to reveal with wrong salt
        vm.prank(bob);
        vm.expectRevert(Contest.InvalidReveal.selector);
        contest.revealVote(voteData, bytes32(uint256(456)));
    }

    function testFullContestFlow() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Register contest for randomness
        vm.prank(owner);
        randomnessManager.addAllowedRequester(contestAddress);

        // Multiple users deposit
        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.stopPrank();

        // Advance block for flash loan protection
        vm.roll(block.number + 1);

        // Users commit
        bytes memory voteData1 = abi.encode("option1");
        bytes32 salt1 = bytes32(uint256(111));
        vm.prank(bob);
        contest.commitVote(keccak256(abi.encodePacked(voteData1, salt1)));

        bytes memory voteData2 = abi.encode("option2");
        bytes32 salt2 = bytes32(uint256(222));
        vm.prank(charlie);
        contest.commitVote(keccak256(abi.encodePacked(voteData2, salt2)));

        // Lock funds
        vm.warp(config.depositEnd + 1);
        contest.lockFunds();
        vm.roll(block.number + 1);

        // Reveal
        vm.warp(config.lockEnd + 1);
        vm.prank(bob);
        contest.revealVote(voteData1, salt1);
        vm.prank(charlie);
        contest.revealVote(voteData2, salt2);

        // Request randomness
        vm.warp(config.revealEnd + 1);
        contest.requestRandomness();

        // Fulfill randomness (picks winner based on random word)
        // Warp past MANUAL_FULFILL_DELAY (1 hour) + VRF_TIMEOUT (2 hours)
        vm.warp(block.timestamp + 4 hours + 7200);
        vm.prank(owner);
        randomnessManager.manualFulfill(1, 12345);

        // Finalize
        contest.finalize();
        assertEq(uint256(contest.getState()), uint256(IContest.ContestState.FINALIZED));

        // Participants withdraw principal
        uint256 bobBalanceBefore = token.balanceOf(bob);
        vm.prank(bob);
        contest.withdrawPrincipal();
        uint256 bobBalanceAfter = token.balanceOf(bob);

        // Bob should get at least his principal back
        assertGe(bobBalanceAfter, bobBalanceBefore + DEPOSIT_AMOUNT);
    }

    function testTierGating() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.tierRequired = 1;

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        // Bob tries to deposit without tier
        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        vm.expectRevert(Contest.InsufficientTier.selector);
        contest.deposit();
        vm.stopPrank();

        // Give Bob tier 1
        vm.prank(owner);
        identityRegistry.setTier(bob, 1);

        // Now Bob can deposit
        vm.startPrank(bob);
        contest.deposit();
        vm.stopPrank();

        assertTrue(contest.hasDeposited(bob));
    }

    function testCannotDoubleDeposit() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT * 2);
        contest.deposit();

        vm.expectRevert(Contest.AlreadyDeposited.selector);
        contest.deposit();
        vm.stopPrank();
    }

    function testCancelContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);
        Contest contest = Contest(contestAddress);

        vm.startPrank(bob);
        token.approve(contestAddress, DEPOSIT_AMOUNT);
        contest.deposit();
        vm.stopPrank();

        // Owner cancels
        vm.prank(owner);
        factory.cancelContest(contestId, "Testing cancellation");

        assertEq(uint256(contest.getState()), uint256(IContest.ContestState.CANCELLED));

        // Bob can withdraw principal
        vm.prank(bob);
        contest.withdrawPrincipal();
        assertEq(token.balanceOf(bob), 1000e18);
    }
}
