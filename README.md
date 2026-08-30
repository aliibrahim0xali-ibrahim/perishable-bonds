<p align="center">
  <img src="docs/banner.jpg" alt="Perishable Bonds" width="100%" />
</p>

# Perishable Bonds

[![test](https://github.com/aliibrahim0xali-ibrahim/perishable-bonds/actions/workflows/test.yml/badge.svg)](https://github.com/aliibrahim0xali-ibrahim/perishable-bonds/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Solidity ^0.8.24](https://img.shields.io/badge/solidity-%5E0.8.24-lightgrey)](foundry.toml)
[![contributors](https://img.shields.io/github/contributors/aliibrahim0xali-ibrahim/perishable-bonds)](https://github.com/aliibrahim0xali-ibrahim/perishable-bonds/graphs/contributors)
[![issues](https://img.shields.io/github/issues/aliibrahim0xali-ibrahim/perishable-bonds)](https://github.com/aliibrahim0xali-ibrahim/perishable-bonds/issues)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![code of conduct](https://img.shields.io/badge/Code%20of%20Conduct-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

**Tokenized supply-chain financing for goods that spoil.** This is a set of
Ethereum smart contracts that turn a single cold-chain shipment — insulin,
vaccines, fresh produce, refrigerated cargo — into an ERC20 bond whose value
**molts in real time** as time passes and temperature deviates, and that
**settles itself** when the goods either arrive intact or clearly spoil: no
claims adjusters, no disputes, no paperwork.

Built with [Foundry](https://getfoundry.sh), tested with a stateful-fuzzing
invariant campaign, and designed to be a clean reference for how to model
"assets that lose value" on-chain.

> **Status: unaudited reference implementation.** This code has been through
> several internal review rounds (see [SECURITY.md](SECURITY.md)) and ships
> with 93 tests, but it has **not** had a professional third-party audit.
> **Do not deploy to mainnet with real value without one.**

---

## Table of contents

- [Why this project exists](#why-this-project-exists)
- [The big picture](#the-big-picture)
- [Lifecycle of a bond](#lifecycle-of-a-bond)
- [Core concepts](#core-concepts)
  - [NAV and the decay curve](#nav-and-the-decay-curve)
  - [Cold-chain breaches](#cold-chain-breaches)
  - [The two pools](#the-two-pools)
  - [Settlement](#settlement)
  - [Claims (pull payments)](#claims-pull-payments)
- [Architecture](#architecture)
  - [Contract map](#contract-map)
  - [Roles and permissions](#roles-and-permissions)
- [A tour of the code](#a-tour-of-the-code)
- [One-call frontend integration](#one-call-frontend-integration)
- [Issuer reputation](#issuer-reputation-issuerreputationregistry)
- [Quickstart](#quickstart)
- [Testing](#testing)
- [Deployment](#deployment)
- [Security, audit history, and known limitations](#security-audit-history-and-known-limitations)
- [Contributing](#contributing)
- [License](#license)

---

## Why this project exists

Traditional real-world-asset (RWA) tokenization assumes an asset **holds or
appreciates** in value — a bond, a treasury note, a property. But a lot of
real-world value is the exact opposite: it **decays the moment it exists**.

A pallet of insulin is worth $100,000 the day it ships. Leave it on a tarmac
for a week, or let it thaw past 8 °C for a few hours, and that same pallet is
worth a fraction of that — or nothing. Today, financing those goods means an
insurer or a logistics financier making a bet on paperwork after the fact.

This protocol moves the entire judgement **on-chain and in real time**:

- **Time** is priced in continuously via a decay curve.
- **Temperature** (and other environmental thresholds) is priced in via oracle
  reports of cold-chain breaches.
- **Value** is a number anyone can read at any block: `currentNAV()`.
- **Settlement** (matured vs liquidated) is a deterministic function of state,
  not of a human's opinion.

If you're new to DeFi/RWA development, the useful mental model is: *"an exotic
ERC20 whose `price` is computed, not quoted, and whose terminal payout is
mostly decided before anyone argues."*

---

## The big picture

Three contracts work together:

| Layer | Contract | Responsibility |
|---|---|---|
| Core | [`PerishableBond.sol`](src/PerishableBond.sol) | One ERC20 per shipment. Decay math, oracle intake, breach tracking, pools, settlement, claims. The whole domain model lives here. |
| Registry | [`PerishableBondFactory.sol`](src/PerishableBondFactory.sol) | Role-gated deployer. Also keeps an on-chain list of every bond, so front-ends and indexers can discover them without scraping events. |
| Reputation | [`IssuerReputationRegistry.sol`](src/IssuerReputationRegistry.sol) | A standalone add-on. Every settled bond becomes a permanent, deal-size-weighted credit-score input for its issuer. |

Data flows in one direction: `Factory` deploys `PerishableBond`s; the
`ReputationRegistry` only *reads* settled bonds (through the factory's
registry) and never touches the core contract.

---

## Lifecycle of a bond

Every bond passes through exactly one of three states:

```
Active ──▶ Matured      (cargo delivered intact in time → redemption pool)
Active ──▶ Liquidated   (NAV hit threshold, or deadline missed → insurance pool)
```

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. TOKENIZE                                                          │
│    Issuer → Factory.createBond(...)                                  │
│      → deploys PerishableBond (ERC20)                                │
│      → mints totalSupply to cargoOwner                               │
│      → registers bond in factory's on-chain list                     │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. REPORT (runs for the whole life of the bond)                       │
│    Oracle → reportTelemetry(temp, humidity, ts)                       │
│      → NAV decays linearly with time                                  │
│      → sustained cold-chain breach → penalty to NAV                   │
│      → NAV below threshold? → auto-liquidate                          │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. SETTLE (first branch that fires wins)                              │
│    · Issuer → markDelivered()            → Status.Matured             │
│    · NAV ≤ threshold (any caller trigger) → Status.Liquidated         │
│    · Time > maturityDeadline, still Active → automatic resolution     │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 4. CLAIM                                                              │
│    Holder → claimPayout() → burns tokens, pulls pro-rata share         │
│    of the pool that applies to how the bond settled.                  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Core concepts

### NAV and the decay curve

**NAV** (Net Asset Value) is the on-chain "price" of the whole bond, in
settlement-token units (e.g. `100_000e18` = 100,000 USDC). It starts at
`initialNAV` and is *only ever allowed to go down*.

`currentNAV()` is the product of two independent penalties:

```
currentNAV = initialNAV × (10000 − timeDecayBps − cumulativeBreachPenaltyBps) / 10000
```

Two things erode it:

1. **Time decay** — linear, configurable per bond via
   `decayRatePerSecondBpsE18` (basis points per second, scaled ×10¹⁸ for
   precision; e.g. `~0.0000002315e18` ≈ 2%/day). Decay is **capped at 60%**
   (`MAX_TIME_DECAY_BPS`), so time alone can never fully zero the bond — it
   leaves room for breach penalties to matter and keeps the liquidation
   threshold reachable.

2. **Breach penalties** — resolved by the oracle (see next section), run
   through `cumulativeBreachPenaltyBps`, and **capped at 100%** (10,000 bps).

When penalties ≥ 100%, NAV floors at `0`. `isBelowLiquidationThreshold()`
compares `currentNAV()` to `initialNAV × liquidationThresholdBps / 10000`.

> **Why linear?** Linearity is the auditable default. The
> `_timeDecayBps()` function is the single place to swap in an
> exponential/Weibull model if your goods decay non-linearly.

### Cold-chain breaches

The bond has a `safeTempCeiling` (e.g. 8 °C) and a `breachDurationLimit` (a
grace window, e.g. 2 hours). The oracle feeds temperature readings:

- A reading **above the ceiling** starts a breach window (`breachStartedAt`).
- If the breach **persists past `breachDurationLimit`**, the bond applies
  `breachPenaltyBps` (e.g. 20%) to NAV exactly once, then resets the window.
- If temperature **returns to safe** first, the window clears with no penalty.

Each confirmed breach is a separate penalty event → repeated temperature
issues keep eating NAV until liquidation. `cumulativeBreachPenaltyBps`
accumulates and caps at 10,000 bps.

Penalties are applied from two places so the system works even if the oracle
goes quiet:
- `reportTelemetry()` applies the penalty the moment it sees an expired
  breach (and auto-liquidates, see below).
- `checkUpkeep()`/`performUpkeep()` (Chainlink Automation hooks) let any
  permissionless keeper apply the penalty and check liquidation on a fixed
  cadence.

**Telemetry safety rails:** `readingTimestamp` must be between the last
report's timestamp and `block.timestamp` — this bounds `breachStartedAt` so
that `block.timestamp - breachStartedAt` can never underflow and brick the
keep-up hooks. This was a past critical bug; see [SECURITY.md](SECURITY.md).

### The two pools

Buyers/insurers pre-fund payout pools **before** a bond settles:

- **`insurancePool`** — used when the bond **liquidates**. Funded by insurance
  underwriters or anyone. This is the "parametric insurance" payout.
- **`redemptionPool`** — used when the bond **matures**. Funded by the issuer
  (or anyone) to buy back the cargo at redemption value.

Funding functions (`fundInsurancePool` / `fundRedemptionPool`) are open to
anyone, follow checks-effects-interactions, and use `SafeERC20`. **Funding is
not enforced** — a bond can exist with empty pools. Always read
`insuranceCoverageBps()` / `getSnapshot()` before trusting a bond (this is a
documented design decision, not a bug).

### Settlement

Exactly one of three things happens, and the first to fire wins:

| Trigger | Who fires it | Result | Holders claim from |
|---|---|---|---|
| Issuer confirms delivery via `markDelivered()` | Caller with `ISSUER_ROLE`, only while NAV is **above** the threshold and status is Active | `Matured` | `redemptionPool` |
| NAV decays/breaches below the liquidation threshold | Anyone triggers `checkUpkeep`/`performUpkeep`/`reportTelemetry` (auto-check) | `Liquidated` | `insurancePool` |
| `maturityDeadline` passes while still `Active` | Anyone calls `performUpkeep` (forced resolution) | `Matured` **if** only `redemptionPool` is funded, else `Liquidated` | whichever pool has funds |

At the exact moment of settlement the contract snapshots `totalSupply()`
(`settledSupplySnapshot`) so pro-rata claims stay consistent even as holders
burn tokens to claim. Once settled, a bond never changes status again.

> The deadline fallback exists so an issuer can never silently freeze funds by
> ignoring the protocol — someone (anyone) can always force a payout path.

### Claims (pull payments)

`claimPayout()` is a classic **pull-payment**:

```
share = (applicablePool × yourBalance) / settledSupplySnapshot
```

- Burns your ERC20 tokens (supply only ever shrinks after settlement).
- Transfers your pro-rata share of the pool that applies to the settlement.
- If the applicable pool is empty, your share is `0` — the call still
  succeeds and burns your tokens (no stuck state).
- After everyone has claimed, integer-division rounding may leave a few wei;
  the issuer can recover that dust with `sweepDust()` **only after every token
  is burned** (`totalSupply() == 0`).

Claims are deliberately **not** affected by `pause()` — holders must always be
able to withdraw funds already in settled pools.

---

## Architecture

### Contract map

| Contract | Key state | Key functions |
|---|---|---|
| **PerishableBond** | `status`, `initialNAV`, `decayRatePerSecondBpsE18`, `safeTempCeiling`, `breachDurationLimit`, `breachPenaltyBps`, `liquidationThresholdBps`, `maturityDeadline`, `cumulativeBreachPenaltyBps`, `breachStartedAt`, `lastReportedTemp`, `lastReportTimestamp`, `insurancePool`, `redemptionPool`, `settledSupplySnapshot` | `currentNAV()`, `isBelowLiquidationThreshold()`, `reportTelemetry()`, `checkUpkeep()`, `performUpkeep()`, `markDelivered()`, `fundInsurancePool()`, `fundRedemptionPool()`, `claimPayout()`, `sweepDust()`, `pause()`/`unpause()`, `getSnapshot()`, `getBondSummary()` |
| **PerishableBondFactory** | `allBonds[]`, `bondsByIssuer[issuer][]`, `isRegisteredBond[bond]`, `defaultOracle` | `createBond()`, `setDefaultOracle()`, `totalBonds()`, `getBondsByIssuer()`, `getAllBonds()`, `getBondsPaginated()` |
| **IssuerReputationRegistry** | `records[issuer]` (`maturedCount`, `liquidatedCount`, `maturedWeight`, `totalWeight`), `recorded[bond]` | `recordFromBond()`, `reputationScoreBps()`, `totalDeals()` |

### Roles and permissions

Access control is provided by OpenZeppelin's `AccessControl`.

**On each `PerishableBond`:**

| Role | Holder | Can do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | issuer | manage roles |
| `ISSUER_ROLE` | issuer | `markDelivered()`, `pause()`/`unpause()`, `sweepDust()` |
| `ORACLE_ROLE` | the oracle address | `reportTelemetry()` |

Everything else (`fund*Pool`, `performUpkeep`, `claimPayout`, ERC20
transfers) is **permissionless** — the protocol is resistant to "the only
person who could settle this is on vacation."

**On the factory:** `DEFAULT_ADMIN_ROLE` + `ORACLE_ADMIN_ROLE` go to `admin`
at construction; `ISSUER_ROLE` must be granted by the admin before a shipper
can `createBond()`. `ORACLE_ADMIN_ROLE` can update `defaultOracle` (applied
to new bonds; existing bonds keep their own oracle).

---

## A tour of the code

Read these in order:

| File | What to look for | Why it matters |
|---|---|---|
| [`src/PerishableBond.sol`](src/PerishableBond.sol) | constructor validation, `_timeDecayBps()`, `currentNAV()`, `reportTelemetry()`, `performUpkeep()`, `_liquidate()`/`_mature()`, `claimPayout()` | The entire domain model. Each of these functions encodes a pricing/safety decision, most with a comment explaining the reasoning (and a linked SECURITY.md fix). |
| [`src/PerishableBondFactory.sol`](src/PerishableBondFactory.sol) | `createBond()`, `getBondsPaginated()` | How bonds get deployed and discovered on-chain. |
| [`src/IssuerReputationRegistry.sol`](src/IssuerReputationRegistry.sol) | `recordFromBond()`, `_weightOf()`, `reputationScoreBps()` | How settlement outcomes become a credit signal. |
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | `run()` | The one-shot deployment flow for factory + registry. |
| [`test/PerishableBond.t.sol`](test/PerishableBond.t.sol) | constructor boundary tests, decay math, breach windows, CEI/reentrancy regression, overflow regression | The core contract's behavior, and the regression tests that lock in every SECURITY.md fix. |
| [`test/PerishableBondFactory.t.sol`](test/PerishableBondFactory.t.sol) | role gating, oracle fallback, pagination | Factory behavior. |
| [`test/IntegrationFeatures.t.sol`](test/IntegrationFeatures.t.sol) | `getSnapshot()`, reputation scoring, funding-credit regressions | Cross-contract behavior. |
| [`test/invariant/Handler.sol`](test/invariant/Handler.sol) | every external action wrapped in `try/catch` | The fuzzer's "random driver" — read this to understand what states the invariants see. |
| [`test/invariant/PerishableBondInvariant.t.sol`](test/invariant/PerishableBondInvariant.t.sol) | the five `invariant_*` properties | The system-wide guarantees the suite verifies. |

**Read order for a first pass:** constructor → `currentNAV`/`_timeDecayBps`
(the price model) → `reportTelemetry` (the state machine's input) →
`markDelivered`/`_liquidate`/`performUpkeep` (the state machine's outputs) →
`claimPayout`/`sweepDust` (money leaving) → tests.

---

## One-call frontend integration

Payments and state machines are the hard parts; the frontend shouldn't be.
A UI needs roughly ten different reads to draw a bond card (status, NAV,
pools, breach state, caller balance, claimable amount…). Reading them across
different blocks can show inconsistent data.

`getSnapshot(address caller)` returns everything in **one** `eth_call`:

```solidity
struct BondSnapshot {
    Status status;
    uint256 currentNav;
    uint256 initialNavValue;
    uint256 navBps;                 // currentNAV as bps of initialNAV
    uint256 secondsUntilMaturity;
    bool isBreaching;
    uint256 breachSecondsElapsed;
    uint256 cumulativeBreachPenaltyBpsValue;
    uint256 insurancePoolValue;
    uint256 redemptionPoolValue;
    uint256 callerBalance;
    uint256 callerClaimableEstimate; // 0 while Active
    int256 lastTemp;
    uint256 lastReportAge;
}
```

Guide for a dashboard (pseudo-code — exact syntax depends on your stack):

```js
const s = bond.getSnapshot(user);

// color the card
if (s.status !== "Active") {
  // s.callerClaimableEstimate is the pull amount if user has tokens
} else if (s.isBreaching) {
  // "breaching" — something is wrong right now
} else if (s.navBps < 4000) {
  // "low" — close to the liquidation threshold
} else {
  // "healthy"
}
```

There's also a compact `getBondSummary()` if you prefer raw fields over the
snapshot struct.

---

## Issuer reputation: `IssuerReputationRegistry`

**The problem it solves:** every cold-chain financing deal is currently priced
as if the issuer is a stranger. "Does this shipper's cargo actually arrive
intact?" should be an on-chain, verifiable fact, not a sales pitch.

**How it works:** anyone (keeper, issuer, buyer) can call `recordFromBond()` a
single time per settled bond. The registry:

1. Rejects bonds the trusted factory didn't deploy (`isRegisteredBond`).
2. Rejects unsettled bonds and double-recordings.
3. Weights each deal by its size (`_weightOf` → `initialNAV`, an explicit
   extension point for weighting schemes).
4. Credits a `Matured` bond **only for the portion of its redemption pool that
   was actually funded** — an issuer can't farm a perfect score by delivering
   cargo nobody got paid for, and over-funding can't buy credit above 100%.

```solidity
registry.recordFromBond(bondAddress);           // permissionless, once per bond
uint256 score = registry.reputationScoreBps(issuer); // 10_000 = 100% of settled
                                                     // deal value paid out intact
uint256 deals   = registry.totalDeals(issuer);   // distinguishes "no history"
                                                 // from "proven track record"
```

**Reading the score:** no history returns a neutral `10_000`, so a new issuer
is never penalized for being new — always surface `totalDeals()` next to the
score. This is a deliberately simple and transparent formula
(`maturedWeight / totalWeight`); the "right" weighting is a product decision,
so `_weightOf()` is the seam for changing it.

---

## Quickstart

Requirements: [Foundry](https://getfoundry.sh) (includes `forge`, `cast`,
`anvil`).

```bash
git clone https://github.com/aliibrahim0xali-ibrahim/perishable-bonds.git
cd perishable-bonds

# install pinned dependencies into lib/
forge install foundry-rs/forge-std@v1.9.6 OpenZeppelin/openzeppelin-contracts@v5.3.0

forge build      # compile
forge test       # run all 93 tests (unit + fuzz + invariant)
```

> Dependencies are fetched at install time and `lib/` is gitignored. In CI
> (<kbd>.github/workflows/test.yml</kbd>) the same pinned install runs before
> build/test/coverage.

### Local smoke test with anvil

```bash
anvil &                          # local chain on :8545
export ADMIN_ADDRESS=0xf39F...   # anvil's default account
export DEFAULT_ORACLE=0xf39F...  # same for the demo
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

---

## Testing

93 tests across 4 suites (run with `forge test`).

| Suite | File(s) | Coverage intent |
|---|---|---|
| Unit | [`test/PerishableBond.t.sol`](test/PerishableBond.t.sol) | Constructor boundaries, decay math, breach windows, pool funding CEI, claims, pause, dust sweep + fuzz/regression tests for every past security fix. |
| Factory | [`test/PerishableBondFactory.t.sol`](test/PerishableBondFactory.t.sol) | Role gating, oracle fallback, registry/list helpers, pagination. |
| Integration/reputation | [`test/IntegrationFeatures.t.sol`](test/IntegrationFeatures.t.sol) | `getSnapshot()`, cross-contract settlement, reputation scoring incl. funding-credit edge cases. |
| Invariant (stateful fuzzing) | [`test/invariant/`](test/invariant/) | ~200,000 randomized calls per run against 5 system-wide properties. |

```bash
forge test                                     # everything
forge test --match-contract PerishableBondInvariantTest -vv   # invariants only
forge coverage --report summary                # line/branch coverage
```

**The five invariants** (checked across every random sequence the handler can
produce — telemetry, funding, delivery, upkeep, claims, transfers, time
warps, pause):

1. Settlement status never reverses (`Active → {Matured, Liquidated}` only).
2. No claim ever exceeds its settled pool.
3. The contract always holds enough to pay remaining claims.
4. `totalSupply` never exceeds the initial mint (only shrinks via burns).
5. `currentNAV()` never reverts — under any reachable sequence.

Configuration lives in [`foundry.toml`](foundry.toml): fuzz `runs = 256`,
invariant `runs = 256`, `depth = 200`. Current coverage: **95.9% lines /
84.5% branches** overall (100% on `IssuerReputationRegistry.sol`).

---

## Deployment

Deploys the factory + reputation registry (bonds are created per-shipment
afterward):

```bash
export ADMIN_ADDRESS=0x...        # factory admin (DEFAULT_ADMIN_ROLE / ORACLE_ADMIN_ROLE)
export DEFAULT_ORACLE=0x...       # default ORACLE_ROLE grantee on new bonds
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

Then create bonds per shipment:

```solidity
factory.createBond(
  PerishableBond.BondParams({
    name: "Cold Chain Bond #1",
    symbol: "PBOND1",
    cargoOwner: <buyer>,
    settlementToken: <USDC address>,
    totalSupply: 1_000e18,
    initialNAV: 100_000e18,
    decayRatePerSecondBpsE18: 0,            // or the linear decay rate
    safeTempCeiling: 8,
    breachDurationLimit: 2 hours,
    breachPenaltyBps: 2000,
    liquidationThresholdBps: 4000,
    maturityDeadline: block.timestamp + 10 days,
    oracle: address(0)                      // falls back to factory default
    // issuer is set to msg.sender by the factory
  })
)
```

Production deployment notes:
- The **oracle should be a contract aggregating multiple reports** (e.g. a
  Chainlink Functions consumer / DON-fed adapter), not a single EOA.
- Register the bond with **Chainlink Automation** so `checkUpkeep`/
  `performUpkeep` run on a cadence even if no one is watching.
- Pre-fund pools and verify `insuranceCoverageBps()` before marketing a bond.

---

## Security, audit history, and known limitations

Read **[SECURITY.md](SECURITY.md)** before integrating. It documents:

- **Audit history** — every issue found across internal review rounds, with
  severity, exact location, and the name of the regression test that locks the
  fix in (e.g. a critical oracle-timestamp bug that could permanently brick a
  bond, an overflow that could freeze `currentNAV()`, CEI violations, and
  reputation-farming vectors).
- **Accepted limitations** — these are design tradeoffs, not oversights:
  - *Single-EOA oracle trust*: one oracle address per bond can fabricate or
    suppress breaches. Production should use multi-reporter / DON aggregation.
  - *No enforced pool funding minimum*: always check pools before trusting a
    bond.
  - *Reputation Sybil resistance*: the `issuer == cargoOwner` self-deal is
    blocked, but a second wallet as `cargoOwner` can still farm score with
    enough capital. Closing this fully needs identity/KYC or staking.
  - *`performUpkeep` is deliberately not pausable* so the maturity deadline
    can always force resolution.

**Reporting a vulnerability:** use GitHub's private security advisory or email
the maintainers — do **not** open a public issue. See SECURITY.md for details.

---

## Contributing

Open source, PRs welcome. Whether it's the decay math, a regression test, a
new invariant, or better docs — contributions are appreciated and governed by
our [Code of Conduct](CODE_OF_CONDUCT.md).

**Start here:** read [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup, coding
conventions, the PR checklist, and where to look for first issues.

- Report bugs via the [bug template](../../issues/new?template=bug_report.yml)
  or a pull request with a regression test that fails on `main`.
- Suggest features via the [feature template](../../issues/new?template=feature_request.yml).
- **Security issues only via the private [security advisory](../../security/advisories/new) — never as a public issue.** See [SECURITY.md](SECURITY.md).
- Run `forge fmt && forge test` before submitting; CI runs fmt, build, tests, and coverage on every PR.

---

## License

[MIT](LICENSE) © 2026 Perishable Bonds Contributors