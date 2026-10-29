// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DataRegistry.sol";
import "../src/IdentityRegistry.sol";
import "../src/HumanVerificationRegistry.sol";
import "../src/oracles/OracleRegistry.sol";
import "../src/YieldVault.sol";
import "../src/RandomnessManager.sol";
import "../src/ContestV2.sol";
import "../src/ContestFactoryV2.sol";
import "../src/PlatformFeeConfig.sol";

/**
 * @title DeployScript — Phase 1.2 + 2.4 (foundation singletons + contest factory)
 *
 * @notice One-shot mainnet relaunch deploy. Replaces the previous incomplete
 *         Deploy.s.sol that (a) silently accepted missing VRF env vars and
 *         (b) left every contract owned by the deployer EOA, requiring ten
 *         manual transferOwnership calls afterwards. Both were footguns.
 *
 * Deploys (in order):
 *   1. DataRegistry, IdentityRegistry, HumanVerificationRegistry, OracleRegistry
 *      — Phase 1.2 registries
 *   2. YieldVault — Phase 1.2 (with default 0-address strategy)
 *   3. RandomnessManager — Phase 1.2 (VRF env vars are HARD-FAIL on mainnet)
 *   4. PlatformFeeConfig — Phase 1.2, master-enabled with 2% yield-only fees
 *   5. ContestV2 implementation + ContestFactoryV2 — Phase 2.4
 *
 * Wires (in same broadcast):
 *   - factory.setContestCreationFee(0)
 *   - randomnessManager.setAuthorizedFactory(factory, true)
 *   - dataRegistry.setAuthorizedRegistrar(factory)
 *   - YieldVault.addStrategy(0)  (no-op default)
 *
 * Decentralization handoff (in same broadcast, if env vars are set):
 *   - YieldVault.setGuardian(GUARDIAN_ADDRESS)
 *   - transferOwnership(TIMELOCK_ADDRESS) on every Ownable contract above
 *
 * Required env vars (hard-fail on missing for mainnet correctness):
 *   PRIVATE_KEY            — deployer private key
 *   TREASURY_ADDRESS       — fee recipient (PlatformFeeConfig + ContestFactoryV2)
 *   VRF_COORDINATOR        — Chainlink VRF V2.5 coordinator
 *   VRF_KEY_HASH           — VRF gas-lane key hash
 *   VRF_SUBSCRIPTION_ID    — funded VRF subscription
 *
 * Optional env vars (skipped on testnet / local; required for mainnet):
 *   TIMELOCK_ADDRESS       — TimelockController to receive ownership of every contract
 *   GUARDIAN_ADDRESS       — Guardian to wire on YieldVault (pause-only)
 *   SKIP_HANDOFF           — set "true" to keep deployer as owner (CI/local only)
 */
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        // Hard-fail VRF env: a zero coordinator silently breaks every random
        // contest/lottery downstream. Previous version used vm.envOr(...,
        // address(0)) which would deploy with no VRF wiring.
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        require(vrfCoordinator != address(0), "Deploy: VRF_COORDINATOR=0");
        require(keyHash != bytes32(0), "Deploy: VRF_KEY_HASH=0");
        require(subscriptionId != 0, "Deploy: VRF_SUBSCRIPTION_ID=0");

        // Handoff targets — optional. If both unset (or SKIP_HANDOFF=true), the
        // script ends with deployer = owner. Mainnet runbook requires both.
        address timelock = vm.envOr("TIMELOCK_ADDRESS", address(0));
        address guardian = vm.envOr("GUARDIAN_ADDRESS", address(0));
        bool skipHandoff = vm.envOr("SKIP_HANDOFF", false);

        vm.startBroadcast(deployerPrivateKey);

        // ── Phase 1.2 — Foundation registries ────────────────────────────────
        DataRegistry dataRegistry = new DataRegistry(deployer);
        IdentityRegistry identityRegistry = new IdentityRegistry();
        HumanVerificationRegistry humanVerification = new HumanVerificationRegistry();
        OracleRegistry oracleRegistry = new OracleRegistry();
        console.log("DataRegistry:               ", address(dataRegistry));
        console.log("IdentityRegistry:           ", address(identityRegistry));
        console.log("HumanVerificationRegistry:  ", address(humanVerification));
        console.log("OracleRegistry:             ", address(oracleRegistry));

        // ── Phase 1.2 — YieldVault (with default 0-address strategy) ─────────
        YieldVault yieldVault = new YieldVault();
        yieldVault.addStrategy(address(0));
        console.log("YieldVault:                 ", address(yieldVault));

        // ── Phase 1.2 — RandomnessManager (VRF) ──────────────────────────────
        RandomnessManager randomnessManager = new RandomnessManager(
            vrfCoordinator,
            keyHash,
            subscriptionId
        );
        console.log("RandomnessManager:          ", address(randomnessManager));

        // ── Phase 1.2 — PlatformFeeConfig (2% yield-only fees enabled) ───────
        PlatformFeeConfig feeConfig = new PlatformFeeConfig(treasury);
        feeConfig.setMasterEnabled(true);
        feeConfig.setContestYieldBps(200);     // 2% of contest yield
        feeConfig.setLotteryYieldBps(200);     // 2% of lottery yield
        feeConfig.setVaultPerformanceBps(200); // 2% of vault yield
        feeConfig.setContestCreationFeeUsdc(0);
        feeConfig.setVaultManagementBps(0);    // No AUM fee
        console.log("PlatformFeeConfig:          ", address(feeConfig));

        // ── Phase 2.4 — ContestV2 implementation + ContestFactoryV2 ──────────
        ContestV2 contestImplementation = new ContestV2();
        ContestFactoryV2 factory = new ContestFactoryV2(
            address(contestImplementation),
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            treasury
        );
        // Factory ships with feeEnabled=true and 200 bps yield fee. Creation
        // fee stays at 0 — we charge only on yield.
        factory.setContestCreationFee(0);
        console.log("ContestV2 (impl):           ", address(contestImplementation));
        console.log("ContestFactoryV2:           ", address(factory));

        // ── Wire factory permissions ─────────────────────────────────────────
        randomnessManager.setAuthorizedFactory(address(factory), true);
        dataRegistry.setAuthorizedRegistrar(address(factory));

        // ── Decentralization handoff ─────────────────────────────────────────
        // Wire guardian + transfer ownership atomically with the deploy. The
        // previous Deploy.s.sol left this as a manual ~10-step ritual; one
        // missed step = permanent EOA backdoor on a production contract.
        if (skipHandoff || timelock == address(0)) {
            console.log("");
            console.log("WARNING: skipping ownership handoff (TIMELOCK_ADDRESS unset");
            console.log("         or SKIP_HANDOFF=true). Deployer remains owner.");
            console.log("         For mainnet, set TIMELOCK_ADDRESS + GUARDIAN_ADDRESS");
            console.log("         and re-run.");
        } else {
            require(guardian != address(0), "Deploy: GUARDIAN_ADDRESS=0 with TIMELOCK set");

            // YieldVault is the only Phase-1.2 contract with a guardian role.
            yieldVault.setGuardian(guardian);
            console.log("YieldVault.guardian   set: ", guardian);

            // Transfer ownership of every Ownable contract deployed above.
            // OracleRegistry uses AccessControl; transferOwnership doesn't apply
            // in the OZ-Ownable sense. Granting DEFAULT_ADMIN to the timelock and
            // revoking from deployer is the equivalent handoff — handled below.
            dataRegistry.transferOwnership(timelock);
            identityRegistry.transferOwnership(timelock);
            humanVerification.transferOwnership(timelock);
            yieldVault.transferOwnership(timelock);
            randomnessManager.transferOwnership(timelock);
            feeConfig.transferOwnership(timelock);
            factory.transferOwnership(timelock);

            // OracleRegistry: AccessControl-style. Grant admin to timelock,
            // revoke from deployer (the last revoke must be the deployer's
            // own DEFAULT_ADMIN_ROLE; renounceRole is idempotent).
            bytes32 adminRole = oracleRegistry.DEFAULT_ADMIN_ROLE();
            oracleRegistry.grantRole(adminRole, timelock);
            oracleRegistry.renounceRole(adminRole, deployer);

            console.log("");
            console.log("Ownership handed to timelock for 7 contracts");
            console.log("OracleRegistry admin role moved to timelock");
        }

        vm.stopBroadcast();

        // ── Final summary ────────────────────────────────────────────────────
        console.log("");
        console.log("=== Deployment Summary (paste into .env files) ===");
        console.log("DATA_REGISTRY_ADDRESS=",          address(dataRegistry));
        console.log("IDENTITY_REGISTRY_ADDRESS=",      address(identityRegistry));
        console.log("HUMAN_VERIFICATION_ADDRESS=",     address(humanVerification));
        console.log("ORACLE_REGISTRY_ADDRESS=",        address(oracleRegistry));
        console.log("YIELD_VAULT_ADDRESS=",            address(yieldVault));
        console.log("RANDOMNESS_MANAGER_ADDRESS=",     address(randomnessManager));
        console.log("PLATFORM_FEE_CONFIG_ADDRESS=",    address(feeConfig));
        console.log("CONTEST_V2_IMPL_ADDRESS=",        address(contestImplementation));
        console.log("CONTEST_FACTORY_V2_ADDRESS=",     address(factory));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Add RandomnessManager as VRF subscription consumer:");
        console.log("     https://vrf.chain.link/ -> Add Consumer ->", address(randomnessManager));
        console.log("  2. Continue with Phase 1.3 (DeployAffiliateDistributor.s.sol)");
        console.log("     and Phase 2 (DeployPlatformProducts, DeployLotteryV3, etc.)");
        if (skipHandoff || timelock == address(0)) {
            console.log("  3. ACTION REQUIRED: set TIMELOCK_ADDRESS + GUARDIAN_ADDRESS");
            console.log("     in .env, then run handoff manually for each contract.");
        }
    }
}
