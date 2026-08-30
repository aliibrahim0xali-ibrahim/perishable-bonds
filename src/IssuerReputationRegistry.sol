// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PerishableBond.sol";
import "./PerishableBondFactory.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title IssuerReputationRegistry
 * @notice THE NEW IDEA: today, every cold-chain financing deal is priced as
 *         if every issuer is a stranger — buyers and insurers have no
 *         on-chain signal for "does this shipper's cargo actually arrive
 *         intact, or do their bonds keep getting liquidated?" This registry
 *         turns every settled PerishableBond into a permanent, public credit
 *         signal for its issuer: a soulbound, tamper-proof track record that
 *         markets can price into future deals (lower required insurance
 *         collateral, better rates, priority in a marketplace UI) the same
 *         way a credit score does off-chain — except it's derived entirely
 *         from verifiable on-chain outcomes instead of self-reported data.
 *
 * @dev    Deliberately kept as a standalone add-on rather than baked into
 *         PerishableBond itself:
 *         - Zero changes, zero re-audit risk, to the already-tested core
 *           bond contract.
 *         - `recordFromBond` only reads PUBLIC, FINALIZED state
 *           (status/issuer/pools/snapshot) off a bond that the trusted
 *           PerishableBondFactory actually deployed — so a malicious
 *           contract can't spoof itself as a "bond" to inflate a fake
 *           issuer's score.
 *         - Anyone can call it (a keeper, the issuer, a buyer, a front-end)
 *           once a bond settles; recording is permissionless but
 *           idempotent (one bond can never be counted twice).
 *
 * @dev    Reputation math here is intentionally simple and transparent
 *         (matured / total, in bps) so it's easy to reason about and audit.
 *         A production version could weight by deal size (larger bonds
 *         should move the score more than tiny ones) or add time-decay so
 *         old history matters less — left as a clearly-labeled extension
 *         point (`_weightOf`) rather than hard-coded, since the "right"
 *         weighting is a product/market decision, not a security one.
 */
contract IssuerReputationRegistry {
    PerishableBondFactory public immutable factory;

    error ZeroAddress();
    error NotARegisteredBond();
    error BondNotSettled();
    error AlreadyRecorded();

    struct IssuerRecord {
        uint256 maturedCount; // delivered on time, holders redeemed in full
        uint256 liquidatedCount; // spoiled / expired, holders fell back to insurance
        uint256 maturedWeight; // sum of weights (by deal size) for matured bonds
        uint256 totalWeight; // sum of weights for all settled bonds
    }

    mapping(address issuer => IssuerRecord) public records;
    mapping(address bond => bool) public recorded;

    event SettlementRecorded(
        address indexed bond, address indexed issuer, PerishableBond.Status outcome, uint256 weight
    );

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = PerishableBondFactory(_factory);
    }

    /// @notice Permissionlessly record a settled bond's outcome against its
    ///         issuer's on-chain track record. Callable by anyone, exactly
    ///         once per bond.
    function recordFromBond(address bondAddr) external {
        if (!factory.isRegisteredBond(bondAddr)) revert NotARegisteredBond();
        if (recorded[bondAddr]) revert AlreadyRecorded();

        PerishableBond bond = PerishableBond(bondAddr);
        PerishableBond.Status outcome = bond.status();
        if (outcome == PerishableBond.Status.Active) revert BondNotSettled();

        recorded[bondAddr] = true;

        address issuer = bond.issuer();
        uint256 weight = _weightOf(bond);

        IssuerRecord storage rec = records[issuer];
        rec.totalWeight += weight;
        if (outcome == PerishableBond.Status.Matured) {
            // HIGH FIX (this round): Status.Matured only means
            // markDelivered() was called without NAV having crossed the
            // liquidation threshold -- PerishableBond does NOT require
            // redemptionPool to actually be funded before allowing that
            // call. Blindly crediting full weight for any "Matured" bond
            // meant an issuer could deliver cargo, never fund the
            // redemption pool, and still walk away with a perfect
            // reputation score even though every holder's claimPayout()
            // would return zero. Credit only the portion of the deal that
            // was actually funded (capped at the deal's own weight, so
            // overfunding can't be used to buy score beyond 100% credit).
            uint256 funded = bond.redemptionPool();
            uint256 creditedWeight = funded < weight ? funded : weight;
            rec.maturedCount += 1;
            rec.maturedWeight += creditedWeight;
        } else {
            rec.liquidatedCount += 1;
        }

        emit SettlementRecorded(bondAddr, issuer, outcome, weight);
    }

    /// @dev Extension point: weight a settlement by deal size (initialNAV)
    ///      so a $2M cold-chain shipment moves the score more than a $200
    ///      test bond. Kept as a simple 1:1 mapping to initialNAV for now.
    function _weightOf(PerishableBond bond) internal view returns (uint256) {
        return bond.initialNAV();
    }

    /// @notice Weighted reputation score in bps (10000 = 100% of settled
    ///         deal value matured AND actually paid out, no incident).
    ///         Returns 10000 (neutral / no penalty) for an issuer with no
    ///         history yet, since "no data" should never be scored the
    ///         same as "bad data" — front-ends should separately surface
    ///         `totalDeals()` so users can distinguish "new issuer" from
    ///         "proven issuer".
    function reputationScoreBps(address issuer) external view returns (uint256) {
        IssuerRecord storage rec = records[issuer];
        if (rec.totalWeight == 0) return 10_000;
        // LOW FIX (this round): `maturedWeight * 10_000` computed directly
        // could overflow uint256 for extreme cumulative weights (an issuer
        // with an astronomical number of very large settled deals),
        // permanently reverting this view for that issuer. Math.mulDiv
        // computes the full-precision product before dividing without
        // ever risking an intermediate overflow.
        return Math.mulDiv(rec.maturedWeight, 10_000, rec.totalWeight);
    }

    function totalDeals(address issuer) external view returns (uint256) {
        IssuerRecord storage rec = records[issuer];
        return rec.maturedCount + rec.liquidatedCount;
    }
}
