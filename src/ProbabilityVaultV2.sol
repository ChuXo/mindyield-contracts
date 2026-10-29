// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IYieldVault.sol";
import "./interfaces/IIdentityRegistry.sol";
import "./interfaces/IResolver.sol";

/// @notice Minimal interface for clones to read the factory's pause flag.
///         Mirrors the interface in ContestV2 — both clones use the same
///         lookup against their respective factories.
interface IFactoryPauseLookup {
    function paused() external view returns (bool);
}

/// @title ProbabilityVaultV2
/// @notice AMM-style no-loss prediction vault that mirrors a Polymarket market.
///         Unlike MirrorContestV2 (fixed-phase tournament with equal deposits
///         and commit-reveal voting), ProbabilityVaultV2 is a continuous pool:
///
///           - Any amount, any time (during JOIN phase).
///           - Deposit on YES or NO; free swap between sides.
///           - Time-weighted (TWAB) yield attribution on the winning side.
///           - Pool YES/NO ratio is the live implied probability, readable
///             by any contract.
///           - Principal always returned (no-loss), yield is the only prize.
///           - Cancel + refund if either side < CANCEL_MINORITY_PCT at freeze,
///             if resolver returns ambiguous, or if resolver times out.
///           - Cancel-with-yield-refund (NEW, post-2026 redeploy): if a
///             cancel produced real yield AND combined TWAB > 0, the
///             surplus (minus protocol fee) is distributed pro-rata across
///             ALL depositors weighted by combined yes+no TWAB — fairer
///             than the legacy "surplus → treasury" routing for the
///             non-strategy-loss cancel paths. Strategy-loss cancel keeps
///             the existing principal-scaling semantics.
///
///         Yield flow: users deposit USDC → vault → yield accrues → at
///         settlement, winning-side-TWAB holders split the yield
///         pro-rata to their time-weighted stake. Losing side gets principal
///         only. Early withdrawers forfeit their accrued TWAB — their
///         historical stake-time is removed from global TWAB so remaining
///         winners' shares aren't diluted.
///
///         Fee model:
///           - Protocol fee on yield (default 2%, factory-settable).
///           - Swap fee per swap (default 0.2%, factory-settable), accrued
///             in-contract and swept to treasury on finalize.
///
///         See docs/MIRROR_PROBABILITY_VAULT.md for the full spec and
///         docs/SAFETY_PERMISSIONING.md for the safety analysis.
contract ProbabilityVaultV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ────────────────────────────────────────────────────────
    error InvalidConfig();
    error InvalidState();
    error NotFactory();
    error AlreadyInitialized();
    error NotDeposited();
    error AlreadyClaimed();
    error InvalidSide();
    error InsufficientStake();
    error TierTooLow();
    error WindowClosed();
    error WindowNotOpen();
    error ResolverNotReady();
    error FlashLoanBlocked();
    error ZeroAmount();
    error NothingToWithdraw();

    // ─── Enums ─────────────────────────────────────────────────────────
    enum State {
        CREATED,     // 0 — transitioned away during initialize
        JOIN_OPEN,   // 1 — deposits, swaps, early withdrawals allowed
        LOCKED,      // 2 — frozen until resolveStart
        RESOLVING,   // 3 — awaiting resolver consultation
        FINALIZED,   // 4 — outcome settled, claims open
        CANCELLED    // 5 — everyone gets principal back, no yield split
    }

    // ─── Storage ───────────────────────────────────────────────────────

    bool private _initialized;
    address public factory;

    // Immutable-after-init config
    address public depositToken;
    address public resolver;
    address public yieldVault;
    address public yieldStrategy;      // strategy 0 in vault; indexer convenience
    address public identityRegistry;
    address public protocolFeeRecipient;

    uint96 public protocolFeeBps;      // yield fee (e.g. 200 = 2%)
    uint96 public swapFeeBps;          // swap fee (e.g. 20 = 0.2%)
    uint8  public tierRequired;
    uint8  public cancelMinorityPct;   // e.g. 5 → minority side must be >= 5% of total TWAB

    uint64 public joinEnd;             // = polymarketEndDate - DEPOSIT_LOCKOUT
    uint64 public polymarketEndDate;
    uint64 public resolveStart;        // = polymarketEndDate + REVEAL_BUFFER
    uint64 public cancelDeadline;      // = polymarketEndDate + CANCEL_TIMEOUT

    bytes32 public conditionId;
    bytes32 public yesOption;
    bytes32 public noOption;
    bytes32 public metadataHash;
    string  public metadataUri;

    // Mutable state
    State public state;

    uint128 public totalYesStake;
    uint128 public totalNoStake;
    uint128 public vaultShares;

    // Global TWAB accumulators (stake-seconds)
    uint128 public totalYesTwab;
    uint128 public totalNoTwab;
    uint64  public lastGlobalUpdate;

    struct User {
        uint96  yesStake;
        uint96  noStake;
        uint96  principal;            // total deposited (minus early-withdrawn)
        uint128 yesTwab;
        uint128 noTwab;
        uint64  lastUserUpdate;
        uint64  depositBlock;         // flash-loan prevention (same-block deposit-withdraw blocked)
        bool    claimed;
        bool    principalWithdrawn;
        uint96  withdrawableAmount;   // non-zero on strategy loss → pro-rata scaled
    }
    mapping(address => User) public users;

    // Resolution outcome
    bytes32 public winningOption;
    uint128 public totalYield;
    uint128 public distributableYield;
    uint128 public totalAccruedSwapFees;
    // Pro-rata yield refund pool reserved for users on cancel paths that
    // produced a real surplus (imbalance / ambiguous / timeout / emergency
    // — NOT strategy loss, which keeps the existing distributableYield-as-
    // recovery semantics). Non-zero only when totalYesTwab + totalNoTwab > 0,
    // so the denominator in the claim path is always live. Computed once in
    // _doCancel after the protocol fee is deducted from the gross surplus.
    // See docs/PV_CANCEL_YIELD_REFUND.md for the full design.
    uint128 public cancelYieldPool;
    string  public cancelReason;

    // ─── Events ────────────────────────────────────────────────────────

    event VaultInitialized(
        address indexed creator,
        bytes32 conditionId,
        uint64 polymarketEndDate
    );
    event Deposited(address indexed user, uint256 amount, bytes32 side);
    event Swapped(
        address indexed user,
        uint256 amount,
        bytes32 fromSide,
        bytes32 toSide,
        uint256 feeDeducted
    );
    event EarlyWithdrawn(address indexed user, uint256 amount);
    event Resolved(bytes32 winningOption, uint256 distributableYield);
    event Cancelled(string reason);
    event Claimed(address indexed user, uint256 principal, uint256 yieldAmount);
    event ProtocolFeeDeducted(uint256 amount, address recipient);
    event ProtocolFeeSkipped(uint256 amount, address recipient, string reason);
    event SwapFeesSwept(uint256 amount, address recipient);
    event StateChanged(State newState);
    /// @notice Emitted in _doCancel when a real yield surplus exists AND a
    ///         non-zero combined TWAB makes a fair denominator available.
    ///         `grossSurplus` is the pre-fee yield; `protocolFee` is what was
    ///         routed to treasury; `reservedForUsers` (= cancelYieldPool) is
    ///         what stays in-contract for pro-rata claim by depositors. Old
    ///         deployments never emit this event — its absence is the cleanest
    ///         signal to off-chain consumers that the legacy "surplus → fee
    ///         recipient" routing was used.
    event CancelYieldReserved(
        uint256 grossSurplus,
        uint256 protocolFee,
        uint256 reservedForUsers
    );

    // ─── Modifiers ─────────────────────────────────────────────────────

    /// @notice Reverts when the factory is paused. Applied only to deposit
    ///         and swap. withdrawEarly, claim, resolveContest, _doCancel and
    ///         emergencyCancel are intentionally NOT gated — principal /
    ///         yield redemption must always succeed even while the factory
    ///         is paused.
    modifier whenFactoryNotPaused() {
        if (factory != address(0) && IFactoryPauseLookup(factory).paused()) revert InvalidState();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ─── Constructor (impl only) ───────────────────────────────────────

    constructor() {
        _initialized = true;
    }

    // ─── Initialization ────────────────────────────────────────────────

    struct InitParams {
        address creator;                 // informational only, for events
        address depositToken;
        uint64  joinEnd;
        uint64  polymarketEndDate;
        uint64  resolveStart;
        uint64  cancelDeadline;
        uint8   tierRequired;
        uint8   cancelMinorityPct;
        bytes32 yesOption;
        bytes32 noOption;
        bytes32 conditionId;
        bytes32 metadataHash;
        string  metadataUri;
        address resolver;
        address yieldVault;
        address yieldStrategy;
        address identityRegistry;
        uint96  protocolFeeBps;
        uint96  swapFeeBps;
        address protocolFeeRecipient;
    }

    function initialize(InitParams calldata p) external nonReentrant {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Only contracts (i.e. the factory) can init clones.
        if (msg.sender.code.length == 0) revert InvalidConfig();
        factory = msg.sender;

        if (p.depositToken == address(0)) revert InvalidConfig();
        if (p.resolver == address(0)) revert InvalidConfig();
        if (p.yieldVault == address(0)) revert InvalidConfig();
        if (p.polymarketEndDate <= block.timestamp) revert InvalidConfig();
        if (p.joinEnd >= p.polymarketEndDate) revert InvalidConfig();
        if (p.joinEnd <= block.timestamp) revert InvalidConfig();
        if (p.resolveStart <= p.polymarketEndDate) revert InvalidConfig();
        if (p.cancelDeadline <= p.resolveStart) revert InvalidConfig();
        if (p.yesOption == bytes32(0) || p.noOption == bytes32(0)) revert InvalidConfig();
        if (p.yesOption == p.noOption) revert InvalidConfig();
        if (p.conditionId == bytes32(0)) revert InvalidConfig();
        if (p.cancelMinorityPct == 0 || p.cancelMinorityPct >= 50) revert InvalidConfig();
        if (p.swapFeeBps > 1_000) revert InvalidConfig(); // 10% hard ceiling
        if (p.protocolFeeBps > 500) revert InvalidConfig(); // 5% hard ceiling — matches platform invariant

        depositToken          = p.depositToken;
        resolver              = p.resolver;
        yieldVault            = p.yieldVault;
        yieldStrategy         = p.yieldStrategy;
        identityRegistry      = p.identityRegistry;
        protocolFeeRecipient  = p.protocolFeeRecipient;
        protocolFeeBps        = p.protocolFeeBps;
        swapFeeBps            = p.swapFeeBps;
        tierRequired          = p.tierRequired;
        cancelMinorityPct     = p.cancelMinorityPct;
        joinEnd               = p.joinEnd;
        polymarketEndDate     = p.polymarketEndDate;
        resolveStart          = p.resolveStart;
        cancelDeadline        = p.cancelDeadline;
        yesOption             = p.yesOption;
        noOption              = p.noOption;
        conditionId           = p.conditionId;
        metadataHash          = p.metadataHash;
        metadataUri           = p.metadataUri;

        lastGlobalUpdate = uint64(block.timestamp);
        state = State.JOIN_OPEN;
        emit StateChanged(State.JOIN_OPEN);
        emit VaultInitialized(p.creator, p.conditionId, p.polymarketEndDate);
    }

    // ─── Deposit ───────────────────────────────────────────────────────

    function deposit(uint256 amount, bytes32 side) external nonReentrant whenFactoryNotPaused {
        _maybeAutoTransitionFromJoin();
        if (state != State.JOIN_OPEN) revert InvalidState();
        if (block.timestamp >= joinEnd) revert WindowClosed();
        if (amount == 0) revert ZeroAmount();
        if (side != yesOption && side != noOption) revert InvalidSide();
        _checkTier(msg.sender);

        _updateGlobalTwab();
        User storage u = users[msg.sender];
        _updateUserTwab(u);

        IERC20 token = IERC20(depositToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        // Deposit into the yield vault. Track shares for proportional withdraw later.
        token.forceApprove(yieldVault, received);
        uint256 shares = IYieldVault(yieldVault).deposit(depositToken, received, 0);
        vaultShares += uint128(shares);

        if (side == yesOption) {
            u.yesStake   += uint96(received);
            totalYesStake += uint128(received);
        } else {
            u.noStake    += uint96(received);
            totalNoStake += uint128(received);
        }
        u.principal     += uint96(received);
        u.depositBlock  = uint64(block.number);

        emit Deposited(msg.sender, received, side);
    }

    // ─── Swap ──────────────────────────────────────────────────────────

    function swap(uint256 amount, bytes32 newSide) external nonReentrant whenFactoryNotPaused {
        _maybeAutoTransitionFromJoin();
        if (state != State.JOIN_OPEN) revert InvalidState();
        if (block.timestamp >= joinEnd) revert WindowClosed();
        if (amount == 0) revert ZeroAmount();
        if (newSide != yesOption && newSide != noOption) revert InvalidSide();

        _updateGlobalTwab();
        User storage u = users[msg.sender];
        _updateUserTwab(u);

        uint96 fee = uint96((amount * uint256(swapFeeBps)) / 10_000);
        uint96 netAmount = uint96(amount) - fee;

        if (newSide == yesOption) {
            // Swap NO → YES
            if (u.noStake < amount) revert InsufficientStake();
            u.noStake    -= uint96(amount);
            totalNoStake -= uint128(amount);
            u.yesStake   += netAmount;
            totalYesStake += uint128(netAmount);
            emit Swapped(msg.sender, amount, noOption, yesOption, fee);
        } else {
            // Swap YES → NO
            if (u.yesStake < amount) revert InsufficientStake();
            u.yesStake   -= uint96(amount);
            totalYesStake -= uint128(amount);
            u.noStake    += netAmount;
            totalNoStake += uint128(netAmount);
            emit Swapped(msg.sender, amount, yesOption, noOption, fee);
        }

        // Swap fee stays in the contract's USDC balance (doesn't go to vault).
        // The depositor's principal claim is reduced by the fee so accounting
        // remains conserved: principal_user + fees = original deposit.
        if (fee > 0) {
            u.principal -= fee;
            totalAccruedSwapFees += uint128(fee);
        }
    }

    // ─── Early withdraw ────────────────────────────────────────────────

    /// @notice Exit before LOCKED. Returns all principal, forfeits yield.
    ///         The user's accumulated TWAB on both sides is removed from the
    ///         global totals so remaining winners aren't diluted.
    function withdrawEarly() external nonReentrant {
        _maybeAutoTransitionFromJoin();
        if (state != State.JOIN_OPEN) revert InvalidState();
        if (block.timestamp >= joinEnd) revert WindowClosed();

        User storage u = users[msg.sender];
        if (u.principal == 0) revert NothingToWithdraw();
        if (u.depositBlock == block.number) revert FlashLoanBlocked();

        _updateGlobalTwab();
        _updateUserTwab(u);

        // Forfeit user's TWAB by subtracting it from the global.
        totalYesTwab -= u.yesTwab;
        totalNoTwab  -= u.noTwab;
        u.yesTwab = 0;
        u.noTwab  = 0;

        // Remove their stake from totals.
        if (u.yesStake > 0) {
            totalYesStake -= uint128(u.yesStake);
            u.yesStake = 0;
        }
        if (u.noStake > 0) {
            totalNoStake -= uint128(u.noStake);
            u.noStake = 0;
        }

        uint256 principalAmount = uint256(u.principal);
        u.principal = 0;
        u.principalWithdrawn = true;

        // Withdraw proportional vault shares at current share-value.
        // Uses getShareValue to compute how many shares represent principalAmount.
        uint256 sharesToRedeem = _sharesForAmount(principalAmount);
        if (sharesToRedeem > vaultShares) sharesToRedeem = vaultShares;
        if (sharesToRedeem == 0) revert NothingToWithdraw();
        uint256 actuallyReceived = IYieldVault(yieldVault).withdraw(
            depositToken, sharesToRedeem, 0, address(this)
        );
        vaultShares -= uint128(sharesToRedeem);

        // If strategy returned less than requested (rare — vault rounding or
        // mild loss), pay what we got. Early withdraw is best-effort.
        uint256 payout = actuallyReceived < principalAmount ? actuallyReceived : principalAmount;
        if (payout == 0) revert NothingToWithdraw();
        IERC20(depositToken).safeTransfer(msg.sender, payout);
        emit EarlyWithdrawn(msg.sender, payout);
    }

    // ─── Resolution ───────────────────────────────────────────────────

    /// @notice Settle the vault. Reads the bound resolver and distributes yield
    ///         to winning-side TWAB holders, or cancels on ambiguous/imbalance/timeout.
    function resolveContest() external nonReentrant {
        _maybeAutoTransitionFromJoin();
        if (state != State.LOCKED && state != State.RESOLVING) revert InvalidState();
        if (block.timestamp < resolveStart) revert WindowNotOpen();
        if (state == State.LOCKED) {
            state = State.RESOLVING;
            emit StateChanged(State.RESOLVING);
        }

        // Finalize global TWAB one last time (it froze at joinEnd effectively
        // because no more stake mutations happen, but we update anyway so the
        // totalYesTwab/totalNoTwab reflect the full contest duration up to
        // resolveStart for final accounting).
        _updateGlobalTwab();

        // Deterministic fairness cancels run first — independent of the resolver
        // and of the timeout. An empty or one-sided pool can never produce a
        // fair yield split, so we cancel + refund regardless of any outcome.
        uint256 totalTwab = uint256(totalYesTwab) + uint256(totalNoTwab);
        if (totalTwab == 0) {
            _cancel("empty pool");
            return;
        }
        uint256 minorityTwab = totalYesTwab < totalNoTwab
            ? uint256(totalYesTwab)
            : uint256(totalNoTwab);
        if (minorityTwab * 100 < totalTwab * uint256(cancelMinorityPct)) {
            _cancel("imbalance: minority side below floor");
            return;
        }

        // Consult the resolver. A ready, unambiguous outcome ALWAYS finalizes —
        // even past cancelDeadline — because the timeout exists only to free
        // funds when the resolver NEVER answers, not to discard a valid answer
        // that arrived late. The call is wrapped so a misbehaving/reverting
        // resolver degrades to "not ready" and the timeout safety net below
        // still fires rather than bricking the vault.
        bytes32 contestKey = bytes32(uint256(uint160(address(this))));
        bool ready;
        bytes32 winner;
        try IResolver(resolver).resolve(contestKey) returns (bool _ready, bytes32 _winner) {
            ready = _ready;
            winner = _winner;
        } catch {
            ready = false;
        }

        if (!ready) {
            // No outcome yet. Past the deadline → timeout-cancel + refund;
            // otherwise tell the caller to retry once the resolver settles.
            if (block.timestamp >= cancelDeadline) {
                _cancel("resolver: timeout");
                return;
            }
            revert ResolverNotReady();
        }

        if (winner == bytes32(0)) {
            _cancel("resolver: ambiguous outcome");
            return;
        }
        // A winner that is neither yesOption nor noOption can only come from a
        // misbehaving/misconfigured resolver. Treat it like an ambiguous result
        // — cancel + refund — rather than reverting. Reverting here would brick
        // the vault permanently: because the resolver is now consulted before
        // the timeout, a `ready==true` garbage winner would skip the timeout
        // safety net and trap all principal forever. Cancelling preserves the
        // no-loss guarantee regardless of resolver behaviour.
        if (winner != yesOption && winner != noOption) {
            _cancel("resolver: invalid winner");
            return;
        }

        // Withdraw everything from vault
        uint256 totalAssets = 0;
        if (vaultShares > 0) {
            totalAssets = IYieldVault(yieldVault).withdraw(
                depositToken, uint256(vaultShares), 0, address(this)
            );
            vaultShares = 0;
        }

        // Audit fix (self-audit 2026-04-18): swap fees are already deducted
        // from users' principal claims (totalYesStake + totalNoStake shrinks
        // by the swap fee on every swap), but the USDC remained in the yield
        // vault. Without adding totalAccruedSwapFees back into the obligation
        // total, `yieldGen` would double-count the fees (once in yield, once
        // in the separate sweep below), causing the contract to try to pay
        // out more than it has. Correct obligation = user principal + accrued
        // swap fees awaiting treasury sweep.
        uint256 principalAndFees =
            uint256(totalYesStake) + uint256(totalNoStake) + uint256(totalAccruedSwapFees);
        uint256 yieldGen = totalAssets > principalAndFees ? totalAssets - principalAndFees : 0;

        // Strategy loss: cancel the contest on strategy loss to refund pro-rata.
        // We pass the already-drained `totalAssets` into _doCancel so it can
        // scale user claims correctly. Without this, _cancel would re-read
        // vaultShares == 0 and treat returned = 0 — the first claimant would
        // be paid full principal (depleting whatever USDC the vault still
        // holds), and the second would revert on insufficient balance.
        uint256 principal = uint256(totalYesStake) + uint256(totalNoStake);
        if (totalAssets < principal && principal > 0) {
            _doCancel("strategy loss during lock", totalAssets);
            return;
        }

        // Protocol fee on yield
        uint256 protocolFee;
        if (protocolFeeBps > 0 && protocolFeeRecipient != address(0) && yieldGen > 0) {
            protocolFee = (yieldGen * uint256(protocolFeeBps)) / 10_000;
            if (protocolFee > 0) {
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, protocolFee) {
                    emit ProtocolFeeDeducted(protocolFee, protocolFeeRecipient);
                } catch {
                    emit ProtocolFeeSkipped(protocolFee, protocolFeeRecipient, "transfer reverted");
                    protocolFee = 0;
                }
            }
        }

        // Sweep accrued swap fees to treasury (separate from yield), but NEVER
        // more than the surplus the vault returned above user principal.
        // Audit fix (2026-06-03): the strategy-loss guard above keys off
        // `principal` (stake only, excl. swap fees), so a small strategy loss in
        // the band `principal <= totalAssets < principal + swapFees` skips both
        // that guard and the surplus path, yet the old code swept the FULL swap
        // fees here — dipping into user principal and stranding late claimants
        // (no-loss broken). Capping the sweep at `totalAssets - principal`
        // keeps >= principal in-contract so every depositor can claim in full;
        // the protocol simply forgoes (part of) its swap fee on a loss.
        if (totalAccruedSwapFees > 0 && protocolFeeRecipient != address(0)) {
            uint256 sweepable = totalAssets > principal ? totalAssets - principal : 0;
            uint256 swapFees = uint256(totalAccruedSwapFees);
            if (swapFees > sweepable) swapFees = sweepable;
            if (swapFees > 0) {
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, swapFees) {
                    emit SwapFeesSwept(swapFees, protocolFeeRecipient);
                    totalAccruedSwapFees -= uint128(swapFees);
                } catch {
                    emit ProtocolFeeSkipped(swapFees, protocolFeeRecipient, "swap fee transfer reverted");
                }
            }
        }

        winningOption      = winner;
        totalYield         = uint128(yieldGen);
        distributableYield = uint128(yieldGen - protocolFee);
        state              = State.FINALIZED;
        emit StateChanged(State.FINALIZED);
        emit Resolved(winner, uint256(distributableYield));
    }

    // ─── Cancel ────────────────────────────────────────────────────────

    /// @notice Factory-only emergency cancel. Reserved for critical issues
    ///         (malicious resolver, compromised deployment). Regular ambiguous
    ///         or timeout cancellation is handled by resolveContest().
    function emergencyCancel() external onlyFactory nonReentrant {
        if (state == State.FINALIZED || state == State.CANCELLED) revert InvalidState();
        _cancel("factory: emergency cancel");
    }

    /// @notice Sweep residual USDC stranded in the contract after a CANCELLED
    ///         state has fully drained user claims. Routes the residue to the
    ///         protocol fee recipient. Factory-only.
    ///
    ///         Grace window:
    ///           - strategy-loss cancel (cancelYieldPool == 0): 30 days past
    ///             cancelDeadline. Residue is just swap-fee dust (max a few
    ///             cents) and the swap-fee sweep was deliberately skipped on
    ///             this path so the pro-rated principal claims don't underflow.
    ///           - cancel with yield refund (cancelYieldPool > 0): 180 days
    ///             past cancelDeadline. Residue here can include unclaimed
    ///             user yield-share — the longer window protects depositors
    ///             who don't check often.
    /// @dev    Audit follow-up to the 2026-04-28 _doCancel(preWithdrawn) fix +
    ///         the cancel-yield-refund design (2026 redeploy). Old strategy-
    ///         loss residue is rescue-able quickly; new yield-pool residue
    ///         needs a longer fuse because it represents real user funds.
    function rescueTrappedDust() external onlyFactory nonReentrant {
        if (state != State.CANCELLED) revert InvalidState();
        uint256 graceDays = cancelYieldPool > 0 ? 180 days : 30 days;
        if (block.timestamp < uint256(cancelDeadline) + graceDays) revert WindowNotOpen();
        if (protocolFeeRecipient == address(0)) revert InvalidConfig();

        uint256 residual = IERC20(depositToken).balanceOf(address(this));
        if (residual == 0) revert NothingToWithdraw();

        try this.executeProtocolFeeTransfer(protocolFeeRecipient, residual) {
            emit ProtocolFeeDeducted(residual, protocolFeeRecipient);
        } catch {
            emit ProtocolFeeSkipped(residual, protocolFeeRecipient, "rescue dust transfer reverted");
        }
    }

    function _cancel(string memory reason) internal {
        _doCancel(reason, 0);
    }

    /// @dev Internal cancel worker that accepts a `preWithdrawn` amount for
    ///      callers (specifically the strategy-loss branch of resolveContest)
    ///      that have already drained the yield vault into the contract's
    ///      balance. preWithdrawn = 0 means "vaultShares is the source of
    ///      truth, withdraw it now". preWithdrawn > 0 means "vaultShares is
    ///      already 0; the vault holds preWithdrawn USDC that should be
    ///      treated as the recovery total".
    function _doCancel(string memory reason, uint256 preWithdrawn) internal {
        // Finalize global TWAB before we read it as the denominator for the
        // pro-rata yield refund below. resolveContest() already calls this at
        // line 412, but emergencyCancel() (factory-only) does not — and if
        // emergencyCancel fires BEFORE joinEnd, the global accumulator would
        // otherwise lag the user-side cap and break the conservation invariant
        // (Σ user yieldOut ≤ cancelYieldPool). Idempotent: a no-op if already
        // current. _updateUserTwab caps at `lastGlobalUpdate` on post-JOIN
        // states so the symmetric cap holds for users that claim later.
        _updateGlobalTwab();

        uint256 returned = preWithdrawn;
        if (vaultShares > 0) {
            returned += IYieldVault(yieldVault).withdraw(
                depositToken, uint256(vaultShares), 0, address(this)
            );
            vaultShares = 0;
        }

        uint256 principal = uint256(totalYesStake) + uint256(totalNoStake);
        uint256 swapFeesHeld = uint256(totalAccruedSwapFees);
        // Audit fix (self-audit 2026-04-18): cancel path had the same swap-fee
        // double-count as resolve. The true obligation is principal + swap fees;
        // surplus above that is the only amount to route to treasury.
        uint256 obligation = principal + swapFeesHeld;

        bool strategyLoss = false;
        if (returned > obligation && obligation > 0) {
            // Real yield surplus exists. Two routes:
            //
            // 1. If combined TWAB > 0, depositors had real stake-seconds and
            //    we can fairly attribute the yield back to them pro-rata.
            //    The market FAILED to resolve, so — unlike a finalized market —
            //    NO protocol fee is taken on this surplus: the full amount is
            //    reserved in `cancelYieldPool` for pro-rata refund to
            //    depositors. This supersedes the legacy P-EXT-03 routing
            //    (surplus → treasury) for new deployments and is truer to the
            //    no-loss promise (the protocol earns only on successful
            //    settlements).
            //
            // 2. If combined TWAB == 0 (truly empty pool — nobody held a
            //    position long enough to accrue a stake-second), there is no
            //    fair denominator and the legacy "surplus → fee recipient"
            //    routing remains the only sane behavior.
            uint256 surplus = returned - obligation;
            uint256 totalCombinedTwab = uint256(totalYesTwab) + uint256(totalNoTwab);

            if (totalCombinedTwab > 0) {
                // No protocol fee on a cancelled market — full surplus to users.
                cancelYieldPool = uint128(surplus);
                emit CancelYieldReserved(surplus, 0, surplus);
            } else if (protocolFeeRecipient != address(0)) {
                // Legacy path — no TWAB to refund against.
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, surplus) {
                    emit ProtocolFeeDeducted(surplus, protocolFeeRecipient);
                } catch {
                    emit ProtocolFeeSkipped(surplus, protocolFeeRecipient, "cancel surplus transfer reverted");
                }
            }
        } else if (returned < principal && principal > 0) {
            // Strategy loss — scale user principal claims by the actual recovery.
            // We deliberately don't add swap fees to the denominator here; that
            // would alter the existing surplus/balanced semantics. Instead we
            // simply skip the swap-fee treasury sweep on this path (see below)
            // so the prorated user payouts don't underflow the vault balance.
            distributableYield = uint128(returned);
            totalYield = uint128(principal); // used as denominator in claim
            strategyLoss = true;
        }

        // Sweep swap fees to treasury — but ONLY when there's no strategy
        // loss. On loss the vault doesn't hold enough USDC to honor BOTH the
        // prorated user payouts AND the full swap-fee obligation; sweeping
        // here would leave the vault short by exactly `swapFeesHeld * (1 -
        // returned/principal)` wei and the second claim would revert. Since
        // the swap fee was already deducted from user principal at swap time,
        // leaving the prorated residue in-contract is the safer semantics
        // (small dust may remain; treasury absorbs the loss along with users).
        // Cap the sweep at the surplus above principal. In the dead-band
        // `principal <= returned < obligation` (a small strategy loss below the
        // accrued swap-fee total) neither the surplus nor the strategy-loss
        // branch fires, so without this cap the full swap-fee sweep would strand
        // user principal for late claimants (no-loss broken). Audit fix
        // 2026-06-03 — mirrors the resolveContest() finalize-path cap.
        if (!strategyLoss && swapFeesHeld > 0 && protocolFeeRecipient != address(0)) {
            uint256 sweepable = returned > principal ? returned - principal : 0;
            uint256 toSweep = swapFeesHeld > sweepable ? sweepable : swapFeesHeld;
            if (toSweep > 0) {
                try this.executeProtocolFeeTransfer(protocolFeeRecipient, toSweep) {
                    emit SwapFeesSwept(toSweep, protocolFeeRecipient);
                    totalAccruedSwapFees -= uint128(toSweep);
                } catch {
                    emit ProtocolFeeSkipped(toSweep, protocolFeeRecipient, "swap fee transfer reverted on cancel");
                }
            }
        }

        cancelReason = reason;
        state = State.CANCELLED;
        emit StateChanged(State.CANCELLED);
        emit Cancelled(reason);
    }

    // ─── Claim ─────────────────────────────────────────────────────────

    function claim() external nonReentrant {
        if (state != State.FINALIZED && state != State.CANCELLED) revert InvalidState();

        User storage u = users[msg.sender];
        if (u.principal == 0 && !u.principalWithdrawn) revert NotDeposited();
        if (u.claimed) revert AlreadyClaimed();

        u.claimed = true;

        // Finalize user TWAB up to last global update (which was brought to
        // resolveStart by resolveContest(), or to cancel time by _cancel()).
        _updateUserTwab(u);

        uint256 principalOut = 0;
        uint256 yieldOut = 0;

        if (state == State.FINALIZED) {
            // Normal path: principal back, plus yield if on winning side.
            principalOut = uint256(u.principal);

            if (distributableYield > 0) {
                uint128 userWinTwab = winningOption == yesOption ? u.yesTwab : u.noTwab;
                uint128 totalWinTwab = winningOption == yesOption ? totalYesTwab : totalNoTwab;
                if (totalWinTwab > 0 && userWinTwab > 0) {
                    yieldOut = (uint256(distributableYield) * uint256(userWinTwab)) / uint256(totalWinTwab);
                }
            }
        } else {
            // Cancel path. Two sub-cases, mutually exclusive:
            //
            //   a. Strategy loss (vault returned < principal). distributableYield
            //      = recovered total, totalYield = principal owed — the ratio
            //      scales each user's principal share down pro-rata. No yield
            //      surplus exists, so cancelYieldPool stays 0.
            //
            //   b. Normal cancel with yield surplus (imbalance / ambiguous /
            //      timeout / emergency where the vault accrued yield AND some
            //      stake-seconds existed). Full principal back, plus a pro-rata
            //      share of cancelYieldPool weighted by combined TWAB.
            //
            // The two cases never co-occur because _doCancel sets at most one
            // of (totalYield+distributableYield) or (cancelYieldPool).
            if (totalYield > 0 && distributableYield > 0) {
                principalOut = (uint256(u.principal) * uint256(distributableYield)) / uint256(totalYield);
            } else {
                principalOut = uint256(u.principal);
                if (cancelYieldPool > 0) {
                    uint256 totalCombinedTwab = uint256(totalYesTwab) + uint256(totalNoTwab);
                    uint256 userCombinedTwab = uint256(u.yesTwab) + uint256(u.noTwab);
                    if (totalCombinedTwab > 0 && userCombinedTwab > 0) {
                        yieldOut = (uint256(cancelYieldPool) * userCombinedTwab) / totalCombinedTwab;
                    }
                }
            }
        }

        if (principalOut == 0 && yieldOut == 0) revert NothingToWithdraw();

        uint256 total = principalOut + yieldOut;
        IERC20(depositToken).safeTransfer(msg.sender, total);
        emit Claimed(msg.sender, principalOut, yieldOut);
    }

    // ─── State machine helper ─────────────────────────────────────────

    /// @notice Permissionless time-based state advance.
    function updateState() external {
        _maybeAutoTransitionFromJoin();
    }

    function _maybeAutoTransitionFromJoin() internal {
        if (state == State.JOIN_OPEN && block.timestamp >= joinEnd) {
            _updateGlobalTwab();
            state = State.LOCKED;
            emit StateChanged(State.LOCKED);
        }
    }

    // ─── TWAB bookkeeping ─────────────────────────────────────────────

    /// @dev Accumulate stake-seconds into global TWAB totals up to `cap` time,
    ///      which is min(now, joinEnd). TWAB stops accruing after joinEnd
    ///      because stake is frozen during LOCKED/RESOLVING.
    function _updateGlobalTwab() internal {
        uint64 cap = uint64(block.timestamp);
        if (cap > joinEnd) cap = joinEnd;
        if (cap <= lastGlobalUpdate) return;
        uint64 elapsed = cap - lastGlobalUpdate;
        if (totalYesStake > 0) {
            totalYesTwab += uint128(uint256(totalYesStake) * uint256(elapsed));
        }
        if (totalNoStake > 0) {
            totalNoTwab += uint128(uint256(totalNoStake) * uint256(elapsed));
        }
        lastGlobalUpdate = cap;
    }

    function _updateUserTwab(User storage u) internal {
        uint64 cap;
        if (state == State.JOIN_OPEN) {
            // Live path — cap at now or joinEnd, whichever is sooner.
            cap = uint64(block.timestamp);
            if (cap > joinEnd) cap = joinEnd;
        } else {
            // Post-JOIN path (LOCKED / RESOLVING / FINALIZED / CANCELLED).
            // Cap at the global TWAB checkpoint set by _updateGlobalTwab. In
            // the normal flow this equals joinEnd, but in the emergencyCancel-
            // before-joinEnd edge case it equals the cancel timestamp — and
            // capping users symmetrically is what preserves the invariant
            // Σ user TWAB == Σ stake_i * elapsed_i == global TWAB. Without
            // this, user TWAB would extend to joinEnd while the global stopped
            // earlier, and the cancel-yield denominator would over-pay.
            cap = lastGlobalUpdate;
        }
        if (u.lastUserUpdate == 0) {
            // First touch — no prior time to accumulate.
            u.lastUserUpdate = cap;
            return;
        }
        if (cap <= u.lastUserUpdate) return;
        uint64 elapsed = cap - u.lastUserUpdate;
        if (u.yesStake > 0) {
            u.yesTwab += uint128(uint256(u.yesStake) * uint256(elapsed));
        }
        if (u.noStake > 0) {
            u.noTwab += uint128(uint256(u.noStake) * uint256(elapsed));
        }
        u.lastUserUpdate = cap;
    }

    // ─── Protocol fee transfer helper (try/catch boundary) ────────────

    function executeProtocolFeeTransfer(address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert InvalidConfig();
        IERC20(depositToken).safeTransfer(recipient, amount);
    }

    // ─── Tier check ────────────────────────────────────────────────────

    function _checkTier(address user) internal view {
        if (tierRequired == 0) return;
        if (identityRegistry == address(0)) return;
        if (IIdentityRegistry(identityRegistry).getTier(user) < tierRequired) {
            revert TierTooLow();
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    /// @dev Estimate how many vault shares represent `amount` of depositToken
    ///      at the current share-value. Uses the vault's view — not atomic with
    ///      the subsequent withdraw, but tolerable for early-withdraw where
    ///      we cap at actuallyReceived anyway.
    function _sharesForAmount(uint256 amount) internal view returns (uint256) {
        if (amount == 0 || vaultShares == 0) return 0;
        uint256 totalValue = IYieldVault(yieldVault).getShareValue(depositToken, uint256(vaultShares), 0);
        if (totalValue == 0) return 0;
        return (amount * uint256(vaultShares)) / totalValue;
    }

    // ─── Views ─────────────────────────────────────────────────────────

    /// @notice Current implied probability of YES in basis points (0-10000).
    ///         Returns 0 if pool is empty.
    function impliedProbabilityYes() external view returns (uint256 bps) {
        uint256 total = uint256(totalYesStake) + uint256(totalNoStake);
        if (total == 0) return 0;
        return (uint256(totalYesStake) * 10_000) / total;
    }

    function poolRatio() external view returns (uint256 yesBps, uint256 noBps) {
        uint256 total = uint256(totalYesStake) + uint256(totalNoStake);
        if (total == 0) return (0, 0);
        yesBps = (uint256(totalYesStake) * 10_000) / total;
        noBps = 10_000 - yesBps;
    }

    struct UserPosition {
        uint96 yesStake;
        uint96 noStake;
        uint96 principal;
        uint128 yesTwab;
        uint128 noTwab;
        bool claimed;
        bool withdrawnEarly;
    }

    function userPosition(address who) external view returns (UserPosition memory) {
        User storage u = users[who];
        return UserPosition({
            yesStake: u.yesStake,
            noStake: u.noStake,
            principal: u.principal,
            yesTwab: u.yesTwab,
            noTwab: u.noTwab,
            claimed: u.claimed,
            withdrawnEarly: u.principalWithdrawn
        });
    }
}
