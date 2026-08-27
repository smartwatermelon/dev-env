# Review Pipeline Redesign — Design

**Status:** In implementation. Item 1 shipped (dotfiles#283), item 3 shipped
(claude-config#442), items 2 and 4 in flight, item 5 dropped. The severity
transport was additionally reworked to a schema-constrained boolean
(claude-config#443, phase 1 in #444) — see Revision history.
**Date:** 2026-08-26 (revised 2026-08-27 — see Revision history)
**Scope:** `claude-config/hooks/run-review.sh`, `claude-config/hooks/lib-review-issues.sh`,
`dotfiles/git/hooks/pre-push`, `dotfiles/git/hooks/commit-msg`

## Problem

The pre-push reviewer files GitHub issues for trivial findings, and the
fix-then-re-review loop does not converge. Working around it with a `--no-file`
dry run and fixing findings before pushing does not terminate either: the
reviewer almost always finds something new.

## Summary of changes

1. **Move the whole-codebase scan off the push path** — weekly plus `/audit`,
   narrowed to the classes no other layer covers. (Not deleted: measurement showed
   55% of its genuine findings have no successor.)
2. **Add a `FIX_NOW` severity tier** — printed at commit time, blocks nothing,
   files nothing. Redundant comments route here.
3. **Fix the blocking gate**, which currently leaks on three of four plausible
   reviewer output formats.
4. **Port anti-noise language** to the four prompts that lack it.
5. ~~**Cache FAIL verdicts**~~ — **dropped 2026-08-27**; it collides with
   claude-config#246 and the cache key defeats its cost premise. See §5.

## Diagnosis

The non-convergence is a **schema** defect, not a prompt defect.

claude-config#434 states the mechanism directly:

> `CLASSIFICATION` asked exactly one question: BLOCK (introduced) vs
> NON_BLOCKING_ISSUE (pre-existing). That axis is *when a thing originated*, not
> *whether it matters*. There was no severity concept anywhere in the prompt, and
> `lib-review-issues.sh` gates only on dedup — it has no severity field at all, so
> every emitted block becomes an issue unconditionally.

Three structural causes follow:

1. **Unbounded search space.** `--mode=codebase` hunts *pre-existing* defects
   across the whole repository. A diff is finite; a repository's imperfections are
   not. Each run samples a fresh subset of an effectively infinite pool, so the
   series cannot converge regardless of prompt quality.

2. **No severity field in the filing layer.** `lib-review-issues.sh` gates only on
   dedup. Anything the reviewer emits is filed. There is no floor.

3. **Dedup matches open issues only.** `gh issue list --state open`
   (`lib-review-issues.sh` ~L646). A finding closed as wontfix is invisible to
   dedup and is re-filed on the next push. Rejected concerns return forever.

### Evidence that prompt-tuning is exhausted

claude-config#434 was a rigorous prompt fix — a DO-NOT-FILE list, a self-check for
findings that concede they are fine, and a mandatory Kind A / Kind B split forcing
runtime-behaviour claims into question form. It validated at **0 findings** on a
branch that previously produced 5. It shipped. Issues #431 and #432 were filed
anyway.

Fourteen consecutive commits on the reviewer each added another suppression gate:
328, 331, 336, 337, 338, 380, 389, 411, 417, 419, 425, 428, 434.
**38 of 100** claude-config commits since 2026-06-01 touch `hooks/`.

### Measured signal-to-noise

**Fleet-wide: 876 auto-filed issues across 19 repos — 46% of all issue volume in
those repos (1,921 total).** Identified by the `*Created by lib-review-issues.sh*`
footer. Some repos are almost entirely machine-generated: qwen-sidebar 100%,
claude-wrapper 90%, mac-dev-server-setup 83%, github-workflows 80%, dotfiles 75%.

Mean 2.09 issues per review run across 420 runs; max 17 in a single run.

**Classified random sample (n=40):**

| Category | n | % |
|---|---|---|
| documentation nit | 10 | 25.0% |
| genuine design/maintainability | 10 | 25.0% |
| style/formatting nit | 7 | 17.5% |
| speculative/hypothetical | 6 | 15.0% |
| real correctness bug | 4 | 10.0% |
| false positive / wrong | 2 | 5.0% |
| real security issue | 1 | 2.5% |

**Only 12.5% are real correctness or security findings.** 57.5% are doc nits,
style nits, speculative, or false positives.

**The bodies convict themselves.** Across all 876:

- **63.0%** contain `Consider…` / `Worth…` / `Suggest…` — a suggestion, not a defect
- **16.7%** use conditional-failure framing (`could fail`, `very low risk`)
- **13.9%** self-deprecate: `not a bug`, `harmless`, `cosmetic`, `no runtime risk`
- **13.5%** say `pre-existing` / `not introduced by this diff`
- **1.7%** say `no action required` outright

Roughly one in seven states in its own body that nothing is wrong.

There is **no severity field**. Only 6% mention severity at all, as prose. The sole
triage signal is a `tech-debt` label carried by 81% of them.

Corroborating, from #434 on the 18 claude-config issues: all 18 closed — a 100%
close rate means the filing threshold carries no signal. ~8 real bugs, ~6
factually wrong, ~3 conceding in their own text that no change was needed.

### Closure is not convergence

Of 806 closed: p10 0.17h, median **42.2h**, p75 **1,934h (81 days)**, p90 2,737h
(114 days), max 133 days. 46% close within 24 hours; the rest sit for two to four
months.

The distribution is bimodal — closed-immediately versus closed-in-bulk-months-later.
The 92% closure rate is consistent with periodic bulk cleanup, **not** with the loop
converging. A low open count is not evidence of health.

### The duplication is intra-run, not cross-push

19 same-repo near-duplicate title pairs. **Median gap between pairs: 72 seconds.**
17 of 19 were filed within 25 minutes — i.e. within a single review pass. Only one
pair (mac-dev-server-setup #13/#16, 68.6h apart) is a true cross-push recurrence.

This corrects the intuitive reading. The loop does not fail because fixes
regenerate findings. It fails because **one pass emits the same finding two or
three times**, and because a fallback queue silently accumulates (dotfiles#231: 43
unfiled findings in `~/.claude/pending-issues/` with no drain path; dotfiles#247,
still open: 13 more recovered).

The open-only dedup gap is therefore a **secondary** cause, not the primary one.

### The mitigations made it worse

Batching (#389) cut issues **per run** from 2.15 to 1.88. But counting checklist
items inside the batched issues individually, **true findings per run rose 2.15 →
2.52.** The mitigation reduced the issue count while the underlying noise grew.

The dedup gate has documented holes: claude-config#330 (a 200-issue listing cap
silently disables it) and a code comment at `lib-review-issues.sh:543` noting that
findings with `LOCATION "general"` or empty are **never** deduped.

## Separate defect: the blocking gate leaks

Independent of the noise problem, and more serious.

All five severity checks use a bare, case-sensitive, space-exact grep
(`run-review.sh` lines 872, 1221, 1460, 1747, 1833):

```bash
grep -q "SEVERITY: BLOCKING"
```

`parse_verdict` (L188) is by contrast case-insensitive and strips markdown
(``tr -d '*`_'`` plus `grep -qiE`). Falsified against known-bad cases:

| Reviewer output | Result |
|---|---|
| `SEVERITY: BLOCKING` | BLOCKS |
| `**SEVERITY:** BLOCKING` | **SLIPS THROUGH** |
| `Severity: Blocking` | **SLIPS THROUGH** |
| `SEVERITY:  BLOCKING` (two spaces) | **SLIPS THROUGH** |

Markdown bolding is a likely emission from a prose-heavy prompt. Real blocking
defects currently pass the gate.

## Design

### 1. Move `--mode=codebase` off the push path

**Revised 2026-08-26 after coverage measurement.** The original design deleted this
mode outright. Measurement showed 55% of its genuine findings have no successor
layer (see "Coverage of the findings this gives up"), so the capability is kept and
the *cadence* changes instead.

**Remove the invocation from `dotfiles/git/hooks/pre-push`** — the second of two
parallel calls in `run_reviews()` (~L573). Nothing about a whole-codebase scan
belongs on a per-push trigger: pre-existing defects do not appear between pushes,
so running it per push buys nothing and costs a Sonnet call, a false-positive tax,
and the non-convergence.

This alone removes:

- the unbounded search from the push path,
- the intra-run duplication (72-second median gap),
- one of two parallel Sonnet calls receiving the *same* full branch diff,
- every auto-filed issue from a push.

**Keep the mode in `run-review.sh`**, reachable two ways:

| Trigger | Cadence | Purpose |
|---|---|---|
| Scheduled sweep | Weekly, fleet-wide | Catches drift without depending on memory |
| `/audit` | On demand | For when a specific suspicion needs checking |

`lib-review-issues.sh` stays wired, but is now reached only from these two paths.

Two constraints follow from the measurement, and they are what make the retained
mode worth keeping rather than a slower version of the same problem:

- **Scope it to the classes that have no successor.** 64% of genuine findings are
  shell, where shellcheck and semgrep both measured at effectively zero. The
  largest and most dangerous group is silent-failure guards — a check that reports
  success when it did nothing. The prompt should hunt that pattern by name.
- **Apply the same severity floor as everything else.** Off-push cadence removes
  the convergence pressure but not the noise obligation. A weekly run that files
  20 doc nits recreates the problem at a slower rate.

**Drain the fallback queue before the first scheduled run.**
`~/.claude/pending-issues/` historically accumulated ~43 unfiled findings with no
drain path (dotfiles#231), plus 13 recovered in dotfiles#247 (still open). Verified
2026-08-26: it now holds **1** file, so the earlier backlog is drained. Triage that
one by hand. The queue needs a real drain path before a recurring producer feeds it
again.

### 2. Three-tier severity taxonomy

Replace the binary `BLOCKING` / `WARNING` contract:

| Tier | Meaning | Action |
|---|---|---|
| `BLOCKING` | A defect **introduced by this diff** | Blocks the commit/push |
| `FIX_NOW` | Small, mechanical, fixable in the current round | **Printed only.** Blocks nothing, files nothing |
| *(omitted)* | Everything else | Not reported at all. No third channel |

`FIX_NOW` has **no filing path in the code** — not a disabled one, an absent one.
That absence is what prevents it becoming the next firehose.

`FIX_NOW` applies at the **commit stage**, the cheapest moment to apply a fix and
early enough that full-diff and CI never see the finding.

**`FIX_NOW` must not inherit the hedging problem.** 63% of current issue bodies are
phrased `Consider…` / `Worth…` / `Suggest…`; unguarded, that language would simply
move from GitHub to the terminal on every commit. Constraints:

- A `FIX_NOW` entry is **one line**: `file:line — what to change`. No rationale,
  no DETAILS block. Current median body is 124 words; the target here is under 15.
- It must name a **concrete edit**. If it cannot be expressed as a specific change
  to a specific line, it is not `FIX_NOW` and is not reported.
- The DO-NOT-FILE phrasings (`consider`, `worth noting`, `may want to`,
  `for the next person`) are banned outright in this tier — that phrasing is the
  tell that the reviewer already decided it is not a defect.
- Cap the number emitted per commit (suggest 5). Beyond that, print a count only.
  A commit generating more than 5 mechanical fixes signals a calibration problem
  worth seeing as one number rather than a wall of text.

**Canonical `FIX_NOW` cases.** The tier is defined by these, not by a general
invitation to comment on quality:

| Case | Why it belongs here |
|---|---|
| Comment that only restates its line | User-requested filter; editing-time fix, never an issue |
| Unused import or dead local | Mechanical, one-line, unambiguous |
| Missing quote on a variable expansion | Concrete edit at a known `file:line` |
| Leaked temp file with no `trap` | Small, and the fix is a single added line |

Anything that cannot be stated as one of these — a concrete edit to a named line —
is not `FIX_NOW`. It is `BLOCKING` or it is omitted.

### 3. Fix the severity match

Replace all five bare greps with the tolerant form already used by
`parse_verdict`:

```bash
printf '%s\n' "${out}" | tr -d '*`_' | grep -qiE 'SEVERITY:[[:space:]]*BLOCKING'
```

Pin the true positives first: build a corpus of the variants that must still match
before changing the pattern, then re-run. A matcher loosened without that corpus
is one character from silently un-blocking a real finding.

### 4. Port anti-noise language to the prompts that lack it

The DO-NOT-FILE list, the self-check, and the Kind A / Kind B verification split
exist **only** in the codebase and CI prompts. The `commit`, `full-diff`,
`chunked`, and `arbiter` prompts are ~20 lines each with no severity calibration
and no anti-nitpick guidance.

Extract the shared block into one variable that every prompt includes.

**Keep** item 5 of the commit prompt ("flag comments that only restate what the
code already says") and route it explicitly to `FIX_NOW`.

This filter exists because of direct user feedback, not reviewer drift. Excessive
commenting is a real thing to catch, and pre-commit is the right stage: it is the
editing moment, before the comment reaches a diff anyone else reads.

What was wrong was not the filter but its lack of a home. Under the old binary
taxonomy a redundant comment could only block the commit or vanish; there was no
tier for "worth editing, not worth stopping for." Redundant comments are the
canonical `FIX_NOW` case — small, mechanical, fixable in the round, and never
worth a GitHub issue.

Pin this with a test so a later noise-reduction pass does not quietly delete it:
a diff containing a comment that restates its line must produce a `FIX_NOW` entry,
exit 0, and no filing call.

### 5. Cache FAIL verdicts — DROPPED

**Status: dropped 2026-08-27.** Retained here because the reasoning matters and
the idea is otherwise easy to re-propose.

The original proposal: the cache is PASS-only, keyed on `(SCRIPT_SHA, diff)`. A
FAIL always re-runs, so an iterating commit pays full price on every attempt.
Cache FAIL under the same key.

**Why it was dropped.** It collides with the claude-config#246 fix, and its cost
premise does not survive contact with the cache key.

*The collision.* Today a code-reviewer FAIL is the one verdict guaranteed to be
re-derived live on every retry. That property is load-bearing. In the #246
incident, code-reviewer FAILed an identical diff three times running on a
**fabricated** claim — that `clear_round_feedback` was "not defined", when it was
defined in the same file and already called twice. Attempt 4 passed clean, first
try, with no change other than `rm -rf .git/claude-review-cache/` forcing a live
call. Caching FAIL would freeze that fabricated finding and replay it on every
subsequent attempt at the same diff.

The two changes also interact badly. #246's fix (`run-review.sh` ~L1795) forces
adversarial-reviewer **live** during a retry-after-FAIL, precisely so the arbiter
gets fresh evidence. Caching FAIL would make code-reviewer **stale** on that same
path — reinstating the provenance asymmetry #246 fixed, with the sides swapped.

*The cost premise.* The cache key includes the diff. Fix the code and the key
changes, so the review re-runs regardless; caching FAIL saves nothing there. It
helps only on a retry with a **byte-identical** diff — which is exactly the #246
scenario, the one case where re-running is the desired behaviour. The savings
land almost entirely on the case where staleness does harm.

*What remains true.* The underlying complaint — an iterating commit is slow — is
real and unaddressed. If it is worth fixing, it needs a different mechanism (for
example, avoiding the second reviewer when the first passes clean) and its own
design work. Do not reach for FAIL caching again without first re-reading #246.

## Cost

Model assignments are unchanged by explicit decision. Savings come from removing
calls, not from downgrading models.

| Measure | Before | After |
|---|---|---|
| Sonnet calls per push | 2 (identical diff) | 1 |
| LLM calls per full cycle | 6–7 | 5–6 |
| Commit retry, unchanged diff | full re-review | unchanged — item 5 dropped |
| Auto-filed issues per push | 1 batched issue, 1–3 findings | 0 |
| Whole-codebase scans | ~420 runs (per push) | ~1/week + on demand |

The codebase scan is not eliminated, so its cost is not eliminated — it is moved
from ~420 per-push runs to roughly weekly. At 2.09 issues per run, that is the
difference between a continuous issue stream and a reviewable weekly batch.

## Coverage of the findings this gives up

This section drove the revision to §1. It answers directly: if the whole-codebase
scan stops, what catches its genuine findings instead?

**Sample:** 69 genuine correctness/security findings, hand-triaged from 484
auto-filed issues across all eight repos.

| Outcome | Count | Fraction |
|---|---|---|
| Caught by a surviving layer (pre-commit / full-diff review) | 31 | 45% |
| Caught by **nothing** | **38** | **55%** |

Extrapolated to the ~110 genuine findings fleet-wide: **~60 would be lost.**

### The determinant is introduced-vs-pre-existing, and nothing else

The split is perfectly clean. **Every introduced finding (31) is caught; every
pre-existing finding (38) is lost.** No other layer moved a single case in either
direction. Method: `git blame` / `log --diff-filter=A` on each flagged `file:line`
at the commit preceding the issue's `createdAt`.

21 of the 38 are more than a month old; the oldest are 8–12 months. A diff-scoped
reviewer structurally cannot see these.

### The fallback layers measured at approximately zero

Each tool was validated against a known-bad control first, so a clean result means
something:

- **shellcheck** — run at `-S info` against the *historical buggy* file versions
  (`git show` at the bug commit): zero relevant findings. A synthetic control
  correctly produced SC2206/SC2086/SC2128, so the tool was working. These bugs are
  semantic — SIGPIPE interaction, trap scope, guard ordering — not lint-shaped.
  Sharper still: `scripts#26`'s SC2206 was **silenced by an inline
  `# shellcheck disable=SC2206`**. The codebase reviewer caught exactly what
  shellcheck had been told to ignore.
- **semgrep** — 1201 rules executed, **0 findings**, including on a known-bad
  control. Structural cause: it loaded **4 bash rules against 1151 Python rules**,
  and **64% of the genuine findings (44/69) are shell**.
- **tests** — several lost findings *are* test-suite defects (scripts#154,
  claude-wrapper#85). The tests are the broken thing; they cannot self-catch.
- **CI `claude-blocking-review.yml`** — fetches its own diff, inheriting the
  identical diff-scope blind spot. Not a rescue layer.

Note this corrects an assumption worth stating: semgrep's pre-push invocation sets
`SEMGREP_BASELINE_REF=origin/main` (and `--baseline-commit origin/main` on the
no-token path), deliberately, to match CI PR behaviour. It is **diff-aware, not
whole-repo**. Every surviving automated layer is diff-scoped.

### What the lost findings have in common

Four recurring shapes, one shared property:

1. **Silent-failure / false-OK guards** — the largest and most dangerous group. A
   check that reports success when it did nothing: SIGPIPE making the reviewer
   silently skip a real diff (claude-config#166); `sha256sum` absent on macOS
   silently disabling the cache (#126); a `log show` permission failure returning
   count=0 (scripts#112); a tier check bypassed when JWT validation fails
   (kebab-tax#1097).
2. **Security / injection in old shell** — osascript URL interpolation
   (scripts#45), stderr corrupting a captured password (#28), UTF-8 password
   mangling (#30). All ~8 months old.
3. **Resource and lifecycle leaks** — claude-config#90, dotfiles#31,
   claude-wrapper#70/#74, kebab-tax#1130.
4. **Bypassable guards in the enforcement infrastructure itself** —
   claude-config#267 (`git worktree list | git worktree add` defeats the block),
   #340, dotfiles#205.

The unifying property: **these are visible only when reading a whole file, not a
hunk.** Most are "this guard does not guard" — invisible in a diff because the diff
never touches the guard, and invisible to linters because the code is syntactically
clean.

### Caveats, stated rather than smoothed over

- "Pre-commit review catches it" is **plausible, not confirmed**. The analysis
  verified the defective code was inside the reviewed diff — a necessary but not
  sufficient condition — without confirming those reviewers actually flag each one.
  The true caught count is ≤31, so **55% lost is a floor, not a point estimate**.
- 69 is a hand-triaged sample of 484. The genuine-finding rate is consistent with
  the 12.5% figure, but the introduced/pre-existing ratio could shift on a full
  census.

### Conclusion

The 45% that overlaps pre-commit review is genuinely redundant and safe to drop.
The 55% has no successor and is disproportionately the security-relevant,
silent-failure end of the distribution, concentrated in shell where both linters
measured at effectively zero.

Deleting the mode outright would remove the only layer that reads code the current
diff did not touch. Moving it off the push path keeps that coverage while removing
every mechanism that caused the non-convergence.

## Side-finding: shellcheck does not run in claude-config

Not part of this redesign, but it bears on the coverage question.

`lint-shell.sh` (shellcheck at `--severity=warning`, auto-applying fixes) is wired
through the **global** pre-commit framework config
(`dotfiles/pre-commit/config.yaml:82`), not the global git `pre-commit` hook.

`claude-config/.pre-commit-config.yaml` is `repos: []`, deliberately, to avoid an
`index.lock` conflict. Its comment reasons that "none of those formatters apply to
this repo's bash scripts" — but shellcheck does apply to bash scripts, and it is in
that config.

Verified 2026-08-26. Net effect: the repo that hosts the reviewer, and that
generates the largest share of its findings, runs no automatic shellcheck. Several
auto-filed findings (missing `trap`, `local` misuse, quoting) are exactly the class
shellcheck catches deterministically and for free.

Worth fixing on its own merits, and it raises the post-deletion coverage floor.

## Non-goals

- Changing model assignments.
- Touching `pre-merge-review.sh`. It may only relay concerns a human reviewer
  already raised, has an explicit omit clause, and is pinned by a test. It is not
  a noise source.
- Reworking the CI blocking review. Its prompt already carries scope constraints,
  a read ceiling, and an evidence standard.

## Verification

Before implementation, enumerate every suite by scanning, not from memory:

```bash
ls tests/ scripts/tests/ hooks/tests/ 2>/dev/null
grep -rl 'bats\|shellcheck' --include='*.sh' --include='Makefile' .
```

claude-config has at least two independent suites — `tests/*.bats` and
`hooks/tests/run-review-test.sh`. Both must run. A fix verified against only one
is the failure mode recorded in `converging-issue-backlogs/field-data.md`.

Validate each check against a known-bad case before trusting a clean result:

- Sabotage a constant the tests assert on; confirm the suite fails.
- Feed `**SEVERITY:** BLOCKING` to the new matcher; confirm it blocks.
- Feed a `FIX_NOW` finding through the full commit path; confirm exit 0 and that
  no `gh issue create` is reached.
- Feed a diff whose comment restates its line; confirm a `FIX_NOW` entry, exit 0,
  and no filing call. This pins the user-requested filter against a future
  noise-reduction pass — nothing currently protects it.
- Push a branch; confirm **no** codebase scan runs and no issue is filed.

**Validate the narrowed prompt against the known-lost set.** The 38 findings the
coverage analysis identified as having no successor are a ready-made regression
corpus. Run the narrowed prompt over those files and measure how many it re-finds.
A narrowing that loses most of them is worse than the unscoped prompt it replaced,
and this is the only check that can tell the difference.

`shellcheck -S info` on every edited script, with no `# shellcheck disable`
directives.

## Open questions

Resolved: whether to keep a codebase sweep at all. The coverage measurement settled
it — the capability is kept, moved to weekly plus `/audit`.

Still open:

- **Does the narrowed prompt actually find the silent-failure-guard class?** The
  scope narrowing is reasoned from the measured distribution, not yet validated.
  Test it against the 38 known-lost findings: a narrowed prompt run over those
  files should re-find a good share of them. If it does not, the narrowing is
  wrong and the unscoped prompt should stay.
- **Weekly cadence is a guess.** No evidence sets it. Revisit once there is data
  on how many genuine findings a week's drift actually produces.
- **Does `/audit` need per-repo scoping**, or is fleet-wide the only useful mode?
- **The `~/.claude/pending-issues/` drain path** is still unbuilt (dotfiles#247
  open). A recurring producer needs one.

## Revision history

- **2026-08-26 (initial):** delete `--mode=codebase` outright.
- **2026-08-27:** the severity transport was reworked beyond what §3 specified.
  §3 made the five prose matchers tolerant (claude-config#442, which found six
  leaking variants where this doc listed three). That treats the symptom: a
  binary decision was being transported as prose and re-derived by grep at five
  sites. The CLI's `--json-schema` was verified to work in both production
  invocation shapes, so the decision is now a schema-constrained boolean
  (claude-config#443; phase 1 merged as #444). #442's matcher survives as the
  fail-closed fallback. Measured trap worth recording: a naive
  `jq -e '.structured_output.blocking'` exits 1 for `false`, for a missing key,
  AND for `null` — collapsing "reviewer said fine" into "reviewer never
  answered", which is the same false-OK guard pattern this doc's own corpus
  identifies as the most dangerous class.
- **2026-08-27:** dropped item 5 (cache FAIL verdicts). It collides with the
  claude-config#246 fix — a cached FAIL would freeze a fabricated finding and
  replay it on every retry of the same diff — and the cache key already includes
  the diff, so it saves nothing once the code is actually fixed. Reasoning kept
  in §5 rather than deleted.
- **2026-08-26 (revised):** coverage measurement showed 55% of genuine findings
  have no successor layer. Changed to moving the mode off the push path — weekly
  plus `/audit` — rather than deleting it. Also reversed the proposed removal of
  the commit prompt's redundant-comment filter: it exists by user request, and
  belongs in `FIX_NOW` rather than being deleted.
