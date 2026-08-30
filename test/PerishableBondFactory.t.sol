// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/PerishableBond.sol";
import "src/PerishableBondFactory.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PerishableBondFactoryTest is Test {
    PerishableBondFactory factory;
    ERC20Mock usdc;

    address admin = makeAddr("admin");
    address defaultOracle = makeAddr("defaultOracle");
    address issuer = makeAddr("issuer");
    address cargoOwner = makeAddr("cargoOwner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new ERC20Mock();
        factory = new PerishableBondFactory(admin, defaultOracle);

        bytes32 issuerRole = factory.ISSUER_ROLE();
        vm.prank(admin);
        factory.grantRole(issuerRole, issuer);
    }

    function _params(address oracle) internal view returns (PerishableBond.BondParams memory) {
        return PerishableBond.BondParams({
            name: "Bond",
            symbol: "PB",
            issuer: address(0), // overridden by factory
            cargoOwner: cargoOwner,
            settlementToken: address(usdc),
            totalSupply: 1000e18,
            initialNAV: 100_000e18,
            decayRatePerSecondBpsE18: 0,
            safeTempCeiling: 8,
            breachDurationLimit: 2 hours,
            breachPenaltyBps: 2000,
            liquidationThresholdBps: 4000,
            maturityDeadline: block.timestamp + 10 days,
            oracle: oracle
        });
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(); // zero address require
        new PerishableBondFactory(address(0), defaultOracle);
    }

    function test_constructor_revertsOnZeroOracle() public {
        vm.expectRevert();
        new PerishableBondFactory(admin, address(0));
    }

    function test_createBond_onlyIssuerRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.createBond(_params(address(0)));
    }

    function test_createBond_overridesIssuerToSender() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params(address(0)));

        PerishableBond bond = PerishableBond(bondAddr);
        assertEq(bond.issuer(), issuer);
        assertTrue(bond.hasRole(bond.ISSUER_ROLE(), issuer));
    }

    function test_createBond_fallsBackToDefaultOracle() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params(address(0)));

        PerishableBond bond = PerishableBond(bondAddr);
        assertTrue(bond.hasRole(bond.ORACLE_ROLE(), defaultOracle));
    }

    function test_createBond_respectsExplicitOracle() public {
        address customOracle = makeAddr("customOracle");
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params(customOracle));

        PerishableBond bond = PerishableBond(bondAddr);
        assertTrue(bond.hasRole(bond.ORACLE_ROLE(), customOracle));
        assertFalse(bond.hasRole(bond.ORACLE_ROLE(), defaultOracle));
    }

    function test_createBond_registersInRegistry() public {
        vm.startPrank(issuer);
        address bond1 = factory.createBond(_params(address(0)));
        address bond2 = factory.createBond(_params(address(0)));
        vm.stopPrank();

        assertEq(factory.totalBonds(), 2);
        assertTrue(factory.isRegisteredBond(bond1));
        assertTrue(factory.isRegisteredBond(bond2));

        address[] memory issuerBonds = factory.getBondsByIssuer(issuer);
        assertEq(issuerBonds.length, 2);
        assertEq(issuerBonds[0], bond1);
        assertEq(issuerBonds[1], bond2);
    }

    function test_setDefaultOracle_onlyOracleAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.setDefaultOracle(makeAddr("newOracle"));
    }

    function test_setDefaultOracle_success() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(admin);
        factory.setDefaultOracle(newOracle);
        assertEq(factory.defaultOracle(), newOracle);
    }

    function test_setDefaultOracle_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert();
        factory.setDefaultOracle(address(0));
    }

    function test_getBondsPaginated() public {
        vm.startPrank(issuer);
        address bond1 = factory.createBond(_params(address(0)));
        address bond2 = factory.createBond(_params(address(0)));
        address bond3 = factory.createBond(_params(address(0)));
        vm.stopPrank();

        address[] memory page = factory.getBondsPaginated(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], bond2);
        assertEq(page[1], bond3);

        // offset past the end returns empty
        address[] memory empty = factory.getBondsPaginated(10, 2);
        assertEq(empty.length, 0);

        // sanity: matches bond1 too
        address[] memory fromStart = factory.getBondsPaginated(0, 1);
        assertEq(fromStart[0], bond1);
    }

    function testFuzz_getBondsPaginated_neverReverts(uint256 offset, uint256 limit) public {
        vm.prank(issuer);
        factory.createBond(_params(address(0)));

        offset = bound(offset, 0, 1000);
        limit = bound(limit, 0, 1000);
        factory.getBondsPaginated(offset, limit); // must not revert
    }
}
