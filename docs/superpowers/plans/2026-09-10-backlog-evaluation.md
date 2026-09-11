# Backlog evaluation — 2026-09-10

**Purpose:** a checkpoint, not a plan. The W-track roadmap
(`2026-09-08-backlog-remainder-roadmap.md`) was written on 2026-09-08 and has
drifted from live state in ways that change what should be done next. This
document records what was measured, what it implies, and the recommended order.
Each stage still gets its own plan document when it starts.

**Method:** every number below came from a live query on 2026-09-10, not from a
status document. Raw data:
`2026-09-10-backlog-evaluation/w3-readiness-live.tsv` (all 41 fleet repos).

## Summary

The plan is not wrong, but it is stale in a way that matters. It sequences W3
behind a wave-3 cleanup that is effectively finished, while the two things that
most threaten the project — expiring credentials and the reliability of the
single remaining judgment reviewer — are not in the backlog at all.

## 1. Credential rotation is the most urgent open work, and it is off-plan

The infrastructure design has no credential-rotation item. These sat underneath
a W-track roadmap that never looks at them. All four are `nightowlstudiollc`:

| Item | State |
| --- | --- |
| `kebab-tax#1258` | Expiring `CHANGELOG_PUBLISHER_PAT`; marked HIGH PRIORITY |
| `kebab-tax#1264` | RevenueCat API key was plaintext; rotation pending |
| `kebab-tax#1265` | Brevo API key plaintext, base64-hidden in an MCP URL |
| `amelia-boone#79` | CI red since 08-30; 4 advisories off-baseline, 1 crit |

An expiring PAT carries a deadline the backlog does not. These go first.

## 2. W3 is much closer than the record says, and wave 3 is no longer its blocker

Live re-measure of all 41 fleet repos, versus the 2026-09-08 table in
`docs/STATUS.md`:

| Measure | STATUS.md (2026-09-08) | Live (2026-09-10) |
| --- | --- | --- |
| green | 9 | **33** |
| red / failure | 15 | **1** |
| never-ran | 17 | **7** |

Roughly 13 repos were swept on 2026-09-10 on branches `…-4b6b87fc` and
`…-5e330f69`. All merged; none recorded in `STATUS.md`. No wave-3 PR is open
fleet-wide.

The one `failure` is `nightowlstudiollc/kebab-tax`, whose two most recent
`standards-check` runs are both from 2026-09-09 — **before** the changed-files
scoping fix landed. It is a stale red, not a current one, and needs a fresh run
rather than a fix.

**The dependency between wave 3 and W3 has dissolved.** Once
`github-workflows#165` scoped the four enumerating linters to changed files, the
required-check contract became *"no new debt in files this PR touches"*, not
*"this repo is clean."* The roadmap still sequences W3 behind whole-repo
cleanliness, which the check no longer asks for. Whole-repo hygiene belongs on a
background track behind the `standards:hygiene` label.

`standards-check` is required on **zero** repos, so W3 has not started anywhere.
Three repos have no branch protection at all (`claude-config-backup`,
`superpowers`, `superpowers-marketplace`) — consistent with the dev-env#89
decision to leave them ungated.

### The real W3 gate: the whole-repo fallback rate

When the base-SHA fetch fails, `standards-check` falls back to a whole-repo
sweep rather than linting zero files. That was a deliberate fail-closed choice
and it is the correct default. But it is not rare:

**The fallback fired in 4 of 15 recent runs sampled across 8 repos (~27%)** —
`twistedmelonman/claude-config` three times, `smartwatermelon/dev-env` once.
All four runs passed, so the behavior is currently invisible.

It stops being invisible the moment the check becomes required: on a repo still
carrying whole-repo debt, a fallback turns a routine PR into a hard block for
reasons its author cannot see in the diff. **Measure and address the fallback
rate before flipping W3, not after.** This is the gate; whole-repo cleanliness
is not.

## 3. "Local hooks are the only judgment pass" still holds, but its subject is unowned

The 2026-09-08 decision removed the judgment reviewer from CI. Evidence filed
*after* that decision, all against the local reviewer that now carries the load
alone:

- `claude-config#488` — fabricated a blocking security finding against a file
  that does not exist
- `claude-config#455` — non-deterministic across repos; rejects direct
  documentation evidence
- `claude-config#489` — full-diff pre-push review has no access to the commit
  message or PR intent
- `claude-config#481`, `claude-config#496` — scoping and behavior defects

`dev-env#116` independently supports keeping judgment out of CI:
`claude-code-action` structurally refuses to review any PR touching
`.github/workflows/`, so the class of change most worth reviewing is the class
CI cannot review at all.

**The decision stands. The consequence is unowned.** Local-reviewer reliability
is now critical-path, and nothing in L2–L5 targets it. This is the largest gap
the evaluation found. It should become an explicit L item.

## 4. The auto-filed findings loop is converging — measured, not assumed

Review tooling that files its findings as issues is a classic self-feeding
backlog: every push that fixes issues seeds the next round. Applying the
convergence metric from `converging-issue-backlogs`:

**"Non-blocking review findings from PR #N" issues: 80 closed, 13 open.**

Comfortably draining; `spawn_ratio` well below 1.0. No intervention needed.
Recorded here so the pattern is not "fixed" reflexively on the strength of its
shape.

Fleet totals (413 open issues across three orgs) are dominated by
`nightowlstudiollc` product backlog — kebab-tax features, cleanroom Phase 0.5,
financial-agent Plaid work. Out of scope for infrastructure; the raw count
should not drive priority.

## 5. The merge gate is nominal, and the fix is to meet the human where they merge

`docs/STATUS.md` records it plainly: **merge locks actually typed by Andrew: 2.**
Every other W2 merge went through the GitHub UI. `dev-env#109` records that
merge authorization is laptop-only, so mobile forces a silent bypass.

Every downstream control assumes this gate holds. Today it is decorative.

**Decision (Andrew, 2026-09-10): make the lock reachable from mobile.** Treat
UI and mobile merging as legitimate and build authorization that works there.
This promotes `dev-env#109` and `dev-env#101` (merge-lock TUI) from housekeeping
to infrastructure-critical: they are what makes the authorization model true
rather than nominal.

## 6. dev-env#114 is scoped separately

`dev-env#114` — "deprecate extensive claude instructions in favor of
deterministic non-skippable checks" — is a thesis that would re-sort the entire
backlog. `#111` (test execution time ceiling), `#112` (emergency protocol) and
`#113` (standards-check failure descriptions) cluster with it.

**Decision (Andrew, 2026-09-10): scope it first, separately.** It gets its own
design session. Backlog ordering is left alone here rather than pre-empted.

## Record drift to correct

- `docs/STATUS.md` reports wave 3 as "not started: the 17 `never-ran` repos".
  Live: 7 never-ran, 33 green. The 2026-09-10 sweep is unrecorded.
- `docs/STATUS.md` cites `#62` as the `repo-template` stale-copy issue. Live
  `#62` is "Reconcile inconsistent .claude/ tracking across ~/Developer repos" —
  a label/thing mismatch of exactly the kind the standing methodology warns
  about.

## Recommended order

| Order | Work | Why it is here |
| --- | --- | --- |
| 1 | Credentials: `#1258`/`#1264`/`#1265`, `#79` | Has a deadline; off-plan |
| 2 | Investigate the ~27% whole-repo fallback rate | The actual W3 gate |
| 3 | **W3** — `standards-check` required | Wave 3 no longer gates it |
| 4 | New L item: local-reviewer reliability | Sole judgment gate, unowned |
| 5 | `dev-env#109` + `#101` — mobile merge auth | Makes the merge gate real |
| 6 | `dev-env#114` design session | Re-sorts the rest; scope before acting |

Whole-repo lint hygiene runs as a background track behind `standards:hygiene`,
not as a blocker on anything above.

## Standing methodology, reconfirmed

Both disciplines paid out again in this evaluation:

**Resolve the thing; don't match its label.** A `standards-check` run reporting
`success` is a claim about changed files, not about the repository. `null` in a
jq-rendered readiness table is a stringified absent record, not a state. `#62`
names a different issue than the document citing it assumes.

**Validate every fix against a known-bad case.** The fallback path is the open
instance: it is correct by construction and has never been observed failing a
PR, because nothing has yet made it block one. Its 27% firing rate is only
harmless while the check is non-required.
