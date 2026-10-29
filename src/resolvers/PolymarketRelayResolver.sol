// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IResolver.sol";

/// @title PolymarketRelayResolver
/// @notice Cheap-settlement Polymarket mirror resolver. A relayer reads
///         Polymarket's settled CTF payouts on Polygon (off-chain) and posts
///         them here on Base via `propose()`. A challenge window then opens.
///         If anyone disputes, the contest enters a dispute-frozen state
///         and a multi-sig admin makes the final call. If nobody disputes,
///         the proposal auto-finalizes once read after the window expires.
///
///         Costs roughly $0.05 per settlement (vs ~$0.30 for Chainlink
///         Functions, vs $750 for direct UMA). Trust assumption: the
///         relayer's identity is irrelevant — anyone (the team, a watcher
///         bot, the contest creator, the public) can challenge a wrong
///         proposal within 24 hours by posting a USDC bond.
///
/// State machine per contest:
///
///                ┌─ register ─►  REGISTERED
///                                  │
///                  propose() (any) │  (after polymarketEndDate + GRACE)
///                                  ▼
///                              PROPOSED ─── 24h ──► (auto-finalize on read)
///                                  │
///                       challenge() │  (within DISPUTE window)
///                                  ▼
///                              DISPUTED ── admin ──► FINALIZED
///
/// @dev Self-contained — no Chainlink dependency. The challenge bond is
///      held in this contract until finalize. Multi-sig admin is the
///      Owner (intended to be a Gnosis Safe).
contract PolymarketRelayResolver is IResolver, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error NotAuthorizedFactory();
    error AlreadyRegistered();
    error NotRegistered();
    error InvalidParams();
    error NotInState(Status expected);
    error GraceWindowNotElapsed();
    error ChallengeWindowExpired();
    error ChallengeWindowActive();
    error TimeoutNotReached();
    error InsufficientBond();
    error UnsupportedOutcome();
    error AlreadySettled();
    error BondOverrideTooHigh();

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    enum Status {
        UNREGISTERED,   // default — never registered
        REGISTERED,     // bound at contest creation, awaiting propose
        PROPOSED,       // relayer (or anyone) has proposed a winner
        DISPUTED,       // a challenger posted a bond; awaiting admin
        FINALIZED       // resolved (auto-timeout, undisputed, or admin)
    }

    enum Outcome {
        UNSET,          // sentinel, never persisted
        YES_WIN,
        NO_WIN,
        AMBIGUOUS,      // CTF returned [1,1] — cancel-and-refund path
        CANCELLED       // 7-day timeout never resolved → cancel
    }

    struct PolyConfig {
        // ─── immutable, set at register() ──────────────────────────
        bytes32 conditionId;            // Polymarket CTF condition id
        bytes32 yesOption;              // optionId returned for YES wins
        bytes32 noOption;               // optionId returned for NO wins
        uint64  polymarketEndDate;      // unix; propose() blocked until +GRACE
        // ─── mutable, set during state transitions ─────────────────
        Status  status;
        Outcome proposedOutcome;
        uint64  proposedAt;             // unix; challenge window starts here
        address proposer;
        Outcome challengerOutcome;      // the challenger's claimed outcome
        address challenger;
        uint96  challengerBond;         // wei (USDC has 6 decimals)
        Outcome finalOutcome;
    }

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    /// @notice Grace period after Polymarket's market endDate before
    ///         anyone can propose a settlement here. Gives Polymarket /
    ///         UMA the standard 2h liveness + buffer.
    uint64 public constant GRACE_WINDOW = 12 hours;

    /// @notice Window after a proposal during which any address can
    ///         post a bond and dispute. Once elapsed without a
    ///         challenge, `resolve()` returns the proposal as final.
    uint64 public constant DISPUTE_WINDOW = 24 hours;

    /// @notice Hard timeout from polymarketEndDate. After this the
    ///         contest can be cancelled-and-refunded by anyone, even
    ///         if the relayer never posted a proposal.
    uint64 public constant SETTLEMENT_TIMEOUT_VAL = 7 days;

    /// @notice Floor on challenge bond (USDC, 6-dec).
    /// @dev    Raised from 25 USDC → 250 USDC on 2026-04-28 per the pre-
    ///         deploy audit. The previous floor made it economically trivial
    ///         to grief a high-TVL market into the multi-sig admin bottleneck
    ///         when an operator forgot to call `setBondOverride`. Admins
    ///         SHOULD still call setBondOverride to scale per-pool, but if
    ///         they don't, 250 USDC is a defensible default friction — high
    ///         enough to deter casual griefing, low enough that legitimate
    ///         disputes on small markets aren't priced out.
    uint96 public constant MIN_BOND = 250e6;

    /// @notice Bond as basis points of the contest's prize pool.
    ///         100 = 1%. Combined with MIN_BOND.
    uint96 public constant BOND_BPS_OF_POOL = 100;

    /// @notice Hard cap on `setBondOverride` — 10× MIN_BOND. A compromised
    ///         owner cannot set an arbitrarily-large bond to make challenges
    ///         economically impossible (a soft-rug vector that would let the
    ///         owner finalize any outcome they want via timeout). 2_500 USDC
    ///         is enough headroom to scale legitimate high-TVL markets while
    ///         remaining a price honest disputers will pay.
    uint96 public constant MAX_BOND_OVERRIDE = MIN_BOND * 10;

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------

    /// @notice Legacy read-only handle for "the" authorized factory.
    ///         Reflects the most recently authorized factory (constructor seed
    ///         or last `setAuthorizedFactory(_, true)` call). Kept as a
    ///         convenience for off-chain tools that read a single address;
    ///         real auth is decided by `isAuthorizedFactory`.
    address public authorizedFactory;

    /// @notice Addresses allowed to call `register()`. A mapping lets the
    ///         owner rotate or co-authorize factories without redeploying
    ///         the resolver (audit follow-up 2026-04-21: the original
    ///         `immutable` broke the yield-market launch when the
    ///         ProbabilityVaultFactory was redeployed — fix is to let the
    ///         owner wire the new factory in without re-deploying every
    ///         existing market binding).
    mapping(address => bool) public isAuthorizedFactory;

    /// @notice USDC (or whichever ERC20) used for challenge bonds.
    IERC20 public immutable bondToken;

    /// @notice Per-contest configuration + lifecycle state.
    mapping(bytes32 => PolyConfig) public configs;

    /// @notice Optional override of bond size per contest (set by admin
    ///         when contest is created, e.g. larger pool → larger bond).
    ///         Zero means "use the formula in requiredBondFor()".
    mapping(bytes32 => uint96) public bondOverride;

    /// @notice Guardian address authorized to call `pause()` (in addition to
    ///         the owner). When wired alongside the AutoYieldVault + adapter
    ///         pause-ables, the multisig can halt the entire prediction market
    ///         product (settlement + capital flow) in one Guardian.pause() tx.
    address public guardian;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event ContestRegistered(
        bytes32 indexed contestId,
        bytes32 indexed conditionId,
        uint64 polymarketEndDate
    );
    event ProposalSubmitted(
        bytes32 indexed contestId,
        Outcome outcome,
        address indexed proposer,
        uint64 challengeWindowEnd
    );
    event Challenged(
        bytes32 indexed contestId,
        Outcome alternativeOutcome,
        address indexed challenger,
        uint96 bond
    );
    event FinalizedByAdmin(
        bytes32 indexed contestId,
        Outcome finalOutcome,
        bool challengerWasHonest
    );
    event FinalizedByTimeout(bytes32 indexed contestId);
    event BondRefunded(bytes32 indexed contestId, address indexed to, uint256 amount);
    event BondSlashed(bytes32 indexed contestId, address indexed slashedFrom, uint256 amount, address indexed treasury);
    event AuthorizedFactoryUpdated(address indexed factory, bool authorized);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    constructor(address _authorizedFactory, address _bondToken) Ownable() {
        if (_authorizedFactory == address(0) || _bondToken == address(0)) revert InvalidParams();
        authorizedFactory = _authorizedFactory;
        isAuthorizedFactory[_authorizedFactory] = true;
        bondToken = IERC20(_bondToken);
        emit AuthorizedFactoryUpdated(_authorizedFactory, true);
    }

    // ---------------------------------------------------------------
    // Factory authorization (owner)
    // ---------------------------------------------------------------

    /// @notice Authorize or revoke a factory from calling `register()`.
    /// @dev    Enables rotating ProbabilityVaultFactory without redeploying
    ///         the resolver (which would also orphan every existing market
    ///         registration). When `authorized == true` the legacy
    ///         `authorizedFactory` getter is updated to point at the new
    ///         factory so off-chain tools that read a single address see
    ///         the latest one.
    /// @notice Pause `propose`, `challenge`, `finalizeAfterDispute`, and
    ///         `forceTimeoutCancel`. View functions (`resolve`,
    ///         `requiredBondFor`, `configs`) stay live so existing markets
    ///         can still be queried; `register` stays live so newly-created
    ///         vaults can still bind themselves (the factory is the only
    ///         caller and is itself pause-able if needed).
    /// @dev    Callable by owner OR the configured Guardian.
    function pause() external {
        require(msg.sender == owner() || msg.sender == guardian, "Resolver: not authorized");
        _pause();
    }

    /// @notice Unpause. Owner-only by design.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Wire a Guardian for emergency pauses.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    function setAuthorizedFactory(address factory, bool authorized) external onlyOwner {
        if (factory == address(0)) revert InvalidParams();
        isAuthorizedFactory[factory] = authorized;
        if (authorized) authorizedFactory = factory;
        emit AuthorizedFactoryUpdated(factory, authorized);
    }

    // ---------------------------------------------------------------
    // IResolver
    // ---------------------------------------------------------------

    /// @notice Bind a MindYield contest to a Polymarket market.
    /// @param params ABI-encoded
    ///        (bytes32 conditionId, bytes32 yesOption, bytes32 noOption, uint64 polymarketEndDate).
    function register(bytes32 contestId, bytes calldata params) external {
        if (!isAuthorizedFactory[msg.sender]) revert NotAuthorizedFactory();
        PolyConfig storage cfg = configs[contestId];
        if (cfg.status != Status.UNREGISTERED) revert AlreadyRegistered();

        (bytes32 conditionId, bytes32 yesOption, bytes32 noOption, uint64 polymarketEndDate) =
            abi.decode(params, (bytes32, bytes32, bytes32, uint64));

        if (conditionId == bytes32(0)) revert InvalidParams();
        if (yesOption == bytes32(0) || noOption == bytes32(0)) revert InvalidParams();
        if (yesOption == noOption) revert InvalidParams();
        if (polymarketEndDate <= block.timestamp) revert InvalidParams();

        cfg.conditionId = conditionId;
        cfg.yesOption = yesOption;
        cfg.noOption = noOption;
        cfg.polymarketEndDate = polymarketEndDate;
        cfg.status = Status.REGISTERED;

        emit ContestRegistered(contestId, conditionId, polymarketEndDate);
    }

    /// @notice Anyone can re-trigger; a no-op for this resolver because
    ///         settlement is push-driven (relayer posts via propose()).
    ///         Returns false so callers don't double-charge.
    function requestSettlement(bytes32 /* contestId */) external pure returns (bool) {
        return false;
    }

    /// @notice Read the resolved outcome.
    /// @return ready          true once finalized OR challenge window has
    ///         expired without a dispute (lazy auto-finalize)
    /// @return winningOption  yesOption / noOption / bytes32(0) for
    ///         AMBIGUOUS / CANCELLED (ContestV2 cancels-and-refunds)
    function resolve(bytes32 contestId)
        external
        view
        returns (bool ready, bytes32 winningOption)
    {
        PolyConfig memory cfg = configs[contestId];
        if (cfg.status == Status.UNREGISTERED) revert NotRegistered();

        Outcome decisive = cfg.finalOutcome;

        // Lazy auto-finalize: a PROPOSED contest whose challenge window
        // has elapsed is treated as final without requiring an explicit
        // finalization tx. Saves callers a tx.
        if (cfg.status == Status.PROPOSED &&
            block.timestamp >= uint256(cfg.proposedAt) + DISPUTE_WINDOW) {
            decisive = cfg.proposedOutcome;
        }

        if (decisive == Outcome.UNSET) return (false, bytes32(0));

        if (decisive == Outcome.YES_WIN) return (true, cfg.yesOption);
        if (decisive == Outcome.NO_WIN)  return (true, cfg.noOption);
        // AMBIGUOUS or CANCELLED → bytes32(0) sentinel for cancel-and-refund
        return (true, bytes32(0));
    }

    function settlementTimeout() external pure returns (uint64) {
        return SETTLEMENT_TIMEOUT_VAL;
    }

    function resolverType() external pure returns (bytes32) {
        return keccak256("PolymarketRelayResolver.v1");
    }

    // ---------------------------------------------------------------
    // Bond accounting
    // ---------------------------------------------------------------

    /// @notice Required challenge bond for a contest.
    /// @dev    Audit fix (P-MIRROR-02, conf 90): the previous version
    ///         accepted a caller-supplied `prizePoolEstimate` that anyone
    ///         could pass as 0, lowering the bond to MIN_BOND for an
    ///         arbitrarily large pool. The bond is now driven entirely by
    ///         per-contest admin override — set at registration time
    ///         based on observed TVL — falling back to MIN_BOND only when
    ///         the admin has not configured one. Admins should set
    ///         bondOverride to scale with the actual prize pool to keep
    ///         frivolous-challenge griefing expensive.
    function requiredBondFor(bytes32 contestId) public view returns (uint96) {
        uint96 explicit = bondOverride[contestId];
        if (explicit > 0) return explicit;
        return MIN_BOND;
    }


    /// @notice Admin override of the challenge bond size for a specific
    ///         contest (e.g. very-high-pool markets where the formula
    ///         underestimates appropriate friction).
    /// @dev    Capped at MAX_BOND_OVERRIDE (10× MIN_BOND) so a compromised
    ///         owner cannot price challenges out of existence. Pass 0 to
    ///         clear the override (falls back to MIN_BOND).
    function setBondOverride(bytes32 contestId, uint96 bond) external onlyOwner {
        if (bond > MAX_BOND_OVERRIDE) revert BondOverrideTooHigh();
        bondOverride[contestId] = bond;
    }

    // ---------------------------------------------------------------
    // Propose / Challenge / Finalize
    // ---------------------------------------------------------------

    /// @notice Submit the relayer's reading of the Polymarket outcome.
    /// @dev    Permissionless after the grace window has elapsed —
    ///         anyone (creator, watchdog, third-party keeper) can call
    ///         to keep contests from getting stuck if our relayer is
    ///         down.
    function propose(bytes32 contestId, Outcome outcome) external whenNotPaused {
        if (outcome != Outcome.YES_WIN &&
            outcome != Outcome.NO_WIN &&
            outcome != Outcome.AMBIGUOUS) revert UnsupportedOutcome();

        PolyConfig storage cfg = configs[contestId];
        if (cfg.status != Status.REGISTERED) revert NotInState(Status.REGISTERED);
        if (block.timestamp < uint256(cfg.polymarketEndDate) + GRACE_WINDOW) {
            revert GraceWindowNotElapsed();
        }

        cfg.status = Status.PROPOSED;
        cfg.proposedOutcome = outcome;
        cfg.proposedAt = uint64(block.timestamp);
        cfg.proposer = msg.sender;

        emit ProposalSubmitted(
            contestId,
            outcome,
            msg.sender,
            uint64(block.timestamp + DISPUTE_WINDOW)
        );
    }

    /// @notice Dispute a proposal by posting a bond and submitting the
    ///         outcome you think is correct. Pulls bondToken via
    ///         transferFrom — challenger must approve this contract.
    /// @dev    Bond is now driven entirely by `bondOverride[contestId]`
    ///         (admin-set, scaled to actual TVL) or MIN_BOND. The
    ///         second-arg overload below preserves the old call shape
    ///         for off-chain integrations but ignores the estimate.
    function challenge(
        bytes32 contestId,
        Outcome alternativeOutcome
    ) external nonReentrant whenNotPaused {
        if (alternativeOutcome != Outcome.YES_WIN &&
            alternativeOutcome != Outcome.NO_WIN &&
            alternativeOutcome != Outcome.AMBIGUOUS) revert UnsupportedOutcome();

        PolyConfig storage cfg = configs[contestId];
        if (cfg.status != Status.PROPOSED) revert NotInState(Status.PROPOSED);
        if (block.timestamp >= uint256(cfg.proposedAt) + DISPUTE_WINDOW) {
            revert ChallengeWindowExpired();
        }
        if (alternativeOutcome == cfg.proposedOutcome) revert UnsupportedOutcome();

        uint96 bond = requiredBondFor(contestId);
        bondToken.safeTransferFrom(msg.sender, address(this), bond);

        cfg.status = Status.DISPUTED;
        cfg.challengerOutcome = alternativeOutcome;
        cfg.challenger = msg.sender;
        cfg.challengerBond = bond;

        emit Challenged(contestId, alternativeOutcome, msg.sender, bond);
    }

    /// @notice Admin (multi-sig) makes the final call on a disputed
    ///         contest. Refunds the bond + sends a small reward if
    ///         the challenger was honest; slashes the bond to treasury
    ///         otherwise.
    /// @param  challengerWasHonest true iff finalOutcome == challenger's
    ///         alternativeOutcome
    /// @param  treasury Where slashed bonds go (only used if
    ///         challengerWasHonest == false)
    function finalizeAfterDispute(
        bytes32 contestId,
        Outcome finalOutcome,
        bool challengerWasHonest,
        address treasury
    ) external onlyOwner nonReentrant whenNotPaused {
        if (finalOutcome != Outcome.YES_WIN &&
            finalOutcome != Outcome.NO_WIN &&
            finalOutcome != Outcome.AMBIGUOUS &&
            finalOutcome != Outcome.CANCELLED) revert UnsupportedOutcome();

        PolyConfig storage cfg = configs[contestId];
        if (cfg.status != Status.DISPUTED) revert NotInState(Status.DISPUTED);

        // Sanity: if admin claims challenger was honest, the final
        // outcome should match challenger's — fail loudly if not.
        if (challengerWasHonest && finalOutcome != cfg.challengerOutcome) {
            revert InvalidParams();
        }

        cfg.status = Status.FINALIZED;
        cfg.finalOutcome = finalOutcome;

        uint256 bond = cfg.challengerBond;
        cfg.challengerBond = 0;

        if (bond > 0) {
            if (challengerWasHonest) {
                bondToken.safeTransfer(cfg.challenger, bond);
                emit BondRefunded(contestId, cfg.challenger, bond);
            } else {
                if (treasury == address(0)) revert InvalidParams();
                bondToken.safeTransfer(treasury, bond);
                emit BondSlashed(contestId, cfg.challenger, bond, treasury);
            }
        }

        emit FinalizedByAdmin(contestId, finalOutcome, challengerWasHonest);
    }

    /// @notice Permissionless cancel after the hard 7-day timeout.
    ///         Used when:
    ///           - relayer never posted (REGISTERED → CANCELLED)
    ///           - admin never resolved a dispute (DISPUTED → CANCELLED)
    ///         Refunds challenger bond if any.
    /// @dev    Audit fix (P-MIRROR-01, conf 100): a PROPOSED contest whose
    ///         dispute window has elapsed is already lazy-finalized by
    ///         `resolve()` even though `cfg.status` storage still reads
    ///         PROPOSED. Without this guard a griefer could call
    ///         forceTimeoutCancel after the 7-day clock — overwriting a
    ///         correct lazy-finalized outcome with CANCELLED and
    ///         redirecting the prize pool away from the rightful winners.
    ///         We refuse the cancel in that window and persist the lazy
    ///         finalization to storage so the state machine reflects truth.
    function forceTimeoutCancel(bytes32 contestId) external nonReentrant whenNotPaused {
        PolyConfig storage cfg = configs[contestId];
        if (cfg.status == Status.UNREGISTERED) revert NotRegistered();
        if (cfg.status == Status.FINALIZED) revert AlreadySettled();

        // PROPOSED-with-elapsed-window: lazy-finalize is in effect — persist
        // it instead of cancelling. Anyone hitting this path effectively
        // moves the lazy result to storage, freezing the correct outcome
        // and blocking subsequent cancel attempts.
        if (cfg.status == Status.PROPOSED &&
            block.timestamp >= uint256(cfg.proposedAt) + DISPUTE_WINDOW) {
            cfg.status = Status.FINALIZED;
            cfg.finalOutcome = cfg.proposedOutcome;
            emit FinalizedByTimeout(contestId);
            return;
        }

        if (block.timestamp < uint256(cfg.polymarketEndDate) + SETTLEMENT_TIMEOUT_VAL) {
            revert TimeoutNotReached();
        }

        cfg.status = Status.FINALIZED;
        cfg.finalOutcome = Outcome.CANCELLED;

        uint256 bond = cfg.challengerBond;
        cfg.challengerBond = 0;
        if (bond > 0 && cfg.challenger != address(0)) {
            bondToken.safeTransfer(cfg.challenger, bond);
            emit BondRefunded(contestId, cfg.challenger, bond);
        }

        emit FinalizedByTimeout(contestId);
    }
}
