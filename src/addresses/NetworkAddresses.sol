// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NetworkAddresses
 * @notice Protocol and token addresses for all supported networks.
 *
 * Used by DeployPlatformProducts.s.sol to deploy strategies against real protocols.
 *
 * Chain IDs:
 *   1       — Ethereum Mainnet
 *   8453    — Base Mainnet
 *   42161   — Arbitrum One
 *   84532   — Base Sepolia (testnet)
 *   11155111— Ethereum Sepolia (testnet)
 */
library NetworkAddresses {

    // ─── Base Mainnet (8453) ──────────────────────────────────────────────────

    address internal constant BASE_AAVE_POOL        = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant BASE_AAVE_DATA_PROV   = 0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A;
    address internal constant BASE_USDC             = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_AUSDC            = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant BASE_COMET_USDC       = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
    address internal constant BASE_METAMORPHO_USDC  = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;

    // ─── Base Sepolia (84532) ─────────────────────────────────────────────────

    address internal constant BASE_SEP_AAVE_POOL    = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
    address internal constant BASE_SEP_USDC         = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_SEP_AUSDC        = 0x96E32De4b1d6b112fAeE3975499A5Ba857c2a55c;
    // Compound V3 Comet (USDC market) on Base Sepolia
    address internal constant BASE_SEP_COMET_USDC   = 0x61490650abaa31393464c3F16E5309061Dd9b890;

    // ─── Chainlink VRF v2 (Base Sepolia 84532) ───────────────────────────────

    address internal constant BASE_SEP_VRF_COORDINATOR = 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE;
    bytes32 internal constant BASE_SEP_VRF_KEY_HASH    = 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71;
    address internal constant BASE_SEP_LINK_TOKEN      = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

    // ─── Chainlink VRF v2 (Base Mainnet 8453) ────────────────────────────────

    address internal constant BASE_VRF_COORDINATOR     = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    // 30 gwei gas lane (recommended for general use)
    bytes32 internal constant BASE_VRF_KEY_HASH        = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;
    address internal constant BASE_LINK_TOKEN          = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;

    // ─── Ethereum Mainnet (1) ─────────────────────────────────────────────────

    address internal constant ETH_AAVE_POOL         = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant ETH_AAVE_DATA_PROV    = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address internal constant ETH_USDC              = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_AUSDC             = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant ETH_COMP_V2_CUSDC     = 0x39AA39c021dfbaE8faC545936693aC917d5E7563;
    address internal constant ETH_COMET_USDC        = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address internal constant ETH_MORPHO_BLUE       = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // ─── Arbitrum One (42161) ─────────────────────────────────────────────────

    address internal constant ARB_AAVE_POOL         = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant ARB_AAVE_DATA_PROV    = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address internal constant ARB_USDC              = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_AUSDC             = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant ARB_COMET_USDC        = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    // ─── Lookup helpers ───────────────────────────────────────────────────────

    /// @notice Aave V3 Pool for the given chain ID (reverts if unsupported)
    function aavePool(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return BASE_AAVE_POOL;
        if (chainId == 1)     return ETH_AAVE_POOL;
        if (chainId == 42161) return ARB_AAVE_POOL;
        if (chainId == 84532) return BASE_SEP_AAVE_POOL;
        revert("NetworkAddresses: unsupported chain");
    }

    /// @notice Aave V3 PoolDataProvider for the given chain ID (0 if none)
    function aaveDataProvider(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return BASE_AAVE_DATA_PROV;
        if (chainId == 1)     return ETH_AAVE_DATA_PROV;
        if (chainId == 42161) return ARB_AAVE_DATA_PROV;
        return address(0); // testnet may not have data provider
    }

    /// @notice USDC address for the given chain ID
    function usdc(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return BASE_USDC;
        if (chainId == 1)     return ETH_USDC;
        if (chainId == 42161) return ARB_USDC;
        if (chainId == 84532) return BASE_SEP_USDC;
        revert("NetworkAddresses: unsupported chain");
    }

    /// @notice Aave aUSDC address for the given chain ID
    function aUsdc(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return BASE_AUSDC;
        if (chainId == 1)     return ETH_AUSDC;
        if (chainId == 42161) return ARB_AUSDC;
        if (chainId == 84532) return BASE_SEP_AUSDC;
        revert("NetworkAddresses: unsupported chain");
    }

    /// @notice Compound V3 Comet (USDC) for the given chain ID (address(0) if absent)
    function cometUsdc(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return BASE_COMET_USDC;
        if (chainId == 1)     return ETH_COMET_USDC;
        if (chainId == 42161) return ARB_COMET_USDC;
        if (chainId == 84532) return BASE_SEP_COMET_USDC;
        return address(0);
    }

    /// @notice Compound V2 cUSDC for the given chain ID (address(0) if absent)
    function cUsdcV2(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return ETH_COMP_V2_CUSDC;
        return address(0);
    }

    /// @notice MetaMorpho USDC vault for the given chain ID (address(0) if absent)
    function metaMorphoUsdc(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) return BASE_METAMORPHO_USDC;
        return address(0);
    }

    /// @notice Chainlink VRF v2 Coordinator for the given chain ID
    function vrfCoordinator(uint256 chainId) internal pure returns (address) {
        if (chainId == 84532) return BASE_SEP_VRF_COORDINATOR;
        if (chainId == 8453)  return BASE_VRF_COORDINATOR;
        // Local Anvil: use deployer as mock VRF coordinator (manualFulfill still works)
        if (chainId == 31337) return 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        revert("NetworkAddresses: no VRF coordinator for chain");
    }

    /// @notice Chainlink VRF v2 key hash for the given chain ID
    function vrfKeyHash(uint256 chainId) internal pure returns (bytes32) {
        if (chainId == 84532) return BASE_SEP_VRF_KEY_HASH;
        if (chainId == 8453)  return BASE_VRF_KEY_HASH;
        if (chainId == 31337) return BASE_SEP_VRF_KEY_HASH; // dummy for local
        revert("NetworkAddresses: no VRF key hash for chain");
    }

    /// @notice LINK token for the given chain ID (address(0) if absent)
    function linkToken(uint256 chainId) internal pure returns (address) {
        if (chainId == 84532) return BASE_SEP_LINK_TOKEN;
        if (chainId == 8453)  return BASE_LINK_TOKEN;
        return address(0);
    }
}
