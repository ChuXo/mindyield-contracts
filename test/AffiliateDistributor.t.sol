// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AffiliateDistributor.sol";
import "../src/mocks/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract AffiliateDistributorTestBase is Test {
    AffiliateDistributor distributor;
    MockERC20 usdc;

    address owner = address(0xA11CE);
    address guardian = address(0x6AD);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address dave = address(0x4);
    address treasury = address(0xBEEF);
    address altRecipient = address(0xA17);

    uint256 constant MAX_CLAIM = 50_000e6;   // $50K
    uint256 constant RESCUE_DELAY = 7 days;

    event RootPosted(uint256 indexed rootVersion, bytes32 indexed root, uint256 totalAllocated, string ipfsCid);
    event Claimed(
        address indexed user,
        address indexed recipient,
        uint256 amount,
        uint256 indexed rootVersion,
        uint256 newCumulative
    );

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(owner);
        distributor = new AffiliateDistributor(
            IERC20(address(usdc)),
            guardian,
            MAX_CLAIM,
            RESCUE_DELAY,
            owner
        );

        usdc.mint(address(distributor), 10_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Merkle tree helpers
    // -------------------------------------------------------------------------

    function _makeLeaf(address user, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _buildTree2(
        address userA,
        uint256 amountA,
        address userB,
        uint256 amountB
    ) internal pure returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) {
        bytes32 leafA = _makeLeaf(userA, amountA);
        bytes32 leafB = _makeLeaf(userB, amountB);
        root = _hashPair(leafA, leafB);
        proofA = new bytes32[](1);
        proofA[0] = leafB;
        proofB = new bytes32[](1);
        proofB[0] = leafA;
    }

    function _buildTree4(
        address[4] memory users,
        uint256[4] memory amounts
    ) internal pure returns (bytes32 root, bytes32[][4] memory proofs) {
        bytes32[4] memory leaves;
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = _makeLeaf(users[i], amounts[i]);
        }
        bytes32 h01 = _hashPair(leaves[0], leaves[1]);
        bytes32 h23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(h01, h23);

        proofs[0] = new bytes32[](2);
        proofs[0][0] = leaves[1];
        proofs[0][1] = h23;
        proofs[1] = new bytes32[](2);
        proofs[1][0] = leaves[0];
        proofs[1][1] = h23;
        proofs[2] = new bytes32[](2);
        proofs[2][0] = leaves[3];
        proofs[2][1] = h01;
        proofs[3] = new bytes32[](2);
        proofs[3][0] = leaves[2];
        proofs[3][1] = h01;
    }

    function _postRoot(bytes32 root, uint256 total) internal returns (uint256 version) {
        vm.prank(owner);
        version = distributor.postRoot(root, total, "ipfs://test-cid");
    }

    /// Convenience wrapper — claim to msg.sender.
    function _claim(
        address user,
        uint256 version,
        uint256 amount,
        bytes32[] memory proof
    ) internal {
        vm.prank(user);
        distributor.claim(version, amount, user, proof);
    }
}

/// @notice Constructor + postRoot + setRootPoster + revokeRoot tests.
/// Split out from the original monolithic test contract to keep each
/// compilation unit small enough for via_ir's stack budget.
contract AffiliateDistributorBasicsTest is AffiliateDistributorTestBase {
    // -------------------------------------------------------------------------
    // Constructor validation
    // -------------------------------------------------------------------------

    function test_Constructor_RevertsOnZeroToken() public {
        vm.expectRevert(AffiliateDistributor.ZeroAddress.selector);
        new AffiliateDistributor(IERC20(address(0)), guardian, MAX_CLAIM, RESCUE_DELAY, owner);
    }

    function test_Constructor_RevertsOnZeroGuardian() public {
        vm.expectRevert(AffiliateDistributor.ZeroAddress.selector);
        new AffiliateDistributor(IERC20(address(usdc)), address(0), MAX_CLAIM, RESCUE_DELAY, owner);
    }

    function test_Constructor_RevertsOnZeroMaxClaim() public {
        vm.expectRevert(AffiliateDistributor.InvalidAmount.selector);
        new AffiliateDistributor(IERC20(address(usdc)), guardian, 0, RESCUE_DELAY, owner);
    }

    function test_Constructor_RevertsOnShortRescueDelay() public {
        // Zero rescue delay is rejected
        vm.expectRevert(AffiliateDistributor.RescueDelayTooShort.selector);
        new AffiliateDistributor(IERC20(address(usdc)), guardian, MAX_CLAIM, 0, owner);

        // Below MIN_RESCUE_DELAY (1 day) is rejected
        vm.expectRevert(AffiliateDistributor.RescueDelayTooShort.selector);
        new AffiliateDistributor(IERC20(address(usdc)), guardian, MAX_CLAIM, 1 days - 1, owner);
    }

    function test_Constructor_AcceptsMinRescueDelay() public {
        AffiliateDistributor d = new AffiliateDistributor(
            IERC20(address(usdc)), guardian, MAX_CLAIM, 1 days, owner
        );
        assertEq(d.rescueDelay(), 1 days);
    }

    function test_Constructor_AcceptsZeroInitialRootPoster() public {
        // Allowed — operator may want to grant the role post-deploy.
        AffiliateDistributor d = new AffiliateDistributor(
            IERC20(address(usdc)), guardian, MAX_CLAIM, RESCUE_DELAY, address(0)
        );
        assertFalse(d.isRootPoster(address(0)));
        assertFalse(d.isRootPoster(address(this)));
    }

    function test_Constructor_GrantsInitialPoster() public {
        // setUp passed `owner` as the initial root poster.
        assertTrue(distributor.isRootPoster(owner));
        assertFalse(distributor.isRootPoster(alice));
    }

    function test_Constructor_SetsImmutables() public {
        assertEq(address(distributor.token()), address(usdc));
        assertEq(distributor.guardian(), guardian);
        assertEq(distributor.maxSingleClaim(), MAX_CLAIM);
        assertEq(distributor.rescueDelay(), RESCUE_DELAY);
        assertEq(distributor.owner(), owner);
        assertEq(distributor.MIN_RESCUE_DELAY(), 1 days);
    }

    // -------------------------------------------------------------------------
    // postRoot
    // -------------------------------------------------------------------------

    function test_PostRoot_IncrementsVersionMonotonically() public {
        (bytes32 root1,,) = _buildTree2(alice, 100e6, bob, 200e6);
        (bytes32 root2,,) = _buildTree2(alice, 150e6, bob, 250e6);

        uint256 v1 = _postRoot(root1, 300e6);
        uint256 v2 = _postRoot(root2, 400e6);

        assertEq(v1, 1);
        assertEq(v2, 2);
        assertEq(distributor.currentRootVersion(), 2);
    }

    function test_PostRoot_StoresAllFields() public {
        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);

        vm.expectEmit(true, true, false, true);
        emit RootPosted(1, root, 300e6, "ipfs://manifest-v1");

        vm.prank(owner);
        distributor.postRoot(root, 300e6, "ipfs://manifest-v1");

        (bytes32 storedRoot, uint64 postedAt, uint192 totalAllocated, string memory cid) = distributor.roots(1);
        assertEq(storedRoot, root);
        assertEq(postedAt, block.timestamp);
        assertEq(totalAllocated, 300e6);
        assertEq(cid, "ipfs://manifest-v1");
    }

    function test_PostRoot_RevertsOnZeroRoot() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.InvalidRoot.selector);
        distributor.postRoot(bytes32(0), 100e6, "");
    }

    function test_PostRoot_RevertsOnOverflow() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.InvalidAmount.selector);
        distributor.postRoot(bytes32(uint256(1)), uint256(type(uint192).max) + 1, "");
    }

    function test_PostRoot_OnlyRootPoster() public {
        // Alice has neither role — postRoot uses a custom error
        // (MissingRootPosterRole) for via_ir stack hygiene.
        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.MissingRootPosterRole.selector);
        distributor.postRoot(bytes32(uint256(1)), 100e6, "");
    }

    function test_PostRoot_GrantedPosterCanPost() public {
        // Owner allowlists a backend hot wallet as a root poster.
        address backend = address(0xB07);
        vm.prank(owner);
        distributor.setRootPoster(backend, true);

        // Backend (not owner) can post.
        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        vm.prank(backend);
        uint256 v = distributor.postRoot(root, 300e6, "ipfs://from-backend");
        assertEq(v, 1);
    }

    function test_PostRoot_RevokedPosterCannotPost() public {
        address backend = address(0xB07);

        vm.prank(owner);
        distributor.setRootPoster(backend, true);

        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        vm.prank(backend);
        distributor.postRoot(root, 300e6, "ipfs://first");

        // Revoke and confirm subsequent posts revert.
        vm.prank(owner);
        distributor.setRootPoster(backend, false);

        vm.prank(backend);
        vm.expectRevert(AffiliateDistributor.MissingRootPosterRole.selector);
        distributor.postRoot(root, 300e6, "ipfs://blocked");
    }

    function test_SetRootPoster_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        distributor.setRootPoster(bob, true);
    }

    function test_SetRootPoster_RejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.ZeroAddress.selector);
        distributor.setRootPoster(address(0), true);
    }

    // -------------------------------------------------------------------------
    // revokeRoot — owner-only emergency neutralization
    // -------------------------------------------------------------------------

    function test_RevokeRoot_OwnerCanRevoke() public {
        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(owner);
        distributor.revokeRoot(v);

        // Storage cleared
        (bytes32 storedRoot,,,) = distributor.roots(v);
        assertEq(storedRoot, bytes32(0));
    }

    function test_RevokeRoot_BlocksFutureClaims() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(owner);
        distributor.revokeRoot(v);

        // Subsequent claim against revoked root reverts
        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.UnknownRoot.selector);
        distributor.claim(v, 100e6, alice, proofA);
    }

    function test_RevokeRoot_DoesNotClawbackPastClaims() public {
        // Alice claims, then root is revoked. Her funds stay; only future
        // claims against this root version are blocked.
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        _claim(alice, v, 100e6, proofA);
        uint256 aliceBalAfterClaim = usdc.balanceOf(alice);
        assertEq(aliceBalAfterClaim, 100e6);

        vm.prank(owner);
        distributor.revokeRoot(v);

        // Alice's balance is unchanged; claimed[] still records the claim.
        assertEq(usdc.balanceOf(alice), aliceBalAfterClaim);
        assertEq(distributor.claimed(alice), 100e6);
    }

    function test_RevokeRoot_LeavesOtherRootsClaimable() public {
        (bytes32 root1,,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v1 = _postRoot(root1, 300e6);

        (bytes32 root2, bytes32[] memory proofA2,) = _buildTree2(alice, 250e6, bob, 400e6);
        uint256 v2 = _postRoot(root2, 650e6);

        vm.prank(owner);
        distributor.revokeRoot(v1);

        // v2 still works
        _claim(alice, v2, 250e6, proofA2);
        assertEq(distributor.claimed(alice), 250e6);
    }

    function test_RevokeRoot_OnlyOwner() public {
        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        // Even a root poster cannot revoke (only owner / timelock can).
        vm.prank(owner);
        distributor.setRootPoster(alice, true);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        distributor.revokeRoot(v);
    }

    function test_RevokeRoot_RevertsOnUnknownVersion() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RootAlreadyRevoked.selector);
        distributor.revokeRoot(999);
    }

    function test_RevokeRoot_RevertsOnDoubleRevoke() public {
        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(owner);
        distributor.revokeRoot(v);

        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RootAlreadyRevoked.selector);
        distributor.revokeRoot(v);
    }
}

/// @notice claim(), claimableAmount(), verifyProof(), and fuzz tests.
contract AffiliateDistributorClaimTest is AffiliateDistributorTestBase {
    // -------------------------------------------------------------------------
    // claim — happy paths
    // -------------------------------------------------------------------------

    function test_Claim_HappyPath() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        uint256 balBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Claimed(alice, alice, 100e6, v, 100e6);

        _claim(alice, v, 100e6, proofA);

        assertEq(usdc.balanceOf(alice) - balBefore, 100e6);
        assertEq(distributor.claimed(alice), 100e6);
    }

    function test_Claim_CumulativeSecondRootPaysDeltaOnly() public {
        (bytes32 root1, bytes32[] memory proofA1,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v1 = _postRoot(root1, 300e6);
        _claim(alice, v1, 100e6, proofA1);
        assertEq(distributor.claimed(alice), 100e6);

        (bytes32 root2, bytes32[] memory proofA2,) = _buildTree2(alice, 150e6, bob, 300e6);
        uint256 v2 = _postRoot(root2, 450e6);

        uint256 balBefore = usdc.balanceOf(alice);
        _claim(alice, v2, 150e6, proofA2);

        assertEq(usdc.balanceOf(alice) - balBefore, 50e6);
        assertEq(distributor.claimed(alice), 150e6);
    }

    function test_Claim_UserSkipsRootAndClaimsLaterCumulative() public {
        (bytes32 root1,,) = _buildTree2(alice, 100e6, bob, 200e6);
        _postRoot(root1, 300e6);

        (bytes32 root2, bytes32[] memory proofA2,) = _buildTree2(alice, 250e6, bob, 500e6);
        uint256 v2 = _postRoot(root2, 750e6);

        uint256 balBefore = usdc.balanceOf(alice);
        _claim(alice, v2, 250e6, proofA2);

        assertEq(usdc.balanceOf(alice) - balBefore, 250e6);
        assertEq(distributor.claimed(alice), 250e6);
    }

    function test_Claim_UserCanClaimAgainstOldRoot() public {
        (bytes32 root1, bytes32[] memory proofA1,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v1 = _postRoot(root1, 300e6);

        (bytes32 root2,,) = _buildTree2(alice, 150e6, bob, 300e6);
        _postRoot(root2, 450e6);

        _claim(alice, v1, 100e6, proofA1);
        assertEq(distributor.claimed(alice), 100e6);
    }

    function test_Claim_MultipleUsers() public {
        address[4] memory users = [alice, bob, carol, dave];
        uint256[4] memory amounts = [uint256(100e6), 200e6, 300e6, 400e6];

        (bytes32 root, bytes32[][4] memory proofs) = _buildTree4(users, amounts);
        uint256 v = _postRoot(root, 1000e6);

        for (uint256 i = 0; i < 4; i++) {
            uint256 balBefore = usdc.balanceOf(users[i]);
            _claim(users[i], v, amounts[i], proofs[i]);
            assertEq(usdc.balanceOf(users[i]) - balBefore, amounts[i]);
        }
    }

    // -------------------------------------------------------------------------
    // claim — partial claims when delta exceeds cap (no longer a DoS)
    // -------------------------------------------------------------------------

    function test_Claim_PartialWhenDeltaExceedsCap() public {
        // Allocation 150K, cap 50K → needs 3 claims to fully drain
        uint256 allocation = 150_000e6;
        (bytes32 root, bytes32[] memory p,) = _buildTree2(alice, allocation, bob, 1e6);
        uint256 v = _postRoot(root, allocation + 1e6);

        uint256 balBefore = usdc.balanceOf(alice);

        // First claim: cap out at MAX_CLAIM
        _claim(alice, v, allocation, p);
        assertEq(usdc.balanceOf(alice) - balBefore, MAX_CLAIM);
        assertEq(distributor.claimed(alice), MAX_CLAIM);

        // Second claim: another MAX_CLAIM
        _claim(alice, v, allocation, p);
        assertEq(usdc.balanceOf(alice) - balBefore, 2 * MAX_CLAIM);
        assertEq(distributor.claimed(alice), 2 * MAX_CLAIM);

        // Third claim: remaining 50K (exactly MAX_CLAIM)
        _claim(alice, v, allocation, p);
        assertEq(usdc.balanceOf(alice) - balBefore, allocation);
        assertEq(distributor.claimed(alice), allocation);

        // Fourth attempt reverts
        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.NothingToClaim.selector);
        distributor.claim(v, allocation, alice, p);
    }

    function test_Claim_ExactlyCapPaysInOneShot() public {
        (bytes32 root, bytes32[] memory p,) = _buildTree2(alice, MAX_CLAIM, bob, 1e6);
        uint256 v = _postRoot(root, MAX_CLAIM + 1e6);

        _claim(alice, v, MAX_CLAIM, p);
        assertEq(usdc.balanceOf(alice), MAX_CLAIM);
        assertEq(distributor.claimed(alice), MAX_CLAIM);
    }

    function test_Claim_PartialFromFirstRootThenFullFromSecond() public {
        // Root 1: alice = 80K (requires 2 claims of 50K + 30K)
        (bytes32 root1, bytes32[] memory p1,) = _buildTree2(alice, 80_000e6, bob, 1e6);
        uint256 v1 = _postRoot(root1, 80_001e6);

        _claim(alice, v1, 80_000e6, p1); // pays MAX_CLAIM, claimed=50K
        assertEq(distributor.claimed(alice), 50_000e6);

        // Root 2: alice = 200K. Delta is 150K — three partial claims needed.
        (bytes32 root2, bytes32[] memory p2,) = _buildTree2(alice, 200_000e6, bob, 2e6);
        uint256 v2 = _postRoot(root2, 200_002e6);

        _claim(alice, v2, 200_000e6, p2);
        assertEq(distributor.claimed(alice), 100_000e6);
        _claim(alice, v2, 200_000e6, p2);
        assertEq(distributor.claimed(alice), 150_000e6);
        _claim(alice, v2, 200_000e6, p2);
        assertEq(distributor.claimed(alice), 200_000e6);
    }

    // -------------------------------------------------------------------------
    // claim — alternate recipient (USDC blacklist escape hatch)
    // -------------------------------------------------------------------------

    function test_Claim_AlternateRecipient() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        uint256 altBefore = usdc.balanceOf(altRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Claimed(alice, altRecipient, 100e6, v, 100e6);

        vm.prank(alice);
        distributor.claim(v, 100e6, altRecipient, proofA);

        // Alice's bal unchanged; alt got the USDC; claimed[alice] updated.
        assertEq(usdc.balanceOf(alice) - aliceBefore, 0);
        assertEq(usdc.balanceOf(altRecipient) - altBefore, 100e6);
        assertEq(distributor.claimed(alice), 100e6);
    }

    function test_Claim_RevertsOnZeroRecipient() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.ZeroAddress.selector);
        distributor.claim(v, 100e6, address(0), proofA);
    }

    function test_Claim_CannotRedirectSomeoneElsesAllocation() public {
        // Bob tries to claim alice's allocation by proving alice's leaf but setting
        // bob's address as recipient. Leaf binds msg.sender, so proof verification fails.
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(bob);
        vm.expectRevert(AffiliateDistributor.InvalidProof.selector);
        distributor.claim(v, 100e6, bob, proofA); // proofA is for alice, msg.sender=bob
    }

    // -------------------------------------------------------------------------
    // claim — revert paths
    // -------------------------------------------------------------------------

    function test_Claim_RevertsOnUnknownRoot() public {
        (,bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.UnknownRoot.selector);
        distributor.claim(999, 100e6, alice, proofA);
    }

    function test_Claim_RevertsOnInvalidProof() public {
        (bytes32 root,,bytes32[] memory proofB) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.InvalidProof.selector);
        distributor.claim(v, 100e6, alice, proofB);
    }

    function test_Claim_RevertsOnWrongAmount() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.InvalidProof.selector);
        distributor.claim(v, 999e6, alice, proofA);
    }

    function test_Claim_RevertsOnSecondClaimSameRoot() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        _claim(alice, v, 100e6, proofA);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.NothingToClaim.selector);
        distributor.claim(v, 100e6, alice, proofA);
    }

    function test_Claim_RevertsOnLowerCumulativeInNewRoot() public {
        (bytes32 root1, bytes32[] memory proofA1,) = _buildTree2(alice, 150e6, bob, 200e6);
        uint256 v1 = _postRoot(root1, 350e6);
        _claim(alice, v1, 150e6, proofA1);

        (bytes32 root2, bytes32[] memory proofA2,) = _buildTree2(alice, 100e6, bob, 300e6);
        uint256 v2 = _postRoot(root2, 400e6);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.NothingToClaim.selector);
        distributor.claim(v2, 100e6, alice, proofA2);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function test_ClaimableAmount_ReturnsDelta() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        assertEq(distributor.claimableAmount(alice, v, 100e6), 100e6);

        _claim(alice, v, 100e6, proofA);
        assertEq(distributor.claimableAmount(alice, v, 100e6), 0);
    }

    function test_ClaimableAmount_ReturnsZeroForUnknownRoot() public {
        assertEq(distributor.claimableAmount(alice, 999, 100e6), 0);
    }

    function test_VerifyProof_True() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);
        assertTrue(distributor.verifyProof(v, alice, 100e6, proofA));
    }

    function test_VerifyProof_FalseOnWrongUser() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);
        assertFalse(distributor.verifyProof(v, bob, 100e6, proofA));
    }

    function test_VerifyProof_FalseOnUnknownRoot() public {
        bytes32[] memory emptyProof = new bytes32[](0);
        assertFalse(distributor.verifyProof(999, alice, 100e6, emptyProof));
    }

    // -------------------------------------------------------------------------
    // Reentrancy sanity
    // -------------------------------------------------------------------------

    function test_Claim_ConsecutiveClaimsWork() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);
        _claim(alice, v, 100e6, proofA);

        (bytes32 root2, bytes32[] memory proofA2,) = _buildTree2(alice, 200e6, bob, 300e6);
        uint256 v2 = _postRoot(root2, 500e6);
        _claim(alice, v2, 200e6, proofA2);

        assertEq(distributor.claimed(alice), 200e6);
    }

    // -------------------------------------------------------------------------
    // Fuzz tests
    // -------------------------------------------------------------------------

    function testFuzz_Claim_Cumulative(uint128 amount1, uint128 amount2) public {
        amount1 = uint128(bound(amount1, 1, uint128(MAX_CLAIM / 2 - 1)));
        amount2 = uint128(bound(amount2, amount1 + 1, uint128(MAX_CLAIM)));

        (bytes32 root1, bytes32[] memory p1,) = _buildTree2(alice, amount1, bob, 1e6);
        uint256 v1 = _postRoot(root1, uint256(amount1) + 1e6);
        _claim(alice, v1, amount1, p1);
        assertEq(distributor.claimed(alice), amount1);

        (bytes32 root2, bytes32[] memory p2,) = _buildTree2(alice, amount2, bob, 2e6);
        uint256 v2 = _postRoot(root2, uint256(amount2) + 2e6);
        _claim(alice, v2, amount2, p2);
        assertEq(distributor.claimed(alice), amount2);
    }

    function testFuzz_Claim_CannotDoubleClaim(uint128 amount) public {
        amount = uint128(bound(amount, 1, uint128(MAX_CLAIM)));

        (bytes32 root, bytes32[] memory p,) = _buildTree2(alice, amount, bob, 1e6);
        uint256 v = _postRoot(root, uint256(amount) + 1e6);

        _claim(alice, v, amount, p);

        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.NothingToClaim.selector);
        distributor.claim(v, amount, alice, p);
    }

    /// @dev Partial-claim fuzz: user can always drain full allocation across
    /// `ceil(allocation / cap)` calls, regardless of allocation size.
    function testFuzz_Claim_PartialAlwaysDrainable(uint128 allocation) public {
        // Ensure allocation fits in uint192 total.
        allocation = uint128(bound(allocation, 1, uint128(MAX_CLAIM) * 20));

        (bytes32 root, bytes32[] memory p,) = _buildTree2(alice, allocation, bob, 1);
        uint256 v = _postRoot(root, uint256(allocation) + 1);

        uint256 balBefore = usdc.balanceOf(alice);
        uint256 claimsNeeded = (uint256(allocation) + MAX_CLAIM - 1) / MAX_CLAIM;

        for (uint256 i = 0; i < claimsNeeded; i++) {
            _claim(alice, v, allocation, p);
        }

        assertEq(usdc.balanceOf(alice) - balBefore, allocation);
        assertEq(distributor.claimed(alice), allocation);
    }
}

/// @notice Pause, parameter updates, funding, and rescue tests.
contract AffiliateDistributorAdminTest is AffiliateDistributorTestBase {
    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function test_Pause_BlocksClaim() public {
        (bytes32 root, bytes32[] memory proofA,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);

        vm.prank(guardian);
        distributor.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        distributor.claim(v, 100e6, alice, proofA);
    }

    function test_Pause_ByOwnerWorks() public {
        vm.prank(owner);
        distributor.pause();
        assertTrue(distributor.paused());
    }

    function test_Pause_ByGuardianWorks() public {
        vm.prank(guardian);
        distributor.pause();
        assertTrue(distributor.paused());
    }

    function test_Pause_RevertsForNonOwnerNonGuardian() public {
        vm.prank(alice);
        vm.expectRevert(AffiliateDistributor.NotGuardianOrOwner.selector);
        distributor.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(guardian);
        distributor.pause();

        vm.prank(guardian);
        vm.expectRevert("Ownable: caller is not the owner");
        distributor.unpause();

        vm.prank(owner);
        distributor.unpause();
        assertFalse(distributor.paused());
    }

    function test_PostRoot_WorksWhilePaused() public {
        vm.prank(owner);
        distributor.pause();

        (bytes32 root,,) = _buildTree2(alice, 100e6, bob, 200e6);
        uint256 v = _postRoot(root, 300e6);
        assertEq(v, 1);
    }

    // -------------------------------------------------------------------------
    // Parameter updates
    // -------------------------------------------------------------------------

    function test_SetMaxSingleClaim() public {
        vm.prank(owner);
        distributor.setMaxSingleClaim(100_000e6);
        assertEq(distributor.maxSingleClaim(), 100_000e6);
    }

    function test_SetMaxSingleClaim_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.InvalidAmount.selector);
        distributor.setMaxSingleClaim(0);
    }

    function test_SetMaxSingleClaim_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        distributor.setMaxSingleClaim(100_000e6);
    }

    function test_SetGuardian() public {
        address newGuardian = address(0xC0DE);
        vm.prank(owner);
        distributor.setGuardian(newGuardian);
        assertEq(distributor.guardian(), newGuardian);
    }

    function test_SetGuardian_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.ZeroAddress.selector);
        distributor.setGuardian(address(0));
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    function test_Fund_TransfersAndEmits() public {
        usdc.mint(alice, 1000e6);
        vm.prank(alice);
        usdc.approve(address(distributor), 1000e6);

        uint256 balBefore = usdc.balanceOf(address(distributor));

        vm.prank(alice);
        distributor.fund(1000e6);

        assertEq(usdc.balanceOf(address(distributor)) - balBefore, 1000e6);
    }

    function test_Fund_RevertsOnZero() public {
        vm.expectRevert(AffiliateDistributor.InvalidAmount.selector);
        distributor.fund(0);
    }

    // -------------------------------------------------------------------------
    // Rescue with timelock
    // -------------------------------------------------------------------------

    function test_Rescue_DistributionTokenRequiresTimelock() public {
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RescueNotRequested.selector);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 1000e6);

        vm.prank(owner);
        distributor.requestRescue();

        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RescueNotReady.selector);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 1000e6);

        vm.warp(block.timestamp + RESCUE_DELAY + 1);

        vm.prank(owner);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 1000e6);
        assertEq(usdc.balanceOf(treasury), 1000e6);
    }

    function test_Rescue_NonDistributionTokenIsImmediate() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(distributor), 500e18);

        vm.prank(owner);
        distributor.rescueToken(IERC20(address(other)), treasury, 500e18);
        assertEq(other.balanceOf(treasury), 500e18);
    }

    function test_Rescue_CancelClearsRequest() public {
        vm.prank(owner);
        distributor.requestRescue();
        vm.prank(owner);
        distributor.cancelRescue();

        vm.warp(block.timestamp + RESCUE_DELAY + 1);

        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RescueNotRequested.selector);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 1000e6);
    }

    function test_Rescue_ConsumesRequestAfterUse() public {
        vm.prank(owner);
        distributor.requestRescue();
        vm.warp(block.timestamp + RESCUE_DELAY + 1);

        vm.prank(owner);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 1000e6);

        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.RescueNotRequested.selector);
        distributor.rescueToken(IERC20(address(usdc)), treasury, 500e6);
    }

    function test_Rescue_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        distributor.requestRescue();
    }

    function test_Rescue_RevertsOnInsufficientBalance() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(owner);
        vm.expectRevert(AffiliateDistributor.InsufficientBalance.selector);
        distributor.rescueToken(IERC20(address(other)), treasury, 1);
    }
}
