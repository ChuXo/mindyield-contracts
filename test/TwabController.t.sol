// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lottery/TwabController.sol";

/**
 * @title TwabControllerHarness
 * @notice Exposes internal functions for testing.
 */
contract TwabControllerHarness is TwabController {
    function increaseBalance(address user, uint96 amount) external {
        _increaseBalance(user, amount);
    }

    function decreaseBalance(address user, uint96 amount) external {
        _decreaseBalance(user, amount);
    }
}

/**
 * @title TwabControllerTest
 * @notice Unit tests for TwabController ring buffer and TWAB queries.
 */
contract TwabControllerTest is Test {
    TwabControllerHarness twab;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() public {
        twab = new TwabControllerHarness();
        vm.warp(1000); // Start at timestamp 1000
    }

    // ─── Basic Balance ──────────────────────────────────────────────────────

    function test_initialBalanceIsZero() public view {
        assertEq(twab.balanceOf(alice), 0);
        assertEq(twab.totalSupply(), 0);
    }

    function test_increaseBalance() public {
        twab.increaseBalance(alice, 100);
        assertEq(twab.balanceOf(alice), 100);
        assertEq(twab.totalSupply(), 100);
    }

    function test_decreaseBalance() public {
        twab.increaseBalance(alice, 100);
        twab.decreaseBalance(alice, 40);
        assertEq(twab.balanceOf(alice), 60);
        assertEq(twab.totalSupply(), 60);
    }

    function test_decreaseBalance_revertsOnUnderflow() public {
        twab.increaseBalance(alice, 50);
        vm.expectRevert("TwabController: insufficient balance");
        twab.decreaseBalance(alice, 51);
    }

    function test_multipleUsers() public {
        twab.increaseBalance(alice, 100);
        twab.increaseBalance(bob, 200);
        assertEq(twab.balanceOf(alice), 100);
        assertEq(twab.balanceOf(bob), 200);
        assertEq(twab.totalSupply(), 300);
    }

    // ─── Observations ───────────────────────────────────────────────────────

    function test_observationCountIncrementsOnNewTimestamp() public {
        twab.increaseBalance(alice, 100);
        assertEq(twab.getObservationCount(alice), 1);

        vm.warp(2000);
        twab.increaseBalance(alice, 50);
        assertEq(twab.getObservationCount(alice), 2);
    }

    function test_sameTimestampDoesNotAddNewObservation() public {
        twab.increaseBalance(alice, 100);
        twab.increaseBalance(alice, 50);
        // Same block → only 1 observation
        assertEq(twab.getObservationCount(alice), 1);
        assertEq(twab.balanceOf(alice), 150);
    }

    // ─── TWAB Queries ───────────────────────────────────────────────────────

    function test_twab_constantBalance() public {
        // Alice deposits 100 at t=1000
        twab.increaseBalance(alice, 100);

        // Query TWAB from t=1000 to t=2000 → should be 100
        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 1000, 2000);
        assertEq(avg, 100);
    }

    function test_twab_halfAndHalf() public {
        // Alice deposits 100 at t=1000
        twab.increaseBalance(alice, 100);

        // Alice deposits another 100 at t=1500 (total 200)
        vm.warp(1500);
        twab.increaseBalance(alice, 100);

        // Query TWAB from t=1000 to t=2000
        // Average: (100 * 500 + 200 * 500) / 1000 = 150
        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 1000, 2000);
        assertEq(avg, 150);
    }

    function test_twab_partialWithdraw() public {
        // Alice deposits 200 at t=1000
        twab.increaseBalance(alice, 200);

        // Alice withdraws 100 at t=1500 (balance → 100)
        vm.warp(1500);
        twab.decreaseBalance(alice, 100);

        // TWAB from t=1000 to t=2000: (200*500 + 100*500) / 1000 = 150
        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 1000, 2000);
        assertEq(avg, 150);
    }

    function test_twab_beforeDeposit() public {
        // Deposit at t=1000
        twab.increaseBalance(alice, 100);

        // Query TWAB for period before deposit → 0
        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 500, 900);
        assertEq(avg, 0);
    }

    function test_twab_querySpanningDeposit() public {
        // Alice deposits 100 at t=1000
        twab.increaseBalance(alice, 100);

        // TWAB from t=500 to t=1500
        // Before t=1000: balance 0 (500 seconds)
        // After  t=1000: balance 100 (500 seconds)
        // Average: (0*500 + 100*500) / 1000 = 50
        vm.warp(1500);
        uint256 avg = twab.getTwab(alice, 500, 1500);
        assertEq(avg, 50);
    }

    function test_twab_totalSupply() public {
        twab.increaseBalance(alice, 100);
        twab.increaseBalance(bob, 200);

        vm.warp(2000);
        uint256 totalTwab = twab.getTotalSupplyTwab(1000, 2000);
        assertEq(totalTwab, 300);
    }

    function test_twab_revertsEndBeforeStart() public {
        twab.increaseBalance(alice, 100);
        vm.expectRevert("TwabController: end <= start");
        twab.getTwab(alice, 2000, 1000);
    }

    function test_twab_revertsEqualStartEnd() public {
        twab.increaseBalance(alice, 100);
        vm.expectRevert("TwabController: end <= start");
        twab.getTwab(alice, 1000, 1000);
    }

    // ─── Ring Buffer Wraparound ─────────────────────────────────────────────

    function test_ringBufferWraparound() public {
        // Fill the ring buffer past MAX_CARDINALITY (256)
        for (uint256 i = 0; i < 260; i++) {
            vm.warp(1000 + i * 10);
            twab.increaseBalance(alice, 1);
        }

        // Should still work correctly with only latest 256 observations
        assertEq(twab.balanceOf(alice), 260);
        assertEq(twab.getObservationCount(alice), 256);

        // TWAB over the most recent range should still be valid
        vm.warp(1000 + 260 * 10);
        uint256 avg = twab.getTwab(alice, 1000 + 250 * 10, 1000 + 260 * 10);
        // Balance was increasing by 1 every 10s; just verify it's > 0
        assertGt(avg, 0);
    }

    // ─── Multiple Balance Changes in One Period ─────────────────────────────

    function test_twab_multipleChanges() public {
        // t=1000: deposit 100
        twab.increaseBalance(alice, 100);

        // t=1250: deposit 100 more (total 200)
        vm.warp(1250);
        twab.increaseBalance(alice, 100);

        // t=1500: withdraw 50 (total 150)
        vm.warp(1500);
        twab.decreaseBalance(alice, 50);

        // t=1750: deposit 50 (total 200)
        vm.warp(1750);
        twab.increaseBalance(alice, 50);

        // Query TWAB from t=1000 to t=2000
        // 100*250 + 200*250 + 150*250 + 200*250 = 25000+50000+37500+50000 = 162500
        // 162500 / 1000 = 162
        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 1000, 2000);
        assertEq(avg, 162); // integer division: 162500 / 1000 = 162
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────────

    function testFuzz_balanceConsistency(uint96 depositA, uint96 depositB) public {
        vm.assume(depositA > 0 && depositB > 0);
        // Prevent overflow
        vm.assume(uint256(depositA) + uint256(depositB) <= type(uint96).max);

        twab.increaseBalance(alice, depositA);
        twab.increaseBalance(bob, depositB);

        assertEq(twab.totalSupply(), uint96(uint256(depositA) + uint256(depositB)));
        assertEq(twab.balanceOf(alice), depositA);
        assertEq(twab.balanceOf(bob), depositB);
    }

    function testFuzz_twabBoundedByBalance(uint96 amount) public {
        vm.assume(amount > 0);
        twab.increaseBalance(alice, amount);

        vm.warp(2000);
        uint256 avg = twab.getTwab(alice, 1000, 2000);
        assertEq(avg, uint256(amount));
    }
}
