// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// @dev Minimal Chainlink Automation interface so a keeper network can
// trigger decay checks / liquidation without any single trusted party
// having to call performUpkeep manually. Swap for the real Chainlink
// AutomationCompatibleInterface package path once you wire this into
// an actual Automation registration.
interface IAutomationCompatible {
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}

/**
 * @title PerishableBond
 * @notice A single-shipment, fractionalized RWA bond whose Net Asset Value
 *         (NAV) decays over time and drops further on environmental
 *         (cold-chain) threshold breaches reported by an oracle. If NAV
 *         falls below a liquidation threshold, the bond self-liquidates:
 *         tokens become claimable against a pre-funded parametric
 *         insurance pool. If the shipment is marked delivered before that
 *         happens, holders instead redeem against a redemption pool funded
 *         by the issuer at face/NAV value.
 *
 * @dev    This is a reference / prototype implementation for demonstration.
 *         It has NOT been audited. Do not deploy to mainnet with real value
 *         without a professional audit, formal verification of the decay
 *         math, and a Chainlink Automation / oracle security review.
 */
contract PerishableBond is ERC20, AccessControl, ReentrancyGuard, Pausable, IAutomationCompatible {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Custom errors (gas-efficient reverts)
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidParam(string reason);
    error BondNotActive();
    error BondStillActive();
    error FutureTimestamp();
    error StaleReport();
    error AlreadySettled();
    error NothingToSweep();

    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    /// @notice Granted to the trusted oracle relayer (e.g. a Chainlink
    ///         Functions consumer or DON-fed adapter) that pushes IoT
    ///         telemetry on-chain. In production this should itself be a
    ///         contract that aggregates multiple node reports, not an EOA.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @notice Granted to the issuer; can fund pools and mark delivery.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    // ---------------------------------------------------------------------
    // Lifecycle state
    // ---------------------------------------------------------------------

    enum Status {
        Active,
        Matured,
        Liquidated
    }

    Status public status;

    IERC20 public immutable settlementToken; // e.g. USDC
    address public immutable issuer;
    address public immutable cargoOwner; // original beneficiary / buyer

    uint256 public immutable issuanceTimestamp;
    uint256 public immutable maturityDeadline; // expected delivery time

    // ---------------------------------------------------------------------
    // NAV / decay curve parameters
    // ---------------------------------------------------------------------

    /// @notice NAV of the shipment at issuance, denominated in
    ///         settlementToken units (per whole bond supply), scaled 1e18.
    uint256 public immutable initialNAV;

    /// @notice Linear time-decay rate, in basis points of initialNAV lost
    ///         PER SECOND, scaled by 1e18 for precision
    ///         (e.g. a good decaying 2%/day => ~0.0000002315 bps/sec).
    ///         Kept linear for auditability; swap _timeDecayBps() for an
    ///         exponential/Weibull model if your goods decay non-linearly.
    uint256 public immutable decayRatePerSecondBpsE18;

    /// @notice Max basis points that time-decay alone may strip (caps the
    ///         curve so oracle-driven breach penalties remain meaningful).
    uint256 public constant MAX_TIME_DECAY_BPS = 6000; // 60%

    uint256 public constant BPS_DENOM = 10_000;

    // --- Cold-chain breach parameters ---
    int256 public immutable safeTempCeiling; // e.g. 8 (°C * 1, adjust scale as needed)
    uint256 public immutable breachDurationLimit; // seconds a breach may persist before penalty
    uint256 public immutable breachPenaltyBps; // NAV hit applied per confirmed breach event

    /// @notice Cumulative bps of NAV destroyed by confirmed breach events.
    uint256 public cumulativeBreachPenaltyBps;

    /// @notice Liquidate once currentNAV() <= initialNAV * thresholdBps/10000.
    uint256 public immutable liquidationThresholdBps;

    // --- Oracle telemetry state ---
    int256 public lastReportedTemp;
    uint256 public lastReportTimestamp;
    uint256 public breachStartedAt; // 0 if not currently breaching

    // --- Pools ---
    uint256 public insurancePool; // paid out to holders on liquidation
    uint256 public redemptionPool; // paid out to holders on maturity

    /// @notice Snapshot of totalSupply() taken at the moment of
    ///         liquidation/maturity so pro-rata claims stay consistent
    ///         even as holders burn tokens to claim.
    uint256 public settledSupplySnapshot;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event TelemetryReported(int256 temperature, uint256 humidityBps, uint256 timestamp);
    event BreachStarted(uint256 timestamp, int256 temperature);
    event BreachPenaltyApplied(uint256 penaltyBps, uint256 cumulativeBps, uint256 navAfter);
    event BreachCleared(uint256 timestamp);
    event InsuranceFunded(address indexed from, uint256 amount);
    event RedemptionFunded(address indexed from, uint256 amount);
    event Liquidated(uint256 navAtLiquidation, uint256 insurancePoolAtLiquidation, uint256 supplySnapshot);
    event Matured(uint256 navAtMaturity, uint256 redemptionPoolAtMaturity, uint256 supplySnapshot);
    event PayoutClaimed(address indexed holder, uint256 tokensBurned, uint256 amountPaid, Status settledAs);

    // ---------------------------------------------------------------------
    // Integration helper: one-call frontend snapshot
    // ---------------------------------------------------------------------

    /// @notice Everything a UI needs to render this bond's card/dashboard in
    ///         a single RPC call, instead of stitching together ~10 separate
    ///         reads (status, NAV, pools, breach state, claimable amount for
    ///         the caller, etc). Front-ends should poll this, not the
    ///         individual public getters, to stay fast and avoid subtle
    ///         inconsistencies from reading fields across different blocks.
    struct BondSnapshot {
        Status status;
        uint256 currentNav;
        uint256 initialNavValue;
        uint256 navBps; // currentNAV as bps of initialNAV, i.e. 10000 = 100%
        uint256 secondsUntilMaturity; // 0 if past deadline or already settled
        bool isBreaching;
        uint256 breachSecondsElapsed; // 0 if not currently breaching
        uint256 cumulativeBreachPenaltyBpsValue;
        uint256 insurancePoolValue;
        uint256 redemptionPoolValue;
        uint256 callerBalance;
        uint256 callerClaimableEstimate; // 0 while Active
        int256 lastTemp;
        uint256 lastReportAge; // seconds since last oracle report, 0 if never
    }

    function getSnapshot(address caller) external view returns (BondSnapshot memory s) {
        uint256 nav = currentNAV();
        s.status = status;
        s.currentNav = nav;
        s.initialNavValue = initialNAV;
        s.navBps = initialNAV == 0 ? 0 : (nav * BPS_DENOM) / initialNAV;
        s.secondsUntilMaturity =
            (status == Status.Active && block.timestamp < maturityDeadline) ? maturityDeadline - block.timestamp : 0;
        s.isBreaching = breachStartedAt != 0;
        s.breachSecondsElapsed = breachStartedAt != 0 ? block.timestamp - breachStartedAt : 0;
        s.cumulativeBreachPenaltyBpsValue = cumulativeBreachPenaltyBps;
        s.insurancePoolValue = insurancePool;
        s.redemptionPoolValue = redemptionPool;
        s.callerBalance = balanceOf(caller);
        if (status != Status.Active && settledSupplySnapshot > 0) {
            uint256 pool = status == Status.Liquidated ? insurancePool : redemptionPool;
            s.callerClaimableEstimate = (pool * balanceOf(caller)) / settledSupplySnapshot;
        }
        s.lastTemp = lastReportedTemp;
        s.lastReportAge = lastReportTimestamp == 0 ? 0 : block.timestamp - lastReportTimestamp;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    struct BondParams {
        string name;
        string symbol;
        address issuer;
        address cargoOwner;
        address settlementToken;
        uint256 totalSupply; // fractional bond units, minted to cargoOwner
        uint256 initialNAV; // scaled 1e18, denominated in settlementToken units
        uint256 decayRatePerSecondBpsE18;
        int256 safeTempCeiling;
        uint256 breachDurationLimit;
        uint256 breachPenaltyBps;
        uint256 liquidationThresholdBps;
        uint256 maturityDeadline;
        address oracle;
    }

    constructor(BondParams memory p) ERC20(p.name, p.symbol) {
        if (
            p.issuer == address(0) || p.cargoOwner == address(0) || p.settlementToken == address(0)
                || p.oracle == address(0)
        ) revert ZeroAddress();
        // MEDIUM FIX (this round): with the new IssuerReputationRegistry
        // scoring issuers by their matured-vs-liquidated settlement
        // history, an issuer == cargoOwner bond lets an issuer manufacture
        // a "successful" settlement risk-free — they fund the redemption
        // pool from their own wallet, immediately markDelivered(), and
        // claim it right back, inflating their own score for the cost of
        // gas alone. Disallowed at the root so the guarantee holds for any
        // future consumer of settlement outcomes, not just this registry.
        if (p.issuer == p.cargoOwner) revert InvalidParam("issuer cannot be cargoOwner");
        if (p.liquidationThresholdBps >= BPS_DENOM) revert InvalidParam("threshold");
        if (p.breachPenaltyBps == 0 || p.breachPenaltyBps > BPS_DENOM) revert InvalidParam("breachPenaltyBps");
        if (p.breachDurationLimit == 0) revert InvalidParam("breachDurationLimit");
        if (p.maturityDeadline <= block.timestamp) revert InvalidParam("deadline in past");
        if (p.totalSupply == 0) revert InvalidParam("totalSupply");
        if (p.initialNAV == 0) revert InvalidParam("initialNAV");

        issuer = p.issuer;
        cargoOwner = p.cargoOwner;
        settlementToken = IERC20(p.settlementToken);
        initialNAV = p.initialNAV;
        decayRatePerSecondBpsE18 = p.decayRatePerSecondBpsE18;
        safeTempCeiling = p.safeTempCeiling;
        breachDurationLimit = p.breachDurationLimit;
        breachPenaltyBps = p.breachPenaltyBps;
        liquidationThresholdBps = p.liquidationThresholdBps;
        maturityDeadline = p.maturityDeadline;
        issuanceTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, p.issuer);
        _grantRole(ISSUER_ROLE, p.issuer);
        _grantRole(ORACLE_ROLE, p.oracle);

        _mint(p.cargoOwner, p.totalSupply);
    }

    // ---------------------------------------------------------------------
    // NAV computation
    // ---------------------------------------------------------------------

    function _timeDecayBps() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - issuanceTimestamp;
        if (decayRatePerSecondBpsE18 == 0) return 0;

        // HIGH FIX (this round): the previous version computed
        // `elapsed * decayRatePerSecondBpsE18` directly. decayRatePerSecondBpsE18
        // is an issuer-supplied constructor parameter with no upper bound.
        // For a bond that runs long enough (or a rate set too high by
        // mistake), that multiplication overflows uint256 and reverts —
        // and because Solidity 0.8 reverts on overflow rather than
        // wrapping, currentNAV() would then revert *forever*. Every
        // function that depends on currentNAV() (isBelowLiquidationThreshold,
        // reportTelemetry's auto-liquidate check, markDelivered,
        // checkUpkeep/performUpkeep, and even the `Liquidated` event's own
        // emit) would revert too — permanently trapping the bond in
        // Status.Active with cargoOwner's tokens frozen and no recovery
        // path, since claimPayout() is gated on status != Active. This
        // would also silently defeat the maturity-deadline safety valve
        // added below (performUpkeep's forced-liquidation branch still
        // emits `Liquidated(currentNAV(), ...)`).
        //
        // Fix: determine algebraically whether elapsed has already passed
        // the point where decay would be capped, and short-circuit before
        // ever performing the multiplication that could overflow.
        uint256 maxElapsedBeforeCap = (MAX_TIME_DECAY_BPS * 1e18) / decayRatePerSecondBpsE18;
        if (elapsed > maxElapsedBeforeCap) return MAX_TIME_DECAY_BPS;

        uint256 decay = (elapsed * decayRatePerSecondBpsE18) / 1e18;
        return decay > MAX_TIME_DECAY_BPS ? MAX_TIME_DECAY_BPS : decay;
    }

    /// @notice Current NAV including time decay and confirmed breach
    ///         penalties. Does NOT include an in-progress, unconfirmed
    ///         breach (that's only applied once it clears
    ///         breachDurationLimit via reportTelemetry/performUpkeep).
    function currentNAV() public view returns (uint256) {
        uint256 totalPenaltyBps = _timeDecayBps() + cumulativeBreachPenaltyBps;
        if (totalPenaltyBps >= BPS_DENOM) return 0;
        return (initialNAV * (BPS_DENOM - totalPenaltyBps)) / BPS_DENOM;
    }

    function isBelowLiquidationThreshold() public view returns (bool) {
        return currentNAV() <= (initialNAV * liquidationThresholdBps) / BPS_DENOM;
    }

    // ---------------------------------------------------------------------
    // Oracle telemetry intake
    // ---------------------------------------------------------------------

    /// @notice Pushed by the oracle relayer on each IoT reading (or on a
    ///         fixed cadence). Tracks breach windows and, once a breach has
    ///         persisted past breachDurationLimit, permanently applies
    ///         breachPenaltyBps to NAV exactly once per breach event.
    function reportTelemetry(int256 temperatureC, uint256 humidityBps, uint256 readingTimestamp)
        external
        onlyRole(ORACLE_ROLE)
        whenNotPaused
    {
        if (status != Status.Active) revert BondNotActive();
        // CRITICAL FIX: bound readingTimestamp to [lastReportTimestamp, block.timestamp].
        // The original code allowed an oracle to push an arbitrary future
        // timestamp with no upper bound. That value is later used as
        // `breachStartedAt`, and checkUpkeep()/performUpkeep() compute
        // `block.timestamp - breachStartedAt`. Once real time passed but
        // breachStartedAt was set further in the future than block.timestamp
        // could ever reach quickly, that subtraction underflows (Solidity
        // 0.8 checked arithmetic) and reverts *forever*, permanently
        // bricking both automated liquidation checks AND, because
        // lastReportTimestamp would also be stuck at that huge value, all
        // future reportTelemetry() calls (their `readingTimestamp >=
        // lastReportTimestamp` check would forever fail). A single bad or
        // compromised oracle report could otherwise permanently disable
        // breach detection for the life of the bond.
        if (readingTimestamp > block.timestamp) revert FutureTimestamp();
        if (readingTimestamp < lastReportTimestamp) revert StaleReport();

        lastReportedTemp = temperatureC;
        lastReportTimestamp = readingTimestamp;
        emit TelemetryReported(temperatureC, humidityBps, readingTimestamp);

        if (temperatureC > safeTempCeiling) {
            if (breachStartedAt == 0) {
                breachStartedAt = readingTimestamp;
                emit BreachStarted(readingTimestamp, temperatureC);
            } else if (readingTimestamp - breachStartedAt >= breachDurationLimit) {
                _applyBreachPenalty();
            }
        } else if (breachStartedAt != 0) {
            breachStartedAt = 0;
            emit BreachCleared(readingTimestamp);
        }

        _checkAutoLiquidate();
    }

    function _applyBreachPenalty() internal {
        cumulativeBreachPenaltyBps += breachPenaltyBps;
        if (cumulativeBreachPenaltyBps > BPS_DENOM) cumulativeBreachPenaltyBps = BPS_DENOM;
        breachStartedAt = 0; // reset window so the same breach isn't double-charged
        emit BreachPenaltyApplied(breachPenaltyBps, cumulativeBreachPenaltyBps, currentNAV());
    }

    // ---------------------------------------------------------------------
    // Chainlink Automation hooks
    // ---------------------------------------------------------------------

    /// @notice Keepers call this off-chain (simulated) on a cadence; if
    ///         either an unresolved breach has exceeded its window, or NAV
    ///         has crossed the liquidation threshold purely from time
    ///         decay, upkeep is needed.
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (status != Status.Active) return (false, bytes(""));

        // breachStartedAt is only ever set from a past-or-present
        // readingTimestamp (enforced in reportTelemetry), and this
        // comparison is against the *current* block.timestamp, which only
        // increases — so this subtraction cannot underflow.
        bool breachExpired = breachStartedAt != 0 && (block.timestamp - breachStartedAt) >= breachDurationLimit;
        bool thresholdCrossed = isBelowLiquidationThreshold();
        bool deadlinePassed = block.timestamp >= maturityDeadline;

        upkeepNeeded = breachExpired || thresholdCrossed || deadlinePassed;
        performData = "";
    }

    function performUpkeep(bytes calldata) external override {
        if (status != Status.Active) revert BondNotActive();

        if (breachStartedAt != 0 && (block.timestamp - breachStartedAt) >= breachDurationLimit) {
            _applyBreachPenalty();
        }

        // MEDIUM FIX: the original contract never enforced maturityDeadline
        // anywhere after the constructor check. If the issuer never called
        // markDelivered() and NAV decay/breaches never crossed the
        // liquidation threshold (e.g. because MAX_TIME_DECAY_BPS caps decay
        // below the threshold, or because a compromised oracle simply
        // stopped reporting), the bond could remain Status.Active forever,
        // permanently freezing cargoOwner's tokens with no path to a
        // payout. Anyone can now force resolution once the deadline has
        // passed: it defaults to liquidation (protecting the buyer via the
        // insurance pool) since delivery was never confirmed in time.
        // MEDIUM FIX (this round): forcing Status.Liquidated unconditionally
        // assumed the insurance pool was funded. If the issuer instead
        // funded the redemption pool (expecting a normal on-time delivery)
        // and simply missed the deadline, claimPayout() would read
        // `insurancePool` (likely 0) instead of the funded
        // `redemptionPool`, stranding those funds in the contract — the
        // only way out would be sweepDust() returning them to the issuer
        // instead of the holders they were meant for. Prefer whichever
        // pool actually has funds so holders aren't stranded by which
        // branch happened to fire.
        if (status == Status.Active && block.timestamp >= maturityDeadline) {
            if (insurancePool == 0 && redemptionPool > 0) {
                _mature();
            } else {
                _liquidate();
            }
            return;
        }

        _checkAutoLiquidate();
    }

    function _mature() internal {
        status = Status.Matured;
        settledSupplySnapshot = totalSupply();
        emit Matured(currentNAV(), redemptionPool, settledSupplySnapshot);
    }

    // ---------------------------------------------------------------------
    // Liquidation / Maturity
    // ---------------------------------------------------------------------

    function _checkAutoLiquidate() internal {
        if (status == Status.Active && isBelowLiquidationThreshold()) {
            _liquidate();
        }
    }

    function _liquidate() internal {
        status = Status.Liquidated;
        settledSupplySnapshot = totalSupply();
        emit Liquidated(currentNAV(), insurancePool, settledSupplySnapshot);
    }

    /// @notice Issuer confirms the shipment was delivered intact before any
    ///         liquidation trigger fired. Locks in redemption at current NAV.
    function markDelivered() external onlyRole(ISSUER_ROLE) {
        if (status != Status.Active) revert BondNotActive();
        if (isBelowLiquidationThreshold()) revert InvalidParam("already below threshold, must liquidate");

        _mature();
    }

    // ---------------------------------------------------------------------
    // Pool funding
    // ---------------------------------------------------------------------

    /// @notice Issuer (or any party, e.g. a parametric insurance
    ///         underwriter) pre-funds the payout pool that backs
    ///         liquidation claims. Must be funded BEFORE the bond can
    ///         safely be trusted by buyers — this contract does not enforce
    ///         a minimum funding ratio, so front-ends / buyers should check
    ///         insurancePool against initialNAV before purchasing exposure.
    function fundInsurancePool(uint256 amount) external nonReentrant whenNotPaused {
        if (status != Status.Active) revert BondNotActive();
        if (amount == 0) revert InvalidParam("amount");
        // Effects before interaction: record the funding before the
        // external call so a reentrant/malicious settlementToken cannot
        // observe an inconsistent pool balance mid-call. nonReentrant
        // already blocks reentry into this contract's other guarded
        // functions, but updating state first is best practice regardless
        // of the token's trust level.
        insurancePool += amount;
        emit InsuranceFunded(msg.sender, amount);
        settlementToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function fundRedemptionPool(uint256 amount) external nonReentrant whenNotPaused {
        if (status != Status.Active) revert BondNotActive();
        if (amount == 0) revert InvalidParam("amount");
        redemptionPool += amount;
        emit RedemptionFunded(msg.sender, amount);
        settlementToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice View helper so front-ends/buyers can check collateralization
    ///         before trusting this bond, since funding is not enforced
    ///         on-chain (a design choice, not a bug — funding sources vary
    ///         by deal). Returns how many bps of initialNAV are currently
    ///         covered by the insurance pool.
    function insuranceCoverageBps() external view returns (uint256) {
        return (insurancePool * BPS_DENOM) / initialNAV;
    }

    // ---------------------------------------------------------------------
    // Claims (pull-payment pattern)
    // ---------------------------------------------------------------------

    /// @notice Burn your bond tokens for a pro-rata share of whichever pool
    ///         applies to how this bond settled.
    function claimPayout() external nonReentrant {
        if (status == Status.Active) revert BondStillActive();

        uint256 bal = balanceOf(msg.sender);
        if (bal == 0) revert InvalidParam("no balance");
        if (settledSupplySnapshot == 0) revert InvalidParam("bad snapshot");

        uint256 pool = status == Status.Liquidated ? insurancePool : redemptionPool;
        uint256 share = (pool * bal) / settledSupplySnapshot;

        _burn(msg.sender, bal); // effects before interaction

        emit PayoutClaimed(msg.sender, bal, share, status);

        if (share > 0) {
            settlementToken.safeTransfer(msg.sender, share);
        }
    }

    /// @notice Sweeps rounding-dust left over after every holder has
    ///         claimed (pro-rata division in claimPayout() floors down, so
    ///         a few wei can otherwise be stuck in the contract forever).
    ///         Only callable once the bond is fully settled AND fully
    ///         burned out, so it can never be used to divert funds away
    ///         from token holders who haven't claimed yet.
    function sweepDust(address to) external onlyRole(ISSUER_ROLE) nonReentrant {
        if (status == Status.Active) revert BondStillActive();
        if (totalSupply() != 0) revert InvalidParam("holders remain");
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = settlementToken.balanceOf(address(this));
        if (bal == 0) revert NothingToSweep();
        settlementToken.safeTransfer(to, bal);
    }

    // ---------------------------------------------------------------------
    // Emergency pause (issuer-controlled circuit breaker)
    // ---------------------------------------------------------------------

    /// @notice Pauses telemetry intake and pool funding in case a bug or a
    ///         compromised oracle/token is discovered. Does NOT pause
    ///         claimPayout — holders must always be able to withdraw funds
    ///         already in the settled pools.
    function pause() external onlyRole(ISSUER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ISSUER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    function getBondSummary()
        external
        view
        returns (
            Status currentStatus,
            uint256 nav,
            uint256 timeDecayBps,
            uint256 breachPenaltyBpsAccrued,
            bool breachActive,
            uint256 insurancePoolBalance,
            uint256 redemptionPoolBalance
        )
    {
        return (
            status,
            currentNAV(),
            _timeDecayBps(),
            cumulativeBreachPenaltyBps,
            breachStartedAt != 0,
            insurancePool,
            redemptionPool
        );
    }
}
