// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ProbabilityVaultV2.sol";
import "./interfaces/IResolver.sol";

/// @notice Minimal interface for the YieldVault hold-time bypass added to
///         mitigate audit finding H-01. Not imported from IYieldVault because
///         it's a vault-specific admin function.
interface IYieldVaultTrustRegistrar {
    function setTrustedDepositor(address depositor, bool trusted) external;
}

/// @title ProbabilityVaultFactory
/// @notice Factory for AMM-style no-loss probability vaults that mirror
///         Polymarket markets. Coexists with MirrorContestFactory (fixed
///         tournament) — creators pick which product at creation time.
///
///         Hardcoded invariants:
///           - depositAmount is NOT fixed per-vault (variable deposits allowed)
///           - No minimum/maximum deposit at protocol level (market handles it)
///           - joinEnd ≤ polymarketEndDate − DEPOSIT_LOCKOUT (24h)
///           - resolveStart ≥ polymarketEndDate + REVEAL_BUFFER (36h)
///           - cancelDeadline ∈ [polymarketEndDate + MIN_CANCEL_TIMEOUT (7d),
///             polymarketEndDate + MAX_CANCEL_TIMEOUT (30d)]; 0 → 7d default
///           - duration ≤ MAX_CONTEST_DURATION (365d)
///
///         Owner-configurable economics (snapshotted per-vault at creation):
///           - protocolFeeBps (default 200 = 2% of yield)
///           - swapFeeBps (default 20 = 0.2% of swapped amount)
///           - feeEnabled (master kill-switch — 0% on new vaults when off)
///           - minTier (default 0 = anonymous; cap MAX_MIN_TIER = 5)
///           - mirrorResolverFee (USDC fee at creation, funds relayer wallet)
///           - resolverTreasury (destination for resolver fee)
///
///         Tier policy: yield markets are intentionally tier 0 / anonymous —
///         depositors are buying a yield-only outcome (principal is always
///         returned), there is no vote to sybil. The min-tier knob exists so
///         a future product variant (e.g. a creator-curated market with
///         identity-gated participants) can opt back into the tier check
///         without redeploying the factory; the previous hard-coded floor of
///         2 silently bricked the 2026-04-28 mainnet redeploy because the
///         IdentityRegistry was empty and no on-chain attestor was wired up.
contract ProbabilityVaultFactory is Ownable2Step {
    using Clones for address;
    using SafeERC20 for IERC20;

    // ─── Errors ────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidParams();
    error VaultExists();
    error FeeOverCap();
    error TreasuryUnset();
    error MinTierTooHigh();
    error Paused();
    error NotPaused();
    error NotGuardianOrOwner();

    // ─── State ─────────────────────────────────────────────────────────

    address public implementation;
    address public yieldVault;
    address public yieldStrategy;     // strategy 0 in the vault
    address public identityRegistry;

    // Economics
    uint96  public protocolFeeBps = 200;      // 2% on yield
    uint96  public swapFeeBps     = 20;       // 0.2% per swap
    bool    public feeEnabled     = true;
    address public immutable protocolFeeRecipient;

    /// @notice Minimum IdentityRegistry tier required to deposit into clones
    ///         created by this factory. Default 0 means yield markets are
    ///         open to anonymous deposits — the no-loss + yield-only model
    ///         doesn't have a vote that needs sybil resistance. Owner can
    ///         raise this up to MAX_MIN_TIER for product variants that DO
    ///         want identity-gated participation.
    uint8   public minTier;

    // Mirror-resolver economics
    uint256 public mirrorResolverFee;
    address public resolverTreasury;

    // ─── Pausable (per-factory; gates new vault creation only) ────────
    // Same pattern as ContestFactoryV2 / YieldVault. Guardian (cold key)
    // can pause without timelock; unpause is owner-only (48h Timelock).
    // Pause halts new vault creation AND new deposits/swaps on every
    // existing ProbabilityVaultV2 clone (each reads
    // `IPausable(factory).paused()`); withdraw/claim/resolve paths are
    // never gated.
    bool public paused;
    address public guardian;
    event ProbabilityVaultFactoryPaused(address indexed by, uint256 timestamp);
    event ProbabilityVaultFactoryUnpaused(address indexed by, uint256 timestamp);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // Vault tracking
    mapping(bytes32 => address) public vaults;
    bytes32[] public vaultIds;
    mapping(address => bytes32[]) public creatorVaults;
    mapping(address => address) public resolverForVault;

    uint256 private _vaultNonce;

    // ─── Constants ─────────────────────────────────────────────────────

    /// @notice Upper bound on `minTier`. Matches the 6-tier IdentityRegistry
    ///         scale (Anon..Legendary, max useful value is 5 = Elite).
    uint8   public constant MAX_MIN_TIER            = 5;
    uint8   public constant CANCEL_MINORITY_PCT     = 5;
    uint256 public constant DEPOSIT_LOCKOUT         = 24 hours;
    uint256 public constant REVEAL_BUFFER           = 36 hours;
    /// @notice Default settlement-timeout window after polymarketEndDate. A
    ///         vault that still has not resolved by `polymarketEndDate +
    ///         CANCEL_TIMEOUT` force-cancels (principal refunded). Used when the
    ///         creator passes `cancelDeadline == 0`.
    uint256 public constant CANCEL_TIMEOUT          = 7 days;
    /// @notice Bounds for a creator-supplied `cancelDeadline` override
    ///         (configurable settlement-timeout window). A LONGER window gives
    ///         the relayer/resolver more time to settle before the vault
    ///         force-cancels — strictly safer for resolution during an RPC or
    ///         relayer outage — at the cost of locking principal longer. We cap
    ///         it so a creator cannot trap funds for an unreasonable time, and
    ///         floor it so the window can never undercut the resolver's own
    ///         7-day settlement timeout in a way that would cancel a market
    ///         that could still settle. The effective deadline is additionally
    ///         required to sit strictly after `resolveStart`. The cap is held
    ///         at 30 days (4× the resolver's 7-day settlement timeout — ample
    ///         resolution margin) so a creator cannot lock participant
    ///         principal for an unreasonable time on a never-resolving market.
    uint256 public constant MIN_CANCEL_TIMEOUT      = 7 days;
    uint256 public constant MAX_CANCEL_TIMEOUT      = 30 days;
    uint256 public constant MAX_CONTEST_DURATION    = 365 days;
    uint96  public constant SWAP_FEE_MAX_BPS        = 1_000;  // 10% ceiling
    /// @dev Aligned with the platform-wide 5% yield-fee cap shared by
    ///      ContestFactoryV2 and NoLossLotteryV3. Tighter than the prior
    ///      placeholder (10_000 bps) so a compromised owner cannot hike
    ///      the yield fee on new vaults beyond the documented invariant.
    uint96  public constant PROTOCOL_FEE_MAX_BPS    = 500;    // 5% ceiling

    // ─── Events ────────────────────────────────────────────────────────

    /// @dev Mirrors the ContestCreated signature used by ContestFactoryV2 +
    ///      MirrorContestFactory for indexer reuse. conditionId in the 4th
    ///      indexed slot; indexer dispatches by factory address.
    event VaultCreated(
        bytes32 indexed vaultId,
        address indexed vaultAddress,
        address indexed creator,
        bytes32 conditionId
    );

    /// @dev Factory-specific aux event so indexers can distinguish Probability
    ///      Vault creation from Mirror-tournament creation.
    event ProbabilityVaultCreated(
        bytes32 indexed vaultId,
        address indexed vaultAddress,
        bytes32 conditionId,
        uint96 swapFeeBps,
        uint96 protocolFeeBps
    );
    event ResolverBound(address indexed vault, address indexed resolver);
    event YieldVaultTrustRegistered(address indexed vault);
    event YieldVaultTrustRegistrationFailed(address indexed vault);
    event MirrorResolverFeePaid(address indexed creator, address indexed treasury, uint256 amount);
    event ImplementationUpdated(address newImpl);
    event ProtocolFeeUpdated(uint96 newFee);
    event SwapFeeUpdated(uint96 newFee);
    event FeeEnabledUpdated(bool enabled);
    event MinTierUpdated(uint8 oldTier, uint8 newTier);
    event MirrorResolverFeeUpdated(uint256 newFee);
    event ResolverTreasuryUpdated(address indexed newTreasury);
    // FeeRecipientUpdated event removed 2026-04-28 — protocolFeeRecipient is now immutable.

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(
        address _implementation,
        address _yieldVault,
        address _yieldStrategy,
        address _identityRegistry,
        address _feeRecipient
    ) Ownable() {
        if (_implementation == address(0)) revert ZeroAddress();
        if (_yieldVault == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        implementation        = _implementation;
        yieldVault            = _yieldVault;
        yieldStrategy         = _yieldStrategy;
        identityRegistry      = _identityRegistry;
        protocolFeeRecipient  = _feeRecipient;
    }

    // ─── Vault creation ────────────────────────────────────────────────

    struct CreateParams {
        address depositToken;
        uint64  polymarketEndDate;
        uint64  joinEnd;         // must be ≤ polymarketEndDate - DEPOSIT_LOCKOUT; 0 → use default (polymarketEndDate − 25h)
        uint64  resolveStart;    // must be ≥ polymarketEndDate + REVEAL_BUFFER; 0 → use default (polymarketEndDate + 37h)
        uint64  cancelDeadline;  // settlement-timeout: must be in [polymarketEndDate + MIN_CANCEL_TIMEOUT, polymarketEndDate + MAX_CANCEL_TIMEOUT] and > resolveStart; 0 → use default (polymarketEndDate + CANCEL_TIMEOUT = 7d)
        bytes32 yesOption;
        bytes32 noOption;
        bytes32 conditionId;
        bytes32 metadataHash;
        string  metadataUri;
        address resolver;
    }

    function createVault(CreateParams calldata p)
        external
        whenNotPaused
        returns (bytes32 vaultId, address vaultAddress)
    {
        // Copy calldata → memory once at the external entrypoint. The shared
        // implementation `_createVault` lives entirely in memory so via_ir
        // doesn't trip over the stack-too-deep limit it hit when the helper
        // pulled fields directly from a calldata struct alongside the inline
        // resolver-fee + Clones.clone() + initialize() locals (2026-04-28).
        return _createVault(p);
    }

    /// @notice Create N vaults in a single transaction. Use when one
    ///         Polymarket event has multiple sub-markets (different
    ///         settlement dates, multi-outcome variants) and the creator
    ///         wants to launch them all in one go. Each vault is created
    ///         independently — params can mix conditionIds, end dates, and
    ///         metadata. Reverts atomically if any single vault fails so
    ///         the caller never ends up with a partial event launch.
    ///
    ///         Resolver fee is charged once per vault, same as createVault.
    ///         Caller must approve a sufficient `mirrorResolverFee * params.length`.
    function createVaultsBatch(CreateParams[] calldata params)
        external
        whenNotPaused
        returns (bytes32[] memory vaultIdsOut, address[] memory vaultAddressesOut)
    {
        uint256 n = params.length;
        if (n == 0) revert InvalidParams();
        // Soft cap to keep gas bounded — 20 variants is well above any real
        // Polymarket event size we've seen and stays under the Base block
        // gas limit even for the most expensive deploy path.
        if (n > 20) revert InvalidParams();
        vaultIdsOut = new bytes32[](n);
        vaultAddressesOut = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            (vaultIdsOut[i], vaultAddressesOut[i]) = _createVault(params[i]);
        }
    }

    function _createVault(CreateParams memory p)
        internal
        returns (bytes32 vaultId, address vaultAddress)
    {
        if (p.depositToken == address(0)) revert ZeroAddress();
        if (p.resolver == address(0)) revert ZeroAddress();
        if (p.conditionId == bytes32(0)) revert InvalidParams();
        if (p.yesOption == bytes32(0) || p.noOption == bytes32(0)) revert InvalidParams();
        if (p.yesOption == p.noOption) revert InvalidParams();
        if (p.polymarketEndDate <= block.timestamp) revert InvalidParams();
        if (p.polymarketEndDate > block.timestamp + MAX_CONTEST_DURATION) revert InvalidParams();

        // Resolve timing — caller can provide overrides, otherwise use the
        // default "floor + small safety margin" derived from polymarketEndDate.
        uint64 joinEndEff = p.joinEnd == 0
            ? uint64(uint256(p.polymarketEndDate) - DEPOSIT_LOCKOUT - 1 hours)
            : p.joinEnd;
        uint64 resolveStartEff = p.resolveStart == 0
            ? uint64(uint256(p.polymarketEndDate) + REVEAL_BUFFER + 1 hours)
            : p.resolveStart;

        if (joinEndEff <= block.timestamp) revert InvalidParams();
        if (joinEndEff > uint256(p.polymarketEndDate) - DEPOSIT_LOCKOUT) revert InvalidParams();
        if (resolveStartEff < uint256(p.polymarketEndDate) + REVEAL_BUFFER) revert InvalidParams();

        // Settlement-timeout window. Caller may extend it (e.g. to survive a
        // multi-day relayer/RPC outage without force-cancelling a market that
        // could still settle); 0 → 7-day default. Bounded so a creator can
        // neither undercut the resolver's settlement timeout nor trap principal
        // for an unreasonable time, and must sit strictly after resolveStart.
        uint64 cancelDeadline = p.cancelDeadline == 0
            ? uint64(uint256(p.polymarketEndDate) + CANCEL_TIMEOUT)
            : p.cancelDeadline;
        if (cancelDeadline < uint256(p.polymarketEndDate) + MIN_CANCEL_TIMEOUT) revert InvalidParams();
        if (cancelDeadline > uint256(p.polymarketEndDate) + MAX_CANCEL_TIMEOUT) revert InvalidParams();
        if (cancelDeadline <= resolveStartEff) revert InvalidParams();

        // Resolver fee (sustains relayer wallet). Charged upfront so the
        // creator pays their share of infra, not other participants.
        //
        // next-redeploy: switch this fee from depositToken (USDC) to native
        // ETH so it can be forwarded straight to the relayer EOA without an
        // off-chain swap. The relayer EOA pays gas in ETH, so collecting USDC
        // here forces a USDC->ETH conversion on every quarterly top-up. To
        // change: mark createVault / createVaultsBatch `payable`, replace this
        // safeTransferFrom block with `(bool ok,) = resolverTreasury.call{
        // value: mirrorResolverFee}(""); require(ok, "RelayerXferFailed");`,
        // and validate `msg.value == mirrorResolverFee * params.length` in
        // the batch path. See docs/NEXT_REDEPLOY_CHECKLIST.md item #1.
        if (mirrorResolverFee > 0) {
            if (resolverTreasury == address(0)) revert TreasuryUnset();
            IERC20(p.depositToken).safeTransferFrom(msg.sender, resolverTreasury, mirrorResolverFee);
            emit MirrorResolverFeePaid(msg.sender, resolverTreasury, mirrorResolverFee);
        }

        // Generate vaultId (nonce prevents same-block collisions).
        vaultId = keccak256(abi.encodePacked(
            msg.sender, block.timestamp, p.metadataHash, _vaultNonce++
        ));
        if (vaults[vaultId] != address(0)) revert VaultExists();

        // Clone + initialize
        vaultAddress = implementation.clone();

        uint96 effProtocolFee = feeEnabled ? protocolFeeBps : uint96(0);
        uint96 effSwapFee     = feeEnabled ? swapFeeBps     : uint96(0);

        ProbabilityVaultV2.InitParams memory init = ProbabilityVaultV2.InitParams({
            creator:               msg.sender,
            depositToken:          p.depositToken,
            joinEnd:               joinEndEff,
            polymarketEndDate:     p.polymarketEndDate,
            resolveStart:          resolveStartEff,
            cancelDeadline:        cancelDeadline,
            tierRequired:          minTier,
            cancelMinorityPct:     CANCEL_MINORITY_PCT,
            yesOption:             p.yesOption,
            noOption:              p.noOption,
            conditionId:           p.conditionId,
            metadataHash:          p.metadataHash,
            metadataUri:           p.metadataUri,
            resolver:              p.resolver,
            yieldVault:            yieldVault,
            yieldStrategy:         yieldStrategy,
            identityRegistry:      identityRegistry,
            protocolFeeBps:        effProtocolFee,
            swapFeeBps:            effSwapFee,
            protocolFeeRecipient:  protocolFeeRecipient
        });
        ProbabilityVaultV2(vaultAddress).initialize(init);

        // Bind resolver
        resolverForVault[vaultAddress] = p.resolver;
        bytes32 vaultKey = bytes32(uint256(uint160(vaultAddress)));
        bytes memory resolverParams = abi.encode(
            p.conditionId, p.yesOption, p.noOption, p.polymarketEndDate
        );
        IResolver(p.resolver).register(vaultKey, resolverParams);

        vaults[vaultId] = vaultAddress;
        vaultIds.push(vaultId);
        creatorVaults[msg.sender].push(vaultId);

        // Register the new clone as a trusted YieldVault depositor so the
        // per-contest flash-loan guards (in ProbabilityVaultV2 itself) are the
        // sole defense — without this the YieldVault's per-SENDER hold-time
        // grant becomes a DoS on withdrawEarly across all users of this clone
        // (audit H-01, 2026-04-18). Requires that this factory has been
        // pre-authorized as YieldVault owner OR that a post-deploy script
        // calls yieldVault.setTrustedDepositor(clone, true). We try the
        // automatic path first and swallow any revert so factory ownership
        // misconfiguration doesn't block vault creation — the deploy runbook
        // (docs/YIELD_MARKET_DEPLOYMENT.md §7) covers the manual fallback.
        try IYieldVaultTrustRegistrar(yieldVault).setTrustedDepositor(vaultAddress, true) {
            emit YieldVaultTrustRegistered(vaultAddress);
        } catch {
            emit YieldVaultTrustRegistrationFailed(vaultAddress);
        }

        emit ResolverBound(vaultAddress, p.resolver);
        emit VaultCreated(vaultId, vaultAddress, msg.sender, p.conditionId);
        emit ProbabilityVaultCreated(vaultId, vaultAddress, p.conditionId, effSwapFee, effProtocolFee);
    }

    /// @notice Factory-only emergency cancel, in case a vault needs to be
    ///         torn down before finalize (compromised resolver, etc.).
    function emergencyCancelVault(bytes32 vaultId) external onlyOwner {
        address vaultAddress = vaults[vaultId];
        if (vaultAddress == address(0)) revert InvalidParams();
        ProbabilityVaultV2(vaultAddress).emergencyCancel();
    }

    /// @notice Sweep residual USDC dust trapped on a CANCELLED vault after
    ///         the 30-day post-cancelDeadline grace window. Routes to the
    ///         protocol fee recipient configured on the vault at creation.
    ///         Only callable for vaults already in CANCELLED state.
    function rescueVaultDust(bytes32 vaultId) external onlyOwner {
        address vaultAddress = vaults[vaultId];
        if (vaultAddress == address(0)) revert InvalidParams();
        ProbabilityVaultV2(vaultAddress).rescueTrappedDust();
    }

    // ─── Owner setters ────────────────────────────────────────────────

    function setImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert ZeroAddress();
        implementation = newImpl;
        emit ImplementationUpdated(newImpl);
    }

    function setProtocolFee(uint96 newFee) external onlyOwner {
        if (newFee > PROTOCOL_FEE_MAX_BPS) revert FeeOverCap();
        protocolFeeBps = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    function setSwapFee(uint96 newFee) external onlyOwner {
        if (newFee > SWAP_FEE_MAX_BPS) revert FeeOverCap();
        swapFeeBps = newFee;
        emit SwapFeeUpdated(newFee);
    }

    function setFeeEnabled(bool enabled) external onlyOwner {
        feeEnabled = enabled;
        emit FeeEnabledUpdated(enabled);
    }

    /// @notice Update the minimum tier required to deposit into NEW vaults
    ///         created by this factory. Existing clones snapshot `minTier`
    ///         into their per-clone storage at initialize() and are not
    ///         affected — see ProbabilityVaultV2.tierRequired (immutable
    ///         post-init). Capped at MAX_MIN_TIER (= 5) so a compromised
    ///         owner cannot brick deposits by setting an unreachable tier.
    function setMinTier(uint8 newTier) external onlyOwner {
        if (newTier > MAX_MIN_TIER) revert MinTierTooHigh();
        uint8 old = minTier;
        minTier = newTier;
        emit MinTierUpdated(old, newTier);
    }

    // setFeeRecipient REMOVED 2026-04-28 — protocolFeeRecipient is now immutable.
    // ProbabilityVaultV2 clones already snapshot it at initialize(), so live vaults
    // were always immune; this change extends the guarantee to future vaults.
    // To rotate the recipient, deploy a new factory.

    // next-redeploy: when createVault becomes payable + ETH-denominated, this
    // setter still works as-is (the units just change from 6-dec USDC to wei).
    // Pick a wei amount that approximates the desired USD value at deploy
    // time; retune via Timelock when ETH price moves materially. Currently
    // 0 — fee gating is OFF until the next factory deploy.
    function setMirrorResolverFee(uint256 newFee) external onlyOwner {
        mirrorResolverFee = newFee;
        emit MirrorResolverFeeUpdated(newFee);
    }

    // next-redeploy: harden by making `resolverTreasury` constructor-immutable
    // (same pattern as protocolFeeRecipient above) and removing this setter.
    // Until then, treat any change to this address as a security event — any
    // monitor should page on a non-expected value. See
    // docs/NEXT_REDEPLOY_CHECKLIST.md items #1 and #4.
    function setResolverTreasury(address newTreasury) external onlyOwner {
        resolverTreasury = newTreasury;
        emit ResolverTreasuryUpdated(newTreasury);
    }

    // ─── Pause controls ─────────────────────────────────────────────────

    function pause() external whenNotPaused {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        paused = true;
        emit ProbabilityVaultFactoryPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit ProbabilityVaultFactoryUnpaused(msg.sender, block.timestamp);
    }

    function setGuardian(address _guardian) external onlyOwner {
        emit GuardianUpdated(guardian, _guardian);
        guardian = _guardian;
    }

    // ─── Views ────────────────────────────────────────────────────────

    function getVault(bytes32 vaultId) external view returns (address) {
        return vaults[vaultId];
    }

    function getVaultCount() external view returns (uint256) {
        return vaultIds.length;
    }

    function getCreatorVaults(address creator) external view returns (bytes32[] memory) {
        return creatorVaults[creator];
    }
}
