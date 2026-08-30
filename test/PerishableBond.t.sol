// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/PerishableBond.sol";
import "src/PerishableBondFactory.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev A settlement token that reenters fundInsurancePool() during
/// transferFrom(), used to prove the CEI-ordering fix actually blocks
/// the reentrancy it targets.
contract ReentrantToken is ERC20Mock {
    PerishableBond public target;
    bool public attack;

    function setTarget(PerishableBond _target) external {
        target = _target;
    }

    function setAttack(bool _attack) external {
        attack = _attack;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attack) {
            attack = false; // prevent infinite recursion
            target.fundInsurancePool(1);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract PerishableBondTest is Test {
    PerishableBond bond;
    ERC20Mock usdc;

    address issuer = makeAddr("issuer");
    address cargoOwner = makeAddr("cargoOwner");
    address oracle = makeAddr("oracle");
    address holder2 = makeAddr("holder2");
    address funder = makeAddr("funder");
    address stranger = makeAddr("stranger");

    uint256 constant TOTAL_SUPPLY = 1_000e18;
    uint256 constant INITIAL_NAV = 100_000e18; // 100k USDC-equivalent
    uint256 constant DECAY_RATE = 0; // set per-test where decay matters
    int256 constant SAFE_TEMP = 8; // deg C
    uint256 constant BREACH_DURATION = 2 hours;
    uint256 constant BREACH_PENALTY_BPS = 2000; // 20%
    uint256 constant LIQ_THRESHOLD_BPS = 4000; // 40%
    uint256 maturityDeadline;

    event Liquidated(uint256 navAtLiquidation, uint256 insurancePoolAtLiquidation, uint256 supplySnapshot);
    event Matured(uint256 navAtMaturity, uint256 redemptionPoolAtMaturity, uint256 supplySnapshot);

    function _defaultParams() internal view returns (PerishableBond.BondParams memory) {
        return PerishableBond.BondParams({
            name: "Cold Chain Bond #1",
            symbol: "PBOND1",
            issuer: issuer,
            cargoOwner: cargoOwner,
            settlementToken: address(usdc),
            totalSupply: TOTAL_SUPPLY,
            initialNAV: INITIAL_NAV,
            decayRatePerSecondBpsE18: DECAY_RATE,
            safeTempCeiling: SAFE_TEMP,
            breachDurationLimit: BREACH_DURATION,
            breachPenaltyBps: BREACH_PENALTY_BPS,
            liquidationThresholdBps: LIQ_THRESHOLD_BPS,
            maturityDeadline: maturityDeadline,
            oracle: oracle
        });
    }

    function setUp() public {
        usdc = new ERC20Mock();
        maturityDeadline = block.timestamp + 10 days;
        bond = new PerishableBond(_defaultParams());

        // mint settlement tokens to parties who fund pools
        usdc.mint(issuer, 1_000_000e18);
        usdc.mint(funder, 1_000_000e18);

        vm.prank(issuer);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(funder);
        usdc.approve(address(bond), type(uint256).max);
    }

    // =========================================================================
    // Constructor validation
    // =========================================================================

    function test_constructor_revertsOnZeroIssuer() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.issuer = address(0);
        vm.expectRevert(PerishableBond.ZeroAddress.selector);
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroCargoOwner() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.cargoOwner = address(0);
        vm.expectRevert(PerishableBond.ZeroAddress.selector);
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroSettlementToken() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.settlementToken = address(0);
        vm.expectRevert(PerishableBond.ZeroAddress.selector);
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroOracle() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.oracle = address(0);
        vm.expectRevert(PerishableBond.ZeroAddress.selector);
        new PerishableBond(p);
    }

    function test_constructor_revertsOnBadThreshold() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.liquidationThresholdBps = 10_000; // must be < BPS_DENOM
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "threshold"));
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroBreachPenalty() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.breachPenaltyBps = 0;
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "breachPenaltyBps"));
        new PerishableBond(p);
    }

    function test_constructor_revertsOnPastDeadline() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.maturityDeadline = block.timestamp; // not > now
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "deadline in past"));
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroTotalSupply() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.totalSupply = 0;
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "totalSupply"));
        new PerishableBond(p);
    }

    function test_constructor_revertsOnZeroInitialNAV() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.initialNAV = 0;
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "initialNAV"));
        new PerishableBond(p);
    }

    function test_constructor_mintsToCargoOwner() public view {
        assertEq(bond.balanceOf(cargoOwner), TOTAL_SUPPLY);
        assertEq(bond.totalSupply(), TOTAL_SUPPLY);
    }

    function test_constructor_grantsRolesCorrectly() public view {
        assertTrue(bond.hasRole(bond.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(bond.hasRole(bond.ISSUER_ROLE(), issuer));
        assertTrue(bond.hasRole(bond.ORACLE_ROLE(), oracle));
    }

    // =========================================================================
    // NAV / decay curve math
    // =========================================================================

    function test_nav_noDecayAtIssuance() public view {
        assertEq(bond.currentNAV(), INITIAL_NAV);
    }

    function test_nav_linearTimeDecay() public {
        // redeploy with a nonzero decay rate: 100 bps/day scaled 1e18
        PerishableBond.BondParams memory p = _defaultParams();
        // decayRatePerSecondBpsE18 such that after 1 day, decay = 100 bps (1%)
        // rate * 86400 / 1e18 = 100  =>  rate = 100 * 1e18 / 86400
        p.decayRatePerSecondBpsE18 = (uint256(100) * 1e18) / 86400;
        PerishableBond b = new PerishableBond(p);

        vm.warp(block.timestamp + 1 days);
        // Compute expected decay the same (truncating) way the contract
        // does, rather than assuming an exact 100 bps, since integer
        // division of decayRatePerSecondBpsE18 already truncates.
        uint256 elapsed = 1 days;
        uint256 expectedDecayBps = (elapsed * p.decayRatePerSecondBpsE18) / 1e18;
        uint256 expected = (INITIAL_NAV * (10_000 - expectedDecayBps)) / 10_000;
        assertEq(b.currentNAV(), expected);
    }

    function test_nav_timeDecayCapsAt60Percent() public {
        PerishableBond.BondParams memory p = _defaultParams();
        // 100 bps decay per second (scaled 1e18) -> cap hit well within 1000s
        p.decayRatePerSecondBpsE18 = 100e18;
        PerishableBond b = new PerishableBond(p);

        vm.warp(block.timestamp + 1000);
        uint256 expected = (INITIAL_NAV * (10_000 - 6000)) / 10_000; // 40% of initialNAV
        assertEq(b.currentNAV(), expected);
    }

    // =========================================================================
    // Oracle telemetry / breach handling
    // =========================================================================

    function test_reportTelemetry_onlyOracle() public {
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl unauthorized
        bond.reportTelemetry(20, 5000, block.timestamp);
    }

    function test_reportTelemetry_startsBreachWindow() public {
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        assertGt(bond.breachStartedAt(), 0);
        assertEq(bond.cumulativeBreachPenaltyBps(), 0); // not yet past duration limit
    }

    function test_reportTelemetry_appliesPenaltyAfterDurationLimit() public {
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);

        vm.warp(block.timestamp + BREACH_DURATION + 1);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);

        assertEq(bond.cumulativeBreachPenaltyBps(), BREACH_PENALTY_BPS);
        uint256 expectedNav = (INITIAL_NAV * (10_000 - BREACH_PENALTY_BPS)) / 10_000;
        assertEq(bond.currentNAV(), expectedNav);
    }

    function test_reportTelemetry_breachClearsWithoutPenaltyIfResolvedInTime() public {
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP - 1, 5000, block.timestamp); // back to safe

        assertEq(bond.breachStartedAt(), 0);
        assertEq(bond.cumulativeBreachPenaltyBps(), 0);
    }

    function test_reportTelemetry_multipleBreachesAccumulatePenalty() public {
        // Breach 1
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        vm.warp(block.timestamp + BREACH_DURATION + 1);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        assertEq(bond.cumulativeBreachPenaltyBps(), BREACH_PENALTY_BPS);

        // clear
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP - 1, 5000, block.timestamp);

        // Breach 2
        vm.warp(block.timestamp + 1 hours);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        vm.warp(block.timestamp + BREACH_DURATION + 1);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);

        assertEq(bond.cumulativeBreachPenaltyBps(), BREACH_PENALTY_BPS * 2);
    }

    function test_reportTelemetry_revertsOnStaleReport() public {
        vm.warp(block.timestamp + 1000); // give ourselves room to go "backwards" while staying <= block.timestamp
        vm.startPrank(oracle);
        bond.reportTelemetry(20, 5000, block.timestamp - 100);
        vm.expectRevert(PerishableBond.StaleReport.selector);
        bond.reportTelemetry(20, 5000, block.timestamp - 200); // older than last report, still <= block.timestamp
        vm.stopPrank();
    }

    /// @dev REGRESSION TEST for the CRITICAL bug fixed in this version:
    /// the original contract had no upper bound on readingTimestamp, so an
    /// oracle report far in the future would later cause
    /// `block.timestamp - breachStartedAt` to underflow in checkUpkeep/
    /// performUpkeep, permanently reverting them. Confirms the fix rejects
    /// future timestamps outright instead of allowing the bond to be bricked.
    function test_reportTelemetry_revertsOnFutureTimestamp() public {
        vm.prank(oracle);
        vm.expectRevert(PerishableBond.FutureTimestamp.selector);
        bond.reportTelemetry(20, 5000, block.timestamp + 1 days);
    }

    /// @dev Further regression coverage: even if we bypass the guard by
    /// warping forward first is not possible (guard is unconditional), so
    /// instead we prove checkUpkeep/performUpkeep never underflow-revert
    /// under any reachable on-chain state by fuzzing breach start times
    /// that are always <= block.timestamp (the only way to reach them now).
    function testFuzz_checkUpkeep_neverUnderflows(uint32 warpSeconds) public {
        vm.assume(warpSeconds > 0 && warpSeconds < 365 days);
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);

        vm.warp(block.timestamp + warpSeconds);
        // must not revert regardless of how far we warp
        bond.checkUpkeep("");
    }

    // =========================================================================
    // Automation hooks: checkUpkeep / performUpkeep
    // =========================================================================

    function test_checkUpkeep_falseInitially() public view {
        (bool needed,) = bond.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_trueAfterBreachExpires() public {
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        vm.warp(block.timestamp + BREACH_DURATION + 1);

        (bool needed,) = bond.checkUpkeep("");
        assertTrue(needed);
    }

    function test_performUpkeep_appliesPenaltyAndCallableByAnyone() public {
        vm.prank(oracle);
        bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
        vm.warp(block.timestamp + BREACH_DURATION + 1);

        vm.prank(stranger); // permissionless keeper
        bond.performUpkeep("");

        assertEq(bond.cumulativeBreachPenaltyBps(), BREACH_PENALTY_BPS);
    }

    function test_performUpkeep_revertsWhenNotActive() public {
        _driveToLiquidationViaBreaches();

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Liquidated));

        vm.expectRevert(PerishableBond.BondNotActive.selector);
        bond.performUpkeep("");
    }

    /// @dev REGRESSION TEST for the maturity-deadline fix: previously a bond
    /// with no breach and NAV decay capped below the liquidation threshold
    /// could stay Active forever with no way for holders to ever claim.
    /// Confirms performUpkeep now force-liquidates once the deadline passes.
    function test_performUpkeep_forceLiquidatesAfterMaturityDeadlineIfUndelivered() public {
        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Active));

        vm.warp(maturityDeadline + 1);

        (bool needed,) = bond.checkUpkeep("");
        assertTrue(needed);

        vm.prank(stranger);
        bond.performUpkeep("");

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Liquidated));
        assertEq(bond.settledSupplySnapshot(), TOTAL_SUPPLY);
    }

    function test_performUpkeep_doesNotForceLiquidateBeforeDeadline() public {
        vm.warp(maturityDeadline - 1);
        (bool needed,) = bond.checkUpkeep("");
        assertFalse(needed);
    }

    /// @dev REGRESSION TEST: expiry must never wipe out an uint256
    /// overflow in currentNAV() for extreme (but issuer-chosen) decay
    /// rates. Before the fix, `_timeDecayBps()` multiplied
    /// `elapsed * decayRatePerSecondBpsE18` directly with no bound, so a
    /// bond that lived long enough (or was configured with too high a
    /// rate) would revert on every call to currentNAV() forever —
    /// including inside the maturity-deadline force-liquidation branch's
    /// own event emission, permanently trapping holder funds.
    function test_currentNAV_neverOverflowsWithExtremeDecayRateOverLongTime() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.decayRatePerSecondBpsE18 = type(uint128).max; // absurdly high, issuer misconfiguration
        PerishableBond b = new PerishableBond(p);

        // warp far into the future -- long past any realistic bond life
        vm.warp(block.timestamp + 50 * 365 days);

        // must not revert, and must be capped correctly
        uint256 nav = b.currentNAV();
        uint256 expectedNav = (INITIAL_NAV * (10_000 - 6000)) / 10_000; // 40% floor
        assertEq(nav, expectedNav);

        // and the automation hooks that depend on it must also survive
        b.checkUpkeep("");
    }

    function testFuzz_currentNAV_neverOverflows(uint256 rate, uint32 warpSeconds) public {
        PerishableBond.BondParams memory p = _defaultParams();
        rate = bound(rate, 1, type(uint256).max / 2); // any issuer-chosen rate
        p.decayRatePerSecondBpsE18 = rate;
        PerishableBond b = new PerishableBond(p);

        vm.warp(block.timestamp + warpSeconds);
        b.currentNAV(); // must never revert regardless of rate/elapsed
    }

    /// @dev REGRESSION TEST: if only the redemption pool was funded (issuer
    /// expected a normal on-time delivery) and the deadline is missed
    /// without insurance funding, forced expiry must mature the bond (so
    /// holders can claim from redemptionPool) rather than blindly
    /// liquidating into an empty insurancePool and stranding the funds.
    function test_performUpkeep_expiryPrefersFundedRedemptionPoolOverEmptyInsurance() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);

        vm.warp(maturityDeadline + 1);
        vm.prank(stranger);
        bond.performUpkeep("");

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Matured));

        vm.prank(cargoOwner);
        bond.claimPayout();
        assertEq(usdc.balanceOf(cargoOwner), INITIAL_NAV);
    }

    /// @dev If insurance IS funded (or neither pool is funded), expiry
    /// still defaults to Liquidated, preserving the original safety bias
    /// toward the insurance-protected path.
    function test_performUpkeep_expiryLiquidatesWhenInsuranceFunded() public {
        vm.prank(issuer);
        bond.fundInsurancePool(1);
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV); // funded too, but insurance takes priority

        vm.warp(maturityDeadline + 1);
        vm.prank(stranger);
        bond.performUpkeep("");

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Liquidated));
    }

    function test_constructor_revertsOnZeroBreachDurationLimit() public {
        PerishableBond.BondParams memory p = _defaultParams();
        p.breachDurationLimit = 0;
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "breachDurationLimit"));
        new PerishableBond(p);
    }

    // =========================================================================
    // markDelivered
    // =========================================================================

    function test_markDelivered_onlyIssuer() public {
        vm.prank(stranger);
        vm.expectRevert();
        bond.markDelivered();
    }

    function test_markDelivered_success() public {
        vm.expectEmit(false, false, false, true);
        emit Matured(INITIAL_NAV, 0, TOTAL_SUPPLY);

        vm.prank(issuer);
        bond.markDelivered();

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Matured));
        assertEq(bond.settledSupplySnapshot(), TOTAL_SUPPLY);
    }

    /// @dev Liquidation triggers when currentNAV() <= initialNAV * 40%,
    /// i.e. once cumulative breach penalty reaches >= 60% (10000-6000=4000).
    /// With BREACH_PENALTY_BPS=2000 per confirmed breach, that takes THREE
    /// full breach cycles, not two.
    function _driveToLiquidationViaBreaches() internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(oracle);
            bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
            vm.warp(block.timestamp + BREACH_DURATION + 1);
            vm.prank(oracle);
            bond.reportTelemetry(SAFE_TEMP + 1, 5000, block.timestamp);
            if (uint256(bond.status()) != uint256(PerishableBond.Status.Active)) break;
            vm.warp(block.timestamp + 1 hours);
        }
    }

    function test_markDelivered_revertsIfAlreadyBelowThreshold() public {
        _driveToLiquidationViaBreaches();

        // bond auto-liquidated already via _checkAutoLiquidate
        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Liquidated));

        vm.prank(issuer);
        vm.expectRevert(PerishableBond.BondNotActive.selector);
        bond.markDelivered();
    }

    function test_markDelivered_revertsIfNotActive() public {
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(issuer);
        vm.expectRevert(PerishableBond.BondNotActive.selector);
        bond.markDelivered();
    }

    // =========================================================================
    // Pool funding
    // =========================================================================

    function test_fundInsurancePool_success() public {
        vm.prank(issuer);
        bond.fundInsurancePool(50_000e18);
        assertEq(bond.insurancePool(), 50_000e18);
        assertEq(usdc.balanceOf(address(bond)), 50_000e18);
    }

    function test_fundInsurancePool_anyoneCanFund() public {
        vm.prank(funder);
        bond.fundInsurancePool(1000e18);
        assertEq(bond.insurancePool(), 1000e18);
    }

    function test_fundInsurancePool_revertsOnZeroAmount() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "amount"));
        bond.fundInsurancePool(0);
    }

    function test_fundInsurancePool_revertsAfterSettlement() public {
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(issuer);
        vm.expectRevert(PerishableBond.BondNotActive.selector);
        bond.fundInsurancePool(1);
    }

    function test_fundRedemptionPool_success() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);
        assertEq(bond.redemptionPool(), INITIAL_NAV);
    }

    function test_insuranceCoverageBps() public {
        vm.prank(issuer);
        bond.fundInsurancePool(50_000e18); // 50% of 100_000e18 initialNAV
        assertEq(bond.insuranceCoverageBps(), 5000);
    }

    /// @dev REGRESSION TEST proving the reentrancy fix: even though
    /// nonReentrant already blocked reentry into the contract's own guarded
    /// functions, this proves the attack path is closed end-to-end with a
    /// token that attempts to reenter fundInsurancePool during transferFrom.
    function test_fundInsurancePool_blocksReentrancy() public {
        ReentrantToken evilToken = new ReentrantToken();
        PerishableBond.BondParams memory p = _defaultParams();
        p.settlementToken = address(evilToken);
        PerishableBond evilBond = new PerishableBond(p);

        evilToken.setTarget(evilBond);
        evilToken.mint(funder, 1000e18);
        vm.prank(funder);
        evilToken.approve(address(evilBond), type(uint256).max);

        evilToken.setAttack(true);
        vm.prank(funder);
        vm.expectRevert(); // ReentrancyGuard: reentrant call
        evilBond.fundInsurancePool(100e18);
    }

    // =========================================================================
    // Claims (pull-payment pattern)
    // =========================================================================

    function test_claimPayout_revertsWhileActive() public {
        vm.prank(cargoOwner);
        vm.expectRevert(PerishableBond.BondStillActive.selector);
        bond.claimPayout();
    }

    function test_claimPayout_revertsWithNoBalance() public {
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "no balance"));
        bond.claimPayout();
    }

    function test_claimPayout_matured_fullPayout() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);

        vm.prank(issuer);
        bond.markDelivered();

        uint256 before = usdc.balanceOf(cargoOwner);
        vm.prank(cargoOwner);
        bond.claimPayout();

        assertEq(usdc.balanceOf(cargoOwner) - before, INITIAL_NAV);
        assertEq(bond.balanceOf(cargoOwner), 0);
    }

    function test_claimPayout_liquidated_proRataAcrossHolders() public {
        // split supply between cargoOwner and holder2
        vm.prank(cargoOwner);
        bond.transfer(holder2, TOTAL_SUPPLY / 4); // holder2 gets 25%

        vm.prank(issuer);
        bond.fundInsurancePool(40_000e18);

        _driveToLiquidationViaBreaches();

        assertEq(uint256(bond.status()), uint256(PerishableBond.Status.Liquidated));

        uint256 snapshot = bond.settledSupplySnapshot();
        uint256 holder2Bal = bond.balanceOf(holder2);
        uint256 expectedHolder2Share = (40_000e18 * holder2Bal) / snapshot;

        vm.prank(holder2);
        bond.claimPayout();
        assertEq(usdc.balanceOf(holder2), expectedHolder2Share);

        uint256 cargoOwnerBal = bond.balanceOf(cargoOwner);
        uint256 expectedCargoOwnerShare = (40_000e18 * cargoOwnerBal) / snapshot;
        vm.prank(cargoOwner);
        bond.claimPayout();
        assertEq(usdc.balanceOf(cargoOwner), expectedCargoOwnerShare);
    }

    function test_claimPayout_revertsOnDoubleClaim() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(cargoOwner);
        bond.claimPayout();

        vm.prank(cargoOwner);
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "no balance"));
        bond.claimPayout();
    }

    function test_claimPayout_zeroShareIfPoolUnfunded() public {
        // matured but redemption pool never funded -> share is 0, but claim
        // still burns tokens and succeeds without reverting.
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(cargoOwner);
        bond.claimPayout();

        assertEq(bond.balanceOf(cargoOwner), 0);
        assertEq(usdc.balanceOf(cargoOwner), 0);
    }

    // =========================================================================
    // Dust sweep
    // =========================================================================

    function test_sweepDust_revertsWhileHoldersRemain() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(PerishableBond.InvalidParam.selector, "holders remain"));
        bond.sweepDust(issuer);
    }

    function test_sweepDust_revertsWhileActive() public {
        vm.prank(issuer);
        vm.expectRevert(PerishableBond.BondStillActive.selector);
        bond.sweepDust(issuer);
    }

    function test_sweepDust_success_afterAllHoldersClaim() public {
        // Fund redemption pool with an amount that doesn't divide evenly
        // across supply, to actually produce dust.
        vm.prank(cargoOwner);
        bond.transfer(holder2, 333); // tiny odd split to force rounding dust

        vm.prank(issuer);
        bond.fundRedemptionPool(1000); // deliberately small + odd vs supply
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(cargoOwner);
        bond.claimPayout();
        vm.prank(holder2);
        bond.claimPayout();

        assertEq(bond.totalSupply(), 0);

        uint256 leftover = usdc.balanceOf(address(bond));
        if (leftover > 0) {
            vm.prank(issuer);
            bond.sweepDust(issuer);
            assertEq(usdc.balanceOf(address(bond)), 0);
        }
    }

    function test_sweepDust_onlyIssuer() public {
        vm.prank(issuer);
        bond.markDelivered();
        vm.prank(stranger);
        vm.expectRevert();
        bond.sweepDust(stranger);
    }

    // =========================================================================
    // Pause / unpause
    // =========================================================================

    function test_pause_blocksReportTelemetryAndFunding() public {
        vm.prank(issuer);
        bond.pause();

        vm.prank(oracle);
        vm.expectRevert();
        bond.reportTelemetry(20, 5000, block.timestamp);

        vm.prank(issuer);
        vm.expectRevert();
        bond.fundInsurancePool(1);
    }

    function test_pause_doesNotBlockClaimPayout() public {
        vm.prank(issuer);
        bond.fundRedemptionPool(INITIAL_NAV);
        vm.prank(issuer);
        bond.markDelivered();

        vm.prank(issuer);
        bond.pause();

        // claims must still work even when paused
        vm.prank(cargoOwner);
        bond.claimPayout();
        assertEq(usdc.balanceOf(cargoOwner), INITIAL_NAV);
    }

    function test_pause_onlyIssuer() public {
        vm.prank(stranger);
        vm.expectRevert();
        bond.pause();
    }

    function test_unpause_restoresFunctionality() public {
        vm.prank(issuer);
        bond.pause();
        vm.prank(issuer);
        bond.unpause();

        vm.prank(oracle);
        bond.reportTelemetry(20, 5000, block.timestamp); // should succeed
    }
}
