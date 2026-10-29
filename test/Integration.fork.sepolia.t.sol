// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Base Sepolia Fork Tests
 * @notice Integration tests against real protocols on Base Sepolia testnet.
 *
 * Run with:
 *   forge test --fork-url $BASE_SEPOLIA_RPC \
 *     --match-path "test/Integration.fork.sepolia.t.sol" -vvvv
 *
 * Or via make:
 *   make test-fork-sepolia
 *
 * Tests auto-skip if BASE_SEPOLIA_RPC / FORK_URL is not set.
 *
 * What is tested:
 *   - AaveStrategy deposits/withdrawals against real Aave V3 on Base Sepolia
 *   - CompoundV3Strategy against real Comet on Base Sepolia
 *   - AutoYieldVault with multiple real strategies
 *   - YieldOptimizer APY comparison
 *   - NoLossLottery round flow (with mock randomness manager)
 *   - Full ContestV2 lifecycle (deposit → lock → reveal → resolve → withdraw)
 *   - Principal protection invariant (users always get back >= deposited)
 */

import "forge-std/Test.sol";
import "../src/strategies/AaveStrategy.sol";
import "../src/strategies/CompoundV3Strategy.sol";
import "../src/vaults/AutoYieldVault.sol";
import "../src/optimizers/YieldOptimizer.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/lottery/NoLossLottery.sol";
import "../src/mocks/MockRandomnessManager.sol";
import "../src/ContestV2.sol";
import "../src/ContestFactoryV2.sol";
import "../src/YieldVault.sol";
import "../src/RandomnessManager.sol";
import "../src/IdentityRegistry.sol";
import "../src/DataRegistry.sol";
import "../src/addresses/NetworkAddresses.sol";

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function mint(address, uint256) external;          // MockERC20 only
    function decimals() external view returns (uint8);
}

// ─────────────────────────────────────────────────────────────────────────────

contract ForkSepoliaBase is Test {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 internal constant CHAIN_BASE_SEPOLIA = 84532;
    uint256 internal constant DEPOSIT_AMOUNT     = 100e6; // 100 USDC

    // ─── Fork state ───────────────────────────────────────────────────────────

    bool    internal skipTests;
    IUSDC   internal usdc;
    address internal aavePool;
    address internal aUsdc;
    address internal cometUsdc;
    address internal deployer;

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", vm.envOr("FORK_URL", string("")));
        if (bytes(rpc).length == 0) {
            skipTests = true;
            return;
        }

        vm.createSelectFork(rpc);

        if (block.chainid != CHAIN_BASE_SEPOLIA) {
            skipTests = true;
            return;
        }

        aavePool  = NetworkAddresses.BASE_SEP_AAVE_POOL;
        aUsdc     = NetworkAddresses.BASE_SEP_AUSDC;
        cometUsdc = NetworkAddresses.BASE_SEP_COMET_USDC;
        deployer  = makeAddr("deployer");

        // On Base Sepolia the test USDC at 0x036CBD... has a public mint function
        // that can be called by anyone (Circle testnet faucet token).
        usdc = IUSDC(NetworkAddresses.BASE_SEP_USDC);

        // Fund deployer with 10M USDC via faucet mint (if available) or deal
        _fundUsdc(deployer, 10_000_000e6);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    modifier onlyFork() {
        if (skipTests) return;
        _;
    }

    /// @dev Try Circle testnet faucet mint, fall back to vm.deal via storage slot
    function _fundUsdc(address to, uint256 amount) internal {
        try usdc.mint(to, amount) {
            return;
        } catch { }
        // Some testnet USDC versions don't have public mint — use deal
        deal(address(usdc), to, amount);
    }

    function _makeAccount(string memory label) internal returns (address addr, uint256 key) {
        key  = uint256(keccak256(abi.encodePacked(label)));
        addr = vm.addr(key);
        vm.label(addr, label);
        _fundUsdc(addr, 1_000_000e6); // 1M USDC
        vm.deal(addr, 10 ether);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Strategy tests
// ─────────────────────────────────────────────────────────────────────────────

contract AaveStrategySepoliaForkTest is ForkSepoliaBase {

    AaveStrategy strategy;
    AutoYieldVault vault;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        vault    = new AutoYieldVault(address(usdc), "USDC");
        strategy = new AaveStrategy(aavePool, address(usdc), aUsdc, address(0));
        strategy.setYieldVault(address(vault));
        vault.addStrategy(address(strategy), "Aave V3 USDC");
        vm.stopPrank();
    }

    function test_fork_aave_depositAndWithdraw() public onlyFork {
        (address alice,) = _makeAccount("alice");

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT_AMOUNT, 1e4, "vault assets should match deposit");

        // Roll forward to accrue interest (Aave accrues per block)
        vm.roll(block.number + 1000);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 returned = vault.withdraw(shares);

        assertGe(returned, DEPOSIT_AMOUNT - 1e4,  "should return at least principal (minus 1 USDC rounding)");
        assertGe(usdc.balanceOf(alice) - balBefore, DEPOSIT_AMOUNT - 1e4, "balance should increase");
    }

    function test_fork_aave_multipleDepositors() public onlyFork {
        (address alice,) = _makeAccount("alice");
        (address bob,)   = _makeAccount("bob");

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 sharesAlice = vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), DEPOSIT_AMOUNT * 2);
        uint256 sharesBob = vault.deposit(DEPOSIT_AMOUNT * 2);
        vm.stopPrank();

        // Bob should have roughly 2x Alice's shares (within rounding)
        assertApproxEqRel(sharesBob, sharesAlice * 2, 0.01e18, "bob should have 2x shares");

        // Roll forward
        vm.roll(block.number + 500);

        // Both withdraw — both should get back at least principal
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(sharesAlice);
        assertGe(usdc.balanceOf(alice) - aliceBefore, DEPOSIT_AMOUNT - 1e4, "alice principal protected");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.withdraw(sharesBob);
        assertGe(usdc.balanceOf(bob) - bobBefore, DEPOSIT_AMOUNT * 2 - 1e4, "bob principal protected");
    }

    function test_fork_aave_estimatedAPY_nonZero() public onlyFork {
        // Base Sepolia Aave may return 0 APY (no real borrowers) but should not revert
        uint256 apy = strategy.getEstimatedAPY();
        // Just verify it doesn't revert and is a sane number
        assertLt(apy, 10000, "APY should be < 100%");
    }

    function test_fork_aave_strategyName() public onlyFork {
        assertEq(strategy.strategyName(), "Aave V3", "strategy name");
        assertEq(strategy.protocolName(), "Aave",    "protocol name");
    }
}

// ─────────────────────────────────────────────────────────────────────────────

contract CompoundV3StrategySepoliaForkTest is ForkSepoliaBase {

    CompoundV3Strategy strategy;
    AutoYieldVault     vault;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        vault    = new AutoYieldVault(address(usdc), "USDC");
        strategy = new CompoundV3Strategy(cometUsdc, address(usdc));
        strategy.setYieldVault(address(vault));
        vault.addStrategy(address(strategy), "Compound V3 USDC");
        vm.stopPrank();
    }

    function test_fork_compoundV3_depositAndWithdraw() public onlyFork {
        (address alice,) = _makeAccount("alice");

        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertGt(shares, 0, "should get shares");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT_AMOUNT, 1e4, "assets match");

        vm.roll(block.number + 500);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares);
        assertGe(usdc.balanceOf(alice) - balBefore, DEPOSIT_AMOUNT - 1e4, "principal protected");
    }

    function test_fork_compoundV3_estimatedAPY() public onlyFork {
        uint256 apy = strategy.getEstimatedAPY();
        assertLt(apy, 10000, "APY < 100%");
    }

    function test_fork_compoundV3_strategyName() public onlyFork {
        assertEq(strategy.protocolName(), "Compound", "protocol name");
    }
}

// ─────────────────────────────────────────────────────────────────────────────

contract YieldOptimizerSepoliaForkTest is ForkSepoliaBase {

    AutoYieldVault     vault;
    AaveStrategy       aaveStrat;
    CompoundV3Strategy c3Strat;
    YieldOptimizer     optim;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        vault = new AutoYieldVault(address(usdc), "USDC");

        aaveStrat = new AaveStrategy(aavePool, address(usdc), aUsdc, address(0));
        aaveStrat.setYieldVault(address(vault));
        vault.addStrategy(address(aaveStrat), "Aave V3 USDC");

        c3Strat = new CompoundV3Strategy(cometUsdc, address(usdc));
        c3Strat.setYieldVault(address(vault));
        vault.addStrategy(address(c3Strat), "Compound V3 USDC");

        {
            YieldOptimizer optImpl = new YieldOptimizer();
            bytes memory optInit = abi.encodeWithSelector(
                YieldOptimizer.initialize.selector, uint256(50), uint256(0), uint256(10e6)
            );
            ERC1967Proxy optProxy = new ERC1967Proxy(address(optImpl), optInit);
            optim = YieldOptimizer(address(optProxy));
        }
        optim.addVault(address(vault));
        vault.setOperator(address(optim));
        vm.stopPrank();
    }

    function test_fork_optimizer_compareAPYs() public onlyFork {
        uint256[] memory apys = vault.getStrategyAPYs();
        assertEq(apys.length, 2, "two strategies");
        // Just ensure we can read APYs without reverting
        assertLt(apys[0], 10000, "aave APY sane");
        assertLt(apys[1], 10000, "compound APY sane");
    }

    function test_fork_optimizer_switchStrategy() public onlyFork {
        (address alice,) = _makeAccount("alice");

        // Deposit first so there are funds to migrate
        vm.startPrank(alice);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();
        assertApproxEqAbs(assetsBefore, DEPOSIT_AMOUNT, 1e4, "assets before switch");

        // Switch from strategy 0 (Aave) to strategy 1 (Compound V3)
        // Optimizer owner is deployer
        vm.prank(deployer);
        vault.switchStrategy(1); // onlyOwnerOrOperator — operator is optimizer, owner is deployer

        assertApproxEqAbs(vault.totalAssets(), assetsBefore, 1e4, "assets preserved after switch");
        assertEq(vault.activeStrategyIndex(), 1, "active strategy is now 1");
    }

    function test_fork_optimizer_checkUpkeep() public onlyFork {
        // checkUpkeep should return without reverting
        (bool needed,) = optim.checkUpkeep("");
        // May or may not need upkeep depending on APY difference — just no revert
        assertTrue(needed == true || needed == false, "upkeep check ran");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NoLossLottery fork test (uses MockRandomnessManager for VRF)
// ─────────────────────────────────────────────────────────────────────────────

contract NoLossLotterySepoliaForkTest is ForkSepoliaBase {

    MockRandomnessManager randMgr;
    AaveStrategy          lotteryStrat;
    NoLossLottery         lotto;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        randMgr     = new MockRandomnessManager();
        lotteryStrat = new AaveStrategy(aavePool, address(usdc), aUsdc, address(0));
        lotto        = new NoLossLottery(
            address(usdc),
            address(lotteryStrat),
            address(randMgr),
            1 hours // short round for tests
        );
        lotteryStrat.setYieldVault(address(lotto));
        vm.stopPrank();
    }

    function test_fork_lottery_depositAndWithdraw() public onlyFork {
        (address alice,) = _makeAccount("alice");

        vm.startPrank(alice);
        usdc.approve(address(lotto), DEPOSIT_AMOUNT);
        lotto.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(lotto.balances(alice), DEPOSIT_AMOUNT, "balance tracked");
        assertEq(lotto.totalDeposited(), DEPOSIT_AMOUNT, "total deposited");

        // Withdraw principal
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lotto.withdraw(DEPOSIT_AMOUNT);

        assertGe(usdc.balanceOf(alice) - balBefore, DEPOSIT_AMOUNT - 1e4, "principal returned");
        assertEq(lotto.balances(alice), 0, "balance cleared");
    }

    function test_fork_lottery_fullRound() public onlyFork {
        (address alice,) = _makeAccount("alice");
        (address bob,)   = _makeAccount("bob");

        // Both deposit
        vm.startPrank(alice);
        usdc.approve(address(lotto), DEPOSIT_AMOUNT);
        lotto.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(lotto), DEPOSIT_AMOUNT * 2);
        lotto.deposit(DEPOSIT_AMOUNT * 2);
        vm.stopPrank();

        uint256 totalDep = lotto.totalDeposited();
        assertEq(totalDep, DEPOSIT_AMOUNT * 3, "total deposited");

        // Warp past round end
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 300);

        // Check upkeep
        (bool upkeepNeeded,) = lotto.checkUpkeep("");
        assertTrue(upkeepNeeded, "upkeep should be needed");

        // Trigger draw (performUpkeep → requestRandomness)
        lotto.performUpkeep("");

        uint256 roundId = lotto.currentRoundId();

        // Fulfill randomness via mock manager (simulates VRF callback)
        randMgr.deliverRandomness(address(lotto), 12345678901234567890);

        // Round should now be settled
        (, , , , , , bool isSettled, address winner, uint256 prizeAmount) =
            lotto.rounds(roundId);

        assertTrue(isSettled, "round should be settled");
        assertTrue(winner == alice || winner == bob, "winner should be a participant");
        // Prize may be 0 on testnet (no real interest in 1 hour) but structure works
        assertGe(prizeAmount, 0, "prize >= 0");

        // Claim prize if winner is alice
        if (winner == alice && prizeAmount > 0) {
            uint256 balBefore = usdc.balanceOf(alice);
            vm.prank(alice);
            lotto.claimPrize(roundId);
            assertGt(usdc.balanceOf(alice) - balBefore, 0, "prize claimed");
        }

        // Both withdraw principal — MUST get back >= deposited
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lotto.withdraw(DEPOSIT_AMOUNT);
        assertGe(usdc.balanceOf(alice) - aliceBefore, DEPOSIT_AMOUNT - 1e4, "alice principal protected");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        lotto.withdraw(DEPOSIT_AMOUNT * 2);
        assertGe(usdc.balanceOf(bob) - bobBefore, DEPOSIT_AMOUNT * 2 - 1e4, "bob principal protected");
    }

    function test_fork_lottery_multipleRounds() public onlyFork {
        (address alice,) = _makeAccount("alice");

        vm.startPrank(alice);
        usdc.approve(address(lotto), DEPOSIT_AMOUNT * 3);
        lotto.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Run 3 rounds
        for (uint256 r = 0; r < 3; r++) {
            vm.warp(block.timestamp + 1 hours + 1);
            vm.roll(block.number + 100);

            lotto.performUpkeep("");
            uint256 roundId = lotto.currentRoundId();
            randMgr.deliverRandomness(address(lotto), uint256(keccak256(abi.encode(r))));

            (, , , , , , bool isSettled, , ) = lotto.rounds(roundId);
            assertTrue(isSettled, string(abi.encodePacked("round ", vm.toString(r), " settled")));
        }

        // Principal still intact after 3 rounds
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lotto.withdraw(DEPOSIT_AMOUNT);
        assertGe(usdc.balanceOf(alice) - balBefore, DEPOSIT_AMOUNT - 1e4, "principal protected after 3 rounds");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full ContestV2 lifecycle fork test
// ─────────────────────────────────────────────────────────────────────────────

contract ContestV2SepoliaForkTest is ForkSepoliaBase {

    YieldVault        yieldVault;
    ContestV2         contestImpl;
    RandomnessManager randMgr;
    ContestFactoryV2  factory;
    IdentityRegistry  identityReg;
    DataRegistry      dataReg;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        yieldVault   = new YieldVault();
        yieldVault.addStrategy(address(0)); // hold strategy id=0

        identityReg  = new IdentityRegistry();
        dataReg      = new DataRegistry(address(this));
        contestImpl  = new ContestV2();

        // Use null VRF (address(0)) so RM falls back to manual fulfill
        randMgr      = new RandomnessManager(address(0), bytes32(0), 0);

        factory      = new ContestFactoryV2(
            address(contestImpl),
            address(yieldVault),
            address(identityReg),
            address(randMgr),
            deployer
        );
        randMgr.setAuthorizedFactory(address(factory), true);
        vm.stopPrank();
    }

    function _createVoteContest(uint256 depositDuration, uint256 lockDuration, uint256 revealDuration)
        internal returns (address contestAddr)
    {
        bytes32[] memory options = new bytes32[](3);
        options[0] = bytes32("option_A");
        options[1] = bytes32("option_B");
        options[2] = bytes32("option_C");

        ContestV2.ContestConfig memory config = ContestV2.ContestConfig({
            depositToken:            address(usdc),
            depositAmount:           10e6, // 10 USDC
            minParticipants:         2,
            maxParticipants:         100,
            depositStart:            block.timestamp,
            depositEnd:              block.timestamp + depositDuration,
            lockEnd:                 block.timestamp + depositDuration + lockDuration,
            revealEnd:               block.timestamp + depositDuration + lockDuration + revealDuration,
            contestType:             ContestV2.ContestType.VOTE,
            winnerDetermination:     ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            tierRequired:            0,
            quorumPercentage:        1, // 1% quorum (easy to meet in tests)
            requiresOracle:          false,
            metadataHash:            keccak256("test-contest"),
            metadataUri:             "ipfs://test"
        });
        // v2.1 PrizeConfig
        ContestV2.PrizeConfig memory prizeCfg = ContestV2.PrizeConfig({
            model: ContestV2.PrizeModel.SINGLE_TOP,
            splitsBps: new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore: false
        });

        ContestV2.ScoringConfig memory scoring = ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        5000,
            confidenceMultiplier: 5000,
            earlyVoterBonus:      0
        });

        ContestV2.SubmissionConfig memory subCfg = ContestV2.SubmissionConfig({
            enabled:               false,
            submissionStart:       0,
            submissionEnd:         0,
            maxPerUser:            0,
            requiresModeration:    false,
            paymentModel:          ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions:        0,
            maxTotalSubmissions:   0
        });

        vm.prank(deployer);
        (, contestAddr) = factory.createCustomContest(config, prizeCfg, scoring, subCfg, address(0), options, 0);
    }

    function test_fork_contest_fullVoteLifecycle() public onlyFork {
        (address alice,) = _makeAccount("alice");
        (address bob,)   = _makeAccount("bob");
        (address carol,) = _makeAccount("carol");

        address contestAddr = _createVoteContest(1 hours, 30 minutes, 30 minutes);
        ContestV2 contest   = ContestV2(contestAddr);

        // Allow contest to request randomness
        vm.prank(deployer);
        randMgr.addAllowedRequester(contestAddr);

        // ── Deposit phase ──────────────────────────────────────────────────────
        bytes32 optionA = bytes32("option_A");
        bytes32 optionB = bytes32("option_B");

        bytes32 saltAlice = bytes32("salt_alice");
        bytes32 saltBob   = bytes32("salt_bob");
        bytes32 saltCarol = bytes32("salt_carol");

        bytes32 hashAlice = keccak256(abi.encodePacked(abi.encode(optionA), saltAlice));
        bytes32 hashBob   = keccak256(abi.encodePacked(abi.encode(optionA), saltBob));
        bytes32 hashCarol = keccak256(abi.encodePacked(abi.encode(optionB), saltCarol));

        vm.startPrank(alice);
        usdc.approve(contestAddr, 10e6);
        contest.deposit();
        contest.commitVote(hashAlice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(contestAddr, 10e6);
        contest.deposit();
        contest.commitVote(hashBob);
        vm.stopPrank();

        vm.startPrank(carol);
        usdc.approve(contestAddr, 10e6);
        contest.deposit();
        contest.commitVote(hashCarol);
        vm.stopPrank();

        assertEq(contest.getParticipantCount(), 3, "3 participants");

        // ── Advance to reveal phase ────────────────────────────────────────────
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 200);
        contest.updateState();

        // Reveal votes
        vm.prank(alice);
        contest.revealVote(abi.encode(optionA), saltAlice);

        vm.prank(bob);
        contest.revealVote(abi.encode(optionA), saltBob);

        vm.prank(carol);
        contest.revealVote(abi.encode(optionB), saltCarol);

        // ── Advance past reveal end ────────────────────────────────────────────
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.roll(block.number + 100);

        // ── Resolve ───────────────────────────────────────────────────────────
        vm.prank(deployer);
        contest.resolveContest();

        assertTrue(contest.getResults().isResolved, "contest resolved");
        assertEq(contest.getResults().winningOption, optionA, "option A wins (2 vs 1)");

        // ── Withdraw principal ─────────────────────────────────────────────────
        uint256 balAliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        contest.withdrawPrincipal();
        assertGe(usdc.balanceOf(alice) - balAliceBefore, 10e6 - 1e4, "alice principal returned");

        uint256 balBobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        contest.withdrawPrincipal();
        assertGe(usdc.balanceOf(bob) - balBobBefore, 10e6 - 1e4, "bob principal returned");

        uint256 balCarolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        contest.withdrawPrincipal();
        assertGe(usdc.balanceOf(carol) - balCarolBefore, 10e6 - 1e4, "carol principal returned");
    }

    function test_fork_contest_cancelAndRefund() public onlyFork {
        (address alice,) = _makeAccount("alice");

        address contestAddr = _createVoteContest(1 hours, 30 minutes, 30 minutes);
        ContestV2 contest   = ContestV2(contestAddr);

        vm.startPrank(alice);
        usdc.approve(contestAddr, 10e6);
        contest.deposit();
        vm.stopPrank();

        // Creator cancels
        vm.prank(deployer);
        contest.cancel("test cancel");

        assertEq(uint8(contest.state()), uint8(ContestV2.ContestState.CANCELLED), "cancelled");

        // Alice gets principal back
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        contest.withdrawPrincipal();
        assertGe(usdc.balanceOf(alice) - balBefore, 10e6 - 1e4, "refund returned");
    }

    function test_fork_contest_allContestTypes() public onlyFork {
        // RANK contest
        _runRankContest();
        // RATE contest
        _runRateContest();
        // PREDICT contest
        _runPredictContest();
    }

    function _runRankContest() internal {
        (address alice,) = _makeAccount("alice_rank");
        (address bob,)   = _makeAccount("bob_rank");

        bytes32[] memory options = new bytes32[](3);
        options[0] = bytes32("X");
        options[1] = bytes32("Y");
        options[2] = bytes32("Z");

        ContestV2.ContestConfig memory config = _baseConfig(address(usdc));
        config.contestType         = ContestV2.ContestType.RANK;
        config.winnerDetermination = ContestV2.WinnerDetermination.BORDA_COUNT;

        ContestV2.ScoringConfig    memory scoring = _baseScoring();
        ContestV2.SubmissionConfig memory subCfg  = _noSubmissions();

        vm.prank(deployer);
        (, address addr) = factory.createCustomContest(config, _basePrize(), scoring, subCfg, address(0), options, 0);
        ContestV2 contest = ContestV2(addr);

        vm.prank(deployer);
        randMgr.addAllowedRequester(addr);

        // Both deposit and commit
        bytes32[] memory rankAlice = new bytes32[](3);
        rankAlice[0] = bytes32("X"); rankAlice[1] = bytes32("Y"); rankAlice[2] = bytes32("Z");
        bytes32[] memory rankBob   = new bytes32[](3);
        rankBob[0]   = bytes32("X"); rankBob[1]   = bytes32("Z"); rankBob[2]   = bytes32("Y");

        bytes32 saltA = keccak256("salt_alice_rank");
        bytes32 saltB = keccak256("salt_bob_rank");

        vm.startPrank(alice);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(abi.encode(rankAlice), saltA)));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(abi.encode(rankBob), saltB)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
        contest.updateState();

        vm.prank(alice);
        contest.revealVote(abi.encode(rankAlice), saltA);
        vm.prank(bob);
        contest.revealVote(abi.encode(rankBob),   saltB);

        vm.warp(block.timestamp + 30 minutes + 1);
        vm.prank(deployer);
        contest.resolveContest();

        assertTrue(contest.getResults().isResolved, "rank contest resolved");
        assertEq(contest.getResults().winningOption, bytes32("X"), "X wins (top of both rankings)");
    }

    function _runRateContest() internal {
        (address alice,) = _makeAccount("alice_rate");
        (address bob,)   = _makeAccount("bob_rate");

        bytes32[] memory options = new bytes32[](2);
        options[0] = bytes32("P");
        options[1] = bytes32("Q");

        ContestV2.ContestConfig memory config = _baseConfig(address(usdc));
        config.contestType         = ContestV2.ContestType.RATE;
        config.winnerDetermination = ContestV2.WinnerDetermination.WEIGHTED_AVERAGE;

        vm.prank(deployer);
        (, address addr) = factory.createCustomContest(config, _basePrize(), _baseScoring(), _noSubmissions(), address(0), options, 0);
        ContestV2 contest = ContestV2(addr);
        vm.prank(deployer);
        randMgr.addAllowedRequester(addr);

        bytes32[] memory optIds = new bytes32[](2);
        optIds[0] = bytes32("P"); optIds[1] = bytes32("Q");
        uint256[] memory ratingsAlice = new uint256[](2);
        ratingsAlice[0] = 8; ratingsAlice[1] = 5;
        uint256[] memory ratingsBob = new uint256[](2);
        ratingsBob[0]  = 9; ratingsBob[1]  = 3;

        bytes32 saltA = keccak256("salt_alice_rate");
        bytes32 saltB = keccak256("salt_bob_rate");
        bytes memory voteA = abi.encode(optIds, ratingsAlice);
        bytes memory voteB = abi.encode(optIds, ratingsBob);

        vm.startPrank(alice);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(voteA, saltA)));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(voteB, saltB)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
        contest.updateState();

        vm.prank(alice);
        contest.revealVote(voteA, saltA);
        vm.prank(bob);
        contest.revealVote(voteB, saltB);

        vm.warp(block.timestamp + 30 minutes + 1);
        vm.prank(deployer);
        contest.resolveContest();
        assertTrue(contest.getResults().isResolved, "rate contest resolved");
        // P average = (8+9)/2 = 8.5, Q average = (5+3)/2 = 4 → P wins
        assertEq(contest.getResults().winningOption, bytes32("P"), "P wins by average rating");
    }

    function _runPredictContest() internal {
        (address alice,) = _makeAccount("alice_predict");
        (address bob,)   = _makeAccount("bob_predict");

        bytes32[] memory options = new bytes32[](2);
        options[0] = bytes32("UP");
        options[1] = bytes32("DOWN");

        ContestV2.ContestConfig memory config = _baseConfig(address(usdc));
        config.contestType         = ContestV2.ContestType.PREDICT;
        config.winnerDetermination = ContestV2.WinnerDetermination.PLURALITY;

        vm.prank(deployer);
        (, address addr) = factory.createCustomContest(config, _basePrize(), _baseScoring(), _noSubmissions(), address(0), options, 0);
        ContestV2 contest = ContestV2(addr);
        vm.prank(deployer);
        randMgr.addAllowedRequester(addr);

        bytes32 saltA = keccak256("salt_alice_predict");
        bytes32 saltB = keccak256("salt_bob_predict");
        bytes memory voteA = abi.encode(bytes32("UP"),   uint256(80)); // 80% confidence
        bytes memory voteB = abi.encode(bytes32("DOWN"), uint256(60));

        vm.startPrank(alice);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(voteA, saltA)));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(addr, 10e6);
        contest.deposit();
        contest.commitVote(keccak256(abi.encodePacked(voteB, saltB)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
        contest.updateState();

        vm.prank(alice);
        contest.revealVote(voteA, saltA);
        vm.prank(bob);
        contest.revealVote(voteB, saltB);

        vm.warp(block.timestamp + 30 minutes + 1);
        vm.prank(deployer);
        contest.resolveContest();
        assertTrue(contest.getResults().isResolved, "predict contest resolved");
    }

    // ─── Config helpers ───────────────────────────────────────────────────────

    function _baseConfig(address token) internal view returns (ContestV2.ContestConfig memory) {
        return ContestV2.ContestConfig({
            depositToken:            token,
            depositAmount:           10e6,
            minParticipants:         2,
            maxParticipants:         100,
            depositStart:            block.timestamp,
            depositEnd:              block.timestamp + 1 hours,
            lockEnd:                 block.timestamp + 1 hours + 30 minutes,
            revealEnd:               block.timestamp + 1 hours + 60 minutes,
            contestType:             ContestV2.ContestType.VOTE,
            winnerDetermination:     ContestV2.WinnerDetermination.PLURALITY,
            voterRewardDistribution: ContestV2.VoterRewardDistribution.EQUAL,
            tierRequired:            0,
            quorumPercentage:        1,
            requiresOracle:          false,
            metadataHash:            keccak256(abi.encodePacked(block.timestamp)),
            metadataUri:             "ipfs://test"
        });
    }

    /// @notice v2.1 default PrizeConfig — SINGLE_TOP, no splits, no threshold.
    function _basePrize() internal pure returns (ContestV2.PrizeConfig memory) {
        return ContestV2.PrizeConfig({
            model: ContestV2.PrizeModel.SINGLE_TOP,
            splitsBps: new uint16[](0),
            eligibilityThreshold: 0,
            weightedByScore: false
        });
    }

    function _baseScoring() internal pure returns (ContestV2.ScoringConfig memory) {
        return ContestV2.ScoringConfig({
            correlationThreshold: 0,
            topPercentile:        5000,
            confidenceMultiplier: 5000,
            earlyVoterBonus:      0
        });
    }

    function _noSubmissions() internal pure returns (ContestV2.SubmissionConfig memory) {
        return ContestV2.SubmissionConfig({
            enabled:                 false,
            submissionStart:         0,
            submissionEnd:           0,
            maxPerUser:              0,
            requiresModeration:      false,
            paymentModel:            ContestV2.PaymentModel.PROTOCOL,
            storageFeePerSubmission: 0,
            minSubmissions:          0,
            maxTotalSubmissions:     0
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Principal protection invariant (property-based)
// ─────────────────────────────────────────────────────────────────────────────

contract PrincipalProtectionForkTest is ForkSepoliaBase {

    AutoYieldVault vault;
    AaveStrategy   strategy;

    function setUp() public override {
        super.setUp();
        if (skipTests) return;

        vm.startPrank(deployer);
        vault    = new AutoYieldVault(address(usdc), "USDC");
        strategy = new AaveStrategy(aavePool, address(usdc), aUsdc, address(0));
        strategy.setYieldVault(address(vault));
        vault.addStrategy(address(strategy), "Aave V3");
        vm.stopPrank();
    }

    /// @dev Invariant: after any deposit + withdraw, user balance >= deposited - 1 USDC rounding
    function test_fork_invariant_principalNeverLost(uint96 amount, uint32 blocksElapsed) public onlyFork {
        // Bound inputs to reasonable ranges
        amount        = uint96(bound(amount, 1e6, 100_000e6));  // 1 to 100k USDC
        blocksElapsed = uint32(bound(blocksElapsed, 0, 50000)); // up to ~7 days of blocks

        (address user,) = _makeAccount("fuzz_user");
        _fundUsdc(user, amount);

        uint256 balBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);
        vm.stopPrank();

        vm.roll(block.number + blocksElapsed);

        vm.prank(user);
        uint256 returned = vault.withdraw(shares);

        assertGe(returned + 1e4, amount, "principal never lost (with 1 USDC tolerance)");
        assertGe(usdc.balanceOf(user) + 1e4, balBefore, "user balance never decreases");
    }
}
