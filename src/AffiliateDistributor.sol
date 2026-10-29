// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title AffiliateDistributor
 * @notice Cumulative merkle-based USDC distributor for affiliate/referral rewards.
 *
 * Design — inspired by 1inch / Hop / Badger cumulative distributors:
 *
 *   - A "root poster" address (held by a backend hot wallet, separate from
 *     the owner) posts new merkle roots periodically (e.g. weekly).
 *   - Each leaf is keccak256(abi.encodePacked(address, cumulativeAmount))
 *     where cumulativeAmount is the user's LIFETIME allocation.
 *   - Users call claim() and receive (cumulativeAmount - alreadyClaimed).
 *   - Historical roots remain valid — users who miss a cycle lose nothing.
 *   - claimed[user] is cumulative and monotonically increases.
 *
 * Security layers (defense in depth):
 *   1. Split authority — owner() holds ALL sensitive setters; a separate
 *      `isRootPoster[]` allowlist holds the routine merkle-root-posting
 *      authority. The split lets the backend hot wallet post on a cron
 *      without invoking the 48h timelock per cycle, while sensitive
 *      operations (rescue, pause-toggle, root revocation, allowlist
 *      changes) stay under the timelock-owned owner key. A compromised
 *      poster cannot drain funds, change parameters, or add new posters —
 *      only post roots whose damage is rate-limited and pause-able.
 *   2. Guardian — separate role that can emergency-pause claims (and is the
 *      first responder to a malicious root).
 *   3. Pausable — halts claims but cannot drain funds.
 *   4. Per-claim cap — rate limits claim payouts (partial-claim-safe: users
 *      can drain their full allocation across multiple txs, the cap only
 *      slows the rate). Gives the guardian a window to pause a malicious root.
 *   5. revokeRoot — owner (timelock) can void a specific root version,
 *      neutralizing a malicious root posted by a compromised poster without
 *      affecting honest historical roots.
 *   6. ReentrancyGuard — claim() is non-reentrant.
 *   7. Rescue function — owner can recover non-distribution tokens or
 *      leftover USDC, but only after MIN_RESCUE_DELAY (enforced at deploy).
 *   8. Monotonic claimed[] — cannot decrease, prevents replay. A malicious
 *      root that LOWERS a user's cumulative allocation is harmless; only
 *      INCREASING a cumulative allocation transfers value, and that path is
 *      capped by maxSingleClaim and ROOT_EXPIRY.
 *   9. Alternate recipient — caller can redirect payout to any address they
 *      control; merkle leaf binds msg.sender so only the rightful owner
 *      can redirect. Escape hatch when USDC blacklists the claimer.
 *
 * Trust model:
 *   - Owner = TimelockController (48h delay) for parameter changes, rescue,
 *     pause toggle, root revocation, and rotating the root-poster allowlist.
 *   - Root poster = backend service account (rotatable); compromise is
 *     contained by layers 2-5 above.
 *   - Guardian = pause-only multisig (separate signer set from the timelock).
 *   - Full transparency via IPFS CID stored with each root.
 *
 * @dev We deliberately use a hand-rolled `isRootPoster` mapping instead of
 *      OpenZeppelin AccessControl. Adding AccessControl to this contract
 *      tipped the rest of the file over Yul's stack-too-deep limit under
 *      via_ir. The mapping carries the same authority split with a smaller
 *      bytecode and code-path footprint.
 */
contract AffiliateDistributor is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Allowlist of addresses permitted to call `postRoot`. Held by
    /// automated backend hot wallets so routine merkle posts can run on a
    /// schedule without invoking the 48h timelock per cycle. Granted /
    /// revoked by the owner (timelock). Compromise is bounded by
    /// maxSingleClaim, pause(), and revokeRoot().
    mapping(address => bool) public isRootPoster;

    /// @notice The USDC token distributed by this contract (immutable for safety).
    IERC20 public immutable token;

    /// @notice Maximum USDC a single claim transaction can pay out.
    /// Bounds the damage if a malicious root is posted. Set at deployment,
    /// adjustable by owner (intended to be raised over time as trust grows).
    uint256 public maxSingleClaim;

    /// @notice Guardian can pause the contract in emergencies (but not unpause or move funds).
    address public guardian;

    /// @notice Timelock (in seconds) before rescueToken() can pull the distribution token.
    /// Prevents rugpull via emergency rescue. Non-distribution tokens are rescuable instantly.
    uint256 public immutable rescueDelay;

    /// @notice Timestamp of the latest rescue request (0 if no active request).
    uint256 public rescueRequestedAt;

    /// @notice Current latest root version (monotonic).
    uint256 public currentRootVersion;

    struct RootData {
        bytes32 root;
        uint64 postedAt;
        uint192 totalAllocated; // Sum of all cumulativeAmounts in this root
        string ipfsCid;         // IPFS CID of the full manifest for auditability
    }

    /// @notice Historical merkle roots — users can claim against ANY past root they're in.
    /// @dev rootVersion => RootData. Version 0 is reserved (unset).
    mapping(uint256 => RootData) public roots;

    /// @notice Lifetime cumulative amount claimed per user across all roots.
    /// Since leaves encode cumulative amounts, this is monotonic and replay-safe.
    mapping(address => uint256) public claimed;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RootPosted(uint256 indexed rootVersion, bytes32 indexed root, uint256 totalAllocated, string ipfsCid);
    event RootRevoked(uint256 indexed rootVersion, bytes32 indexed root);
    event RootPosterUpdated(address indexed poster, bool enabled);
    event Claimed(
        address indexed user,
        address indexed recipient,
        uint256 amount,
        uint256 indexed rootVersion,
        uint256 newCumulative
    );
    event MaxSingleClaimUpdated(uint256 oldValue, uint256 newValue);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event RescueRequested(uint256 availableAt);
    event RescueCancelled();
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event Funded(address indexed from, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidProof();
    error NothingToClaim();
    error UnknownRoot();
    error RootExpired();
    error InvalidRoot();
    error InvalidAmount();
    error NotGuardianOrOwner();
    error RescueNotReady();
    error RescueNotRequested();
    error InsufficientBalance();
    error RescueDelayTooShort();
    error RootAlreadyRevoked();
    error MissingRootPosterRole();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Minimum allowable rescueDelay. Prevents the anti-rug timelock
    /// from being silently set to zero at deployment.
    uint256 public constant MIN_RESCUE_DELAY = 1 days;
    /// @notice Merkle roots expire after 180 days — prevents replay of roots with errors.
    uint256 public constant ROOT_EXPIRY = 180 days;

    /**
     * @param _token           The ERC20 token distributed (USDC on Base).
     * @param _guardian        Emergency-pause role (can be same as owner initially).
     * @param _maxSingleClaim  Per-claim cap in token units (e.g. 50_000e6 for $50K USDC).
     * @param _rescueDelay     Seconds before owner can rescue distribution token.
     *                         MUST be >= MIN_RESCUE_DELAY (1 day). Production
     *                         deployments should use >= 7 days.
     * @param _initialRootPoster Address added to the root-poster allowlist
     *                         at deploy. May be address(0) to skip and
     *                         allowlist later via `setRootPoster()`.
     *                         Typically the backend hot wallet that signs
     *                         root-posting txs.
     *
     * @dev Deploy flow:
     *   1. Deployer (msg.sender) becomes owner() via Ownable() and seeds
     *      the initial root-poster allowlist (if provided).
     *   2. Deployer transfers ownership to TimelockController (Ownable2Step
     *      two-step), timelock accepts.
     *   3. From that point on, only the timelock can rotate the
     *      root-poster allowlist via `setRootPoster()`. The runbook
     *      (docs/MAINNET_RELAUNCH_RUNBOOK.md) covers this handoff.
     */
    constructor(
        IERC20 _token,
        address _guardian,
        uint256 _maxSingleClaim,
        uint256 _rescueDelay,
        address _initialRootPoster
    ) Ownable() {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (_guardian == address(0)) revert ZeroAddress();
        if (_maxSingleClaim == 0) revert InvalidAmount();
        if (_rescueDelay < MIN_RESCUE_DELAY) revert RescueDelayTooShort();

        token = _token;
        guardian = _guardian;
        maxSingleClaim = _maxSingleClaim;
        rescueDelay = _rescueDelay;

        if (_initialRootPoster != address(0)) {
            isRootPoster[_initialRootPoster] = true;
            emit RootPosterUpdated(_initialRootPoster, true);
        }
    }

    // -------------------------------------------------------------------------
    // User claim
    // -------------------------------------------------------------------------

    /**
     * @notice Claim USDC owed to the caller. Authorization is via the merkle
     *         proof (the leaf binds msg.sender), so only the allocation's
     *         rightful owner can trigger the claim.
     *
     * @dev    PARTIAL CLAIMS: if the available delta (cumulativeAmount - already
     *         claimed) exceeds `maxSingleClaim`, the payout is capped at
     *         `maxSingleClaim` and `claimed[]` advances by the capped amount
     *         only. Users can call claim() again against the same or a later
     *         root to continue draining. This ensures the per-claim cap
     *         functions as a rate limiter, NOT as a fund-lock.
     *
     * @dev    ALTERNATE RECIPIENT: the caller can direct funds to any
     *         non-zero address. This is safe because the merkle leaf binds
     *         msg.sender — only the allocation owner can set recipient.
     *         Needed when USDC has blacklisted the claimer's own address.
     *
     * @param rootVersion       The merkle root version the proof is against.
     * @param cumulativeAmount  The user's LIFETIME cumulative allocation (not delta).
     * @param recipient         Destination address for the USDC transfer.
     *                          Usually msg.sender but can be any address the
     *                          caller controls; blacklist-bypass escape hatch.
     * @param proof             Merkle proof.
     */
    function claim(
        uint256 rootVersion,
        uint256 cumulativeAmount,
        address recipient,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        _verifyClaimProof(rootVersion, cumulativeAmount, proof);

        (uint256 payout, uint256 newCumulative) =
            _settleClaim(msg.sender, cumulativeAmount);

        token.safeTransfer(recipient, payout);
        emit Claimed(msg.sender, recipient, payout, rootVersion, newCumulative);
    }

    /// @dev Validates the merkle proof against `roots[rootVersion]` and
    ///      reverts on any failure. Extracted from claim() to keep the
    ///      caller's stack frame small enough for via_ir.
    function _verifyClaimProof(
        uint256 rootVersion,
        uint256 cumulativeAmount,
        bytes32[] calldata proof
    ) private view {
        bytes32 storedRoot = roots[rootVersion].root;
        if (storedRoot == bytes32(0)) revert UnknownRoot();
        if (block.timestamp > roots[rootVersion].postedAt + ROOT_EXPIRY) revert RootExpired();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, cumulativeAmount));
        if (!MerkleProof.verify(proof, storedRoot, leaf)) revert InvalidProof();
    }

    /// @dev Computes the partial-claim payout (capped at maxSingleClaim) and
    ///      advances `claimed[user]` accordingly. Returns the (payout,
    ///      newCumulative) pair to the caller. Extracted from claim() for
    ///      via_ir stack hygiene.
    function _settleClaim(address user, uint256 cumulativeAmount)
        private
        returns (uint256 payout, uint256 newCumulative)
    {
        uint256 already = claimed[user];
        if (cumulativeAmount <= already) revert NothingToClaim();

        unchecked {
            // Safe: we just checked cumulativeAmount > already.
            uint256 delta = cumulativeAmount - already;
            uint256 cap = maxSingleClaim;
            if (delta > cap) {
                // Partial claim — pay up to cap, advance claimed by cap only.
                payout = cap;
                newCumulative = already + cap;
            } else {
                payout = delta;
                newCumulative = cumulativeAmount;
            }
        }

        // Effects before interaction (caller does the transfer).
        claimed[user] = newCumulative;
    }

    // -------------------------------------------------------------------------
    // Root poster: root posting
    // -------------------------------------------------------------------------

    /**
     * @notice Post a new merkle root for a distribution cycle.
     * @dev Each call creates a NEW version; historical roots remain valid so users
     *      can claim against any of them. This means posting a bad root cannot
     *      invalidate a user's prior honest allocation.
     *
     *      Callable by any address on the root-poster allowlist — typically
     *      an automated backend hot wallet. Compromise of the poster key
     *      is contained: the timelock can revokeRoot() the malicious
     *      version and call setRootPoster(poster, false); meanwhile
     *      maxSingleClaim and the guardian-pause window cap the bleed rate.
     *
     * @param merkleRoot      The Merkle root.
     * @param totalAllocated  The sum of all cumulativeAmount leaves (for transparency).
     *                        NOTE: cumulative across all users at this snapshot —
     *                        not the delta since last root.
     * @param ipfsCid         IPFS CID of the full manifest JSON for auditability.
     */
    function postRoot(
        bytes32 merkleRoot,
        uint256 totalAllocated,
        string calldata ipfsCid
    ) external returns (uint256 version) {
        if (!isRootPoster[msg.sender]) revert MissingRootPosterRole();
        if (merkleRoot == bytes32(0)) revert InvalidRoot();
        if (totalAllocated > type(uint192).max) revert InvalidAmount();

        unchecked {
            version = ++currentRootVersion;
        }

        roots[version] = RootData({
            root: merkleRoot,
            postedAt: uint64(block.timestamp),
            totalAllocated: uint192(totalAllocated),
            ipfsCid: ipfsCid
        });

        emit RootPosted(version, merkleRoot, totalAllocated, ipfsCid);
    }

    /**
     * @notice Owner-only emergency root revocation. Voids a specific root
     *         version so any further claims against it revert with
     *         UnknownRoot. Used to neutralize a malicious root posted by a
     *         compromised root poster before claims drain allocations
     *         beyond what maxSingleClaim already capped.
     *
     * @dev    Honest roots are unaffected — claims against a different
     *         version continue to work, so this is non-destructive to
     *         legitimate users. claimed[] is monotonic, so previously
     *         honored claims against the revoked root are NOT clawed back;
     *         only future claims against this version are blocked.
     */
    function revokeRoot(uint256 rootVersion) external onlyOwner {
        if (roots[rootVersion].root == bytes32(0)) revert RootAlreadyRevoked();
        bytes32 oldRoot = roots[rootVersion].root;
        delete roots[rootVersion];
        emit RootRevoked(rootVersion, oldRoot);
    }

    // -------------------------------------------------------------------------
    // Owner / guardian: pause controls
    // -------------------------------------------------------------------------

    /// @notice Either owner or guardian can pause. Intended for emergencies.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        _pause();
    }

    /// @notice Only owner can unpause — guardian is intentionally one-directional.
    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Owner: parameter updates
    // -------------------------------------------------------------------------

    /**
     * @notice Grant or revoke `postRoot` authority for `poster`. Owner-only,
     *         so under the production deployment this is timelock-gated and
     *         takes 48h to ripen — ideal for routine rotation. The owner can
     *         still pre-emptively pause via the guardian (instant) and use
     *         revokeRoot() (instant) if a compromised poster posts a malicious
     *         root before the rotation queue clears.
     */
    function setRootPoster(address poster, bool enabled) external onlyOwner {
        if (poster == address(0)) revert ZeroAddress();
        isRootPoster[poster] = enabled;
        emit RootPosterUpdated(poster, enabled);
    }

    function setMaxSingleClaim(uint256 newMax) external onlyOwner {
        if (newMax == 0) revert InvalidAmount();
        uint256 old = maxSingleClaim;
        maxSingleClaim = newMax;
        emit MaxSingleClaimUpdated(old, newMax);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        address old = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(old, newGuardian);
    }

    // -------------------------------------------------------------------------
    // Owner: funding and rescue
    // -------------------------------------------------------------------------

    /**
     * @notice Convenience funder — anyone can top up the contract with the
     *         distribution token. Emits a Funded event for accounting.
     *         Direct transfers to the contract work too but don't emit the event.
     */
    function fund(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Start the rescue delay clock for the distribution token.
    function requestRescue() external onlyOwner {
        rescueRequestedAt = block.timestamp;
        emit RescueRequested(block.timestamp + rescueDelay);
    }

    /// @notice Cancel an active rescue request.
    function cancelRescue() external onlyOwner {
        rescueRequestedAt = 0;
        emit RescueCancelled();
    }

    /**
     * @notice Rescue tokens from the contract.
     * @dev    For the distribution token, requires rescueRequestedAt + rescueDelay
     *         to have passed. For any other token (e.g. accidental deposits),
     *         rescue is immediate.
     */
    function rescueToken(IERC20 t, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (address(t) == address(token)) {
            // Distribution token — enforce timelock
            if (rescueRequestedAt == 0) revert RescueNotRequested();
            if (block.timestamp < rescueRequestedAt + rescueDelay) revert RescueNotReady();
            // Consume the request so a second rescue needs a fresh clock
            rescueRequestedAt = 0;
        }

        uint256 bal = t.balanceOf(address(this));
        if (amount > bal) revert InsufficientBalance();

        t.safeTransfer(to, amount);
        emit TokenRescued(address(t), to, amount);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Check how much a user could claim against a given root without
     *         submitting the claim (useful for UIs).
     */
    function claimableAmount(
        address user,
        uint256 rootVersion,
        uint256 cumulativeAmount
    ) external view returns (uint256) {
        uint256 already = claimed[user];
        if (cumulativeAmount <= already) return 0;
        if (roots[rootVersion].root == bytes32(0)) return 0;
        unchecked {
            return cumulativeAmount - already;
        }
    }

    /**
     * @notice Verify a merkle proof without state changes.
     */
    function verifyProof(
        uint256 rootVersion,
        address user,
        uint256 cumulativeAmount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 root = roots[rootVersion].root;
        if (root == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(user, cumulativeAmount));
        return MerkleProof.verify(proof, root, leaf);
    }
}
