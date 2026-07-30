# Upgrading to 0.6.0

0.6.0 adds `uc rebind` and `uc unbind`, and with them a new event in the binding
ledger: `binding_released`. The binding registry is a persisted file format, and
persisted formats are part of the [public contract](../reference/stability.md) —
so this note says exactly what moves, what does not, and what to do about it.

**The short version.** Upgrading changes nothing about a project that carries on
as before. The moment someone runs `rebind` or `unbind`, that workspace requires
0.6.0 for everyone who touches it.

## What does not change

An existing project that upgrades and keeps working the way it always has sees
**no difference at all**. This is mechanically enforced, not asserted:

- `tests/release/upgrade-contract-0.5.5.test.ts` replays the 16-step daily loop
  over a fixed workspace and compares **1295 JSON key paths** against a contract
  captured from the real published 0.5.5 binary. Its declared-changes list is
  empty: any key, type, shape, scalar value, or exit code a 0.5.5 consumer could
  observe differing fails the build.
- A rehearsal on a project built by 0.5.5 — bound, verified, and signed to
  `FRESH` in trusted CI — confirms that after swapping only the binary, the
  signed row is still `FRESH`, the unsigned row is still `UNPROVEN`, the
  `--gate` exit code is unchanged, and every `row_hash`,
  `current_binding_set_hash`, `verification_policy_hash`, and
  `approval_policy_hash` is bit-identical.

Reading is one-way compatible: 0.6.0 reads every ledger any earlier version
wrote, unchanged.

## What changes, and when it bites

`binding_released` is an event type older versions have never seen, and their
event schema pins `event_type` to a single constant. So:

| Situation | Result |
|---|---|
| Upgrade, keep using `bind` / `verify` / `scan` / `prove` | Nothing changes. A 0.5.5 client can still read the ledger you write. |
| Anyone runs `rebind` or `unbind` in the workspace | That workspace now needs 0.6.0. A 0.5.5 client exits `4` with `REGISTRY_SCHEMA_INVALID`. |

A staggered rollout is therefore safe right up until the first `rebind` or
`unbind` — which is the useful property, because it means you can upgrade
gradually and choose when to cross the line.

**It fails closed.** A 0.5.5 client meeting a released ledger reads nothing it
misunderstands and writes nothing at all: it cannot half-apply the ledger, and it
cannot corrupt it. That is deliberate. The alternative — an older client silently
ignoring the release event and acting on a registration that has ended — would
have it disagree about which code is bound while reporting success.

## What to do

1. **Upgrade CI and every developer to 0.6.0** before anyone uses the new
   commands. `uc --version` on each surface is the check.
2. If your CI pins a version, bump the pin in the same change that introduces
   the first `rebind` / `unbind`.
3. Until both are done, the old commands work exactly as they did. There is no
   rush and no forced migration step — no ledger rewrite, no re-binding, no
   re-proving.

## If you need to go back

The ledger and the markers it describes are committed together, so a rollback is
an ordinary `git revert` of the commit that introduced the `rebind`/`unbind` —
after which 0.5.5 reads the workspace again and signed proofs are still intact.
Rehearsed as part of this release, along with the corruption check: a stranded
0.5.5 client left the ledger byte-identical. The rehearsal is
`scripts/rehearse-upgrade.sh <path-to-old-uc>` — 13 assertions over the whole
sequence above, re-runnable against any previously-published binary.

Do **not** hand-edit `.use-cases/bindings.jsonl` to strip release events. The
ledger is append-only and checked against its git base ref; deleting lines is a
violation the tool will report, and `uc unbind` / `uc rebind` exist precisely so
you never need to.
