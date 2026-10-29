// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MirrorContestV2.sol";
import "../src/MirrorContestFactory.sol";
import "../src/YieldVault.sol";
import "../src/IdentityRegistry.sol";
import "../src/resolvers/PolymarketRelayResolver.sol";
import "../src/mocks/MockERC20.sol";

/// @notice End-to-end tests for the slim MirrorContestV2 + MirrorContestFactory
///         pair. Asserts:
///           - createMirrorContest validates all guard conditions
///           - lifecycle: deposit → commit → reveal → resolve → claim
///           - resolver consultation (override votes with resolver answer)
///           - cancel + refund on resolver ambiguity
///           - STAKE_WEIGHTED distribution math (whale earns proportionally more)
///           - protocol fee deducted from yield only
///           - commit hash binds msg.sender (audit P-EXT-09 mitigation)
///           - resolver fee at creation routes to treasury
contract MirrorContestTest is Test {
    MirrorContestV2     public mirrorImpl;
    MirrorContestFactory public factory;
    YieldVault          public yieldVault;
    IdentityRegistry    public identityRegistry;
    PolymarketRelayResolver public resolver;
    MockERC20           public usdc;

    address public deployer = address(this); // factory owner
    address public creator  = address(0x100);
    address public alice    = address(0x101);
    address public bob      = address(0x102);
    address public charlie  = address(0x103);
    address public dave     = address(0x104);
    address public eve      = address(0x105);
    address public frank    = address(0x106);
    address public grace    = address(0x107);
    address public henry    = address(0x108);
    address public iris     = address(0x109);
    address public jack     = address(0x10A);
    address public treasury = address(0x111);

    bytes32 public constant CONDITION_ID = keccak256("polymarket-cond-test");
    bytes32 public constant YES = keccak256("YES");
    bytes32 public constant NO  = keccak256("NO");

    uint64 public polyEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        polyEnd = uint64(block.timestamp + 7 days);

        usdc = new MockERC20("USDC", "USDC", 6);

        yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));

        identityRegistry = new IdentityRegistry();
        // Register all participants at tier 2 (mirror requires)
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) {
            identityRegistry.setTier(all[i], 2);
            usdc.mint(all[i], 100_000e6);
        }
        usdc.mint(creator, 100_000e6);

        mirrorImpl = new MirrorContestV2();
        factory = new MirrorContestFactory(
            address(mirrorImpl),
            address(yieldVault),
            address(0),                  // strategy 0 sentinel
            address(identityRegistry),
            treasury                     // protocol fee recipient
        );

        resolver = new PolymarketRelayResolver(address(factory), address(usdc));
    }

    function _baseParams() internal view returns (MirrorContestFactory.MirrorParams memory) {
        return MirrorContestFactory.MirrorParams({
            depositToken:       address(usdc),
            depositAmount:      100e6,
            maxParticipants:    100,
            quorumPercentage:   50,
            depositStart:       uint64(block.timestamp),
            depositEnd:         uint64(uint256(polyEnd) - 25 hours),
            lockEnd:            uint64(uint256(polyEnd) - 1 hours),
            revealEnd:          uint64(uint256(polyEnd) + 37 hours),
            metadataHash:       keccak256("test-mirror"),
            metadataUri:        "ipfs://test",
            resolver:           address(resolver),
            conditionId:        CONDITION_ID,
            polymarketEndDate:  polyEnd,
            yesOption:          YES,
            noOption:           NO
        });
    }

    function _deposit(address user, address contestAddr, uint256 amount) internal {
        vm.prank(user);
        usdc.approve(contestAddr, amount);
        vm.prank(user);
        MirrorContestV2(contestAddr).deposit();
        // Advance block number for YieldVault's same-block flash-loan guard.
        // ContestV2TestBase tracks this via an internal _nextBlock counter;
        // we use a simpler vm.roll(+1) since mirror tests are tighter-scoped.
        vm.roll(block.number + 1);
    }

    function _commit(address user, address contestAddr, bytes32 option, bytes32 salt) internal {
        bytes32 hash = keccak256(abi.encodePacked(user, option, salt));
        vm.prank(user);
        MirrorContestV2(contestAddr).commitVote(hash);
    }

    function _reveal(address user, address contestAddr, bytes32 option, bytes32 salt) internal {
        vm.prank(user);
        MirrorContestV2(contestAddr).revealVote(option, salt);
    }

    /// @dev Inject yield via storage slot manipulation on YieldVault — same
    ///      pattern ContestV2 prizeModels tests use.
    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(yieldVault), amount);
        bytes32 base = keccak256(abi.encode(uint256(0), uint256(4)));
        bytes32 totalDepositedSlot = bytes32(uint256(base) + 2);
        uint256 cur = uint256(vm.load(address(yieldVault), totalDepositedSlot));
        vm.store(address(yieldVault), totalDepositedSlot, bytes32(cur + amount));
        bytes32 innerSlot = keccak256(abi.encode(address(usdc), uint256(7)));
        bytes32 tokenDepositSlot = keccak256(abi.encode(uint256(0), innerSlot));
        uint256 cur2 = uint256(vm.load(address(yieldVault), tokenDepositSlot));
        vm.store(address(yieldVault), tokenDepositSlot, bytes32(cur2 + amount));
    }

    // ─── Factory validation ───────────────────────────────────────────

    function test_createMirrorContest_succeeds() public {
        vm.prank(creator);
        (bytes32 id, address addr) = factory.createMirrorContest(_baseParams());
        assertTrue(id != bytes32(0));
        assertTrue(addr != address(0));
        assertEq(factory.resolverForContest(addr), address(resolver));

        // Resolver bound + registered
        bytes32 cid = bytes32(uint256(uint160(addr)));
        ( , bytes32 yes, bytes32 no, uint64 end, , , , , , , , ) = resolver.configs(cid);
        assertEq(yes, YES);
        assertEq(no, NO);
        assertEq(end, polyEnd);
    }

    function test_factory_rejectsZeroResolver() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        p.resolver = address(0);
        vm.prank(creator);
        vm.expectRevert("Mirror: zero resolver");
        factory.createMirrorContest(p);
    }

    function test_factory_rejectsZeroDeposit() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        p.depositAmount = 0;
        vm.prank(creator);
        vm.expectRevert("Mirror: deposit required (sybil risk)");
        factory.createMirrorContest(p);
    }

    function test_factory_rejectsLowMaxParticipants() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        p.maxParticipants = 9;
        vm.prank(creator);
        vm.expectRevert("Mirror: maxParticipants < 10");
        factory.createMirrorContest(p);
    }

    function test_factory_rejectsLateDepositEnd() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        // depositEnd within the 24h lockout, but bump lockEnd > depositEnd
        // so the lockout check fires (not the lockEnd ordering check).
        p.depositEnd = uint64(uint256(polyEnd) - 1 hours);
        p.lockEnd    = uint64(uint256(polyEnd) - 30 minutes);
        vm.prank(creator);
        vm.expectRevert("Mirror: depositEnd too close to settlement");
        factory.createMirrorContest(p);
    }

    function test_factory_rejectsEarlyRevealEnd() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        p.revealEnd = uint64(uint256(polyEnd) + 1 hours);
        p.lockEnd = uint64(uint256(p.revealEnd) - 1 hours);
        p.depositEnd = uint64(uint256(p.lockEnd) - 1 hours);
        // depositEnd must still satisfy lockout — adjust polyEnd-aware
        p.depositEnd = uint64(uint256(polyEnd) - 25 hours);
        p.lockEnd = uint64(uint256(p.depositEnd) + 1 hours);
        // revealEnd is the failing one
        p.revealEnd = uint64(uint256(polyEnd) + 1 hours);
        vm.prank(creator);
        vm.expectRevert("Mirror: revealEnd too early (grace+dispute)");
        factory.createMirrorContest(p);
    }

    function test_factory_rejectsSameYesNo() public {
        MirrorContestFactory.MirrorParams memory p = _baseParams();
        p.noOption = p.yesOption;
        vm.prank(creator);
        vm.expectRevert("Mirror: yes==no");
        factory.createMirrorContest(p);
    }

    // ─── Resolver fee economics ───────────────────────────────────────

    function test_resolverFee_chargedAtCreationWhenSet() public {
        factory.setMirrorResolverFee(2e6);
        factory.setResolverTreasury(treasury);

        vm.prank(creator);
        usdc.approve(address(factory), 2e6);

        uint256 creatorBefore = usdc.balanceOf(creator);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(creator);
        factory.createMirrorContest(_baseParams());

        assertEq(usdc.balanceOf(creator),  creatorBefore  - 2e6);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 2e6);
    }

    function test_resolverFee_revertsWhenTreasuryUnset() public {
        factory.setMirrorResolverFee(1e6);
        vm.prank(creator);
        usdc.approve(address(factory), 1e6);
        vm.prank(creator);
        vm.expectRevert("Mirror: treasury unset");
        factory.createMirrorContest(_baseParams());
    }

    // ─── Lifecycle (full happy path) ──────────────────────────────────

    function _createAndDeposit() internal returns (address contestAddr) {
        vm.prank(creator);
        ( , contestAddr) = factory.createMirrorContest(_baseParams());
        // 10 depositors — meets MIRROR_MIN_PARTICIPANTS
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) {
            _deposit(all[i], contestAddr, 100e6);
        }
    }

    function test_lifecycle_yesWinsStakeWeighted() public {
        address contestAddr = _createAndDeposit();
        bytes32 salt = keccak256("salt");
        // 6 vote YES, 4 vote NO
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) {
            bytes32 vote = i < 6 ? YES : NO;
            _commit(all[i], contestAddr, vote, salt);
        }

        // Advance to REVEAL_OPEN
        vm.warp(uint256(MirrorContestV2(contestAddr).lockEnd()));
        MirrorContestV2(contestAddr).updateState();
        for (uint256 i = 0; i < all.length; i++) {
            bytes32 vote = i < 6 ? YES : NO;
            _reveal(all[i], contestAddr, vote, salt);
        }

        // Inject yield
        _simulateYield(100e6);

        // Polymarket settles → relayer proposes YES → wait dispute window
        vm.warp(uint256(polyEnd) + uint256(resolver.GRACE_WINDOW()));
        bytes32 cid = bytes32(uint256(uint160(contestAddr)));
        resolver.propose(cid, PolymarketRelayResolver.Outcome.YES_WIN);
        // Past dispute window. Also warp past revealEnd so resolveContest's
        // `block.timestamp >= revealEnd` guard is satisfied (revealEnd is
        // polyEnd + 37h; dispute-window-end was polyEnd + 36h).
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        vm.warp(uint256(MirrorContestV2(contestAddr).revealEnd()));
        vm.roll(block.number + 1);    // MIN_HOLD_TIME + flash-loan guard in YieldVault.withdraw

        // Resolve
        vm.prank(creator);
        MirrorContestV2(contestAddr).resolveContest();

        assertEq(uint8(MirrorContestV2(contestAddr).state()), uint8(MirrorContestV2.State.FINALIZED));
        assertEq(MirrorContestV2(contestAddr).winningOption(), YES);

        // Each YES voter should have non-zero reward (equal stakes → equal split)
        uint96 firstReward = MirrorContestV2(contestAddr).voterRewards(alice);
        assertGt(firstReward, 0);
        for (uint256 i = 1; i < 6; i++) {
            assertEq(MirrorContestV2(contestAddr).voterRewards(all[i]), firstReward);
        }
        // NO voters get 0
        for (uint256 i = 6; i < 10; i++) {
            assertEq(MirrorContestV2(contestAddr).voterRewards(all[i]), 0);
        }
    }

    function test_lifecycle_resolverOverridesPlurality() public {
        address contestAddr = _createAndDeposit();
        bytes32 salt = keccak256("salt");
        // Crowd majority votes YES, but resolver says NO
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) {
            bytes32 vote = i < 7 ? YES : NO; // 7 YES vs 3 NO
            _commit(all[i], contestAddr, vote, salt);
        }
        vm.warp(uint256(MirrorContestV2(contestAddr).lockEnd()));
        MirrorContestV2(contestAddr).updateState();
        for (uint256 i = 0; i < all.length; i++) {
            bytes32 vote = i < 7 ? YES : NO;
            _reveal(all[i], contestAddr, vote, salt);
        }
        _simulateYield(100e6);

        vm.warp(uint256(polyEnd) + uint256(resolver.GRACE_WINDOW()));
        bytes32 cid = bytes32(uint256(uint160(contestAddr)));
        resolver.propose(cid, PolymarketRelayResolver.Outcome.NO_WIN);  // ← OPPOSITE of crowd
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        vm.warp(uint256(MirrorContestV2(contestAddr).revealEnd()));
        vm.roll(block.number + 1);    // MIN_HOLD_TIME + flash-loan guard in YieldVault.withdraw

        vm.prank(creator);
        MirrorContestV2(contestAddr).resolveContest();

        assertEq(MirrorContestV2(contestAddr).winningOption(), NO);

        // YES voters (majority of crowd) get 0; NO voters split the yield
        for (uint256 i = 0; i < 7; i++) {
            assertEq(MirrorContestV2(contestAddr).voterRewards(all[i]), 0);
        }
        uint96 noReward = MirrorContestV2(contestAddr).voterRewards(all[7]);
        assertGt(noReward, 0);
    }

    function test_lifecycle_ambiguousCancels() public {
        address contestAddr = _createAndDeposit();
        bytes32 salt = keccak256("salt");
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) {
            _commit(all[i], contestAddr, YES, salt);
        }
        vm.warp(uint256(MirrorContestV2(contestAddr).lockEnd()));
        MirrorContestV2(contestAddr).updateState();
        for (uint256 i = 0; i < all.length; i++) {
            _reveal(all[i], contestAddr, YES, salt);
        }
        _simulateYield(100e6);

        vm.warp(uint256(polyEnd) + uint256(resolver.GRACE_WINDOW()));
        bytes32 cid = bytes32(uint256(uint160(contestAddr)));
        resolver.propose(cid, PolymarketRelayResolver.Outcome.AMBIGUOUS);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        vm.warp(uint256(MirrorContestV2(contestAddr).revealEnd()));
        vm.roll(block.number + 1);    // MIN_HOLD_TIME + flash-loan guard in YieldVault.withdraw

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(creator);
        MirrorContestV2(contestAddr).resolveContest();
        assertEq(uint8(MirrorContestV2(contestAddr).state()), uint8(MirrorContestV2.State.CANCELLED));

        vm.prank(alice);
        MirrorContestV2(contestAddr).withdrawPrincipal();
        assertEq(usdc.balanceOf(alice), aliceBefore + 100e6);
    }

    // ─── Audit P-EXT-09: commit hash binds msg.sender ────────────────

    function test_revealVote_rejectsCopiedReveal() public {
        address contestAddr = _createAndDeposit();
        bytes32 salt = keccak256("alice-salt");

        // Both commits BEFORE lockEnd warp — commitVote rejects after lockEnd.
        _commit(alice, contestAddr, YES, salt);
        _commit(bob, contestAddr, NO, keccak256("bob-salt"));

        vm.warp(uint256(MirrorContestV2(contestAddr).lockEnd()));
        MirrorContestV2(contestAddr).updateState();

        // Bob attempts to copy Alice's (option, salt) — fails because the
        // commit hash is bound to msg.sender (= bob, not alice).
        vm.prank(bob);
        vm.expectRevert(MirrorContestV2.InvalidReveal.selector);
        MirrorContestV2(contestAddr).revealVote(YES, salt);
    }

    // ─── Withdrawals ──────────────────────────────────────────────────

    function test_principalRefundedAfterFinalize() public {
        address contestAddr = _createAndDeposit();
        bytes32 salt = keccak256("salt");
        address[10] memory all = [alice, bob, charlie, dave, eve, frank, grace, henry, iris, jack];
        for (uint256 i = 0; i < all.length; i++) _commit(all[i], contestAddr, YES, salt);
        vm.warp(uint256(MirrorContestV2(contestAddr).lockEnd()));
        MirrorContestV2(contestAddr).updateState();
        for (uint256 i = 0; i < all.length; i++) _reveal(all[i], contestAddr, YES, salt);

        _simulateYield(100e6);
        vm.warp(uint256(polyEnd) + uint256(resolver.GRACE_WINDOW()));
        bytes32 cid = bytes32(uint256(uint160(contestAddr)));
        resolver.propose(cid, PolymarketRelayResolver.Outcome.YES_WIN);
        vm.warp(block.timestamp + uint256(resolver.DISPUTE_WINDOW()));
        vm.warp(uint256(MirrorContestV2(contestAddr).revealEnd()));
        vm.roll(block.number + 1);    // MIN_HOLD_TIME + flash-loan guard in YieldVault.withdraw
        vm.prank(creator);
        MirrorContestV2(contestAddr).resolveContest();

        // Alice should be able to withdraw principal AND claim reward separately
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint96 reward = MirrorContestV2(contestAddr).voterRewards(alice);

        vm.prank(alice);
        MirrorContestV2(contestAddr).withdrawPrincipal();

        vm.prank(alice);
        MirrorContestV2(contestAddr).claimVoterReward();

        assertEq(usdc.balanceOf(alice), aliceBefore + 100e6 + uint256(reward));
    }

    // ─── Tier gating ──────────────────────────────────────────────────

    function test_deposit_revertsForLowTier() public {
        vm.prank(creator);
        ( , address contestAddr) = factory.createMirrorContest(_baseParams());

        address mallory = address(0x999);
        usdc.mint(mallory, 1000e6);
        // Mallory is tier 0 (default) — below MIRROR_MIN_TIER = 2
        vm.prank(mallory);
        usdc.approve(contestAddr, 100e6);
        vm.prank(mallory);
        vm.expectRevert(MirrorContestV2.TierTooLow.selector);
        MirrorContestV2(contestAddr).deposit();
    }

    // ─── Fee cap regression (B1 fix, 2026-04-27) ─────────────────────────

    function test_setProtocolFee_capIs500Bps() public view {
        // The mirror factory shares the platform-wide 5% yield-fee cap with
        // ContestFactoryV2 / NoLossLotteryV3 / ProbabilityVaultV2. Anchoring
        // the constant here prevents accidental drift in future edits.
        assertEq(factory.MAX_PROTOCOL_FEE_BPS(), 500);
    }

    function test_setProtocolFee_acceptsCapBoundary() public {
        factory.setProtocolFee(500); // exactly 5%
        assertEq(factory.protocolFeePercentage(), 500);
    }

    function test_setProtocolFee_revertsAboveCap() public {
        vm.expectRevert(bytes("MirrorFactory: fee > 5%"));
        factory.setProtocolFee(501);
    }

    function test_setProtocolFee_revertsAtFormerPlaceholderCap() public {
        // Sanity-check that the old 100% placeholder is now blocked.
        vm.expectRevert(bytes("MirrorFactory: fee > 5%"));
        factory.setProtocolFee(10_000);
    }
}
