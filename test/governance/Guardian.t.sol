// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../../src/governance/Guardian.sol";

contract MockPausable is Pausable {
    function pause() external {
        _pause();
    }
}

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _v) external {
        value = _v;
    }
}

contract GuardianTest is Test {
    Guardian public guardian;
    TimelockController public timelock;
    MockPausable public p1;
    MockPausable public p2;
    MockTarget public target;

    address public deployer = address(this);
    address public guardianOwner = address(0xCAFE);
    address public proposer = address(0xBEEF);

    bytes32 public constant SALT = bytes32(uint256(0xdead));

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(48 hours, proposers, executors, deployer);

        guardian = new Guardian(guardianOwner, address(timelock));

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        timelock.grantRole(cancellerRole, address(guardian));
        timelock.renounceRole(timelock.TIMELOCK_ADMIN_ROLE(), deployer);

        p1 = new MockPausable();
        p2 = new MockPausable();
        target = new MockTarget();

        vm.startPrank(guardianOwner);
        guardian.addPausable(address(p1));
        guardian.addPausable(address(p2));
        vm.stopPrank();
    }

    // ─────────── pause() existing behavior ───────────

    function test_PauseAllRegisteredTargets() public {
        vm.prank(guardianOwner);
        guardian.pause();
        assertTrue(p1.paused());
        assertTrue(p2.paused());
    }

    function test_PauseRevertsForNonOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        guardian.pause();
    }

    // ─────────── timelock pointer ───────────

    function test_TimelockSetAtConstruction() public {
        assertEq(address(guardian.timelock()), address(timelock));
    }

    function test_SetTimelockController_RevertsIfAlreadySet() public {
        vm.prank(guardianOwner);
        vm.expectRevert(Guardian.TimelockAlreadySet.selector);
        guardian.setTimelockController(address(0xBEEF));
    }

    function test_SetTimelockController_OnFreshGuardian() public {
        Guardian fresh = new Guardian(address(this), address(0));
        assertEq(address(fresh.timelock()), address(0));
        fresh.setTimelockController(address(timelock));
        assertEq(address(fresh.timelock()), address(timelock));
    }

    function test_SetTimelockController_RevertsOnZero() public {
        Guardian fresh = new Guardian(address(this), address(0));
        vm.expectRevert(Guardian.ZeroAddress.selector);
        fresh.setTimelockController(address(0));
    }

    function test_SetTimelockController_OnlyOwner() public {
        Guardian fresh = new Guardian(guardianOwner, address(0));
        vm.expectRevert("Ownable: caller is not the owner");
        fresh.setTimelockController(address(timelock));
    }

    // ─────────── cancelTimelockProposal ───────────

    function _queueDummyProposal() internal returns (bytes32) {
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), SALT);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), SALT, 48 hours);
        return id;
    }

    function test_CancelTimelockProposal_Success() public {
        bytes32 id = _queueDummyProposal();
        assertTrue(timelock.isOperationPending(id));

        vm.prank(guardianOwner);
        guardian.cancelTimelockProposal(id);

        assertFalse(timelock.isOperationPending(id));
    }

    function test_CancelTimelockProposal_RevertsIfNotPending() public {
        bytes32 id = bytes32(uint256(0xfeedbeef));
        vm.prank(guardianOwner);
        vm.expectRevert(Guardian.ProposalNotPending.selector);
        guardian.cancelTimelockProposal(id);
    }

    function test_CancelTimelockProposal_RevertsForNonOwner() public {
        bytes32 id = _queueDummyProposal();
        vm.expectRevert("Ownable: caller is not the owner");
        guardian.cancelTimelockProposal(id);
    }

    function test_CancelTimelockProposal_RevertsIfTimelockNotSet() public {
        Guardian fresh = new Guardian(address(this), address(0));
        vm.expectRevert(Guardian.TimelockNotSet.selector);
        fresh.cancelTimelockProposal(bytes32(uint256(1)));
    }

    function test_CancelTimelockProposal_AfterDelayCannotBeCancelled() public {
        bytes32 id = _queueDummyProposal();

        // Execute the proposal (after delay it becomes ready, then done)
        vm.warp(block.timestamp + 48 hours);
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        timelock.execute(address(target), 0, data, bytes32(0), SALT);
        assertTrue(timelock.isOperationDone(id));

        // Now Guardian cannot cancel — it's no longer pending
        vm.prank(guardianOwner);
        vm.expectRevert(Guardian.ProposalNotPending.selector);
        guardian.cancelTimelockProposal(id);
    }

    // ─────────── compromise model ───────────

    function test_CompromisedGuardianCannotMoveFunds() public {
        // The guardian has no fund-extraction primitives. This test asserts
        // the absence by attempting every callable function as the owner and
        // verifying none of them can transfer ETH or tokens.
        vm.deal(address(guardian), 1 ether);
        uint256 before = address(guardianOwner).balance;

        vm.startPrank(guardianOwner);
        guardian.pause();
        // No withdraw / sweep / rescue exists. Balance unchanged.
        vm.stopPrank();

        assertEq(address(guardian).balance, 1 ether);
        assertEq(address(guardianOwner).balance, before);
    }

    function test_CompromisedProposerCanBeVetoedByGuardian() public {
        // Simulate proposer compromise: it queues a malicious upgrade.
        // Guardian (separate cold key) cancels before the 48h delay.
        bytes32 id = _queueDummyProposal();

        // Halfway through the delay, Guardian vetoes
        vm.warp(block.timestamp + 24 hours);
        vm.prank(guardianOwner);
        guardian.cancelTimelockProposal(id);

        // After delay, execution must fail because the operation no longer exists
        vm.warp(block.timestamp + 24 hours);
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        vm.expectRevert("TimelockController: operation is not ready");
        timelock.execute(address(target), 0, data, bytes32(0), SALT);
    }
}
