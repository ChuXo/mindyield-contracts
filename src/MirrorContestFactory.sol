// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MirrorContestV2.sol";
import "./interfaces/IResolver.sol";

/// @title MirrorContestFactory
/// @notice Slim factory dedicated to Polymarket-mirror contests. Coexists
///         with the existing ContestFactoryV2 — non-mirror flows continue
///         to use that factory. This one ONLY creates MirrorContestV2 clones.
///
///         Hardcoded sybil/insider guards (no owner override):
///           - depositAmount > 0 (no free-to-join sponsored mirrors)
///           - tierRequired ≥ MIRROR_MIN_TIER (Identity-verified users only)
///           - maxParticipants ≥ MIRROR_MIN_PARTICIPANTS
///           - depositEnd ≤ polymarketEndDate − MIRROR_DEPOSIT_LOCKOUT
///           - revealEnd ≥ polymarketEndDate + MIRROR_REVEAL_BUFFER
///
///         Owner-configurable economics:
///           - protocolFeePercentage (default 200 bps = 2%, snapshotted per contest)
///           - feeEnabled (kill switch — sets effectiveFee to 0 on new contests)
///           - mirrorResolverFee (USDC fee at creation, funds relayer wallet)
///           - resolverTreasury (destination for resolver fee)
contract MirrorContestFactory is Ownable2Step {
    using Clones for address;
    using SafeERC20 for IERC20;

    // ─── State ─────────────────────────────────────────────────────────

    address public mirrorImplementation;
    address public yieldVault;
    address public yieldStrategy;          // strategy 0 in the vault
    address public identityRegistry;

    // Protocol fee
    /// @dev Hard ceiling for protocolFeePercentage. Aligned with the
    ///      platform-wide 5% yield-fee cap shared by ContestFactoryV2 and
    ///      NoLossLotteryV3, so a compromised owner cannot hike the
    ///      yield fee on new mirror contests beyond the documented invariant.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 500; // 5%
    uint256 public protocolFeePercentage = 200; // 2% in basis points
    address public protocolFeeRecipient;
    bool    public feeEnabled = true;

    // Mirror-resolver economics
    uint256 public mirrorResolverFee;       // USDC (6-dec), per-contest
    address public resolverTreasury;        // destination for relayer top-ups

    // Contest tracking
    mapping(bytes32 => address) public contests;
    bytes32[] public contestIds;
    mapping(address => bytes32[]) public creatorContests;
    mapping(address => address) public resolverForContest;

    uint256 private _contestNonce;

    // ─── Constants (hardcoded guards) ─────────────────────────────────

    uint8   public constant MIRROR_MIN_TIER          = 2;
    uint96  public constant MIRROR_MIN_PARTICIPANTS  = 10;
    uint256 public constant MIRROR_DEPOSIT_LOCKOUT   = 24 hours;
    uint256 public constant MIRROR_REVEAL_BUFFER     = 36 hours;
    uint256 public constant MAX_CONTEST_DURATION     = 365 days;

    // ─── Events ────────────────────────────────────────────────────────

    /// @dev Event signature INTENTIONALLY matches ContestFactoryV2.ContestCreated
    ///      so the indexer picks both up via the same topic[0] hash. The 4th
    ///      indexed field carries `conditionId` here (vs `templateId` in the
    ///      legacy factory) but the data layout is identical, so the
    ///      processContestCreated handler can read either.
    event ContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        address indexed creator,
        bytes32 conditionId
    );

    /// @dev Mirror-specific aux event for off-chain tooling that needs to
    ///      distinguish mirror from non-mirror contests. Emitted alongside
    ///      ContestCreated for mirror contests.
    event MirrorContestCreated(
        bytes32 indexed contestId,
        address indexed contestAddress,
        bytes32 conditionId
    );
    event ResolverBound(address indexed contest, address indexed resolver);
    event MirrorResolverFeePaid(address indexed creator, address indexed treasury, uint256 amount);
    event ImplementationUpdated(address newImpl);
    event ProtocolFeeUpdated(uint256 newFee);
    event FeeEnabledUpdated(bool enabled);
    event MirrorResolverFeeUpdated(uint256 newFee);
    event ResolverTreasuryUpdated(address indexed newTreasury);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ─── Constructor ───────────────────────────────────────────────────

    constructor(
        address _mirrorImplementation,
        address _yieldVault,
        address _yieldStrategy,
        address _identityRegistry,
        address _feeRecipient
    ) Ownable() {
        require(_mirrorImplementation != address(0), "MirrorFactory: zero impl");
        require(_yieldVault != address(0),           "MirrorFactory: zero vault");
        require(_feeRecipient != address(0),         "MirrorFactory: zero feeRecipient");
        mirrorImplementation = _mirrorImplementation;
        yieldVault           = _yieldVault;
        yieldStrategy        = _yieldStrategy;
        identityRegistry     = _identityRegistry;
        protocolFeeRecipient = _feeRecipient;
    }

    // ─── Mirror contest creation ──────────────────────────────────────

    struct MirrorParams {
        address depositToken;
        uint96  depositAmount;
        uint96  maxParticipants;
        uint8   quorumPercentage;
        uint64  depositStart;
        uint64  depositEnd;
        uint64  lockEnd;
        uint64  revealEnd;
        bytes32 metadataHash;
        string  metadataUri;
        // Resolver binding
        address resolver;
        bytes32 conditionId;
        uint64  polymarketEndDate;
        bytes32 yesOption;
        bytes32 noOption;
    }

    function createMirrorContest(MirrorParams calldata p)
        external
        returns (bytes32 contestId, address contestAddress)
    {
        // ── Validation ────────────────────────────────────────────
        require(p.resolver != address(0),            "Mirror: zero resolver");
        require(p.depositToken != address(0),        "Mirror: zero token");
        require(p.depositAmount > 0,                 "Mirror: deposit required (sybil risk)");
        require(p.maxParticipants >= MIRROR_MIN_PARTICIPANTS, "Mirror: maxParticipants < 10");
        require(p.conditionId != bytes32(0),         "Mirror: zero conditionId");
        require(p.yesOption != bytes32(0) && p.noOption != bytes32(0), "Mirror: zero option");
        require(p.yesOption != p.noOption,           "Mirror: yes==no");
        require(p.polymarketEndDate > 0,             "Mirror: zero polymarketEndDate");
        require(p.depositStart >= block.timestamp,   "Mirror: depositStart in past");
        require(p.depositEnd > p.depositStart + 1 hours, "Mirror: deposit period too short");
        require(p.lockEnd > p.depositEnd,            "Mirror: lockEnd <= depositEnd");
        require(p.revealEnd > p.lockEnd,             "Mirror: revealEnd <= lockEnd");
        require(p.revealEnd - p.depositStart <= MAX_CONTEST_DURATION, "Mirror: duration too long");
        require(
            p.depositEnd + MIRROR_DEPOSIT_LOCKOUT <= uint256(p.polymarketEndDate),
            "Mirror: depositEnd too close to settlement"
        );
        require(
            p.revealEnd >= uint256(p.polymarketEndDate) + MIRROR_REVEAL_BUFFER,
            "Mirror: revealEnd too early (grace+dispute)"
        );

        // ── Resolver fee (sustains the relayer wallet) ───────────
        if (mirrorResolverFee > 0) {
            require(resolverTreasury != address(0), "Mirror: treasury unset");
            IERC20(p.depositToken).safeTransferFrom(msg.sender, resolverTreasury, mirrorResolverFee);
            emit MirrorResolverFeePaid(msg.sender, resolverTreasury, mirrorResolverFee);
        }

        // ── Generate contestId (nonce prevents same-block collisions) ──
        contestId = keccak256(abi.encodePacked(
            msg.sender, block.timestamp, p.metadataHash, _contestNonce++
        ));
        require(contests[contestId] == address(0), "Mirror: contest exists");

        // ── Clone + initialize ───────────────────────────────────
        contestAddress = mirrorImplementation.clone();

        uint96 effectiveFee = feeEnabled ? uint96(protocolFeePercentage) : uint96(0);
        MirrorContestV2.InitParams memory init = MirrorContestV2.InitParams({
            creator:               msg.sender,
            depositToken:          p.depositToken,
            depositAmount:         p.depositAmount,
            maxParticipants:       p.maxParticipants,
            depositStart:          p.depositStart,
            depositEnd:            p.depositEnd,
            lockEnd:               p.lockEnd,
            revealEnd:             p.revealEnd,
            tierRequired:          MIRROR_MIN_TIER,        // hard floor
            quorumPercentage:      p.quorumPercentage,
            yesOption:             p.yesOption,
            noOption:              p.noOption,
            metadataHash:          p.metadataHash,
            metadataUri:           p.metadataUri,
            conditionId:           p.conditionId,
            polymarketEndDate:     p.polymarketEndDate,
            resolver:              p.resolver,
            yieldVault:            yieldVault,
            yieldStrategy:         yieldStrategy,
            identityRegistry:      identityRegistry,
            protocolFeePercentage: effectiveFee,
            protocolFeeRecipient:  protocolFeeRecipient
        });
        MirrorContestV2(contestAddress).initialize(init);

        // ── Bind resolver + register with the resolver itself ────
        resolverForContest[contestAddress] = p.resolver;
        bytes32 contestKey = bytes32(uint256(uint160(contestAddress)));
        bytes memory resolverParams = abi.encode(
            p.conditionId, p.yesOption, p.noOption, p.polymarketEndDate
        );
        IResolver(p.resolver).register(contestKey, resolverParams);

        // ── Track ────────────────────────────────────────────────
        contests[contestId] = contestAddress;
        contestIds.push(contestId);
        creatorContests[msg.sender].push(contestId);

        emit ResolverBound(contestAddress, p.resolver);
        emit ContestCreated(contestId, contestAddress, msg.sender, p.conditionId);
        emit MirrorContestCreated(contestId, contestAddress, p.conditionId);
    }

    // ─── Owner setters ────────────────────────────────────────────────

    function setImplementation(address newImpl) external onlyOwner {
        require(newImpl != address(0), "MirrorFactory: zero impl");
        mirrorImplementation = newImpl;
        emit ImplementationUpdated(newImpl);
    }

    function setProtocolFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_PROTOCOL_FEE_BPS, "MirrorFactory: fee > 5%");
        protocolFeePercentage = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    function setFeeEnabled(bool enabled) external onlyOwner {
        feeEnabled = enabled;
        emit FeeEnabledUpdated(enabled);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "MirrorFactory: zero recipient");
        address old = protocolFeeRecipient;
        protocolFeeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    function setMirrorResolverFee(uint256 newFee) external onlyOwner {
        mirrorResolverFee = newFee;
        emit MirrorResolverFeeUpdated(newFee);
    }

    function setResolverTreasury(address newTreasury) external onlyOwner {
        resolverTreasury = newTreasury;
        emit ResolverTreasuryUpdated(newTreasury);
    }

    // ─── Views ────────────────────────────────────────────────────────

    function getContest(bytes32 contestId) external view returns (address) {
        return contests[contestId];
    }

    function getContestCount() external view returns (uint256) {
        return contestIds.length;
    }

    function getCreatorContests(address creator) external view returns (bytes32[] memory) {
        return creatorContests[creator];
    }
}
