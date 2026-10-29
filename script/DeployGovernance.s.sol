// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../src/governance/Guardian.sol";
import "../src/governance/GovernanceContest.sol";

/**
 * @title DeployGovernance
 * @notice Deploys MindYield's decentralized governance stack: a TimelockController
 *         (48h delay, anyone-can-execute), a Guardian (pause-only, faster reaction),
 *         and optionally a fresh GovernanceContest (DAO voting contract).
 *
 *         Together these replace the need for a Gnosis Safe to be in the hot path:
 *           - Routine config changes go through Timelock → 48h queue → permissionless execute.
 *           - Emergencies go through Guardian → instant pause across all registered contracts.
 *           - Unpause + funding rescues remain owner-only on each contract (the Timelock
 *             is that owner), so even an attacker who compromises the Guardian's key
 *             cannot drain funds — they can only pause.
 *
 * Modes (env-controlled):
 *   default                        — deploy Timelock + Guardian (Phase 1.1).
 *   SKIP_TIMELOCK_GUARDIAN=true    — skip Timelock + Guardian (reuse existing).
 *                                    Useful for Phase 4.5.4 fresh-GovernanceContest.
 *   DEPLOY_GOVERNANCE_CONTEST=true — also deploy GovernanceContest. The
 *                                    `_yieldVault` constructor param is now
 *                                    IGNORED (audit fix 2026-04-26) — script
 *                                    passes address(0).
 *
 * Required env vars (default mode):
 *   MULTISIG_ADDRESS          — Gnosis Safe (PROPOSER on the timelock).
 *                                Recommended: 3/5 multisig with diverse signers.
 *                                ONLY needed for queueing — it does NOT execute.
 *                                Can be replaced with a token-vote contract later.
 *   GUARDIAN_MULTISIG_ADDRESS — EOA or 2/3 Gnosis Safe (owner of Guardian).
 *                                Should be a HOT key for fast emergency response.
 *                                It can ONLY pause, never unpause or move funds.
 *
 * Required env vars (DEPLOY_GOVERNANCE_CONTEST=true):
 *   GOV_DEPOSIT_TOKEN         — ERC20 used for proposal deposits (usually USDC).
 *   GOV_GOVERNANCE_TOKEN      — ERC20 used for voting weight (e.g. MIND token).
 *
 * Optional env vars:
 *   TIMELOCK_DELAY_HOURS      — override the default 48h delay (must be >= 24h, <= 7d).
 *   GOV_VOTING_DELAY          — seconds before voting starts (default 1 day).
 *   GOV_VOTING_PERIOD         — seconds voting is open (default 7 days).
 *   GOV_PROPOSAL_THRESHOLD    — min governance tokens to create a proposal (default 0).
 *   GOV_QUORUM_BPS            — required participation in basis points (default 1000 = 10%).
 *   GOV_MIN_DEPOSIT           — min deposit token to vote (default 0).
 *   GOV_WEIGHTED_VOTING       — true = token-weighted, false = 1-person-1-vote (default true).
 */
contract DeployGovernance is Script {
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 48 hours;

    function run() external {
        bool skipTimelockGuardian = vm.envOr("SKIP_TIMELOCK_GUARDIAN", false);
        bool deployGovernanceContest = vm.envOr("DEPLOY_GOVERNANCE_CONTEST", false);

        require(
            !skipTimelockGuardian || deployGovernanceContest,
            "DG: SKIP_TIMELOCK_GUARDIAN=true requires DEPLOY_GOVERNANCE_CONTEST=true"
        );

        vm.startBroadcast();

        address timelockAddr;
        address guardianAddr;
        if (!skipTimelockGuardian) {
            (timelockAddr, guardianAddr) = _deployTimelockAndGuardian();
        } else {
            console.log("Skipping Timelock + Guardian (SKIP_TIMELOCK_GUARDIAN=true)");
        }

        address governanceContestAddr;
        if (deployGovernanceContest) {
            governanceContestAddr = _deployGovernanceContest();
        }

        vm.stopBroadcast();

        _printSummary(timelockAddr, guardianAddr, governanceContestAddr, skipTimelockGuardian);
    }

    function _deployTimelockAndGuardian() internal returns (address, address) {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address guardianMultisig = vm.envAddress("GUARDIAN_MULTISIG_ADDRESS");
        uint256 delay = vm.envOr("TIMELOCK_DELAY_HOURS", uint256(48)) * 1 hours;
        require(delay >= 24 hours, "DG: delay too short");
        require(delay <= 7 days, "DG: delay too long");

        // PROPOSERS: only the multisig (or a future token-vote contract) can
        // queue an admin action. Multiple proposers are allowed — add later via
        // PROPOSER_ROLE grants if needed.
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;

        // EXECUTORS: address(0) means anyone can execute after the delay.
        // This is the decentralization-critical bit: the multisig that queues
        // an action does NOT need to be online to execute it. After the 48h
        // delay any community member (or a keeper bot) can push it through.
        // If the multisig changes its mind during the delay window, it can
        // call cancel() on the timelock — but it cannot unilaterally bypass
        // the delay or alter the queued payload.
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        // ADMIN role on the timelock: deployer holds it transiently so we can
        // grant CANCELLER_ROLE to the Guardian below, then renounce it in the
        // same tx so the timelock becomes its own only admin (any future role
        // change must itself go through a timelocked proposal). This is the
        // canonical OZ pattern: "pass deployer as admin, configure, renounce".
        TimelockController timelock = new TimelockController(
            delay,
            proposers,
            executors,
            msg.sender
        );

        // Guardian is constructed with the timelock pointer pre-wired so we
        // never need a follow-up tx from the cold guardianMultisig.
        Guardian guardian = new Guardian(guardianMultisig, address(timelock));

        // Grant the Guardian CANCELLER_ROLE on the Timelock so it can veto
        // queued proposals during the 48h delay window. This is the second
        // half of "Option D": Guardian holds pause + cancel, Timelock holds
        // queue + execute. Compromise of either single key cannot lose user
        // funds — they can only DoS or pause.
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        timelock.grantRole(cancellerRole, address(guardian));

        // Renounce the deployer's transient TIMELOCK_ADMIN_ROLE in the same
        // deploy tx. After this point only the Timelock itself can change
        // roles, and only via a timelocked proposal (queued + 48h delay).
        bytes32 adminRole = timelock.TIMELOCK_ADMIN_ROLE();
        timelock.renounceRole(adminRole, msg.sender);

        console.log("TimelockController:    ", address(timelock));
        console.log("  Delay (seconds):     ", delay);
        console.log("  Proposer:            ", multisig);
        console.log("  Executor:            ", address(0), "(anyone after delay)");
        console.log("  Canceller (extra):   ", address(guardian), "(Guardian veto)");
        console.log("Guardian:              ", address(guardian));
        console.log("  Owner:               ", guardianMultisig);
        console.log("  Timelock wired:      ", address(guardian.timelock()));

        return (address(timelock), address(guardian));
    }

    function _deployGovernanceContest() internal returns (address) {
        address depositToken = vm.envAddress("GOV_DEPOSIT_TOKEN");
        address governanceToken = vm.envAddress("GOV_GOVERNANCE_TOKEN");
        require(depositToken != address(0), "DG: GOV_DEPOSIT_TOKEN=0");
        require(governanceToken != address(0), "DG: GOV_GOVERNANCE_TOKEN=0");

        GovernanceContest.GovernanceConfig memory cfg = GovernanceContest.GovernanceConfig({
            votingDelay:        vm.envOr("GOV_VOTING_DELAY", uint256(1 days)),
            votingPeriod:       vm.envOr("GOV_VOTING_PERIOD", uint256(7 days)),
            proposalThreshold:  vm.envOr("GOV_PROPOSAL_THRESHOLD", uint256(0)),
            quorumPercentage:   vm.envOr("GOV_QUORUM_BPS", uint256(1000)),
            minDeposit:         vm.envOr("GOV_MIN_DEPOSIT", uint256(0)),
            weightedVoting:     vm.envOr("GOV_WEIGHTED_VOTING", true)
        });

        // _yieldVault is now IGNORED (audit fix 2026-04-26 — castVote/claimReward
        // no longer route through IAutoYieldVault, deposits held in-contract).
        // Pass address(0) per the runbook.
        GovernanceContest gov = new GovernanceContest(
            depositToken,
            governanceToken,
            address(0),
            cfg
        );

        console.log("GovernanceContest:     ", address(gov));
        console.log("  Deposit token:       ", depositToken);
        console.log("  Governance token:    ", governanceToken);
        console.log("  Voting delay (s):    ", cfg.votingDelay);
        console.log("  Voting period (s):   ", cfg.votingPeriod);
        console.log("  Quorum bps:          ", cfg.quorumPercentage);
        console.log("  Weighted voting:     ", cfg.weightedVoting);

        return address(gov);
    }

    function _printSummary(
        address timelockAddr,
        address guardianAddr,
        address governanceContestAddr,
        bool skipTimelockGuardian
    ) internal pure {
        console.log("");
        console.log("===== Governance Deployed =====");

        if (!skipTimelockGuardian) {
            console.log("");
            console.log("===== Post-Deploy Steps (manual) =====");
            console.log("");
            console.log("1. Transfer ownership of every protocol contract to the TimelockController:");
            console.log("   contract.transferOwnership(", timelockAddr, ")");
            console.log("   Targets:");
            console.log("   - ContestFactoryV2");
            console.log("   - ProbabilityVaultFactory");
            console.log("   - NoLossLotteryV3 (each pool)");
            console.log("   - AutoYieldVault (each token)");
            console.log("   - YieldVault");
            console.log("   - RandomnessManager");
            console.log("   - PlatformFeeConfig");
            console.log("   - AffiliateDistributor");
            console.log("   - OracleRegistry");
            console.log("   - IdentityRegistry / HumanVerificationRegistry");
            console.log("   The Timelock then calls acceptOwnership() in a queued tx.");
            console.log("   (Note: Deploy.s.sol now does this automatically when");
            console.log("    TIMELOCK_ADDRESS env is set.)");
            console.log("");
            console.log("2. Register pausable contracts in the Guardian:");
            console.log("   guardian.addPausable(<NoLossLotteryV3>)");
            console.log("   guardian.addPausable(<AutoYieldVault>)");
            console.log("   guardian.addPausable(<YieldVault>)");
            console.log("   guardian.addPausable(<AffiliateDistributor>)");
            console.log("   guardian.addPausable(<ContestFactoryV2>)        // added next-redeploy");
            console.log("   guardian.addPausable(<ProbabilityVaultFactory>) // added next-redeploy");
            console.log("");
            console.log("3. Set the guardian address on each pausable contract:");
            console.log("   lottery.setGuardian(", guardianAddr, ")");
            console.log("   autoYieldVault.setGuardian(", guardianAddr, ")");
            console.log("   yieldVault.setGuardian(", guardianAddr, ")");
            console.log("   affiliateDistributor.setGuardian(", guardianAddr, ")");
            console.log("   contestFactory.setGuardian(", guardianAddr, ")        // added next-redeploy");
            console.log("   probabilityVaultFactory.setGuardian(", guardianAddr, ") // added next-redeploy");
            console.log("");
            console.log("4. (Optional, irreversible) For contracts that don't need ongoing config,");
            console.log("   call renounceOwnership() instead of transferring (Tier-A contracts):");
            console.log("   - ChainlinkFeedResolver / PolymarketRelayResolver clones");
            console.log("   - PVAutoYieldAdapter (after strategy is configured)");
            console.log("   - BaseStrategy children once their yieldVault is wired");
        }

        if (governanceContestAddr != address(0)) {
            console.log("");
            console.log("===== GovernanceContest deployed =====");
            console.log("Update GOVERNANCE_CONTEST_ADDRESS in .env files:");
            console.log("GOVERNANCE_CONTEST_ADDRESS=", governanceContestAddr);
        }
    }
}
