// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IPausable {
    function pause() external;
}

interface ITimelockCanceller {
    function cancel(bytes32 id) external;
    function isOperationPending(bytes32 id) external view returns (bool);
}

/**
 * @title Guardian
 * @notice Emergency response contract. Owner is a separate cold/independent key
 *         from the Timelock proposer (the "hot" key). Guardian holds two powers:
 *           1. pause()                    — halt all registered IPausable targets.
 *           2. cancelTimelockProposal()   — veto a queued TimelockController action
 *                                            before its delay elapses (requires
 *                                            CANCELLER_ROLE on the Timelock).
 *
 *         These powers exist so the system stays safe under EOA-key compromise:
 *           - If the proposer key is compromised, the attacker queues a
 *             malicious admin action. Guardian (separate key, kept cold) cancels
 *             it within the 48h timelock window and pauses affected products.
 *           - If the Guardian key is compromised, the attacker can pause and/or
 *             cancel proposals (DoS) but cannot move funds, change parameters,
 *             unpause, or extract value. The Timelock owner can rotate the
 *             Guardian role on each Pausable via setGuardian(...).
 *
 *         Trade-off: a compromised Guardian can DoS governance by cancelling
 *         every queued proposal. Mitigate by giving the Guardian role to a
 *         physically-separated cold key (different person, different machine).
 */
contract Guardian is Ownable2Step {
    uint256 public constant MAX_PAUSABLES = 20;

    address[] private _pausables;
    mapping(address => bool) public isPausable;

    /// @notice TimelockController this Guardian can veto. Settable once by owner.
    ITimelockCanceller public timelock;

    event PausableAdded(address indexed target);
    event PausableRemoved(address indexed target);
    event EmergencyPauseExecuted(address indexed triggeredBy, uint256 pausedCount);
    event TimelockSet(address indexed timelock);
    event TimelockProposalCancelled(bytes32 indexed id, address indexed triggeredBy);

    error TooManyPausables();
    error AlreadyRegistered();
    error NotRegistered();
    error TimelockAlreadySet();
    error TimelockNotSet();
    error ZeroAddress();
    error ProposalNotPending();

    constructor(address _owner, address _timelock) Ownable() {
        // Optionally wire the timelock at construction. Passing address(0)
        // is supported for retrofit deploys; the owner must then call
        // setTimelockController(...) before cancellations work.
        if (_timelock != address(0)) {
            timelock = ITimelockCanceller(_timelock);
            emit TimelockSet(_timelock);
        }
        if (_owner != address(0) && _owner != msg.sender) {
            _transferOwnership(_owner);
        }
    }

    function addPausable(address target) external onlyOwner {
        if (_pausables.length >= MAX_PAUSABLES) revert TooManyPausables();
        if (isPausable[target]) revert AlreadyRegistered();
        isPausable[target] = true;
        _pausables.push(target);
        emit PausableAdded(target);
    }

    function removePausable(address target) external onlyOwner {
        if (!isPausable[target]) revert NotRegistered();
        isPausable[target] = false;
        for (uint256 i = 0; i < _pausables.length; i++) {
            if (_pausables[i] == target) {
                _pausables[i] = _pausables[_pausables.length - 1];
                _pausables.pop();
                break;
            }
        }
        emit PausableRemoved(target);
    }

    function pause() external onlyOwner {
        uint256 pausedCount = 0;
        for (uint256 i = 0; i < _pausables.length; i++) {
            try IPausable(_pausables[i]).pause() {
                pausedCount++;
            } catch {}
        }
        emit EmergencyPauseExecuted(msg.sender, pausedCount);
    }

    function getPausables() external view returns (address[] memory) {
        return _pausables;
    }

    /**
     * @notice Wire this Guardian to the TimelockController it can veto.
     *         One-shot: once set, cannot be changed. This is intentional —
     *         a mutable timelock pointer would let a compromised owner
     *         redirect cancel attempts to a sham contract.
     */
    function setTimelockController(address _timelock) external onlyOwner {
        if (_timelock == address(0)) revert ZeroAddress();
        if (address(timelock) != address(0)) revert TimelockAlreadySet();
        timelock = ITimelockCanceller(_timelock);
        emit TimelockSet(_timelock);
    }

    /**
     * @notice Cancel a queued Timelock proposal. Requires this Guardian to
     *         hold CANCELLER_ROLE on the Timelock (granted at deploy time
     *         in DeployGovernance.s.sol).
     * @dev    Reverts if the proposal is not currently pending. Cancelling a
     *         non-pending proposal would silently succeed on the OZ Timelock,
     *         which we want to surface as a clear error.
     */
    function cancelTimelockProposal(bytes32 id) external onlyOwner {
        if (address(timelock) == address(0)) revert TimelockNotSet();
        if (!timelock.isOperationPending(id)) revert ProposalNotPending();
        timelock.cancel(id);
        emit TimelockProposalCancelled(id, msg.sender);
    }
}
