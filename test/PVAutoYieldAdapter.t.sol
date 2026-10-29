// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/vaults/PVAutoYieldAdapter.sol";
import "../src/interfaces/IAutoYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockStrategy — lightweight IAutoYieldStrategy implementation for adapter tests.
//
// Design choices:
//   - Tracks deposited token balance using a simple uint (`_balance`).
//   - simulateYield(amount) mints extra tokens directly to self and increases
//     _balance, so getTotalValue() reflects principal + accrued yield.
//   - harvestYield() returns 0; yield accretes inside the strategy value and is
//     accessed only through share appreciation (matching on-chain strategy behaviour).
//   - withdrawAmount() returns exactly `tokenAmount` when balance >= tokenAmount,
//     capped at the current balance. This is sufficient for the tests here.
//   - Caller-level share tracking mirrors MockAutoYieldStrategy so the adapter
//     (which is always msg.sender) can withdraw what it deposited.
// ─────────────────────────────────────────────────────────────────────────────
contract MockStrategy is IAutoYieldStrategy {
    MockERC20 public immutable token;

    /// @dev Total token value managed (principal + simulated yield).
    uint256 public _balance;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    // ─── IAutoYieldStrategy ──────────────────────────────────────────────────

    function deposit(uint256 amount) external override {
        require(amount > 0, "MockStrategy: zero");
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "MockStrategy: transferFrom failed"
        );
        _balance += amount;
    }

    function withdrawAmount(uint256 tokenAmount) external override returns (uint256 actualOut) {
        if (_balance == 0 || tokenAmount == 0) return 0;
        actualOut = tokenAmount > _balance ? _balance : tokenAmount;
        _balance -= actualOut;
        require(token.transfer(msg.sender, actualOut), "MockStrategy: transfer failed");
    }

    function withdraw(uint256 sharesToBurn) external override returns (uint256 amountOut) {
        // For these tests withdraw-by-shares is not exercised directly; treat shares as token amount.
        if (_balance == 0 || sharesToBurn == 0) return 0;
        amountOut = sharesToBurn > _balance ? _balance : sharesToBurn;
        _balance -= amountOut;
        require(token.transfer(msg.sender, amountOut), "MockStrategy: transfer failed");
    }

    function getTotalValue() external view override returns (uint256) {
        return _balance;
    }

    function getEstimatedAPY() external pure override returns (uint256) {
        return 300; // 3% in basis points
    }

    function harvestYield() external pure override returns (uint256) {
        // Yield stays inside _balance (accretes in share price).
        return 0;
    }

    function strategyName() external pure override returns (string memory) {
        return "MockStrategy";
    }

    function protocolName() external pure override returns (string memory) {
        return "Mock";
    }

    // ─── Test helpers ────────────────────────────────────────────────────────

    /// @notice Simulate yield accrual: mint tokens to self, increasing getTotalValue().
    function simulateYield(uint256 amount) external {
        token.mint(address(this), amount);
        _balance += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockHarvestStrategy — like MockStrategy but harvestYield() actually sends
// accumulated yield back to the caller (adapter), so harvestAndReinvest tests
// can verify the reinvestment path.
// ─────────────────────────────────────────────────────────────────────────────
contract MockHarvestStrategy is IAutoYieldStrategy {
    MockERC20 public immutable token;
    uint256 public _balance;
    uint256 public _pendingYield;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function deposit(uint256 amount) external override {
        require(amount > 0, "MockHarvestStrategy: zero");
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _balance += amount;
    }

    function withdrawAmount(uint256 tokenAmount) external override returns (uint256 actualOut) {
        if (_balance == 0 || tokenAmount == 0) return 0;
        actualOut = tokenAmount > _balance ? _balance : tokenAmount;
        _balance -= actualOut;
        require(token.transfer(msg.sender, actualOut), "transfer failed");
    }

    function withdraw(uint256 sharesToBurn) external override returns (uint256 amountOut) {
        if (_balance == 0 || sharesToBurn == 0) return 0;
        amountOut = sharesToBurn > _balance ? _balance : sharesToBurn;
        _balance -= amountOut;
        require(token.transfer(msg.sender, amountOut), "transfer failed");
    }

    function getTotalValue() external view override returns (uint256) {
        return _balance;
    }

    function getEstimatedAPY() external pure override returns (uint256) {
        return 500;
    }

    function harvestYield() external override returns (uint256 harvested) {
        harvested = _pendingYield;
        _pendingYield = 0;
        if (harvested > 0) {
            _balance -= harvested; // tokens leave the strategy
            require(token.transfer(msg.sender, harvested), "harvest transfer failed");
        }
    }

    function strategyName() external pure override returns (string memory) {
        return "MockHarvestStrategy";
    }

    function protocolName() external pure override returns (string memory) {
        return "MockHarvest";
    }

    // ─── Test helpers ────────────────────────────────────────────────────────

    /// @notice Simulate yield: mint extra tokens, mark as pending harvest.
    function simulateYield(uint256 amount) external {
        token.mint(address(this), amount);
        _balance       += amount;
        _pendingYield  += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BadSlippageStrategy — withdrawAmount always returns less than requested
// (simulating a lossy migration), used for the slippage-guard test.
// ─────────────────────────────────────────────────────────────────────────────
contract BadSlippageStrategy is IAutoYieldStrategy {
    MockERC20 public immutable token;
    uint256 public _balance;
    uint256 public slippageBps; // e.g. 200 = 2% loss

    constructor(address _token, uint256 _slippageBps) {
        token = MockERC20(_token);
        slippageBps = _slippageBps;
    }

    function deposit(uint256 amount) external override {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        _balance += amount;
    }

    function withdrawAmount(uint256 tokenAmount) external override returns (uint256 actualOut) {
        if (_balance == 0 || tokenAmount == 0) return 0;
        uint256 loss = (tokenAmount * slippageBps) / 10_000;
        actualOut = tokenAmount - loss;
        if (actualOut > _balance) actualOut = _balance;
        _balance -= actualOut;
        require(token.transfer(msg.sender, actualOut), "transfer failed");
    }

    function withdraw(uint256 shares) external override returns (uint256 actualOut) {
        if (_balance == 0 || shares == 0) return 0;
        uint256 loss = (shares * slippageBps) / 10_000;
        actualOut = shares - loss;
        if (actualOut > _balance) actualOut = _balance;
        _balance -= actualOut;
        require(token.transfer(msg.sender, actualOut), "transfer failed");
    }

    function getTotalValue() external view override returns (uint256) {
        return _balance;
    }

    function getEstimatedAPY() external pure override returns (uint256) { return 0; }
    function harvestYield() external pure override returns (uint256) { return 0; }
    function strategyName() external pure override returns (string memory) { return "BadStrategy"; }
    function protocolName() external pure override returns (string memory) { return "Bad"; }
}

// ─────────────────────────────────────────────────────────────────────────────
// PVAutoYieldAdapterTest
// ─────────────────────────────────────────────────────────────────────────────
contract PVAutoYieldAdapterTest is Test {

    // ─── Contracts ────────────────────────────────────────────────────────────

    MockERC20          usdc;
    MockStrategy       strategy;
    PVAutoYieldAdapter adapter;

    // ─── Actors ───────────────────────────────────────────────────────────────

    address owner   = address(0x1);
    address alice   = address(0x2);
    address bob     = address(0x3);
    address nobody  = address(0x4);

    // ─── Config ───────────────────────────────────────────────────────────────

    uint256 constant INITIAL_BALANCE = 10_000e6;
    uint256 constant DEP_ALICE       = 1_000e6;
    uint256 constant DEP_BOB         =   500e6;

    // ─── Events (mirror adapter definitions) ──────────────────────────────────

    event StrategySwitchQueued(address indexed newStrategy, uint256 executeAfter);
    event StrategySwitchExecuted(address indexed oldStrategy, address indexed newStrategy);
    event StrategySwitchCancelled(address indexed strategy);
    event SwitchDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event Harvested(uint256 amount);

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        usdc     = new MockERC20("Test USDC", "USDC", 6);
        strategy = new MockStrategy(address(usdc));

        // Deploy adapter with owner=owner, initialStrategy=strategy
        vm.prank(owner);
        adapter = new PVAutoYieldAdapter(address(usdc), address(strategy), owner);

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob,   INITIAL_BALANCE);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Deposit `amount` USDC from `user` through the IYieldVault interface.
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        shares = adapter.deposit(address(usdc), amount, 0);
        vm.stopPrank();
    }

    /// Withdraw `shares` from `user` to `user`.
    function _withdraw(address user, uint256 shares) internal returns (uint256 amount) {
        vm.prank(user);
        amount = adapter.withdraw(address(usdc), shares, 0, user);
    }

    // =========================================================================
    // 1. test_deposit_mintsCorrectShares
    //    Two depositors with no yield in-between should receive shares strictly
    //    proportional to their deposit amounts.
    // =========================================================================

    function test_deposit_mintsCorrectShares() public {
        uint256 sharesAlice = _deposit(alice, DEP_ALICE);
        uint256 sharesBob   = _deposit(bob,   DEP_BOB);

        // Virtual-offset formula: shares = amount * (totalShares + 1e6) / (totalAssets + 1)
        // With no yield the ratio is fixed by the relative deposit sizes.
        // Alice deposited 2× Bob's amount, so she should hold ~2× his shares.
        assertGt(sharesAlice, 0, "alice has shares");
        assertGt(sharesBob,   0, "bob has shares");

        // Proportionality: shares are proportional within virtual-offset rounding.
        // sharesAlice / sharesBob ≈ DEP_ALICE / DEP_BOB = 2
        // Use assertApproxEqRel with 0.01% tolerance (1e12 out of 1e18).
        assertApproxEqRel(sharesAlice * DEP_BOB, sharesBob * DEP_ALICE, 1e12,
            "shares proportional to deposit amounts");

        // Total shares held by adapter should equal the sum minted.
        assertEq(adapter.totalShares(), sharesAlice + sharesBob, "totalShares accounting");

        // All tokens should be inside the strategy (adapter holds no idle balance).
        assertEq(usdc.balanceOf(address(strategy)), DEP_ALICE + DEP_BOB, "all tokens in strategy");
        assertEq(usdc.balanceOf(address(adapter)),  0,                    "adapter holds no idle");
    }

    // =========================================================================
    // 2. test_withdraw_returnsCorrectTokens
    //    After yield accumulates, withdraw should return principal + proportional yield.
    // =========================================================================

    function test_withdraw_returnsCorrectTokens() public {
        uint256 sharesAlice = _deposit(alice, DEP_ALICE);
        uint256 sharesBob   = _deposit(bob,   DEP_BOB);

        // Inject 150 USDC yield (10% on the combined 1,500 deposit).
        uint256 yieldAmount = 150e6;
        strategy.simulateYield(yieldAmount);

        uint256 totalExpected = DEP_ALICE + DEP_BOB + yieldAmount;

        // Alice owns 2/3 of the deposits → ~2/3 of total assets.
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        uint256 aliceReceived = _withdraw(alice, sharesAlice);
        uint256 bobReceived   = _withdraw(bob,   sharesBob);

        // Each depositor should receive at least their principal back.
        assertGe(aliceReceived, DEP_ALICE, "alice receives >= principal");
        assertGe(bobReceived,   DEP_BOB,   "bob receives >= principal");

        // Combined receipts should account for full pool (rounding dust of ≤ 2 wei).
        assertApproxEqAbs(aliceReceived + bobReceived, totalExpected, 2,
            "combined withdrawal matches total pool");

        // Balance accounting check.
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceReceived, "alice balance updated");
        assertEq(usdc.balanceOf(bob)   - bobBefore,   bobReceived,   "bob balance updated");

        // Virtual-offset rounding leaves at most 1 wei in the strategy after a full
        // withdrawal — this is expected and acceptable (same behavior as OpenZeppelin ERC-4626).
        assertLe(adapter.getTotalDeposited(address(usdc), 0), 1, "strategy dust after full withdrawal (max 1 wei)");
        assertEq(adapter.totalShares(), 0, "totalShares zero after full withdrawal");
    }

    // =========================================================================
    // 3. test_virtualOffset_preventsInflation
    //    The classic first-depositor inflation attack: deposit 1 wei, donate a
    //    large amount to the strategy, then observe that the second depositor's
    //    shares are not inflated away.
    //
    //    With VIRTUAL_SHARES=1e6 and VIRTUAL_ASSETS=1, an attacker that deposits
    //    1 token unit and then donates 1e18 tokens cannot round a second depositor
    //    to 0 shares.
    // =========================================================================

    function test_virtualOffset_preventsInflation() public {
        address attacker = address(0xDEAD);
        usdc.mint(attacker, INITIAL_BALANCE);

        // Step 1: attacker deposits 1 wei.
        vm.startPrank(attacker);
        usdc.approve(address(adapter), 1);
        uint256 attackerShares = adapter.deposit(address(usdc), 1, 0);
        vm.stopPrank();

        // Step 2: attacker donates a large sum directly to the strategy
        //         (simulated as a yield injection, same economic effect as donation).
        strategy.simulateYield(1_000e6);

        // Step 3: honest depositor (alice) deposits 500 USDC.
        uint256 aliceDeposit = 500e6;
        uint256 aliceShares  = _deposit(alice, aliceDeposit);

        // With the virtual offset the attacker cannot inflate the price enough to
        // round alice to 0 shares.
        assertGt(aliceShares, 0, "inflation attack: alice must receive > 0 shares");

        // alice's value should be at least 99% of her deposit (rounding only).
        uint256 aliceValue = adapter.getShareValue(address(usdc), aliceShares, 0);
        assertGe(aliceValue * 100, aliceDeposit * 99,
            "inflation attack: alice must not lose more than 1% of her deposit");

        // Sanity: attacker can still withdraw.
        uint256 attackerValue = adapter.getShareValue(address(usdc), attackerShares, 0);
        assertGt(attackerValue, 0, "attacker share value > 0");
    }

    // =========================================================================
    // 4. test_queueStrategySwitch_onlyOwner
    //    Non-owner calling queueStrategySwitch should revert.
    // =========================================================================

    function test_queueStrategySwitch_onlyOwner() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));

        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.queueStrategySwitch(address(newStrategy));
    }

    // =========================================================================
    // 4b. test_queueStrategySwitch_emitsEvent
    // =========================================================================

    function test_queueStrategySwitch_emitsEvent() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));
        uint256 expectedTime = block.timestamp + adapter.switchDelay();

        vm.expectEmit(true, false, false, true);
        emit StrategySwitchQueued(address(newStrategy), expectedTime);

        vm.prank(owner);
        adapter.queueStrategySwitch(address(newStrategy));

        assertEq(address(adapter.pendingStrategy()), address(newStrategy), "pending strategy set");
        assertEq(adapter.pendingSwitchTime(), expectedTime, "pending switch time set");
    }

    // =========================================================================
    // 4c. test_queueStrategySwitch_alreadyQueued_reverts
    //     Attempting to queue a second switch while one is pending should revert.
    // =========================================================================

    function test_queueStrategySwitch_alreadyQueued_reverts() public {
        MockStrategy s1 = new MockStrategy(address(usdc));
        MockStrategy s2 = new MockStrategy(address(usdc));

        vm.startPrank(owner);
        adapter.queueStrategySwitch(address(s1));

        vm.expectRevert(PVAutoYieldAdapter.AlreadyQueued.selector);
        adapter.queueStrategySwitch(address(s2));
        vm.stopPrank();
    }

    // =========================================================================
    // 5. test_executeStrategySwitch_beforeDelay_reverts
    //    Calling executeStrategySwitch before the timelock elapses should
    //    revert with SwitchTooEarly.
    // =========================================================================

    function test_executeStrategySwitch_beforeDelay_reverts() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));

        vm.prank(owner);
        adapter.queueStrategySwitch(address(newStrategy));

        // Advance time but NOT far enough (1 second short of the delay).
        vm.warp(block.timestamp + adapter.switchDelay() - 1);

        vm.expectRevert(PVAutoYieldAdapter.SwitchTooEarly.selector);
        adapter.executeStrategySwitch();
    }

    // =========================================================================
    // 6. test_executeStrategySwitch_migratesAssets
    //    After the timelock, executeStrategySwitch should move ALL assets from
    //    the old strategy to the new one and update activeStrategy.
    // =========================================================================

    function test_executeStrategySwitch_migratesAssets() public {
        // Deposit so there are real assets to migrate.
        _deposit(alice, DEP_ALICE);
        _deposit(bob,   DEP_BOB);
        uint256 totalDeposited = DEP_ALICE + DEP_BOB;

        MockStrategy newStrategy = new MockStrategy(address(usdc));

        vm.prank(owner);
        adapter.queueStrategySwitch(address(newStrategy));
        vm.warp(block.timestamp + adapter.switchDelay() + 1);

        address oldStratAddr = address(strategy);
        address newStratAddr = address(newStrategy);

        vm.expectEmit(true, true, false, true);
        emit StrategySwitchExecuted(oldStratAddr, newStratAddr);

        // executeStrategySwitch is permissionless after delay — call as nobody.
        vm.prank(nobody);
        adapter.executeStrategySwitch();

        // Old strategy should be drained.
        assertEq(strategy._balance(), 0, "old strategy drained");
        // New strategy should hold all assets.
        assertEq(newStrategy._balance(), totalDeposited, "new strategy has all assets");

        // Adapter state updated.
        assertEq(address(adapter.activeStrategy()), newStratAddr, "activeStrategy updated");
        assertEq(address(adapter.pendingStrategy()), address(0), "pendingStrategy cleared");
        assertEq(adapter.pendingSwitchTime(), 0, "pendingSwitchTime cleared");

        // Share value should be unchanged — depositors can still withdraw their full principal.
        uint256 aliceShares = adapter.totalShares(); // only alice + bob deposited
        // Check via getShareValue that total shares map to total assets.
        uint256 totalValue = adapter.getShareValue(address(usdc), aliceShares, 0);
        assertApproxEqAbs(totalValue, totalDeposited, 1, "share value preserved after migration");
    }

    // =========================================================================
    // 7. test_executeStrategySwitch_slippageGuard
    //    If the new strategy receives fewer tokens than the slippage floor
    //    (MAX_MIGRATION_LOSS_BPS), revert with SlippageTooHigh. The cap was
    //    tightened from 100 → 50 bps on 2026-04-28; this test reads the
    //    constant rather than hardcoding so future tightening doesn't break it.
    // =========================================================================

    function test_executeStrategySwitch_slippageGuard() public {
        _deposit(alice, DEP_ALICE);

        // Deploy a strategy that deliberately loses 2% on every withdrawal —
        // 4× the current cap (so the guard fires regardless of small cap
        // changes within the 1-50 bps band).
        BadSlippageStrategy badNewStrategy = new BadSlippageStrategy(address(usdc), 200);

        // We need the adapter to migrate TO badNewStrategy, meaning the OLD strategy
        // must be the lossy one. Rebuild the adapter with badNewStrategy as initial.
        vm.prank(owner);
        PVAutoYieldAdapter adapter2 = new PVAutoYieldAdapter(
            address(usdc),
            address(badNewStrategy),
            owner
        );

        // Fund badNewStrategy directly so there's something to migrate FROM.
        usdc.mint(address(badNewStrategy), DEP_ALICE);
        badNewStrategy._balance(); // just access to confirm state
        // Manually set balance by depositing through adapter2.
        usdc.mint(alice, DEP_ALICE);
        vm.startPrank(alice);
        usdc.approve(address(adapter2), DEP_ALICE);
        adapter2.deposit(address(usdc), DEP_ALICE, 0);
        vm.stopPrank();

        // Now queue a switch to a normal new strategy — the withdrawal from
        // badNewStrategy (which loses 2%) will trip the slippage guard.
        MockStrategy goodNewStrategy = new MockStrategy(address(usdc));

        vm.prank(owner);
        adapter2.queueStrategySwitch(address(goodNewStrategy));
        vm.warp(block.timestamp + adapter2.switchDelay() + 1);

        uint256 cap = adapter2.MAX_MIGRATION_LOSS_BPS();
        vm.expectRevert(
            abi.encodeWithSelector(
                PVAutoYieldAdapter.SlippageTooHigh.selector,
                // minReceived = DEP_ALICE * (10_000 - cap) / 10_000
                DEP_ALICE - (DEP_ALICE * cap / 10_000),
                // actual = DEP_ALICE * 98% (BadSlippageStrategy loses 200 bps)
                DEP_ALICE - (DEP_ALICE * 200 / 10_000)
            )
        );
        adapter2.executeStrategySwitch();
    }

    // =========================================================================
    // 8. test_cancelStrategySwitch
    //    Owner cancels a queued switch — pending state must be cleared.
    // =========================================================================

    function test_cancelStrategySwitch() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));

        vm.startPrank(owner);
        adapter.queueStrategySwitch(address(newStrategy));

        vm.expectEmit(true, false, false, false);
        emit StrategySwitchCancelled(address(newStrategy));

        adapter.cancelStrategySwitch();
        vm.stopPrank();

        assertEq(address(adapter.pendingStrategy()), address(0), "pendingStrategy cleared");
        assertEq(adapter.pendingSwitchTime(), 0, "pendingSwitchTime cleared");
        // activeStrategy unchanged.
        assertEq(address(adapter.activeStrategy()), address(strategy), "activeStrategy unchanged");
    }

    function test_cancelStrategySwitch_noPending_reverts() public {
        vm.prank(owner);
        vm.expectRevert(PVAutoYieldAdapter.NoPendingSwitch.selector);
        adapter.cancelStrategySwitch();
    }

    function test_cancelStrategySwitch_onlyOwner() public {
        MockStrategy newStrategy = new MockStrategy(address(usdc));
        vm.prank(owner);
        adapter.queueStrategySwitch(address(newStrategy));

        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.cancelStrategySwitch();
    }

    // =========================================================================
    // 9. test_harvestAndReinvest
    //    After yield is harvested from the strategy and sits idle in the adapter,
    //    harvestAndReinvest should re-deposit it so totalAssets grows correctly.
    // =========================================================================

    function test_harvestAndReinvest() public {
        MockHarvestStrategy harvestStrat = new MockHarvestStrategy(address(usdc));

        vm.prank(owner);
        PVAutoYieldAdapter adapter2 = new PVAutoYieldAdapter(
            address(usdc),
            address(harvestStrat),
            owner
        );

        uint256 depositAmount = 1_000e6;
        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(adapter2), depositAmount);
        adapter2.deposit(address(usdc), depositAmount, 0);
        vm.stopPrank();

        uint256 yieldAmount = 50e6;
        harvestStrat.simulateYield(yieldAmount);

        // Before harvest: yield is inside the strategy's balance.
        uint256 totalBefore = adapter2.getTotalDeposited(address(usdc), 0);
        assertEq(totalBefore, depositAmount + yieldAmount, "total includes yield before harvest");

        // harvestAndReinvest: strategy's harvestYield() sends tokens to adapter,
        // adapter immediately re-deposits them into the strategy.
        vm.expectEmit(false, false, false, true);
        emit Harvested(yieldAmount);

        uint256 harvested = adapter2.harvestAndReinvest();
        assertEq(harvested, yieldAmount, "harvested amount matches yield");

        // Adapter should hold no idle tokens (all reinvested).
        assertEq(usdc.balanceOf(address(adapter2)), 0, "no idle tokens after reinvest");

        // Strategy balance should be back to total (principal + yield reinvested).
        assertEq(harvestStrat._balance(), depositAmount + yieldAmount, "strategy has all assets");

        // Total deposited unchanged after reinvestment.
        assertEq(adapter2.getTotalDeposited(address(usdc), 0), depositAmount + yieldAmount,
            "totalDeposited unchanged");
    }

    function test_harvest_emitsAndReturns() public {
        MockHarvestStrategy harvestStrat = new MockHarvestStrategy(address(usdc));

        vm.prank(owner);
        PVAutoYieldAdapter adapter2 = new PVAutoYieldAdapter(
            address(usdc),
            address(harvestStrat),
            owner
        );

        uint256 depositAmount = 500e6;
        usdc.mint(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(adapter2), depositAmount);
        adapter2.deposit(address(usdc), depositAmount, 0);
        vm.stopPrank();

        uint256 yieldAmount = 30e6;
        harvestStrat.simulateYield(yieldAmount);

        vm.expectEmit(false, false, false, true);
        emit Harvested(yieldAmount);

        uint256 harvested = adapter2.harvest();
        assertEq(harvested, yieldAmount, "harvest returns yield amount");

        // After harvest without reinvest, tokens sit idle in adapter.
        assertEq(usdc.balanceOf(address(adapter2)), yieldAmount, "adapter holds harvested tokens");
    }

    // =========================================================================
    // 10. test_multipleVaultsSameAdapter
    //     Simulate two ProbabilityVault-like contracts sharing one adapter.
    //     Each "vault" deposits independently, yield accrues, and each redeems
    //     its exact proportional share.
    // =========================================================================

    function test_multipleVaultsSameAdapter() public {
        // Simulate two "PV contracts" as simple EOAs (alice = PV1, bob = PV2).
        // Each deposits independently through the IYieldVault interface.

        uint256 pv1Deposit = 3_000e6;
        uint256 pv2Deposit = 1_000e6;
        uint256 yieldAmount = 400e6; // 10% on combined 4,000

        usdc.mint(alice, pv1Deposit);
        usdc.mint(bob,   pv2Deposit);

        // PV1 deposits first.
        uint256 pv1Shares = _deposit(alice, pv1Deposit);
        // PV2 deposits second.
        uint256 pv2Shares = _deposit(bob,   pv2Deposit);

        // Yield accrues equally across the combined pool.
        strategy.simulateYield(yieldAmount);

        uint256 totalPool = pv1Deposit + pv2Deposit + yieldAmount;

        // PV1 owns 3/4 of deposits → should receive ~3/4 of total pool.
        uint256 pv1Expected = (totalPool * pv1Deposit) / (pv1Deposit + pv2Deposit);
        // PV2 owns 1/4.
        uint256 pv2Expected = totalPool - pv1Expected;

        uint256 pv1Received = _withdraw(alice, pv1Shares);
        uint256 pv2Received = _withdraw(bob,   pv2Shares);

        assertApproxEqAbs(pv1Received, pv1Expected, 2, "PV1 proportional payout");
        assertApproxEqAbs(pv2Received, pv2Expected, 2, "PV2 proportional payout");

        // Combined receipts equal total pool (virtual-offset rounding ≤ 2 wei).
        assertApproxEqAbs(pv1Received + pv2Received, totalPool, 2,
            "combined receipts equal total pool");
    }

    // =========================================================================
    // 11. test_wrongToken_reverts
    //     Depositing or withdrawing with a token other than depositToken reverts.
    // =========================================================================

    function test_wrongToken_reverts_onDeposit() public {
        MockERC20 wrongToken = new MockERC20("DAI", "DAI", 18);
        wrongToken.mint(alice, 1_000e18);

        vm.startPrank(alice);
        wrongToken.approve(address(adapter), 1_000e18);
        vm.expectRevert(PVAutoYieldAdapter.WrongToken.selector);
        adapter.deposit(address(wrongToken), 1_000e18, 0);
        vm.stopPrank();
    }

    function test_wrongToken_reverts_onWithdraw() public {
        uint256 shares = _deposit(alice, DEP_ALICE);

        MockERC20 wrongToken = new MockERC20("DAI", "DAI", 18);

        vm.prank(alice);
        vm.expectRevert(PVAutoYieldAdapter.WrongToken.selector);
        adapter.withdraw(address(wrongToken), shares, 0, alice);
    }

    function test_wrongToken_getShareValue_returnsZero() public {
        uint256 shares = _deposit(alice, DEP_ALICE);

        MockERC20 wrongToken = new MockERC20("DAI", "DAI", 18);
        uint256 value = adapter.getShareValue(address(wrongToken), shares, 0);
        assertEq(value, 0, "wrong token returns 0 share value");
    }

    function test_wrongToken_getTotalDeposited_returnsZero() public {
        _deposit(alice, DEP_ALICE);

        MockERC20 wrongToken = new MockERC20("DAI", "DAI", 18);
        uint256 total = adapter.getTotalDeposited(address(wrongToken), 0);
        assertEq(total, 0, "wrong token returns 0 total deposited");
    }

    // =========================================================================
    // 12. test_setSwitchDelay_outOfRange_reverts
    //     setSwitchDelay reverts when delay < 1 hour or > 7 days.
    // =========================================================================

    function test_setSwitchDelay_tooLow_reverts() public {
        vm.prank(owner);
        vm.expectRevert("PVAdapter: delay out of range");
        adapter.setSwitchDelay(1 hours - 1);
    }

    function test_setSwitchDelay_tooHigh_reverts() public {
        vm.prank(owner);
        vm.expectRevert("PVAdapter: delay out of range");
        adapter.setSwitchDelay(7 days + 1);
    }

    function test_setSwitchDelay_boundaries_succeed() public {
        vm.startPrank(owner);

        // Exactly 1 hour — minimum boundary.
        vm.expectEmit(false, false, false, true);
        emit SwitchDelayUpdated(adapter.switchDelay(), 1 hours);
        adapter.setSwitchDelay(1 hours);
        assertEq(adapter.switchDelay(), 1 hours);

        // Exactly 7 days — maximum boundary.
        vm.expectEmit(false, false, false, true);
        emit SwitchDelayUpdated(1 hours, 7 days);
        adapter.setSwitchDelay(7 days);
        assertEq(adapter.switchDelay(), 7 days);

        vm.stopPrank();
    }

    function test_setSwitchDelay_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.setSwitchDelay(2 hours);
    }

    // =========================================================================
    // Additional: constructor guard tests
    // =========================================================================

    function test_constructor_zeroToken_reverts() public {
        MockStrategy s = new MockStrategy(address(usdc));
        vm.expectRevert(PVAutoYieldAdapter.ZeroAddress.selector);
        new PVAutoYieldAdapter(address(0), address(s), owner);
    }

    function test_constructor_zeroStrategy_reverts() public {
        vm.expectRevert(PVAutoYieldAdapter.ZeroAddress.selector);
        new PVAutoYieldAdapter(address(usdc), address(0), owner);
    }

    function test_constructor_ownerTransferredCorrectly() public {
        vm.prank(nobody);
        PVAutoYieldAdapter a = new PVAutoYieldAdapter(
            address(usdc),
            address(strategy),
            owner  // explicit owner != msg.sender
        );
        assertEq(a.owner(), owner, "ownership transferred to provided owner");
    }

    function test_constructor_ownerIsDeployer_whenZeroOwnerArg() public {
        vm.prank(nobody);
        PVAutoYieldAdapter a = new PVAutoYieldAdapter(
            address(usdc),
            address(strategy),
            address(0) // zero = keep msg.sender as owner
        );
        assertEq(a.owner(), nobody, "owner defaults to deployer");
    }

    // =========================================================================
    // Additional: view helpers
    // =========================================================================

    function test_getCurrentAPY() public {
        assertEq(adapter.getCurrentAPY(), 300, "APY from MockStrategy");
    }

    function test_activeStrategyName() public {
        assertEq(adapter.activeStrategyName(), "MockStrategy", "strategy name");
    }

    function test_isStrategyActive_alwaysTrue() public {
        assertTrue(adapter.isStrategyActive(0),   "strategy 0 active");
        assertTrue(adapter.isStrategyActive(999), "strategy 999 active (any id)");
    }

    function test_setTrustedDepositor_noOp() public {
        // Should not revert (compatibility shim).
        adapter.setTrustedDepositor(alice, true);
        adapter.setTrustedDepositor(alice, false);
    }

    // =========================================================================
    // Additional: zero-amount guards
    // =========================================================================

    function test_deposit_zeroAmount_reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(adapter), 1);
        vm.expectRevert(PVAutoYieldAdapter.ZeroAmount.selector);
        adapter.deposit(address(usdc), 0, 0);
        vm.stopPrank();
    }

    function test_withdraw_zeroShares_reverts() public {
        _deposit(alice, DEP_ALICE);
        vm.prank(alice);
        vm.expectRevert(PVAutoYieldAdapter.ZeroAmount.selector);
        adapter.withdraw(address(usdc), 0, 0, alice);
    }

    // =========================================================================
    // Additional: pause stubs (owner-gated, no state change in this adapter)
    // =========================================================================

    function test_pause_onlyOwnerOrGuardian() public {
        // Post-2026-04-28 dual-key pause: callable by owner OR configured guardian.
        // A bystander still gets a custom revert.
        vm.prank(nobody);
        vm.expectRevert(bytes("PVAdapter: not authorized"));
        adapter.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.unpause();
    }

    // =========================================================================
    // Additional: getShareValue and getTotalDeposited consistency
    // =========================================================================

    function test_getShareValue_matchesWithdrawAmount() public {
        uint256 shares = _deposit(alice, DEP_ALICE);

        // Simulate yield
        strategy.simulateYield(100e6);

        uint256 shareValue = adapter.getShareValue(address(usdc), shares, 0);
        uint256 withdrawAmount = _withdraw(alice, shares);

        // getShareValue (a view) and actual withdrawal should agree within rounding.
        assertApproxEqAbs(shareValue, withdrawAmount, 1, "getShareValue matches actual withdrawal");
    }

    function test_getTotalDeposited_reflectsStrategyValue() public {
        _deposit(alice, DEP_ALICE);
        assertEq(adapter.getTotalDeposited(address(usdc), 0), DEP_ALICE,
            "getTotalDeposited matches deposit");

        strategy.simulateYield(50e6);
        assertEq(adapter.getTotalDeposited(address(usdc), 0), DEP_ALICE + 50e6,
            "getTotalDeposited includes yield");
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_depositWithdraw_principalReturned(uint256 amount) public {
        amount = bound(amount, 1e6, INITIAL_BALANCE);
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(adapter), amount);
        uint256 shares = adapter.deposit(address(usdc), amount, 0);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, shares);
        uint256 received = usdc.balanceOf(alice) - before;

        // Virtual-offset rounding can cause up to 1 wei loss — acceptable.
        assertApproxEqAbs(received, amount, 1, "principal returned within 1 wei");
    }

    function testFuzz_yieldNeverHarmsDepositor(uint256 amount, uint256 yield_) public {
        amount = bound(amount, 1e6, INITIAL_BALANCE);
        yield_ = bound(yield_, 0, 100_000e6);

        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(adapter), amount);
        uint256 shares = adapter.deposit(address(usdc), amount, 0);
        vm.stopPrank();

        strategy.simulateYield(yield_);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, shares);
        uint256 received = usdc.balanceOf(alice) - before;

        // Depositor should NEVER receive less than deposited (yield never negative).
        assertGe(received + 1, amount, "depositor never loses principal (within 1 wei rounding)");
    }

    // =========================================================================
    // Security: test_unauthorized_withdraw_reverts (Finding 1 regression test)
    //   An address that deposited no shares must not be able to steal funds from
    //   depositors. Before the fix, withdraw() had no per-caller check so any
    //   address could drain the entire pool.
    // =========================================================================

    function test_unauthorized_withdraw_reverts() public {
        uint256 aliceShares = _deposit(alice, DEP_ALICE);
        _deposit(bob, DEP_BOB);

        // nobody holds 0 userShares — any attempt to withdraw must revert.
        vm.prank(nobody);
        vm.expectRevert(PVAutoYieldAdapter.InsufficientShares.selector);
        adapter.withdraw(address(usdc), aliceShares, 0, nobody);
    }

    function test_drain_totalShares_reverts() public {
        _deposit(alice, DEP_ALICE);
        _deposit(bob, DEP_BOB);
        uint256 total = adapter.totalShares();

        // Attacker tries to redeem the entire pool's shares in one call.
        vm.prank(nobody);
        vm.expectRevert(PVAutoYieldAdapter.InsufficientShares.selector);
        adapter.withdraw(address(usdc), total, 0, nobody);

        // Funds must still be intact.
        assertEq(adapter.totalShares(), total, "totalShares unchanged after failed drain");
    }

    function test_userShares_trackedPerCaller() public {
        uint256 sharesAlice = _deposit(alice, DEP_ALICE);
        uint256 sharesBob   = _deposit(bob,   DEP_BOB);

        assertEq(adapter.userShares(alice),  sharesAlice, "alice userShares match");
        assertEq(adapter.userShares(bob),    sharesBob,   "bob userShares match");
        assertEq(adapter.userShares(nobody), 0,           "nobody has no shares");

        // After alice withdraws, only her shares are reduced.
        _withdraw(alice, sharesAlice);
        assertEq(adapter.userShares(alice), 0,          "alice shares cleared after withdraw");
        assertEq(adapter.userShares(bob),   sharesBob,  "bob shares unaffected");
    }

    function testFuzz_switchDelay_boundaries(uint256 delay) public {
        // Valid range: [1 hours, 7 days]
        delay = bound(delay, 1 hours, 7 days);
        vm.prank(owner);
        adapter.setSwitchDelay(delay);
        assertEq(adapter.switchDelay(), delay);
    }

    function testFuzz_SharesRoundtrip(uint128 assets) external {
        // Bound to reasonable range: at least 1 USDC, at most 1 billion USDC
        uint256 amount = bound(uint256(assets), 1e6, 1e15);

        deal(address(usdc), address(this), amount);
        usdc.approve(address(adapter), amount);

        uint256 sharesBefore = adapter.totalShares();
        uint256 shares = adapter.deposit(address(usdc), amount, 0);
        assertGt(shares, 0, "Shares must be > 0");

        // Roundtrip invariant: redeeming shares must give back <= deposited amount
        // (rounding always favors the vault, never the depositor)
        uint256 redeemed = adapter.withdraw(address(usdc), shares, 0, address(this));
        assertLe(redeemed, amount, "Roundtrip must not give back more than deposited");

        // Shares should return to pre-deposit level
        assertEq(adapter.totalShares(), sharesBefore, "Shares must return to baseline");
    }
}
