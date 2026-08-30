// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/PerishableBond.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import "./Handler.sol";

contract PerishableBondInvariantTest is Test {
    PerishableBond bond;
    ERC20Mock token;
    Handler handler;

    address issuer = makeAddr("issuer");
    address cargoOwner = makeAddr("cargoOwner");
    address oracle = makeAddr("oracle");

    uint256 constant TOTAL_SUPPLY = 1_000e18;
    uint256 constant INITIAL_NAV = 100_000e18;

    function setUp() public {
        token = new ERC20Mock();

        PerishableBond.BondParams memory p = PerishableBond.BondParams({
            name: "Invariant Bond",
            symbol: "IBOND",
            issuer: issuer,
            cargoOwner: cargoOwner,
            settlementToken: address(token),
            totalSupply: TOTAL_SUPPLY,
            initialNAV: INITIAL_NAV,
            decayRatePerSecondBpsE18: (uint256(50) * 1e18) / 1 days, // mild decay
            safeTempCeiling: 8,
            breachDurationLimit: 2 hours,
            breachPenaltyBps: 1500,
            liquidationThresholdBps: 4000,
            maturityDeadline: block.timestamp + 30 days,
            oracle: oracle
        });
        bond = new PerishableBond(p);

        address[] memory holders = new address[](4);
        holders[0] = cargoOwner;
        holders[1] = makeAddr("holder1");
        holders[2] = makeAddr("holder2");
        holders[3] = makeAddr("holder3");

        // spread initial supply across a couple holders so transfer/claim
        // sequences actually exercise multiple pro-rata claimants
        vm.startPrank(cargoOwner);
        bond.transfer(holders[1], TOTAL_SUPPLY / 4);
        bond.transfer(holders[2], TOTAL_SUPPLY / 4);
        vm.stopPrank();

        handler = new Handler(bond, token, issuer, oracle, holders);

        // only fuzz through the handler's bounded action surface, never
        // call the bond/token directly with arbitrary calldata
        targetContract(address(handler));
    }

    /// @notice Status can only ever move Active -> {Matured, Liquidated},
    /// and once settled it can never change to a different status. There
    /// is no function in the contract that should be able to reverse this.
    function invariant_statusNeverGoesBackward() public view {
        assertFalse(handler.invariant_statusWentBackward());
    }

    /// @notice Solvency: across any sequence of funding/claim calls, the
    /// contract must never pay out more settlement-token than the pool
    /// amount that was locked in at the moment of settlement. This is the
    /// core financial guarantee of the pull-payment claim mechanism.
    function invariant_neverOverpaysSettledPool() public view {
        if (handler.ghost_settled()) {
            assertLe(handler.ghost_totalClaimed(), handler.ghost_poolAtSettlement());
        }
    }

    /// @notice The contract's settlement-token balance must never go
    /// negative relative to obligations -- i.e. it must always hold at
    /// least (pool - alreadyClaimed) once settled, so a later claimant can
    /// never be shorted by an earlier one draining more than their share.
    function invariant_contractHoldsEnoughToPayRemainingClaims() public view {
        if (handler.ghost_settled()) {
            uint256 remaining = handler.ghost_poolAtSettlement() - handler.ghost_totalClaimed();
            assertGe(token.balanceOf(address(bond)), remaining);
        }
    }

    /// @notice ERC20 accounting sanity: totalSupply must always equal what
    /// currentNAV()/decay logic assumes it does not exceed the original
    /// mint (tokens are only ever burned via claimPayout, never minted
    /// after construction).
    function invariant_totalSupplyNeverExceedsInitialMint() public view {
        assertLe(bond.totalSupply(), TOTAL_SUPPLY);
    }

    /// @notice currentNAV() must never revert, no matter what sequence of
    /// telemetry/time-warps the handler explored (regression coverage for
    /// the overflow fix, now under adversarial random sequencing rather
    /// than a single crafted fuzz input).
    function invariant_currentNAVNeverReverts() public view {
        bond.currentNAV();
    }
}
