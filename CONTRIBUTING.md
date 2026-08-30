# Contributing to Perishable Bonds

First off, thanks for taking the time to contribute! This project is a
reference implementation for tokenizing goods that lose value over time —
and it only gets better with more eyes on the edge cases.

## Table of contents

- [Code of conduct](#code-of-conduct)
- [How can I help?](#how-can-i-help)
- [Getting started](#getting-started)
- [Project layout](#project-layout)
- [Development workflow](#development-workflow)
- [Pull request checklist](#pull-request-checklist)
- [Coding conventions](#coding-conventions)
- [Testing and the invariant suite](#testing-and-the-invariant-suite)
- [Security](#security)

## Code of conduct

This project is governed by the [Contributor Covenant](CODE_OF_CONDUCT.md).
By participating you agree to keep the space respectful and harassment-free.
Remember: this is a protocol that handles **people's money** — disagreements
about the code deserve good-faith technical debate, not personal attacks.

## How can I help?

Pick whatever fits your skills. All of these are valuable:

1. **Review the math.** The decay curve, breach penalties, and pro-rata claim
   logic are the heart of the protocol. A second pair of eyes on the
   [SECURITY.md](SECURITY.md) register is always welcome.
2. **Add regression tests.** Every past security fix has a test that fails on
   the old code. If you find a new edge case, add the test too.
3. **Grow the invariant campaign.** New handler actions and new invariants
   probe states no unit test thinks to construct.
4. **Docs & tooling.** Better READMEs, deployment guides, frontend examples,
   and CI improvements all count.
5. **Report bugs and security issues** (see [Security](#security)).

New here? Look for issues labeled
[`good first issue`](../../labels/good%20first%20issue) and
[`help wanted`](../../labels/help%20wanted).

## Getting started

Requirements: [Foundry](https://getfoundry.sh) (`forge`, `cast`, `anvil`).

```bash
# 1. Fork the repo on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/perishable-bonds.git
cd perishable-bonds

# 2. Add the upstream remote so you can sync
git remote add upstream https://github.com/aliibrahim0xali-ibrahim/perishable-bonds.git

# 3. Install pinned dependencies
forge install foundry-rs/forge-std@v1.9.6 OpenZeppelin/openzeppelin-contracts@v5.3.0

# 4. Verify everything works before you start
forge build
forge test
```

> Dependencies are **pinned by version on purpose**. If you bump
> `forge-std` or `openzeppelin-contracts`, bump them intentionally (and
> update this README + CI to match) — never `forge update` casually.

## Project layout

```
src/                               # production contracts
  PerishableBond.sol               #   one ERC20 per shipment: the whole domain model
  PerishableBondFactory.sol        #   role-gated deployer + on-chain bond registry
  IssuerReputationRegistry.sol     #   settlement-outcome credit score (standalone add-on)
script/
  Deploy.s.sol                     # one-shot deployment of factory + registry
test/
  PerishableBond.t.sol             # unit tests + regression tests for past fixes
  PerishableBondFactory.t.sol      # factory tests
  IntegrationFeatures.t.sol        # snapshot + reputation integration tests
  invariant/
    Handler.sol                    # the fuzzer's random "driver" over all actions
    PerishableBondInvariant.t.sol  # the five system-wide invariants
.github/workflows/test.yml         # CI: fmt → build → test → coverage
```

Start by reading [`src/PerishableBond.sol`](src/PerishableBond.sol) top to
bottom — the comments explain *why* each unusual line exists (usually a past
bug that now has a regression test).

## Development workflow

1. **Sync your fork first:**

   ```bash
   git fetch upstream
   git checkout main && git merge upstream/main
   ```

2. **Create a feature branch** — one logical change per branch:

   ```bash
   git checkout -b fix/claim-rounding-dust
   ```

3. **Make your change.** Keep it small; a good bug fix is a few lines of
   code + one regression test. If you're touching behavior, think about how
   it shows up in the invariant suite.

4. **Run the full gate before committing:**

   ```bash
   forge fmt          # formatting
   forge build        # compile
   forge test         # all suites
   forge coverage --report summary   # confirm you didn't regress coverage
   ```

5. **Commit** with a clear message:

   ```text
   fix: prevent integer underflow in sweepDust() when pool is 0

   Body: what changed, why, and how the regression test proves it.
   ```

6. **Push and open a pull request** against `main`. Use the
   [PR template](../.github/PULL_REQUEST_TEMPLATE.md) — it exists to make
   your PR easy to review.

## Pull request checklist

Before you mark a PR "ready for review":

- [ ] `forge fmt` clean, `forge build` passes.
- [ ] `forge test` passes locally (all suites).
- [ ] **Every behavior change ships with a test** — ideally a regression test
      that fails on `main`.
- [ ] New state transitions / new external calls are reflected in the
      invariant handler and/or a new invariant.
- [ ] No unrelated changes in the same PR (keep diffs reviewable).
- [ ] README/deploy docs updated if user-facing behavior changed.
- [ ] Solidity pragma / dependency versions not bumped incidentally.

Expect a review conversation; push additional commits to the same branch to
address comments (no force-push to your feature branch unless asked).

## Coding conventions

- **Formatter:** `forge fmt` is the law. Run it before every commit.
- **Solidity:** `pragma ^0.8.24`, checked arithmetic by default (0.8.x). Do
  not add unchecked blocks "for gas" unless you've proven safety and said so.
- **License headers:** `// SPDX-License-Identifier: MIT` at the top of every
  Solidity file.
- **Errors over strings:** use custom errors (`error ZeroAddress();`), not
  `require("message")` — unless the file's established pattern differs.
- **Checks → effects → interactions:** external calls last, always.
- **Comments:** explain *why*, not *what*. If a line looks strange, there is
  almost certainly a bug behind it — say which one ([SECURITY.md](SECURITY.md)
  is full of examples).
- **Never** commit secrets, `.env`, `broadcast/`, or `cache/` (all gitignored).

## Testing and the invariant suite

- Unit tests live in `test/*.t.sol`; keep the existing naming style
  (`test_<fn>_<case>`).
- Fuzzed tests use `forge`'s `bound()`/`vm.assume()` patterns already in use
  in the suites.
- The **invariant suite** (`test/invariant/`) drives hundreds of thousands of
  randomized calls through [`Handler.sol`](test/invariant/Handler.sol) and
  asserts five properties. When you add a new contract function, consider
  adding a corresponding `trackStatus` handler action so the invariants keep
  covering it. Run it with:
  ```bash
  forge test --match-contract PerishableBondInvariantTest -vv
  ```
- Coverage is tracked in CI (`forge coverage --report summary`). Currently
  ~96% lines / ~85% branches. Keep it at or above.

## Security

This is **unapproved, unaudited reference code for a money-handling
protocol**. Please read [SECURITY.md](SECURITY.md) and its accepted
limitations before integrating.

- **Do not** open a public issue for a suspected vulnerability. Use GitHub's
  private [security advisory](../../security/advisories/new) or email the
  maintainers (details in SECURITY.md).
- When a vulnerability is confirmed, please **give us a grace period** before
  publicly disclosing, so a patched release and advisory can ship first.

## Good first contributions shadow map

Stuck for ideas? High-value, well-scoped places to look:

- The `getBondsPaginated()` / `getAllBonds()` view layer has room for
  index-pagination edge cases.
- `_weightOf()` in the reputation registry is an explicit extension point.
- The decay curve is *documented* as swappable — an exponential/Weibull
  variant with property tests would be a great, self-contained PR.
- Frontend integration examples (anvil demo, a snapshot-driven dashboard
  component) don't exist yet.

Thank you for helping make perishable-goods financing transparent.