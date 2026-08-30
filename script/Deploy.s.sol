// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PerishableBondFactory.sol";
import "../src/IssuerReputationRegistry.sol";

/**
 * @title Deploy
 * @notice Deploys PerishableBondFactory and IssuerReputationRegistry.
 *         Individual PerishableBond instances are created afterward by
 *         calling `factory.createBond(...)` per shipment -- they are not
 *         deployed here.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast --verify
 *
 * Required env vars:
 *   ADMIN_ADDRESS      - receives DEFAULT_ADMIN_ROLE / ORACLE_ADMIN_ROLE on the factory
 *   DEFAULT_ORACLE      - default ORACLE_ROLE grantee for new bonds
 */
contract Deploy is Script {
    function run() external returns (PerishableBondFactory factory, IssuerReputationRegistry registry) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address defaultOracle = vm.envAddress("DEFAULT_ORACLE");

        vm.startBroadcast();

        factory = new PerishableBondFactory(admin, defaultOracle);
        registry = new IssuerReputationRegistry(address(factory));

        vm.stopBroadcast();

        console2.log("PerishableBondFactory deployed:", address(factory));
        console2.log("IssuerReputationRegistry deployed:", address(registry));
    }
}
