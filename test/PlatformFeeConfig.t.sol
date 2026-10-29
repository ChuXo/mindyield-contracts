// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PlatformFeeConfig.sol";

contract PlatformFeeConfigTest is Test {
    PlatformFeeConfig cfg;
    address owner = address(0xA);
    address treasury = address(0xB);
    address rando = address(0xC);

    function setUp() public {
        vm.prank(owner);
        cfg = new PlatformFeeConfig(treasury);
    }

    function test_defaults() public {
        assertEq(cfg.feeRecipient(), treasury);
        assertEq(cfg.masterEnabled(), false);
        assertEq(cfg.contestYieldBps(), 0);
        assertEq(cfg.lotteryYieldBps(), 0);
        assertEq(cfg.contestCreationFeeUsdc(), 0);
        assertEq(cfg.vaultPerformanceBps(), 0);
        assertEq(cfg.vaultManagementBps(), 0);
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(PlatformFeeConfig.InvalidRecipient.selector);
        new PlatformFeeConfig(address(0));
    }

    function test_killSwitchOverridesNonZeroFees() public {
        vm.startPrank(owner);
        cfg.setContestYieldBps(500);
        cfg.setLotteryYieldBps(700);
        cfg.setVaultPerformanceBps(1000);
        vm.stopPrank();

        // Master still off → all views must return 0
        assertEq(cfg.contestYieldBps(), 0);
        assertEq(cfg.lotteryYieldBps(), 0);
        assertEq(cfg.vaultPerformanceBps(), 0);

        // Raw values still readable
        (uint256 y, uint256 l,, uint256 vp,) = cfg.getRaw();
        assertEq(y, 500);
        assertEq(l, 700);
        assertEq(vp, 1000);

        // Flip on
        vm.prank(owner);
        cfg.setMasterEnabled(true);
        assertEq(cfg.contestYieldBps(), 500);
        assertEq(cfg.lotteryYieldBps(), 700);
        assertEq(cfg.vaultPerformanceBps(), 1000);
    }

    function test_capsEnforced() public {
        vm.startPrank(owner);
        vm.expectRevert(PlatformFeeConfig.FeeTooHigh.selector);
        cfg.setContestYieldBps(2_001);

        vm.expectRevert(PlatformFeeConfig.FeeTooHigh.selector);
        cfg.setLotteryYieldBps(2_001);

        vm.expectRevert(PlatformFeeConfig.FeeTooHigh.selector);
        cfg.setVaultPerformanceBps(2_001);

        vm.expectRevert(PlatformFeeConfig.FeeTooHigh.selector);
        cfg.setVaultManagementBps(201);
        vm.stopPrank();
    }

    function test_onlyOwnerCanWrite() public {
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        cfg.setMasterEnabled(true);

        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        cfg.setContestYieldBps(100);
    }

    /// @notice Fee values are now applied via individual setters only (setAll() was
    ///         removed because it let an owner change the master switch and the fee
    ///         recipient atomically, defeating per-setter timelocks). This test
    ///         documents the per-setter equivalent that any caller should use.
    function test_individualSettersApplyAllValues() public {
        vm.startPrank(owner);
        cfg.setMasterEnabled(true);
        cfg.setContestYieldBps(100);
        cfg.setLotteryYieldBps(200);
        cfg.setContestCreationFeeUsdc(5e6);
        cfg.setVaultPerformanceBps(1500);
        cfg.setVaultManagementBps(100);
        vm.stopPrank();

        assertEq(cfg.masterEnabled(), true);
        assertEq(cfg.contestYieldBps(), 100);
        assertEq(cfg.lotteryYieldBps(), 200);
        assertEq(cfg.contestCreationFeeUsdc(), 5e6);
        assertEq(cfg.vaultPerformanceBps(), 1500);
        assertEq(cfg.vaultManagementBps(), 100);
    }

    function test_feeRecipient_isImmutable() public view {
        // Post-2026-04-28: setFeeRecipient was removed; feeRecipient is constructor-immutable.
        // Confirms a compromised owner cannot redirect the protocol-fee target.
        assertEq(cfg.feeRecipient(), treasury);
    }
}
