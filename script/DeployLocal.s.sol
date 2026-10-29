// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/DataRegistry.sol";
import "../src/IdentityRegistry.sol";
import "../src/ReputationRegistry.sol";
import "../src/YieldVault.sol";
import "../src/RandomnessManager.sol";
import "../src/ContestV2.sol";
import "../src/ContestFactoryV2.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockVRFCoordinator.sol";

/**
 * @title DeployLocal
 * @notice Deployment script for local Anvil testing
 * @dev Run with: forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
 */
contract DeployLocal is Script {
    // Deployment addresses
    DataRegistry public dataRegistry;
    IdentityRegistry public identityRegistry;
    ReputationRegistry public reputationRegistry;
    YieldVault public yieldVault;
    RandomnessManager public randomnessManager;
    ContestV2 public contestImplementation;
    ContestFactoryV2 public factory;
    MockERC20 public testUSDC;
    MockVRFCoordinator public mockVRF;

    function run() external {
        // DEV-ONLY guard (audit W12): this script uses MockVRF, mock USDC, and a
        // hardcoded Anvil private key. Refuse to broadcast on Base mainnet.
        require(block.chainid != 8453, "DeployLocal: dev script, refusing to run on Base mainnet");
        require(block.chainid != 1,    "DeployLocal: dev script, refusing to run on Ethereum mainnet");

        // Use Anvil's first default account
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== MindYield Local Deployment ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock VRF Coordinator
        mockVRF = new MockVRFCoordinator();
        console.log("1. MockVRFCoordinator deployed at:", address(mockVRF));

        // 2. Deploy Test USDC Token
        testUSDC = new MockERC20("Test USDC", "tUSDC", 6);
        console.log("2. TestUSDC deployed at:", address(testUSDC));

        // Mint test tokens to deployer (10 million USDC)
        testUSDC.mint(deployer, 10_000_000 * 10 ** 6);
        console.log("   - Minted 10M tUSDC to deployer");

        // 3. Deploy Data Registry (deployer is initial registrar, updated to factory below)
        dataRegistry = new DataRegistry(deployer);
        console.log("3. DataRegistry deployed at:", address(dataRegistry));

        // 4. Deploy Identity Registry
        identityRegistry = new IdentityRegistry();
        console.log("4. IdentityRegistry deployed at:", address(identityRegistry));

        // 5. Deploy Reputation Registry
        reputationRegistry = new ReputationRegistry();
        console.log("5. ReputationRegistry deployed at:", address(reputationRegistry));

        // 6. Deploy Yield Vault
        yieldVault = new YieldVault();
        console.log("6. YieldVault deployed at:", address(yieldVault));

        // Add default strategy (simple hold - no external protocol)
        uint256 holdStrategyId = yieldVault.addStrategy(address(0));
        console.log("   - Added hold strategy with ID:", holdStrategyId);

        // 7. Deploy Randomness Manager with mock VRF
        randomnessManager = new RandomnessManager(
            address(mockVRF),
            bytes32(0), // Key hash doesn't matter for mock
            0 // Subscription ID doesn't matter for mock
        );
        console.log("7. RandomnessManager deployed at:", address(randomnessManager));

        // 8. Deploy ContestV2 implementation + ContestFactoryV2
        contestImplementation = new ContestV2();
        console.log("8a. ContestV2 implementation deployed at:", address(contestImplementation));

        factory = new ContestFactoryV2(
            address(contestImplementation),
            address(yieldVault),
            address(identityRegistry),
            address(randomnessManager),
            deployer // Treasury/feeRecipient is deployer for local testing
        );
        console.log("8b. ContestFactoryV2 deployed at:", address(factory));

        // 9. Configure permissions - factory must be authorized so it can register
        //    each newly created contest as an allowed requester
        randomnessManager.setAuthorizedFactory(address(factory), true);
        dataRegistry.setAuthorizedRegistrar(address(factory));
        console.log("9. Configured permissions (factory authorized)");

        // 10. Mint tokens to test accounts (Anvil default accounts)
        address[9] memory testAccounts = [
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,
            0x976EA74026E726554dB657fA54763abd0C3a0aa9,
            0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,
            0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,
            0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
        ];

        for (uint256 i = 0; i < testAccounts.length; i++) {
            testUSDC.mint(testAccounts[i], 1_000_000 * 10 ** 6);
        }
        console.log("10. Minted 1M tUSDC to 9 test accounts");

        vm.stopBroadcast();

        // Output deployment summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("");
        console.log("Add these to your .env file:");
        console.log("----------------------------------------");
        console.log("CHAIN_ID=31337");
        console.log("RPC_URL=http://localhost:8545");
        console.log("NEXT_PUBLIC_FACTORY_ADDRESS=", address(factory));
        console.log("NEXT_PUBLIC_USDC_ADDRESS=", address(testUSDC));
        console.log("DATA_REGISTRY=", address(dataRegistry));
        console.log("IDENTITY_REGISTRY=", address(identityRegistry));
        console.log("REPUTATION_REGISTRY=", address(reputationRegistry));
        console.log("YIELD_VAULT=", address(yieldVault));
        console.log("RANDOMNESS_MANAGER=", address(randomnessManager));
        console.log("MOCK_VRF_COORDINATOR=", address(mockVRF));
        console.log("----------------------------------------");
        console.log("");
        console.log("Local testing is ready!");
        console.log("Use Anvil account #0 private key for deployer transactions:");
        console.log("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
    }
}
