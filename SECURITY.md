# Security

> **Status: unaudited reference implementation.** This code has been through
> several rounds of internal review (summarized below) and has a large
> automated test suite, but it has **not** had a professional third-party
> audit. Do not deploy to mainnet with real value without one.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a suspected vulnerability.
Instead, email the maintainers (or use GitHub's private
[security advisory](../../security/advisories/new) feature on this repo) with:

- A description of the issue and its impact
- Steps or a PoC to reproduce it
- Any suggested fix, if you have one

We'll acknowledge reports within a few days and credit reporters in the fix
commit/release notes unless you'd prefer to stay anonymous.

## What's been reviewed

Every item below was found during internal review, fixed, and locked in with
a regression test — see `test/` for the corresponding test names.

| # | Issue | Severity | Where |
|---|---|---|---|
| 1 | Oracle-supplied timestamp had no upper bound; a future timestamp caused `block.timestamp - breachStartedAt` to underflow in `checkUpkeep`/`performUpkeep`, permanently reverting them and bricking breach detection | Critical | `PerishableBond.reportTelemetry` |
| 2 | No fallback if `maturityDeadline` passed without delivery confirmation or a liquidation trigger — bond could stay `Active` forever, permanently freezing holder funds | High | `PerishableBond.performUpkeep` |
| 3 | Unbounded `decayRatePerSecondBpsE18` could overflow `elapsed * rate` in NAV decay math, reverting `currentNAV()` forever (defeats item 2's safety valve too, since `_liquidate()`'s event emit also calls `currentNAV()`) | High | `PerishableBond._timeDecayBps` |
| 4 | Forced expiry always resolved to `Liquidated` (insurance pool), even when only the redemption pool was funded — could strand a funded redemption pool with holders receiving nothing | Medium | `PerishableBond.performUpkeep` |
| 5 | Pool-funding functions updated external-token state after the external `transferFrom` call (interaction before effects) | Medium | `PerishableBond.fundInsurancePool` / `fundRedemptionPool` |
| 6 | Reputation registry credited full weight for any `Matured` bond, even if `redemptionPool` was never funded — holders could get zero while the issuer's score read 100% | High | `IssuerReputationRegistry.recordFromBond` |
| 7 | `issuer == cargoOwner` allowed a risk-free, self-dealt "successful" settlement to farm reputation score | Medium | `PerishableBond` constructor |
| 8 | Unbounded multiplication in `reputationScoreBps()` could overflow for extreme cumulative weights | Low | `IssuerReputationRegistry.reputationScoreBps` |
| 9 | Missing zero-address / zero-value validation on several constructor parameters | Low | `PerishableBond` constructor |
| 10 | Unbounded array return (`getAllBonds`) risks out-of-gas for on-chain callers as the registry grows | Low | `PerishableBondFactory` |

## Known, accepted limitations

These are documented design tradeoffs, not oversights — read before integrating:

- **Single-EOA oracle trust.** `ORACLE_ROLE` is one address per bond. A
  compromised oracle key can fabricate a breach (forcing liquidation) or
  suppress a real one. Production deployments should replace this with a
  DON-aggregating consumer or multi-reporter median, not a single relayer.
- **No enforced minimum pool funding.** Neither `insurancePool` nor
  `redemptionPool` has a required funding ratio. A bond can be issued and
  bought into before either pool is funded. Front-ends and buyers must check
  `getSnapshot()` / `insuranceCoverageBps()` themselves before trusting a bond.
- **Reputation Sybil resistance.** `IssuerReputationRegistry` prevents the
  trivial `issuer == cargoOwner` self-deal, but an issuer using a second
  wallet as `cargoOwner` can still farm reputation with enough capital.
  Closing this fully requires an off-chain identity/KYC layer or a staking
  mechanism — out of scope for this contract.
- **`performUpkeep` is deliberately not pausable.** The maturity-deadline
  force-resolution path stays callable even while paused, so an issuer can't
  use `pause()` to indefinitely freeze holder funds past the deadline.

## Test suite as security surface

93 tests across 4 suites, including a Foundry invariant (stateful fuzzing)
campaign of ~200,000 randomized calls checking that: settlement status never
reverses, no claim ever exceeds its settled pool, the contract always holds
enough to pay remaining claims, and `currentNAV()` never reverts under any
reachable sequence. See the [README](README.md#testing) for how to run it.
