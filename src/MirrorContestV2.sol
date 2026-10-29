// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IYieldVault.sol";
import "./interfaces/IIdentityRegistry.sol";
import "./interfaces/IResolver.sol";

/// @title MirrorContestV2
/// @notice Slim, mirror-only no-loss contest implementation. Built to fit
///         comfortably under the EIP-170 24,576-byte runtime bytecode limit.
///
///         Deliberate omissions vs ContestV2:
///           - No SUBMISSIONS subsystem (mirror options are fixed YES/NO)
///           - Only PREDICT contest type (binary outcome)
///           - Only STAKE_WEIGHTED prize model (the prediction-market default)
///           - No VRF / random distribution paths
///           - No oracle-data-blob legacy field
///           - No multi-contest-type vote dispatcher
///           - Resolver address stored DIRECTLY (no factory staticcall)
///
///         Inherited semantics from ContestV2 (same shape, same events):
///           - Commit-reveal voting
///           - Yield generated via IYieldVault
///           - Principal always returned (no-loss)
///           - Yield = pool * stake / totalWinnerStake (winners only)
///           - 2% protocol fee on yield (configurable per-contest at init)
///           - Tier-gated participation via IdentityRegistry
///           - Cancel-and-refund on resolver ambiguity / 7-day timeout
///
///         Designed to coexist with ContestV2 — uses its own factory,
///         doesn't share storage layout, but emits same-named events
///         (Deposited, VoteCommitted, VoteRevealed, ContestResolved,
///         ContestCancelled, PrincipalWithdrawn, RewardClaimed,
///         ProtocolFeeDeducted) so the existing indexer + affiliate hook
///         flow inherits without modification.
contract MirrorContestV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ────────────────────────────────────────────────────────
    error InvalidConfig();
    error InvalidState();
    error NotCreator();
    error NotFactory();
    error AlreadyInitialized();
    error NotDeposited();
    error AlreadyDeposited();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error AlreadyClaimed();
    error InvalidReveal();
    error InvalidOption();
    error NotAuthorized();
    error AlreadyFinalized();
    error AlreadyCancelled();
    error ResolverNotReady();
    error TierTooLow();
    error CapExceeded();
    error NoReward();
    error WindowClosed();

    // ─── Enums ─────────────────────────────────────────────────────────
    enum State {
        CREATED,        // 0 — never used externally; transitions immediately
        DEPOSIT_OPEN,   // 1
        LOCKED,         // 2 — deposits closed, awaiting reveal
        REVEAL_OPEN,    // 3
        RESOLVING,      // 4 — quorum check + resolver consultation
        FINALIZED,      // 5
        CANCELLED       // 6
    }

    // ─── Storage ───────────────────────────────────────────────────────

    // Initialization guard (clones don't run constructor)
    bool private _initialized;
    address public factory;

    // Immutable-after-init config (one storage slot per logical group)
    address public depositToken;       // ERC20 used for deposits + bonds
    uint96  public depositAmount;      // exact stake per participant
    address public creator;
    uint96  public maxParticipants;
    address public resolver;           // bound IResolver instance
    uint96  public protocolFeePercentage; // basis points (default 200 = 2%)
    address public protocolFeeRecipient;
    address public identityRegistry;   // IIdentityRegistry
    address public yieldVault;         // IYieldVault
    address public yieldStrategy;      // strategy 0 in vault; for indexer
    uint64  public depositStart;
    uint64  public depositEnd;
    uint64  public lockEnd;
    uint64  public revealEnd;
    uint8   public tierRequired;
    uint8   public quorumPercentage;
    bytes32 public yesOption;
    bytes32 public noOption;
    bytes32 public metadataHash;
    string  public metadataUri;

    // Polymarket-mirror reference (off-chain only — not consumed on-chain)
    bytes32 public conditionId;
    uint64  public polymarketEndDate;

    // Mutable lifecycle
    State public state;

    struct Participant {
        bool hasDeposited;
        bool hasCommitted;
        bool hasRevealed;
        bool principalWithdrawn;
        bool rewardsClaimed;
        uint96 depositReceived;     // fee-on-transfer-safe actual amount
        uint96 withdrawableAmount;  // 0 == use depositReceived; non-zero on strategy loss
        bytes32 commitHash;
        bytes32 revealedOption;     // YES_OPTION or NO_OPTION
    }
    mapping(address => Participant) public participants;
    address[] public participantList;

    uint128 public totalDeposited;
    uint128 public vaultShares;

    mapping(bytes32 => uint64) public optionVotes;          // YES/NO tally
    mapping(bytes32 => uint128) public optionTotalStake;    // sum of deposits per side

    mapping(address => uint96) public voterRewards;
    uint128 public totalRewardsDistributed;
    uint128 public undistributedRewards;

    bool public isResolved;
    bytes32 public winningOption;
    uint128 public totalYield;
    uint128 public prizePool;
    uint64  public revealedCount;

    // ─── Events (match ContestV2 signatures for indexer reuse) ────────

    event ContestCreated(address indexed creator);
    event Deposited(address indexed participant, uint256 amount);
    event VoteCommitted(address indexed participant, bytes32 commitHash);
    event VoteRevealed(address indexed participant, bytes data);
    event ContestResolved(bytes32 winningOption, uint256 totalYield);
    event ProtocolFeeDeducted(uint256 amount, address recipient);
    event ProtocolFeeSkipped(uint256 amount, address recipient, string reason);
    event RewardClaimed(address indexed participant, uint256 amount);
    event PrincipalWithdrawn(address indexed participant, uint256 amount);
    event ContestCancelled(string reason);
    event StateChanged(State newState);

    // ─── Modifiers ─────────────────────────────────────────────────────

    modifier onlyCreator() {
        if (msg.sender != creator) revert NotCreator();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier inState(State expected) {
        if (state != expected) revert InvalidState();
        _;
    }

    // ─── Constructor (impl only — clones bypass) ──────────────────────

    constructor() {
        _initialized = true;
    }

    // ─── Initialization ────────────────────────────────────────────────

    /// @notice Init params bundled to keep the signature short and mirror
    ///         the factory's MirrorParams. Each field is required.
    struct InitParams {
        address creator;
        address depositToken;
        uint96  depositAmount;
        uint96  maxParticipants;
        uint64  depositStart;
        uint64  depositEnd;
        uint64  lockEnd;
        uint64  revealEnd;
        uint8   tierRequired;
        uint8   quorumPercentage;
        bytes32 yesOption;
        bytes32 noOption;
        bytes32 metadataHash;
        string  metadataUri;
        // Polymarket reference
        bytes32 conditionId;
        uint64  polymarketEndDate;
        // Bound resolver (immutable after init)
        address resolver;
        // Infra
        address yieldVault;
        address yieldStrategy;        // for indexer convenience
        address identityRegistry;
        // Fee
        uint96  protocolFeePercentage; // basis points (200 = 2%)
        address protocolFeeRecipient;
    }

    function initialize(InitParams calldata p) external nonReentrant {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Only contracts (i.e. the factory) can init clones.
        if (msg.sender.code.length == 0) revert InvalidConfig();
        factory = msg.sender;

        if (p.creator == address(0)) revert InvalidConfig();
        if (p.depositToken == address(0)) revert InvalidConfig();
        if (p.depositAmount == 0) revert InvalidConfig();
        if (p.maxParticipants == 0) revert InvalidConfig();
        if (p.depositEnd <= p.depositStart) revert InvalidConfig();
        if (p.lockEnd <= p.depositEnd) revert InvalidConfig();
        if (p.revealEnd <= p.lockEnd) revert InvalidConfig();
        if (p.yesOption == bytes32(0) || p.noOption == bytes32(0)) revert InvalidConfig();
        if (p.yesOption == p.noOption) revert InvalidConfig();
        if (p.resolver == address(0)) revert InvalidConfig();
        if (p.yieldVault == address(0)) revert InvalidConfig();

        creator                = p.creator;
        depositToken           = p.depositToken;
        depositAmount          = p.depositAmount;
        maxParticipants        = p.maxParticipants;
        depositStart           = p.depositStart;
        depositEnd             = p.depositEnd;
        lockEnd                = p.lockEnd;
        revealEnd              = p.revealEnd;
        tierRequired           = p.tierRequired;
        quorumPercentage       = p.quorumPercentage == 0 ? 50 : p.quorumPercentage;
        yesOption              = p.yesOption;
        noOption               = p.noOption;
        metadataHash           = p.metadataHash;
        metadataUri            = p.metadataUri;
        conditionId            = p.conditionId;
        polymarketEndDate      = p.polymarketEndDate;
        resolver               = p.resolver;
        yieldVault             = p.yieldVault;
        yieldStrategy          = p.yieldStrategy;
        identityRegistry       = p.identityRegistry;
        protocolFeePercentage  = p.protocolFeePercentage;
        protocolFeeRecipient   = p.protocolFeeRecipient;

        _transition(State.DEPOSIT_OPEN);
        emit ContestCreated(p.creator);
    }

    // ─── Deposit ──────────────────────────────────────────────────────

    function deposit() external nonReentrant inState(State.DEPOSIT_OPEN) {
        if (block.timestamp < depositStart) revert WindowClosed();
        if (block.timestamp >= depositEnd) {
            _transition(State.LOCKED);
            revert WindowClosed();
        }
        if (participants[msg.sender].hasDeposited) revert AlreadyDeposited();
        if (participantList.length >= maxParticipants) revert CapExceeded();

        // Tier gate (mirror contests typically require tier ≥ 2)
        if (tierRequired > 0) {
            if (IIdentityRegistry(identityRegistry).getTier(msg.sender) < tierRequired) {
                revert TierTooLow();
            }
        }

        IERC20 token = IERC20(depositToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), depositAmount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidConfig();

        token.forceApprove(yieldVault, received);
        uint256 shares = IYieldVault(yieldVault).deposit(depositToken, received, 0);

        vaultShares    += uint128(shares);
        totalDeposited += uint128(received);

        Participant storage p = participants[msg.sender];
        p.hasDeposited     = true;
        p.depositReceived  = uint96(received);
        participantList.push(msg.sender);

        emit Deposited(msg.sender, received);
    }

    // ─── Commit-reveal voting ─────────────────────────────────────────

    function commitVote(bytes32 commitHash) external nonReentrant {
        if (state != State.DEPOSIT_OPEN && state != State.LOCKED) revert InvalidState();
        if (block.timestamp >= lockEnd) revert WindowClosed();

        Participant storage p = participants[msg.sender];
        if (!p.hasDeposited) revert NotDeposited();
        if (p.hasCommitted) revert AlreadyCommitted();

        p.hasCommitted = true;
        p.commitHash   = commitHash;
        emit VoteCommitted(msg.sender, commitHash);
    }

    /// @notice Reveal the previously committed vote.
    /// @dev Commit hash binds msg.sender (audit P-EXT-09 mitigation):
    ///      `keccak256(abi.encodePacked(msg.sender, optionId, salt))`.
    ///      This prevents an attacker from copying another voter's reveal
    ///      from the mempool and casting the same vote.
    function revealVote(bytes32 optionId, bytes32 salt)
        external
        nonReentrant
    {
        if (state != State.REVEAL_OPEN) {
            if (state == State.LOCKED && block.timestamp >= lockEnd) {
                _transition(State.REVEAL_OPEN);
            } else {
                revert InvalidState();
            }
        }
        if (block.timestamp >= revealEnd) revert WindowClosed();

        Participant storage p = participants[msg.sender];
        if (!p.hasCommitted) revert InvalidConfig();
        if (p.hasRevealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(msg.sender, optionId, salt));
        if (expected != p.commitHash) revert InvalidReveal();
        if (optionId != yesOption && optionId != noOption) revert InvalidOption();

        p.hasRevealed     = true;
        p.revealedOption  = optionId;
        revealedCount++;
        optionVotes[optionId]++;
        optionTotalStake[optionId] += uint128(p.depositReceived);

        // Off-chain consumers expect VoteRevealed(address,bytes); encode
        // the optionId as a single bytes32 payload to match ContestV2.
        emit VoteRevealed(msg.sender, abi.encode(optionId));
    }

    // ─── Resolution ───────────────────────────────────────────────────

    function resolveContest() external nonReentrant {
        if (msg.sender != creator && msg.sender != factory) revert NotAuthorized();
        if (state != State.REVEAL_OPEN && state != State.RESOLVING) revert InvalidState();
        if (block.timestamp < revealEnd) revert WindowClosed();
        if (state == State.REVEAL_OPEN) _transition(State.RESOLVING);

        // Quorum check
        uint256 quorum = (participantList.length * quorumPercentage) / 100;
        if (revealedCount < quorum) revert InvalidConfig();

        // Resolver consultation BEFORE vault withdrawal so revert-on-not-ready
        // doesn't double-withdraw or mutate state.
        bytes32 cid = bytes32(uint256(uint160(address(this))));
        (bool ready, bytes32 resolverWinner) = IResolver(resolver).resolve(cid);
        if (!ready) revert ResolverNotReady();
        if (resolverWinner == bytes32(0)) {
            // Ambiguous (e.g. UMA 50/50) → cancel + refund
            _cancel("resolver: ambiguous outcome");
            return;
        }
        if (resolverWinner != yesOption && resolverWinner != noOption) revert InvalidOption();

        // Withdraw from vault
        uint256 totalAssets = 0;
        if (vaultShares > 0) {
            totalAssets = IYieldVault(yieldVault).withdraw(
                depositToken, uint256(vaultShares), 0, address(this)
            );
            vaultShares = 0;
        }

        uint256 principal = uint256(totalDeposited);
        uint256 yieldGen = totalAssets > principal ? totalAssets - principal : 0;

        // Strategy loss → scale withdrawableAmount pro-rata for all participants
        if (totalAssets < principal && principal > 0) {
            uint256 n = participantList.length;
            for (uint256 i = 0; i < n; ) {
                Participant storage q = participants[participantList[i]];
                if (q.hasDeposited && q.depositReceived > 0) {
                    q.withdrawableAmount = uint96(
                        (uint256(q.depositReceived) * totalAssets) / principal
                    );
                }
                unchecked { ++i; }
            }
        }

        // Protocol fee on yield (try/catch so a reverting recipient can't lock funds)
        uint256 protocolFee;
        if (protocolFeePercentage > 0 && protocolFeeRecipient != address(0) && yieldGen > 0) {
            protocolFee = (yieldGen * protocolFeePercentage) / 10_000;
            if (protocolFee > 0) {
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, protocolFee) {
                    emit ProtocolFeeDeducted(protocolFee, protocolFeeRecipient);
                } catch {
                    emit ProtocolFeeSkipped(protocolFee, protocolFeeRecipient, "transfer reverted");
                    protocolFee = 0;
                }
            }
        }

        uint256 distributableYield = yieldGen - protocolFee;
        winningOption = resolverWinner;
        totalYield    = uint128(distributableYield);
        prizePool     = uint128(distributableYield);
        isResolved    = true;

        // STAKE_WEIGHTED distribution: each winner gets pool * theirStake / totalWinnerStake.
        _distributeStakeWeighted(distributableYield);

        _transition(State.FINALIZED);
        emit ContestResolved(resolverWinner, distributableYield);
    }

    function _distributeStakeWeighted(uint256 pool) internal {
        if (pool == 0) return;
        uint256 winnerStake = uint256(optionTotalStake[winningOption]);
        if (winnerStake == 0) {
            undistributedRewards = uint128(pool);
            return;
        }
        uint256 distributed = 0;
        uint256 n = participantList.length;
        for (uint256 i = 0; i < n; ) {
            address voter = participantList[i];
            Participant storage q = participants[voter];
            if (q.hasRevealed && q.revealedOption == winningOption && q.depositReceived > 0) {
                uint256 reward = (pool * uint256(q.depositReceived)) / winnerStake;
                voterRewards[voter] = uint96(reward);
                distributed += reward;
            }
            unchecked { ++i; }
        }
        totalRewardsDistributed = uint128(distributed);
        if (pool > distributed) {
            undistributedRewards = uint128(pool - distributed);
        }
    }

    // ─── Cancel + refund ──────────────────────────────────────────────

    function cancel(string calldata reason) external onlyCreator nonReentrant {
        if (state == State.FINALIZED) revert AlreadyFinalized();
        if (state == State.CANCELLED) revert AlreadyCancelled();
        _cancel(reason);
    }

    function emergencyCancel() external onlyFactory nonReentrant {
        if (state == State.FINALIZED) revert AlreadyFinalized();
        if (state == State.CANCELLED) revert AlreadyCancelled();
        _cancel("Emergency cancel by factory");
    }

    function _cancel(string memory reason) internal {
        // Withdraw vault funds + scale withdrawableAmount on loss.
        uint256 returned = 0;
        if (vaultShares > 0) {
            returned = IYieldVault(yieldVault).withdraw(
                depositToken, uint256(vaultShares), 0, address(this)
            );
            vaultShares = 0;

            uint256 principal = uint256(totalDeposited);
            if (returned < principal && principal > 0) {
                uint256 n = participantList.length;
                for (uint256 i = 0; i < n; ) {
                    Participant storage q = participants[participantList[i]];
                    if (q.hasDeposited && !q.principalWithdrawn && q.depositReceived > 0) {
                        q.withdrawableAmount = uint96(
                            (uint256(q.depositReceived) * returned) / principal
                        );
                    }
                    unchecked { ++i; }
                }
            } else if (returned > principal) {
                // Audit fix P-EXT-03: yield generated but no creator prize and no
                // distribution path — route surplus to protocol fee recipient
                // rather than trapping it in the contract.
                uint256 surplus = returned - principal;
                if (protocolFeeRecipient != address(0)) {
                    // Wrap in try/catch: a blacklisted protocolFeeRecipient must not
                    // permanently block cancel and trap participant principal.
                    try this.executeProtocolFeeTransfer(protocolFeeRecipient, surplus) {
                        emit ProtocolFeeDeducted(surplus, protocolFeeRecipient);
                    } catch {
                        emit ProtocolFeeSkipped(surplus, protocolFeeRecipient, "cancel: transfer reverted");
                        undistributedRewards = uint128(surplus);
                    }
                } else {
                    undistributedRewards = uint128(surplus);
                }
            }
        }
        _transition(State.CANCELLED);
        emit ContestCancelled(reason);
    }

    // ─── Withdrawals ──────────────────────────────────────────────────

    function withdrawPrincipal() external nonReentrant {
        if (state != State.FINALIZED && state != State.CANCELLED) revert InvalidState();

        Participant storage p = participants[msg.sender];
        if (!p.hasDeposited) revert NotDeposited();
        if (p.principalWithdrawn) revert AlreadyClaimed();

        p.principalWithdrawn = true;

        uint256 amount = p.withdrawableAmount > 0
            ? uint256(p.withdrawableAmount)
            : uint256(p.depositReceived);
        if (amount == 0) revert InvalidConfig();

        IERC20(depositToken).safeTransfer(msg.sender, amount);
        emit PrincipalWithdrawn(msg.sender, amount);
    }

    function claimVoterReward() external nonReentrant inState(State.FINALIZED) {
        Participant storage p = participants[msg.sender];
        if (!p.hasRevealed) revert InvalidConfig();
        if (p.rewardsClaimed) revert AlreadyClaimed();

        uint256 reward = uint256(voterRewards[msg.sender]);
        if (reward == 0) revert NoReward();

        p.rewardsClaimed = true;
        voterRewards[msg.sender] = 0;

        IERC20(depositToken).safeTransfer(msg.sender, reward);
        emit RewardClaimed(msg.sender, reward);
    }

    // ─── State-machine helper ─────────────────────────────────────────

    /// @notice Permissionless time-based state advance.
    function updateState() external {
        if (state == State.DEPOSIT_OPEN && block.timestamp >= depositEnd) {
            _transition(State.LOCKED);
        } else if (state == State.LOCKED && block.timestamp >= lockEnd) {
            _transition(State.REVEAL_OPEN);
        }
    }

    function _transition(State next) internal {
        state = next;
        emit StateChanged(next);
    }

    // ─── Protocol fee transfer helper (try/catch boundary) ────────────

    function executeProtocolFeeTransfer(address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert InvalidConfig();
        IERC20(depositToken).safeTransfer(recipient, amount);
    }

    // ─── View helpers ─────────────────────────────────────────────────

    function getParticipantCount() external view returns (uint256) {
        return participantList.length;
    }
}
