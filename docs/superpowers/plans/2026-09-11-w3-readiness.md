# W3 readiness — measured 2026-09-11

W3 is the step that flips `standards-check / run-standards-check` from an
advisory check to a **required** one, per repo. This document measures what is
actually ready, and proposes an order.

It supersedes the readiness numbers in the 2026-09-10 evaluation, which were
measured with a classifier that produced two wrong answers (see
[Measurement notes](#measurement-notes) — both are recorded because the errors
are more instructive than the numbers).

## Headline

**There is no longer a fallback gate.** The 2026-09-10 evaluation ranked
"investigate the ~27% whole-repo fallback rate" as the blocker ahead of W3.
Re-measured, that rate is **zero** (dev-env#121). Nothing structural stands
between here and flipping checks.

What remains is ordinary per-repo readiness, below.

## Fleet state

44 active (non-archived) repos across the three orgs.

| Bucket | Count | Meaning |
| --- | --- | --- |
| **Ready** — stub present, newest PR green | 34 | Flip candidates |
| Stub present, no PR since rollout | 5 | Unexercised, not broken |
| Stub present, no PRs ever | 1 | `claude-config-backup` |
| Stub present, newest PR red | 1 | `kebab-tax` — deferred by decision |
| **No stub** | 3 | 1 ignored by decision, 2 forks — see below |

`standards-check` is required on **zero** repos today, so W3 has not started
anywhere. That zero was validated against a positive case rather than trusted:
the same query returns `["claude-review / run-review"]` for `dotfiles`,
`claude-config` and `dev-env`, so it demonstrably *can* report a required
check, and reads empty for `standards-check` because it genuinely is.

### Why 44 here and 41 in the 2026-09-10 evaluation

The earlier document measured "all 41 fleet repos". The three additional repos
are **exactly the three with no stub** — but for three different reasons, and
only one of them is a gap:

| Repo | Why no stub |
| --- | --- |
| `nightowlstudiollc/networth-agent` | **On the ignore list, deliberately** |
| `twistedmelonman/homebrew-brew` | Fork, created 2026-08-24 |
| `twistedmelonman/Instapaper-MCP` | Fork, created 2026-07-29 |

`bulk-install-standards-check.sh` enumerates live (`gh repo list --limit 200`);
it has no fixed inventory. It reads `.standards-check-ignore`, which contains
exactly one entry: `nightowlstudiollc/networth-agent`. So that repo is not an
oversight — someone decided it should never receive the stub, and this document
should not quietly reverse that.

The two forks are not on the ignore list and the script does not filter forks,
so their absence is unexplained by configuration. Whether forks *should* carry
the check is a real question — they are not where this fleet's work happens —
but it is a decision, not a gap to close silently.

### No stub (3)

- `nightowlstudiollc/networth-agent` — **on `.standards-check-ignore`.** It has
  live PR traffic (newest 2026-09-10) and would exercise the check immediately,
  which makes it tempting to seed; do not, without reversing that decision
  explicitly. The ignore file is the only record of the reasoning, and it does
  not state one.
- `twistedmelonman/homebrew-brew` — fork, no PRs ever.
- `twistedmelonman/Instapaper-MCP` — fork, newest PR 2026-08-07.

`smartwatermelon/github-workflows` is a special case worth stating precisely,
because a naive contents query gets it backwards. It **does** have
`.github/workflows/standards-check.yml` — but that is the reusable *definition*
(`on: workflow_call`), not a caller stub. It cannot call its own tag, so it
dogfoods itself through `self-standards-check.yml`, which invokes the local
path on its own PRs. That caller produces a check-run named
`standards-check / run-standards-check`, identical to every other repo's, so it
is counted as ready and W3 applies to it normally.

### Stub present, unexercised (5)

`vpn-lan-bridge`, `crazy-larry`, `homebrew-tap`, `superpowers-marketplace`,
`x-thread-reader`.

Every one of these landed its stub on **2026-09-09**, and every one's newest PR
predates that date. The check has therefore never run on them — not because it
fails, but because no PR has opened since. Their first PR after a flip would be
the first time the check runs *and* the first time it blocks, simultaneously.

That is the one place where flipping creates real risk: an unexercised required
check on a repo carrying unknown debt. The mitigation is cheap — open a
throwaway PR (or push any trivial change) and read the result before flipping.

### Red (1)

`nightowlstudiollc/kebab-tax` — the only repo whose newest PR shows the check
failing. Deferred by Andrew's 2026-09-10 decision ("kebab-tax can hold"), so it
is out of scope here rather than unresolved.

## Proposed order

1. **Pilot on 2–3 known-good repos.** `dev-env`, `claude-config`, `dotfiles` —
   all high-traffic, all green, all repos where a mistake is noticed within
   hours. Flip, then watch the next few real PRs before widening.
2. **Widen to the remaining ready repos** (31 more) once the pilot has ridden
   several PRs without a surprise.
3. **Exercise the 5 unexercised repos first**, then flip them. Do not flip an
   unexercised check.
4. **Do not seed the 3 missing stubs without a decision.** `networth-agent` is
   on `.standards-check-ignore` deliberately; the other two are forks. Each
   needs Andrew's call, not a sweep. See the table above.
5. **`kebab-tax`** rejoins whenever its deferral lifts.

Steps 1–2 are the bulk of the value and carry the least risk. Steps 3–5 are
cleanup that does not block them.

## What flipping actually requires

Branch protection is **per repo**, not org rulesets — `nightowlstudiollc`'s org
ruleset is `enforcement=disabled`, so the exemplar settings live on individual
repos. Each flip adds `standards-check / run-standards-check` to that repo's
`required_status_checks.contexts`.

**This is an add, not a replace.** All three pilot repos today require exactly
one check:

| Repo | `required_status_checks.contexts` |
| --- | --- |
| `twistedmelonman/dotfiles` | `claude-review / run-review` |
| `twistedmelonman/claude-config` | `claude-review / run-review` |
| `smartwatermelon/dev-env` | `claude-review / run-review` |

W3 adds a second entry alongside `claude-review`; it does not displace it. Any
decision to *remove* `claude-review / run-review` is separate work and is not
part of W3.

Five repos have **no branch protection at all**: `claude-config-backup`,
`superpowers`, `superpowers-marketplace`, `homebrew-brew`, and
`Instapaper-MCP`.

The first three are covered by dev-env#89, which left them unprotected
deliberately: at the time there was no review workflow to require, and
protection without a required check would have been worse than none. That
rationale is now partly stale — `standards-check` *is* a workflow these repos
could require — so #89's premise is worth revisiting rather than assuming it
still decides the question. The other two (`homebrew-brew`, `Instapaper-MCP`)
are not part of #89 and have no recorded decision.

Either way, a required check cannot be added without first adding protection,
which is a larger decision than W3 and should not be smuggled in as a side
effect of it.

## Measurement notes

Both errors below are recorded deliberately. Each produced a confident wrong
number from a query that looked correct.

**1. Matching a label instead of resolving the thing.** The first sweep asked
`gh run list --workflow standards-check.yml` per repo and read the newest
conclusion. That reported `github-workflows` as `never-ran` — but its check had
passed minutes earlier on PR #166. The repo runs `self-standards-check.yml`;
the filename was the label, not the state. Re-measuring by **check-run name on
the newest PR's head SHA** — which is what branch protection actually keys on —
gave the real answer.

**2. A 404 swallowed into a truthy value.** `gh api .../contents/... --jq '.sha'`
prints GitHub's JSON error body on a 404 and still exits through the pipeline,
so a missing file read as present. That reported 44 of 44 repos carrying the
stub. Testing the **exit status** instead of the output found 41, with 3
genuinely missing — including `networth-agent`, which is what exposed the bug:
its stub-commit history came back empty while the stub check said present. Two
signals disagreeing is what caught it; a single signal would have shipped.

**3. A near-miss worth more than either.** The first draft of this document
told a plausible story about the 41→44 delta — that the bulk-install sweep
worked from a stale 41-repo inventory — and recommended seeding
`networth-agent` first. Both were wrong. The script enumerates live
(`gh repo list --limit 200`) and has no inventory; and `networth-agent` is on
`.standards-check-ignore` **deliberately**. Acting on that recommendation would
have reversed someone's explicit decision while believing it was closing a gap.

The story was coherent, consistent with every number on the page, and invented.
It survived until the script was actually opened. Chesterton's Fence applies to
absences too: a missing file is a decision until proven otherwise.

The general rule, which the withdrawn fallback finding also illustrates: a
measurement that cannot return a negative has not been validated. Check it
against a case you know should come back the other way — and when you explain
*why* a number is what it is, read the mechanism rather than constructing an
explanation that fits.
