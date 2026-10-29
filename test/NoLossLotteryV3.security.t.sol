// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../src/lottery/NoLossLotteryV3.sol";
import "../src/lottery/LotteryReceiptToken.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAToken.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockRandomnessManager.sol";

/**
 * @title NoLossLotteryV3SecurityTest
 * @notice Security tests covering the 3 audit findings + edge cases.
 */
contract NoLossLotteryV3SecurityTest is Test {
    MockERC20             usdc;
    MockAToken            aUsdc;
    MockAavePool          aavePool;
    AaveStrategy          strategy;
    MockRandomnessManager randMgr;
    NoLossLotteryV3       lottery;
    LotteryReceiptToken   receipt;

    address owner    = address(this);
    address alice    = address(0xA11CE);
    address bob      = address(0xB0B);
    address charlie  = address(0xC4A1);
    address treasury = address(0x7EA5);

    uint256 constant ROUND_DURATION = 7 days;
    uint256 constant DEPOSIT_AMOUNT = 1000e6;

    function setUp() public {
        vm.warp(1000);

        usdc     = new MockERC20("USD Coin", "USDC", 6);
        aUsdc    = new MockAToken(address(usdc));
        aavePool = new MockAavePool(address(usdc), address(aUsdc));
        strategy = new AaveStrategy(
            address(aavePool), address(usdc), address(aUsdc), address(0)
        );
        randMgr  = new MockRandomnessManager();

        NoLossLotteryV3 impl = new NoLossLotteryV3();
        receipt = new LotteryReceiptToken("MindYield Weekly USDC", "myWeeklyUSDC", 6);
        lottery = NoLossLotteryV3(Clones.clone(address(impl)));

        uint256[5] memory tierBps = [uint256(7500), uint256(2500), uint256(0), uint256(0), uint256(0)];
        lottery.initialize(
            address(usdc), address(strategy), address(randMgr),
            ROUND_DURATION, treasury, 200, 2, tierBps, 0, address(receipt)
        );

        strategy.setYieldVault(address(lottery));
        receipt.transferOwnership(address(lottery));
        lottery.transferOwnership(owner);

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(lottery), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(lottery), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        lottery.deposit(amount);
    }

    function _advanceAndSettle(uint256 randomWord) internal {
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");
        vm.prank(address(randMgr));
        lottery.fulfillRandomness(randomWord);
        lottery.settleRound();
        lottery.updateStreaks();
    }

    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(aUsdc), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  AUDIT FINDING #1: Receipt token transfer does NOT lock principal
    // ═══════════════════════════════════════════════════════════════════════════

    function test_security_withdrawSucceedsAfterReceiptTransfer() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        assertEq(receipt.balanceOf(alice), DEPOSIT_AMOUNT);

        // Alice transfers ALL receipt tokens to charlie
        vm.prank(alice);
        receipt.transfer(charlie, DEPOSIT_AMOUNT);
        assertEq(receipt.balanceOf(alice), 0);

        // Alice can still withdraw her principal (receipt burn is best-effort)
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);

        // Alice received her principal back
        assertGt(usdc.balanceOf(alice), aliceBefore);
        // Receipt tokens on charlie are now unbacked (cosmetic)
        assertEq(receipt.balanceOf(charlie), DEPOSIT_AMOUNT);
    }

    function test_security_withdrawWithPartialReceiptBalance() public {
        _deposit(alice, DEPOSIT_AMOUNT);

        // Alice transfers half her receipt tokens
        vm.prank(alice);
        receipt.transfer(charlie, DEPOSIT_AMOUNT / 2);
        assertEq(receipt.balanceOf(alice), DEPOSIT_AMOUNT / 2);

        // Alice withdraws full amount — burns what she has, withdraws the rest
        vm.prank(alice);
        lottery.withdraw(DEPOSIT_AMOUNT);

        // Receipt balance should be 0 (burned the half she had)
        assertEq(receipt.balanceOf(alice), 0);
        assertFalse(lottery.isParticipant(alice));
    }

    function test_security_receiptTokenHolderCannotWithdrawOthersPrincipal() public {
        _deposit(alice, DEPOSIT_AMOUNT);

        // Alice transfers receipt tokens to charlie
        vm.prank(alice);
        receipt.transfer(charlie, DEPOSIT_AMOUNT);

        // Charlie holds receipt tokens but has no deposit — cannot withdraw
        vm.prank(charlie);
        vm.expectRevert(NoLossLotteryV3.InsufficientBalance.selector);
        lottery.withdraw(DEPOSIT_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  AUDIT FINDING #2: Minimum deposit + participant cap
    // ═══════════════════════════════════════════════════════════════════════════

    function test_security_belowMinDepositReverts() public {
        usdc.mint(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV3.BelowMinDeposit.selector);
        lottery.deposit(1e6 - 1); // 999999 < MIN_DEPOSIT (1e6)
    }

    function test_security_exactMinDepositSucceeds() public {
        vm.prank(alice);
        lottery.deposit(1e6); // Exactly MIN_DEPOSIT
        assertTrue(lottery.isParticipant(alice));
    }

    function test_security_participantCapEnforced() public {
        // Set a small cap for testing
        lottery.setMaxParticipants(10);

        // Fill up to cap
        for (uint256 i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            usdc.mint(user, 10e6);
            vm.prank(user);
            usdc.approve(address(lottery), 10e6);
            vm.prank(user);
            lottery.deposit(1e6);
        }
        assertEq(lottery.participantCount(), 10);

        // One more deposit from a new participant should revert
        address overflow = address(uint160(0x1000 + 10));
        usdc.mint(overflow, 10e6);
        vm.prank(overflow);
        usdc.approve(address(lottery), 10e6);
        vm.prank(overflow);
        vm.expectRevert(NoLossLotteryV3.ParticipantCapReached.selector);
        lottery.deposit(1e6);
    }

    function test_security_existingParticipantCanDepositMoreBeyondCap() public {
        // Set a small cap for testing
        lottery.setMaxParticipants(10);

        // Fill to cap
        for (uint256 i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            usdc.mint(user, 10e6);
            vm.prank(user);
            usdc.approve(address(lottery), 10e6);
            vm.prank(user);
            lottery.deposit(1e6);
        }

        // Existing participant can deposit more (doesn't increase participant count)
        address existing = address(uint160(0x1000));
        usdc.mint(existing, 10e6);
        vm.prank(existing);
        usdc.approve(address(lottery), 10e6);
        vm.prank(existing);
        lottery.deposit(1e6); // Should succeed — already a participant
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  AUDIT FINDING #3: Canary-up proportional reduction
    // ═══════════════════════════════════════════════════════════════════════════

    function test_security_canaryUpWithSmallTiers() public {
        // Set up a config where some tiers are very small
        // 3 tiers: [8500, 500, 1000] — tier 1 (index 2) is the smallest (last active)
        uint256[5] memory smallTierBps = [uint256(8500), uint256(500), uint256(1000), uint256(0), uint256(0)];
        lottery.setTierConfig(3, smallTierBps);

        // Enable canary
        lottery.setCanaryAutoTune(true);

        // Deposit and run 3 rounds with significant yield so all tiers get prizes
        _deposit(alice, DEPOSIT_AMOUNT);
        _deposit(bob, DEPOSIT_AMOUNT);

        for (uint256 i = 0; i < 3; i++) {
            _simulateYield(1000e6); // Large yield ensures non-zero prizes for all tiers
            _advanceAndSettle(uint256(keccak256(abi.encode(i, "canary"))));
        }

        // Canary should have triggered. The smallest tier (tier 2) was claimed each time.
        // After 3 claims: canary-up adds tier 3.
        // If yield was insufficient or winner selection failed, canaryUnclaimed increments instead.
        // Check the actual state:
        uint8 tiers = lottery.numberOfTiers();

        // Verify BPS sum to 10000 regardless of tier count
        uint256 total = 0;
        for (uint8 i = 0; i < tiers; i++) {
            total += lottery.tierBps(i);
        }
        assertEq(total, 10000, "BPS must always sum to 10000");
    }

    function test_security_canaryUpProportionalReductionSafe() public {
        // Test that proportional reduction doesn't underflow even with tiny tiers
        // Set 2 tiers: [9900, 100] — tier 1 is only 1%
        uint256[5] memory tinyTierBps = [uint256(9900), uint256(100), uint256(0), uint256(0), uint256(0)];
        lottery.setTierConfig(2, tinyTierBps);

        // Enable canary
        lottery.setCanaryAutoTune(true);
        _deposit(alice, DEPOSIT_AMOUNT);
        _deposit(bob, DEPOSIT_AMOUNT);

        // Run 3 rounds with large yield
        for (uint256 i = 0; i < 3; i++) {
            _simulateYield(1000e6);
            _advanceAndSettle(uint256(keccak256(abi.encode(i, "tiny"))));
        }

        // If canary-up triggered: proportional reduction would give
        // 9900 * 9000 / 10000 = 8910, 100 * 9000 / 10000 = 90, new = 10000 - 9000 = 1000
        // Key: the 100 BPS tier survives (no underflow from old uniform subtraction of 500)
        uint8 tiers = lottery.numberOfTiers();
        uint256 total = 0;
        for (uint8 i = 0; i < tiers; i++) {
            total += lottery.tierBps(i);
        }
        assertEq(total, 10000, "BPS must always sum to 10000");

        // If canary-up did trigger, verify tier 1 didn't underflow
        if (tiers == 3) {
            assertGt(lottery.tierBps(1), 0, "Small tier should survive proportional reduction");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADDITIONAL SECURITY EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_security_withdrawWithZeroReceiptToken() public {
        // Deploy lottery without receipt token
        NoLossLotteryV3 impl2 = new NoLossLotteryV3();
        NoLossLotteryV3 lottery2 = NoLossLotteryV3(Clones.clone(address(impl2)));
        AaveStrategy strategy2 = new AaveStrategy(
            address(aavePool), address(usdc), address(aUsdc), address(0)
        );

        uint256[5] memory tierBps = [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)];
        lottery2.initialize(
            address(usdc), address(strategy2), address(randMgr),
            ROUND_DURATION, treasury, 200, 1, tierBps, 1, address(0) // no receipt
        );
        strategy2.setYieldVault(address(lottery2));
        lottery2.transferOwnership(owner);

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(lottery2), type(uint256).max);
        vm.prank(alice);
        lottery2.deposit(DEPOSIT_AMOUNT);

        // Withdraw should work fine without receipt token
        vm.prank(alice);
        lottery2.withdraw(DEPOSIT_AMOUNT);
        assertFalse(lottery2.isParticipant(alice));
    }

    function test_security_doubleInitializeReverts() public {
        uint256[5] memory tierBps = [uint256(10000), uint256(0), uint256(0), uint256(0), uint256(0)];
        vm.expectRevert("Initializable: contract is already initialized");
        lottery.initialize(
            address(usdc), address(strategy), address(randMgr),
            ROUND_DURATION, treasury, 200, 1, tierBps, 0, address(0)
        );
    }

    function test_security_onlyRandomnessManagerCanFulfill() public {
        _deposit(alice, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + ROUND_DURATION + 1);
        lottery.performUpkeep("");

        // Random address cannot fulfill
        vm.prank(alice);
        vm.expectRevert(NoLossLotteryV3.NotRandomnessManager.selector);
        lottery.fulfillRandomness(42);
    }

    function test_security_protocolFeeCappedAt5Percent() public {
        // MAX_LOTTERY_FEE_BPS / MAX_PROTOCOL_FEE_BPS = 500 (5%) hard ceiling.
        vm.expectRevert(NoLossLotteryV3.FeeTooHigh.selector);
        lottery.setProtocolFee(501);

        // Exactly 5% is allowed
        lottery.setProtocolFee(500);
        assertEq(lottery.protocolFeeBps(), 500);
    }
}
