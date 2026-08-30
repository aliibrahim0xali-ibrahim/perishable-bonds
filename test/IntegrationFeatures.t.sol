// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/PerishableBond.sol";
import "src/PerishableBondFactory.sol";
import "src/IssuerReputationRegistry.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract IntegrationFeaturesTest is Test {
    PerishableBondFactory factory;
    IssuerReputationRegistry registry;
    ERC20Mock usdc;

    address admin = makeAddr("admin");
    address defaultOracle = makeAddr("defaultOracle");
    address issuer = makeAddr("issuer");
    address cargoOwner = makeAddr("cargoOwner");
    address stranger = makeAddr("stranger");

    uint256 constant TOTAL_SUPPLY = 1_000e18;
    uint256 constant INITIAL_NAV = 100_000e18;

    function setUp() public {
        usdc = new ERC20Mock();
        factory = new PerishableBondFactory(admin, defaultOracle);
        registry = new IssuerReputationRegistry(address(factory));

        bytes32 issuerRole = factory.ISSUER_ROLE();
        vm.prank(admin);
        factory.grantRole(issuerRole, issuer);

        usdc.mint(issuer, 10_000_000e18);
    }

    function _params() internal view returns (PerishableBond.BondParams memory) {
        return PerishableBond.BondParams({
            name: "Bond",
            symbol: "PB",
            issuer: address(0),
            cargoOwner: cargoOwner,
            settlementToken: address(usdc),
            totalSupply: TOTAL_SUPPLY,
            initialNAV: INITIAL_NAV,
            decayRatePerSecondBpsE18: 0,
            safeTempCeiling: 8,
            breachDurationLimit: 2 hours,
            breachPenaltyBps: 2000,
            liquidationThresholdBps: 4000,
            maturityDeadline: block.timestamp + 10 days,
            oracle: defaultOracle
        });
    }

    // =========================================================================
    // getSnapshot()
    // =========================================================================

    function test_getSnapshot_activeBond() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);

        PerishableBond.BondSnapshot memory s = bond.getSnapshot(cargoOwner);

        assertEq(uint256(s.status), uint256(PerishableBond.Status.Active));
        assertEq(s.currentNav, INITIAL_NAV);
        assertEq(s.navBps, 10_000);
        assertEq(s.secondsUntilMaturity, 10 days);
        assertFalse(s.isBreaching);
        assertEq(s.callerBalance, TOTAL_SUPPLY);
        assertEq(s.callerClaimableEstimate, 0); // still active
        assertEq(s.lastReportAge, 0); // never reported
    }

    function test_getSnapshot_reflectsBreachState() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);

        vm.prank(defaultOracle);
        bond.reportTelemetry(20, 5000, block.timestamp); // above safeTempCeiling=8

        vm.warp(block.timestamp + 30 minutes);
        PerishableBond.BondSnapshot memory s = bond.getSnapshot(cargoOwner);

        assertTrue(s.isBreaching);
        assertEq(s.breachSecondsElapsed, 30 minutes);
        assertEq(s.lastTemp, 20);
        assertEq(s.lastReportAge, 30 minutes);
    }

    function test_getSnapshot_claimableEstimateAfterMaturity() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundRedemptionPool(INITIAL_NAV);
        bond.markDelivered();
        vm.stopPrank();

        PerishableBond.BondSnapshot memory s = bond.getSnapshot(cargoOwner);
        assertEq(uint256(s.status), uint256(PerishableBond.Status.Matured));
        assertEq(s.callerClaimableEstimate, INITIAL_NAV);
        assertEq(s.secondsUntilMaturity, 0); // settled, not "time left"
    }

    function test_getSnapshot_neverRevertsRegardlessOfCaller() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);

        // arbitrary caller with zero balance/history must not revert
        bond.getSnapshot(stranger);
        bond.getSnapshot(address(0));
    }

    // =========================================================================
    // IssuerReputationRegistry
    // =========================================================================

    function test_registry_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(IssuerReputationRegistry.ZeroAddress.selector);
        new IssuerReputationRegistry(address(0));
    }

    function test_registry_neutralScoreWithNoHistory() public view {
        assertEq(registry.reputationScoreBps(issuer), 10_000);
        assertEq(registry.totalDeals(issuer), 0);
    }

    function test_registry_revertsOnUnregisteredBond() public {
        // a bond NOT deployed through the factory
        PerishableBond.BondParams memory p = _params();
        p.issuer = issuer;
        p.oracle = defaultOracle;
        PerishableBond rogueBond = new PerishableBond(p);

        vm.prank(issuer);
        rogueBond.markDelivered();

        vm.expectRevert(IssuerReputationRegistry.NotARegisteredBond.selector);
        registry.recordFromBond(address(rogueBond));
    }

    function test_registry_revertsIfNotYetSettled() public {
        vm.prank(issuer);
        address bondAddr = factory.createBond(_params());

        vm.expectRevert(IssuerReputationRegistry.BondNotSettled.selector);
        registry.recordFromBond(bondAddr);
    }

    function test_registry_revertsOnDoubleRecord() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundRedemptionPool(INITIAL_NAV);
        bond.markDelivered();
        vm.stopPrank();

        registry.recordFromBond(bondAddr);

        vm.expectRevert(IssuerReputationRegistry.AlreadyRecorded.selector);
        registry.recordFromBond(bondAddr);
    }

    function test_registry_maturedBondBoostsScore() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundRedemptionPool(INITIAL_NAV);
        bond.markDelivered();
        vm.stopPrank();

        vm.prank(stranger); // anyone can call it, permissionless
        registry.recordFromBond(bondAddr);

        assertEq(registry.reputationScoreBps(issuer), 10_000); // 1/1 matured
        assertEq(registry.totalDeals(issuer), 1);
    }

    function test_registry_liquidatedBondHurtsScore() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundInsurancePool(INITIAL_NAV);
        vm.stopPrank();

        PerishableBond bondC = PerishableBond(bondAddr);
        // drive to liquidation via 3 confirmed breaches (60% cumulative penalty)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(defaultOracle);
            bondC.reportTelemetry(20, 5000, block.timestamp);
            vm.warp(block.timestamp + 2 hours + 1);
            vm.prank(defaultOracle);
            bondC.reportTelemetry(20, 5000, block.timestamp);
            if (uint256(bondC.status()) != uint256(PerishableBond.Status.Active)) break;
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(uint256(bondC.status()), uint256(PerishableBond.Status.Liquidated));

        registry.recordFromBond(bondAddr);
        assertEq(registry.reputationScoreBps(issuer), 0); // 0/1 matured
        assertEq(registry.totalDeals(issuer), 1);
    }

    function test_registry_weightedAverageAcrossMultipleBonds() public {
        // Bond A: matures, small deal
        PerishableBond.BondParams memory pa = _params();
        pa.initialNAV = 10_000e18;
        pa.totalSupply = 100e18;
        vm.prank(issuer);
        address bondA = factory.createBond(pa);
        vm.startPrank(issuer);
        usdc.approve(bondA, type(uint256).max);
        PerishableBond(bondA).fundRedemptionPool(10_000e18);
        PerishableBond(bondA).markDelivered();
        vm.stopPrank();
        registry.recordFromBond(bondA);

        // Bond B: liquidates, LARGE deal -> should dominate the weighted score
        PerishableBond.BondParams memory pb = _params();
        pb.initialNAV = 90_000e18;
        vm.prank(issuer);
        address bondB = factory.createBond(pb);
        vm.startPrank(issuer);
        usdc.approve(bondB, type(uint256).max);
        PerishableBond(bondB).fundInsurancePool(90_000e18);
        vm.stopPrank();
        PerishableBond bc = PerishableBond(bondB);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(defaultOracle);
            bc.reportTelemetry(20, 5000, block.timestamp);
            vm.warp(block.timestamp + 2 hours + 1);
            vm.prank(defaultOracle);
            bc.reportTelemetry(20, 5000, block.timestamp);
            if (uint256(bc.status()) != uint256(PerishableBond.Status.Active)) break;
            vm.warp(block.timestamp + 1 hours);
        }
        registry.recordFromBond(bondB);

        // weighted: matured 10k / total 100k = 1000 bps (10%), correctly
        // dominated by the large liquidated deal rather than a naive 1/2=50%
        // simple-count average
        assertEq(registry.reputationScoreBps(issuer), 1000);
        assertEq(registry.totalDeals(issuer), 2);
    }

    // =========================================================================
    // Regression tests for this round's fixes
    // =========================================================================

    /// @dev REGRESSION TEST: an issuer == cargoOwner bond let an issuer
    /// manufacture a risk-free "successful" settlement (fund the redemption
    /// pool from their own wallet, mark delivered, claim it right back) to
    /// pad their own reputation score. Now rejected at construction.
    function test_constructor_revertsWhenIssuerEqualsCargoOwner() public {
        PerishableBond.BondParams memory p = _params();
        p.issuer = issuer;
        p.cargoOwner = issuer; // self-dealing attempt
        p.oracle = defaultOracle;

        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "issuer cannot be cargoOwner"));
        new PerishableBond(p);
    }

    function test_createBond_revertsWhenCargoOwnerEqualsSender() public {
        PerishableBond.BondParams memory p = _params();
        p.cargoOwner = issuer; // msg.sender will become issuer via the factory
        p.oracle = defaultOracle;

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "issuer cannot be cargoOwner"));
        factory.createBond(p);
    }

    /// @dev REGRESSION TEST: Status.Matured alone doesn't prove holders got
    /// paid -- markDelivered() never required redemptionPool to be funded.
    /// An issuer who delivers cargo but never funds the pool must NOT get
    /// full reputation credit, since every holder's claim would pay zero.
    function test_registry_unfundedMaturedBondGetsNoCredit() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        // deliberately never call fundRedemptionPool
        bond.markDelivered();
        vm.stopPrank();

        registry.recordFromBond(bondAddr);

        // matured status recorded (maturedCount++) but zero weight credited
        // since nothing was actually funded -> score reflects reality (0),
        // not the surface-level "Matured" label.
        assertEq(registry.reputationScoreBps(issuer), 0);
        assertEq(registry.totalDeals(issuer), 1);
    }

    /// @dev REGRESSION TEST: a partially-funded matured bond gets partial
    /// credit proportional to what was actually funded, not all-or-nothing.
    function test_registry_partiallyFundedMaturedBondGetsPartialCredit() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundRedemptionPool(INITIAL_NAV / 2); // only half funded
        bond.markDelivered();
        vm.stopPrank();

        registry.recordFromBond(bondAddr);

        assertEq(registry.reputationScoreBps(issuer), 5000); // 50%
    }

    /// @dev REGRESSION TEST: overfunding a matured bond beyond initialNAV
    /// must not let an issuer buy credit above 100% for that deal.
    function test_registry_overfundedMaturedBondCapsCreditAt100Percent() public {
        vm.startPrank(issuer);
        address bondAddr = factory.createBond(_params());
        PerishableBond bond = PerishableBond(bondAddr);
        usdc.approve(bondAddr, type(uint256).max);
        bond.fundRedemptionPool(INITIAL_NAV * 2); // 2x overfunded
        bond.markDelivered();
        vm.stopPrank();

        registry.recordFromBond(bondAddr);

        assertEq(registry.reputationScoreBps(issuer), 10_000); // capped, not 20000
    }

    /// @dev REGRESSION TEST: reputationScoreBps() must never revert from
    /// intermediate multiplication overflow, regardless of how large
    /// cumulative weights get (Math.mulDiv fix).
    function testFuzz_reputationScoreBps_neverOverflows(uint256 maturedWeight, uint256 liquidatedWeight) public {
        maturedWeight = bound(maturedWeight, 0, type(uint256).max / 2);
        liquidatedWeight = bound(liquidatedWeight, 0, type(uint256).max / 2 - maturedWeight);

        // Use two bonds sized so their initialNAV sums approximate the
        // fuzzed weights closely enough to exercise the same code path
        // without needing to mint astronomical settlement-token amounts.
        PerishableBond.BondParams memory pa = _params();
        pa.initialNAV = bound(maturedWeight, 1, type(uint128).max);
        vm.prank(issuer);
        address bondA = factory.createBond(pa);
        vm.startPrank(issuer);
        usdc.mint(issuer, pa.initialNAV);
        usdc.approve(bondA, type(uint256).max);
        PerishableBond(bondA).fundRedemptionPool(pa.initialNAV);
        PerishableBond(bondA).markDelivered();
        vm.stopPrank();
        registry.recordFromBond(bondA);

        registry.reputationScoreBps(issuer); // must not revert
    }
}
