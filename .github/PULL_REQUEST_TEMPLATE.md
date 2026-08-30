<!-- Mark each item with [x]. Short PRs with a strong regression test beat long ones -->

## Summary

<!-- One or two sentences: what does this change do, and why? -->

Closes #<!-- issue number if applicable -->

## Changes

<!-- Bullet list of the behavior/state/functions changed -->

- 

## Tests

<!-- What did you run and what did you add? -->

- [ ] `forge fmt --check` passes
- [ ] `forge build` passes
- [ ] `forge test` passes locally (all suites, including invariants)
- [ ] Added a regression test that fails on `main` (for bug fixes)
- [ ] New state transitions are covered by the invariant handler / a new invariant, if applicable

If this is a bug fix, describe the bug and how the new test proves the fix:

## Checklist

- [ ] No unrelated changes in this PR
- [ ] Solidity pragma / dependency versions not bumped incidentally
- [ ] README or deployment docs updated if user-facing behavior changed
- [ ] No secrets, `.env`, `broadcast/`, or `cache/` files added

> Security note: if this PR could involve a fund-loss or adversarial-input
> scenario, do **not** submit it as a public PR — report privately via the
> GitHub security advisory or SECURITY.md contacts first.