// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoYieldStrategy.sol";

/**
 * @title AutoYieldVaultTrustMinTest
 * @notice Coverage for the 2026-04-28 trust-minimization additions:
 *           - setFeeRecipient is set-once
 *           - addStrategy is hard-capped at MAX_STRATEGIES = 5
 *           - addStrategy enforces a 14-day cooldown after the
 *             7-day bootstrap window expires
 *
 *         Code is correct in AutoYieldVault.sol (audit 2026-04-28); these
 *         tests close the test-coverage gap flagged by the readiness audit.
 */
contract AutoYieldVaultTrustMinTest is Test {
    MockERC20 usdc;
    MockAutoYieldStrategy s0;
    MockAutoYieldStrategy s1;
    MockAutoYieldStrategy s2;
    MockAutoYieldStrategy s3;
    MockAutoYieldStrategy s4;
    MockAutoYieldStrategy s5;
    AutoYieldVault vault;

    address owner    = address(0xA11CE);
    address treasury = address(0xBEEF);
    address other    = address(0xCAFE);

    function setUp() public {
        vm.startPrank(owner);
        usdc  = new MockERC20("USD Coin", "USDC", 6);
        s0    = new MockAutoYieldStrategy(address(usdc));
        s1    = new MockAutoYieldStrategy(address(usdc));
        s2    = new MockAutoYieldStrategy(address(usdc));
        s3    = new MockAutoYieldStrategy(address(usdc));
        s4    = new MockAutoYieldStrategy(address(usdc));
        s5    = new MockAutoYieldStrategy(address(usdc));
        vault = new AutoYieldVault(address(usdc), "USDC");
        vm.stopPrank();
    }

    // =========================================================================
    // setFeeRecipient — set-once
    // =========================================================================

    function test_setFeeRecipient_setsOnce() public {
        vm.prank(owner);
        vault.setFeeRecipient(treasury);
        assertEq(vault.feeRecipient(), treasury, "first set must persist");
    }

    function test_setFeeRecipient_revertsOnSecondCall() public {
        vm.prank(owner);
        vault.setFeeRecipient(treasury);

        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.FeeRecipientAlreadySet.selector);
        vault.setFeeRecipient(other);

        // Original recipient must remain after the failed rotation attempt.
        assertEq(vault.feeRecipient(), treasury, "recipient must not change");
    }

    function test_setFeeRecipient_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.InvalidRecipient.selector);
        vault.setFeeRecipient(address(0));
    }

    // =========================================================================
    // addStrategy — MAX_STRATEGIES = 5 cap
    // =========================================================================

    function test_addStrategy_capAtMaxStrategies() public {
        // All five adds happen inside the bootstrap window — no cooldown applies.
        vm.startPrank(owner);
        vault.addStrategy(address(s0), "S0");
        vault.addStrategy(address(s1), "S1");
        vault.addStrategy(address(s2), "S2");
        vault.addStrategy(address(s3), "S3");
        vault.addStrategy(address(s4), "S4");

        assertEq(vault.strategyCount(), vault.MAX_STRATEGIES(), "should be at the cap");

        // Sixth add must revert with TooManyStrategies, regardless of timing.
        vm.expectRevert(AutoYieldVault.TooManyStrategies.selector);
        vault.addStrategy(address(s5), "S5");
        vm.stopPrank();

        assertEq(vault.strategyCount(), vault.MAX_STRATEGIES(), "count unchanged after revert");
    }

    // =========================================================================
    // addStrategy — 14-day cooldown after the 7-day bootstrap window
    // =========================================================================

    function test_addStrategy_cooldownEnforcedAfterBootstrap() public {
        // 1. Add the first strategy inside the bootstrap window. This sets
        //    lastStrategyAddTime so the cooldown gate becomes active once
        //    bootstrapEndTime has passed.
        vm.prank(owner);
        vault.addStrategy(address(s0), "S0");

        // 2. Warp past the bootstrap window. The most recent add was at
        //    block.timestamp before the warp, so we are now inside the
        //    14-day cooldown window post-bootstrap.
        vm.warp(vault.bootstrapEndTime() + 1);

        // 3. Adding before MIN_STRATEGY_ADD_INTERVAL elapses must revert.
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.StrategyAddTooSoon.selector);
        vault.addStrategy(address(s1), "S1-too-soon");

        // 4. Warp forward by the full cooldown — the same call now succeeds.
        vm.warp(vault.lastStrategyAddTime() + vault.MIN_STRATEGY_ADD_INTERVAL());
        vm.prank(owner);
        vault.addStrategy(address(s1), "S1");
        assertEq(vault.strategyCount(), 2, "second strategy should now be registered");

        // 5. A third add immediately after must revert again (cooldown rearms).
        vm.prank(owner);
        vm.expectRevert(AutoYieldVault.StrategyAddTooSoon.selector);
        vault.addStrategy(address(s2), "S2-too-soon");
    }

    function test_addStrategy_bootstrapWindowAllowsMultipleAddsWithoutCooldown() public {
        // Sanity check: the cooldown does NOT apply inside the bootstrap window,
        // so the deployer can wire the initial strategy set in one session.
        vm.startPrank(owner);
        vault.addStrategy(address(s0), "S0");
        vault.addStrategy(address(s1), "S1");
        vault.addStrategy(address(s2), "S2");
        vm.stopPrank();
        assertEq(vault.strategyCount(), 3, "three adds must succeed inside bootstrap");
        assertLt(block.timestamp, vault.bootstrapEndTime(), "should still be in bootstrap window");
    }
}
