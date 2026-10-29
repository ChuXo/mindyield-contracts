// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/AffiliateDistributor.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployAffiliateDistributor
 * @notice Deploys the AffiliateDistributor contract for decentralized USDC claims.
 *
 * Usage:
 *   # Base Sepolia (testnet):
 *   DEPLOYER_PRIVATE_KEY=0x... \
 *   USDC_ADDRESS=0x... \
 *   AFFILIATE_GUARDIAN=0x... \
 *   forge script script/DeployAffiliateDistributor.s.sol \
 *     --broadcast --rpc-url $RPC_URL --verify
 *
 *   # Base mainnet:
 *   same but with mainnet USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
 *
 * Environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Deployer key (required)
 *   - USDC_ADDRESS: USDC token address (required)
 *   - AFFILIATE_GUARDIAN: Address that can emergency-pause (required).
 *                         For production: use a separate EOA or multisig from owner.
 *   - AFFILIATE_OWNER: Owner after deployment (optional). If not set, deployer is owner.
 *                      For production: transfer to a Gnosis Safe behind a timelock.
 *   - AFFILIATE_ROOT_POSTER: Address that receives ROOT_POSTER_ROLE at deploy
 *                      (optional). If not set, deployer is the initial poster.
 *                      For production: a backend hot wallet rotated regularly;
 *                      DEFAULT_ADMIN_ROLE (held by owner/timelock) controls
 *                      grant/revoke without invoking the 48h delay per cycle.
 *   - MAX_SINGLE_CLAIM_USDC: Per-claim cap in whole USDC (optional, default 50000).
 *   - RESCUE_DELAY_SECONDS: Timelock for distribution-token rescue (optional, default 7 days).
 */
contract DeployAffiliateDistributor is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address guardian = vm.envAddress("AFFILIATE_GUARDIAN");
        address targetOwner = vm.envOr("AFFILIATE_OWNER", address(0));
        address rootPoster = vm.envOr("AFFILIATE_ROOT_POSTER", deployer);

        // Defaults: 50,000 USDC per-claim cap, 7-day rescue delay.
        uint256 maxSingleClaimUsdc = vm.envOr("MAX_SINGLE_CLAIM_USDC", uint256(50_000));
        uint256 rescueDelay = vm.envOr("RESCUE_DELAY_SECONDS", uint256(7 days));

        // Convert whole USDC to 6-decimal raw.
        uint256 maxSingleClaim = maxSingleClaimUsdc * 1e6;

        console.log("=== DeployAffiliateDistributor ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Deployer:                ", deployer);
        console.log("USDC:                    ", usdcAddress);
        console.log("Guardian:                ", guardian);
        console.log("Target owner:            ", targetOwner == address(0) ? deployer : targetOwner);
        console.log("Initial root poster:     ", rootPoster);
        console.log("Max single claim (USDC): ", maxSingleClaimUsdc);
        console.log("Rescue delay (seconds):  ", rescueDelay);

        vm.startBroadcast(deployerKey);

        AffiliateDistributor distributor = new AffiliateDistributor(
            IERC20(usdcAddress),
            guardian,
            maxSingleClaim,
            rescueDelay,
            rootPoster
        );

        // Transfer ownership to the target owner (Ownable2Step — pending
        // accept). The owner controls `setRootPoster`, so after
        // `acceptOwnership()` it can rotate the poster allowlist directly
        // through its timelock queue.
        if (targetOwner != address(0) && targetOwner != deployer) {
            distributor.transferOwnership(targetOwner);
            console.log("Ownership transferred to (pending accept):", targetOwner);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("AffiliateDistributor:    ", address(distributor));
        console.log("");
        console.log("Next steps:");
        console.log("1. Set NEXT_PUBLIC_AFFILIATE_DISTRIBUTOR in env");
        console.log("2. Target owner calls `acceptOwnership()` (Ownable2Step)");
        console.log("3. (If rootPoster == deployer) target owner queues");
        console.log("   `setRootPoster(<deployer>, false)` through timelock");
        console.log("   and `setRootPoster(<backend hot wallet>, true)` to");
        console.log("   activate the production poster.");
        console.log("4. Run off-chain worker to post first merkle root");
        console.log("5. Fund the contract with USDC via .fund() or direct transfer");
    }
}
