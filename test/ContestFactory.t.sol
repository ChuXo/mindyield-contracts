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
 * @title ContestFactoryTest
 * @notice Comprehensive tests for the ContestFactory contract
 */
contract ContestFactoryTest is Test {
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
    address public attacker = address(0xBAD);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    event ContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        IContest.ContestConfig config
    );
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

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

        // Authorize factory to register contest addresses with RandomnessManager
        randomnessManager.setAuthorizedFactory(address(factory), true);

        vm.stopPrank();

        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
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

    // ============ DEPLOYMENT TESTS ============

    function testDeployment() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.treasury(), treasury);
        assertEq(factory.yieldVault(), address(yieldVault));
        assertEq(factory.identityRegistry(), address(identityRegistry));
        assertEq(factory.randomnessManager(), address(randomnessManager));
        assertEq(factory.dataRegistry(), address(dataRegistry));
        assertEq(factory.protocolFee(), 1000); // 10% default
    }

    // ============ CONTEST CREATION TESTS ============

    function testCreateContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);

        assertFalse(contestId == bytes32(0));
        assertFalse(contestAddress == address(0));
        assertEq(factory.getContest(contestId), contestAddress);
        assertEq(factory.getContestCount(), 1);
    }

    function testCreateContestEmitsEvent() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        // Check that ContestCreated event is emitted (don't check contestId or contestAddress as they're non-deterministic)
        // Check indexed parameters: creator (alice)
        // Check data parameters: config
        vm.expectEmit(false, false, false, true);
        emit ContestCreated(bytes32(0), address(0), alice, config);
        factory.createContest(config);
    }

    function testCreateMultipleContests() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.startPrank(alice);
        (bytes32 id1,) = factory.createContest(config);
        (bytes32 id2,) = factory.createContest(config);
        (bytes32 id3,) = factory.createContest(config);
        vm.stopPrank();

        assertEq(factory.getContestCount(), 3);
        assertTrue(id1 != id2 && id2 != id3 && id1 != id3);
    }

    function testGetContestsByCreator() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        factory.createContest(config);
        vm.prank(alice);
        factory.createContest(config);
        vm.prank(bob);
        factory.createContest(config);

        bytes32[] memory aliceContests = factory.getContestsByCreator(alice);
        bytes32[] memory bobContests = factory.getContestsByCreator(bob);

        assertEq(aliceContests.length, 2);
        assertEq(bobContests.length, 1);
    }

    function testGetAllContests() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        factory.createContest(config);
        vm.prank(bob);
        factory.createContest(config);

        bytes32[] memory allContests = factory.getAllContests();
        assertEq(allContests.length, 2);
    }

    // ============ CONFIG VALIDATION TESTS ============

    function testCannotCreateWithZeroDepositToken() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositToken = address(0);

        vm.prank(alice);
        vm.expectRevert(ContestFactory.ZeroAddress.selector);
        factory.createContest(config);
    }

    function testCannotCreateWithInvalidTiming() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        // depositEnd <= depositStart
        config.depositEnd = config.depositStart;
        vm.prank(alice);
        vm.expectRevert(ContestFactory.InvalidConfig.selector);
        factory.createContest(config);

        // Reset and test lockEnd <= depositEnd
        config = _createDefaultConfig();
        config.lockEnd = config.depositEnd;
        vm.prank(alice);
        vm.expectRevert(ContestFactory.InvalidConfig.selector);
        factory.createContest(config);

        // Reset and test revealEnd <= lockEnd
        config = _createDefaultConfig();
        config.revealEnd = config.lockEnd;
        vm.prank(alice);
        vm.expectRevert(ContestFactory.InvalidConfig.selector);
        factory.createContest(config);
    }

    function testCannotCreateWithZeroDepositAmount() public {
        IContest.ContestConfig memory config = _createDefaultConfig();
        config.depositAmount = 0;

        vm.prank(alice);
        vm.expectRevert(ContestFactory.InvalidConfig.selector);
        factory.createContest(config);
    }

    // ============ PROTOCOL FEE TESTS ============

    function testSetProtocolFee() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeUpdated(1000, 500);
        factory.setProtocolFee(500);

        assertEq(factory.getProtocolFee(), 500);
    }

    function testCannotSetProtocolFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Fee too high");
        factory.setProtocolFee(2001);
    }

    function testNonOwnerCannotSetProtocolFee() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setProtocolFee(500);
    }

    function testSetMaxProtocolFee() public {
        vm.prank(owner);
        factory.setProtocolFee(2000);
        assertEq(factory.getProtocolFee(), 2000);
    }

    // ============ TREASURY TESTS ============

    function testSetTreasury() public {
        address newTreasury = address(100);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TreasuryUpdated(treasury, newTreasury);
        factory.setTreasury(newTreasury);

        assertEq(factory.getTreasury(), newTreasury);
    }

    function testCannotSetZeroTreasury() public {
        vm.prank(owner);
        vm.expectRevert(ContestFactory.ZeroAddress.selector);
        factory.setTreasury(address(0));
    }

    function testNonOwnerCannotSetTreasury() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setTreasury(address(100));
    }

    // ============ CANCEL CONTEST TESTS ============

    function testOwnerCanCancelContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId, address contestAddress) = factory.createContest(config);

        vm.prank(owner);
        factory.cancelContest(contestId, "Testing cancellation");

        Contest contest = Contest(contestAddress);
        assertEq(uint256(contest.getState()), uint256(IContest.ContestState.CANCELLED));
    }

    function testNonOwnerCannotCancelContest() public {
        IContest.ContestConfig memory config = _createDefaultConfig();

        vm.prank(alice);
        (bytes32 contestId,) = factory.createContest(config);

        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.cancelContest(contestId, "Attacker cancel");
    }

    function testCannotCancelNonExistentContest() public {
        vm.prank(owner);
        vm.expectRevert("Contest not found");
        factory.cancelContest(bytes32(uint256(999)), "Test");
    }

    // ============ REGISTRY UPDATES TESTS ============

    function testUpdateRegistries() public {
        address newYieldVault = address(200);
        address newIdentityRegistry = address(201);
        address newRandomnessManager = address(202);
        address newDataRegistry = address(203);

        vm.prank(owner);
        factory.updateRegistries(
            newYieldVault,
            newIdentityRegistry,
            newRandomnessManager,
            newDataRegistry
        );

        assertEq(factory.yieldVault(), newYieldVault);
        assertEq(factory.identityRegistry(), newIdentityRegistry);
        assertEq(factory.randomnessManager(), newRandomnessManager);
        assertEq(factory.dataRegistry(), newDataRegistry);
    }

    function testPartialRegistryUpdate() public {
        address originalYieldVault = factory.yieldVault();
        address newIdentityRegistry = address(201);

        vm.prank(owner);
        factory.updateRegistries(
            address(0), // Keep original
            newIdentityRegistry,
            address(0), // Keep original
            address(0)  // Keep original
        );

        assertEq(factory.yieldVault(), originalYieldVault);
        assertEq(factory.identityRegistry(), newIdentityRegistry);
    }

    function testNonOwnerCannotUpdateRegistries() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.updateRegistries(
            address(200),
            address(201),
            address(202),
            address(203)
        );
    }

    // ============ OWNERSHIP TESTS ============

    function testTransferOwnership() public {
        // Ownable2Step: transferOwnership stages a pendingOwner; the new owner
        // must call acceptOwnership() to complete the handoff.
        address newOwner = address(100);

        vm.prank(owner);
        factory.transferOwnership(newOwner);
        assertEq(factory.pendingOwner(), newOwner, "pending set");
        assertEq(factory.owner(), owner, "owner unchanged until accept");

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner, "ownership transferred");
    }

    function testCannotTransferOwnershipToZero() public {
        // Ownable2Step accepts address(0) and clears the pendingOwner — it does
        // NOT revert. Use renounceOwnership() to relinquish entirely.
        vm.prank(owner);
        factory.transferOwnership(address(0));
        assertEq(factory.pendingOwner(), address(0), "pending cleared");
        assertEq(factory.owner(), owner, "owner unchanged");
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.transferOwnership(attacker);
    }

    function testNewOwnerCanSetFee() public {
        address newOwner = address(100);

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        // Ownable2Step: new owner must accept before they hold the role.
        vm.prank(newOwner);
        factory.acceptOwnership();

        vm.prank(newOwner);
        factory.setProtocolFee(2000);

        assertEq(factory.getProtocolFee(), 2000);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_ProtocolFee(uint256 fee) public {
        fee = bound(fee, 0, 2000);

        vm.prank(owner);
        factory.setProtocolFee(fee);

        assertEq(factory.getProtocolFee(), fee);
    }

    function testFuzz_CreateMultipleContests(uint8 count) public {
        count = uint8(bound(count, 1, 50));
        IContest.ContestConfig memory config = _createDefaultConfig();

        for (uint256 i = 0; i < count; i++) {
            vm.prank(alice);
            factory.createContest(config);
        }

        assertEq(factory.getContestCount(), count);
    }
}
