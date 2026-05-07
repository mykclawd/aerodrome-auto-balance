// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AerodromeRebalancer} from "../src/AerodromeRebalancer.sol";

/// @notice Deploys the AerodromeRebalancer module against the Base mainnet WETH/cbBTC SlipStream
///         tick-spacing-10 pool.
///         The Safe address is read from the SAFE_ADDRESS env var. Pass the deployer key on the CLI
///         (`forge script ... --broadcast --verify --private-key <key>`); do not bake it into `.env`.
///         Optionally pass keepers to `run(address[])` or set KEEPER_ADDRESSES to allowlist keepers at
///         construction. After deploy, Safe owners must call `Safe.enableModule(<deployed module>)` and then
///         `module.setCurrentTokenId(<nft>)`.
contract DeployAerodromeRebalancer is Script {
    // Base mainnet addresses
    address internal constant POOL = 0x42d4a22CaD0F5a49681a5715cE994Af73A43B76b;
    address internal constant GAUGE = 0x61E0B10423a0009C3f83ab4313813d29437d0817;
    address internal constant NPM = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
    address internal constant SWAP_ROUTER = 0xcAF22ce31298CF2BF1D152862F80216478ad7c67;

    function run() external returns (AerodromeRebalancer module) {
        address[] memory defaultKeepers = new address[](0);
        return _run(vm.envOr("KEEPER_ADDRESSES", ",", defaultKeepers));
    }

    function run(address[] memory initialKeepers) external returns (AerodromeRebalancer module) {
        return _run(initialKeepers);
    }

    function _run(address[] memory initialKeepers) internal returns (AerodromeRebalancer module) {
        address safe = vm.envAddress("SAFE_ADDRESS");

        AerodromeRebalancer.ConstructorParams memory p = AerodromeRebalancer.ConstructorParams({
            safe: safe,
            pool: POOL,
            gauge: GAUGE,
            npm: NPM,
            swapRouter: SWAP_ROUTER,
            initialKeepers: initialKeepers,
            twapWindow: 600, // 10 min
            maxTickDeviation: 50, // ~0.5% spot vs TWAP
            maxSlippageBps: 50, // 0.5% on swap
            maxRebalanceLossBps: 100 // 1% total-value floor
        });

        vm.startBroadcast();
        module = new AerodromeRebalancer(p);
        vm.stopBroadcast();

        console2.log("AerodromeRebalancer deployed at:", address(module));
        console2.log("Safe:", safe);
        console2.log("Initial keeper count:", initialKeepers.length);
        for (uint256 i = 0; i < initialKeepers.length; ++i) {
            console2.log("Initial keeper:", initialKeepers[i]);
        }
        console2.log("Next steps for Safe owners:");
        console2.log("  1. Safe.enableModule(<this address>)");
        console2.log("  2. module.setCurrentTokenId(<position NFT id>)");
    }
}
