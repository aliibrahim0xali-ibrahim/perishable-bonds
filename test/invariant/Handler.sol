// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/PerishableBond.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @dev Drives PerishableBond through random, bounded sequences of every
/// external action (telemetry, funding, delivery, upkeep, claims, plain
/// ERC20 transfers, and time warps) so the invariant suite can explore
/// states no hand-written unit test thought to construct. All calls are
/// wrapped so an *expected* revert (wrong role, wrong status, etc.) is
/// swallowed rather than aborting the run -- we only care about invariants
/// holding across whatever *successful* state transitions occur.
contract Handler is Test {
    PerishableBond public bond;
    ERC20Mock public token;

    address public issuer;
    address public oracle;
    address[] public holders;

    // ghost accounting
    uint256 public ghost_totalClaimed; // sum of settlementToken paid out via claimPayout
    uint256 public ghost_poolAtSettlement; // insurancePool or redemptionPool value at the moment status left Active
    bool public ghost_settled;
    PerishableBond.Status public ghost_settledStatus;

    // track status transitions to catch any backward move (un-settling)
    PerishableBond.Status public lastObservedStatus;
    bool public invariant_statusWentBackward;

    int256 internal constant SAFE_TEMP = 8;

    constructor(PerishableBond _bond, ERC20Mock _token, address _issuer, address _oracle, address[] memory _holders) {
        bond = _bond;
        token = _token;
        issuer = _issuer;
        oracle = _oracle;
        holders = _holders;
        lastObservedStatus = bond.status();
    }

    modifier trackStatus() {
        _;
        PerishableBond.Status current = bond.status();
        // Active(0) -> Matured(1)/Liquidated(2) is the only legal direction.
        // Anything that moves status back toward a lower enum value, or
        // away from a settled status entirely, is a violation.
        if (uint256(current) < uint256(lastObservedStatus)) {
            invariant_statusWentBackward = true;
        }
        if (lastObservedStatus != PerishableBond.Status.Active && current != lastObservedStatus) {
            invariant_statusWentBackward = true;
        }
        if (!ghost_settled && current != PerishableBond.Status.Active) {
            ghost_settled = true;
            ghost_settledStatus = current;
            ghost_poolAtSettlement =
                current == PerishableBond.Status.Liquidated ? bond.insurancePool() : bond.redemptionPool();
        }
        lastObservedStatus = current;
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    // ---------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------

    function reportTelemetry(bool breach, uint32 warpForward, uint256 tsBackoff) external trackStatus {
        // stay within [lastReportTimestamp, block.timestamp] to respect the
        // FutureTimestamp/StaleReport guards deliberately -- the handler
        // isn't trying to attack the timestamp guard here (that's covered
        // by dedicated unit/fuzz tests), it's exploring otherwise-valid
        // sequences.
        vm.warp(block.timestamp + (warpForward % 3 days));
        uint256 ts = block.timestamp - (tsBackoff % 1 hours);
        if (ts < bond.lastReportTimestamp()) ts = bond.lastReportTimestamp();

        int256 temp = breach ? SAFE_TEMP + 5 : SAFE_TEMP - 5;
        vm.prank(oracle);
        try bond.reportTelemetry(temp, 5000, ts) {} catch {}
    }

    function performUpkeep() external trackStatus {
        try bond.performUpkeep("") {} catch {}
    }

    function fundInsurance(uint256 amount, uint256 seed) external trackStatus {
        amount = bound(amount, 0, 10_000e18);
        address who = _holder(seed);
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(bond), amount);
        vm.prank(who);
        try bond.fundInsurancePool(amount) {} catch {}
    }

    function fundRedemption(uint256 amount, uint256 seed) external trackStatus {
        amount = bound(amount, 0, 10_000e18);
        address who = _holder(seed);
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(bond), amount);
        vm.prank(who);
        try bond.fundRedemptionPool(amount) {} catch {}
    }

    function markDelivered() external trackStatus {
        vm.prank(issuer);
        try bond.markDelivered() {} catch {}
    }

    function claimPayout(uint256 seed) external trackStatus {
        address who = _holder(seed);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try bond.claimPayout() {
            ghost_totalClaimed += token.balanceOf(who) - before;
        } catch {}
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external trackStatus {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 bal = bond.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(from);
        try bond.transfer(to, amount) {} catch {}
    }

    function warp(uint32 seconds_) external trackStatus {
        vm.warp(block.timestamp + (seconds_ % 30 days));
    }

    function pauseUnpause(bool doPause) external trackStatus {
        vm.prank(issuer);
        if (doPause) {
            try bond.pause() {} catch {}
        } else {
            try bond.unpause() {} catch {}
        }
    }
}
