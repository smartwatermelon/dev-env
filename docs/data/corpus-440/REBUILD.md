# Corpus rebuild — claude-config#440

How the no-successor regression corpus was reconstructed, what was included, what
was rejected, and every judgement call another person might reasonably make
differently.

**Rebuilt:** 2026-08-27
**Source of the claim being reconstructed:**
`docs/plans/2026-08-26-review-pipeline-redesign-design.md`, lines 340–450.
That analysis reported **38 of 69** hand-triaged genuine findings (55%) had no
successor layer. The per-finding list was never written down; only the count and
about fifteen named examples survived.

**Result: 48 CONFIRMED members**, not 38. See "Discrepancies" below — this is a
real result about the original analysis, not a padding artifact.

## 1. Repos surveyed

The design doc says "all eight repos" but never names them. Rather than
reverse-engineer a set that no longer reproduces (issue counts have drifted since
the analysis), **13 repos** were surveyed — a superset of any plausible eight.

Auto-filed findings were identified by body text matching
`lib-review-issues.sh` or `Source: pre-push whole-codebase review`.

| Repo | Auto-filed findings |
|---|---|
| smartwatermelon/claude-config | 113 |
| smartwatermelon/dotfiles | 80 |
| smartwatermelon/scripts | 69 |
| smartwatermelon/github-workflows | 58 |
| nightowlstudiollc/kebab-tax | 54 |
| nightowlstudiollc/financial-agent | 51 |
| smartwatermelon/claude-wrapper | 47 |
| smartwatermelon/mac-server-setup | 23 |
| smartwatermelon/mac-dev-server-setup | 22 |
| smartwatermelon/personify | 19 |
| smartwatermelon/qwen-sidebar | 19 |
| smartwatermelon/dev-env | 16 |
| nightowlstudiollc/reliquarist | 11 |
| **Total candidates** | **582** |

### Which eight were the original eight?

Unresolved, and worth stating rather than guessing. The top seven by volume sum
to 472; adding any one small repo lands in 483–495, bracketing the doc's 484.
Six different eight-repo combinations fit. The five repos named in the design
doc (claude-config, dotfiles, scripts, claude-wrapper, kebab-tax) are in all of
them. Because counts have drifted since the analysis ran, the exact original set
is not recoverable. Surveying 13 sidesteps the question.

## 2. Inclusion criteria and how they were applied

A finding qualifies only when **all three** hold:

1. **GENUINE** — a real defect a maintainer would change code for.
2. **PRE-EXISTING** — the defect was not introduced by the diff that surfaced it.
3. **NO SUCCESSOR LAYER** — a diff-scoped pre-commit reviewer would not catch it,
   because the defect is not inside the diff hunk.

Rejected wholesale as failing criterion 1:

- documentation / README / comment staleness
- naming and style nits
- "consider adding a test" / missing coverage alone
- supply-chain pin preferences (SHA vs. floating tag) — a large share of the 582
- "verify X before merging" requests
- permission-hygiene tidying, "no CI configured"
- anything whose own body concedes it is fine ("no action required", "not a bug",
  "purely cosmetic", "no functional impact", "correct as written")
- speculative "if a future author does X" hazards where nothing is wrong today
- anything a linter catches deterministically or CI fails loudly on — the corpus
  targets **silent** defects

Triage of claude-config, scripts, dotfiles, claude-wrapper and kebab-tax (363
findings) was done by direct reading. The remaining eight repos (219 findings)
were triaged by two subagents applying the identical written criteria; every
selection they returned was then independently recovered and validated by the
same process as the rest, and two of their picks were rejected at validation
(see §5).

## 3. Recovery method

Every corpus member is CLOSED and fixed, so the corpus needs the **historical
buggy version** of each file.

**Anchor on the issue's filing date, not on the fix commit's parent.** Files drift
between filing and fix. Verified on claude-config#166: the fix landed 2026-07-29,
the finding was filed 2026-05-20, and line 705 in the fix's parent is unrelated
code.

```bash
c=$(git -C <abspath> rev-list -1 --before="<issue createdAt ISO8601>" main)
git -C <abspath> show "$c":<path from the Location field>
```

Default branch is `main` in all 13 repos (checked, not assumed).

**Control.** For claude-config#166 this recovers
`80deb566a1362c9333b636118a61bba5fc1dd3f7`, whose `hooks/run-review.sh` line 705
is exactly `if ! echo "${DIFF}" | grep -qE '^[+-][^+-]'; then` — the SIGPIPE bug
as described. The method was not trusted until this control reproduced.

### Two failure modes the naive method hits, and the fallbacks used

**(a) File not on `main` at filing time.** The reviewer runs pre-push, so it
reads a feature branch. The file often reaches `main` minutes to hours *after*
the issue is filed. `rev-list --before=<filed> main` then returns a commit
predating the file's existence. Fallback: widen the cutoff progressively
(+6h, +48h, +14d) across `--all`, taking the first commit whose version of the
file contains the flagged construct.

**(b) The widened window overshoots the fix.** Dangerous, and the reason
validation is load-bearing rather than ceremonial. Real instances caught:

- `claude-config#364` — the 48h window recovered a version already containing the
  *fixed* `stopReason === 'converged' ? [] : [...]`. Re-anchored by pickaxe to
  `b1b22ef`, which has the buggy `stopReason === 'capped' ? queue : []`.
- `dotfiles#117` / `#118` — the 6h window recovered versions with the fix already
  applied (`|| true` present; all four helpers exported). Re-anchored to `9781898b`.
- `github-workflows#66` — recovered version already applies `strip_comments` to
  `TARGET_VERSION`. **Rejected outright**; the defect never existed at filing time
  as described.
- `claude-wrapper#82` — recovered version already uses the fixed array-based
  check rather than the bare `tests/lib/*.sh` glob. Rejected.

For these, the anchor is chosen by `git log -S<construct> -- <path>` (pickaxe),
taking the newest commit at or before the filing date whose file content contains
the defective construct.

## 4. Validation (load-bearing)

Every member was validated in two passes.

**Pass 1 — construct present.** Read the issue's Location and DETAILS, then grep
the recovered file for the specific defective construct the issue describes. A
match on a comment or a function header does not count; several first-pass
"CONFIRMED" results were caught this way and re-checked against the actual line
of code.

**Pass 2 — round-trip.** For all 48 members, assert that the file in
`files/<id>/` contains, at the recorded `line`, exactly the string recorded in
`evidence`.

```
verified 48/48, failures 0
```

**No member is marked CONFIRMED on the strength of a recovery that succeeded;
only on the strength of the bug being demonstrably present.** Anything that could
not clear both passes was dropped rather than downgraded, so the shipped corpus
contains no DRIFTED or UNRECOVERABLE rows.

### Drift is the norm, not the exception

Only a minority of members sit at the line number the issue cites. The recorded
`line` in `corpus.json` is the **corrected** line in the recovered file, found by
locating the construct. Examples: claude-config#126 cited 326, actually 282;
claude-config#127 cited 518, actually 435; claude-config#90 cited "codebase
block", actually 591. Consumers should trust `line` + `evidence` together, and
should not expect them to match the issue text.

## 5. Rejected at validation

These passed triage but failed recovery or validation, and are **not** in the
corpus:

| Finding | Why rejected |
|---|---|
| `github-workflows#66` | Recovered version already has the `strip_comments` fix; defect not present as described |
| `claude-wrapper#82` | Recovered version already uses the fixed array check, not the bare glob |
| `claude-wrapper#60` | Construct (`stub_dir}:/usr/bin`) absent from every version in history |
| `scripts#45` | Recovered version uses the injection-**safe** argv/heredoc pattern; the issue itself says the safe pattern is in use and no action is needed |
| `dotfiles#117` | Recovered version exports all four helpers — the fix, not the bug |
| `dotfiles#118` | Recovered version has `\|\| true` — the fix, not the bug |
| `kebab-tax#1130` | `pendingDelete` timer construct not locatable in any recovered version |
| `kebab-tax#1136`, `#1143`, `#1135` | try/catch and getItemsByIds constructs absent at every anchor tried |
| `dev-env#40` | `pull_request.user.login` guard not present in the recovered workflow |
| `github-workflows#110` | `DEP_NAMES` guard not present at the cited location in the recovered file |
| `claude-config#148` (first attempt) | Later recovered successfully via pickaxe to `418fe25a`; **is** in the corpus |

`scripts#45` deserves emphasis: it is one of the fifteen examples named in the
design doc, and it does not survive validation. Its own issue body reads "a later
reviewer noted that the code actually passes the URL via argv … which is
injection-safe. … No action needed if argv pattern is already in use." It was
counted as a genuine no-successor finding in the original analysis; on the
evidence it is not one.

## 6. Rejected at triage

Eight further findings passed the first triage but were dropped on a stricter
second read. Recorded so the decision can be argued with:

| Finding | Reason |
|---|---|
| `claude-config#349` | Duplicate of the #267/#352 regex-limitation class; body says "No action required" |
| `claude-config#342` | Heredoc `EOF` collision is theoretical; the arbiter emits structured output |
| `claude-config#190` | Cache-key staleness reachable only by a manual config change mid-diff |
| `scripts#135` | `stringprefix.sh` is a toy utility, not a production path |
| `scripts#16` | `jq`-on-PATH is an environment assumption; the failure is visible, not silent |
| `dotfiles#213` | git `includeIf` sync is a documented manual-sync note, not a code defect |
| `claude-wrapper#86` | Test-only duplicate of `#85` — same `stat` pattern, same commit |
| `kebab-tax#1089` | Inconsistent normalization across callers; closer to refactor than defect |

The bulk of the 582 → 48 reduction is the criterion-1 rejection classes listed in
§2. The two subagent triage passes returned full rejection ledgers with per-item
reasons for their 219 findings; those reasons are summarized by class in §2 rather
than reproduced item-by-item.

## 7. Judgement calls another person might make differently

- **`dotfiles#205` is included, and its body says "This is not a bug given the
  stated design intent."** It is kept because the design doc names it explicitly
  as a category-4 example. A stricter reading would drop it. This is the single
  most arguable inclusion.
- **Test-suite defects are included** (`scripts#154`, `claude-wrapper#70`, `#74`,
  `#85`, `#96`, `qwen-sidebar#21`). The design doc's §"fallback layers" argues
  these belong precisely because the tests are the broken thing and cannot
  self-catch. Someone measuring "production code defects" would exclude all six.
- **Category assignment is judgement, not measurement.** `bypassable-guard` and
  `silent-failure-guard` overlap heavily — a guard that can be bypassed is
  usually also one that reports OK. Where a finding fits both, the mechanism
  decided it: a false-OK on a check that ran is `silent-failure-guard`; a check
  that can be routed around is `bypassable-guard`.
- **The eight-repo set was not reconstructed** (§1). Surveying 13 can only add
  members relative to the original eight, never remove them, so the 48 is an
  upper bound with respect to repo scope.
- **`bug_summary` is the first sentence of the issue's own "What was flagged"
  text, truncated.** It is the reviewer's claim, not an independent restatement.
  `evidence` is the load-bearing field.

## 8. Files

- `corpus.json` — 48 objects. `line` and `evidence` are the corrected, verified
  location in the recovered file; `commit` is the full 40-char anchor SHA.
- `files/<repo>-<issue>/<basename>` — the recovered buggy file content, one
  directory per member. These are the actual measurement inputs.
- `REBUILD.md` — this file.

## 9. Reproducing a single member

```bash
# claude-config#166
git -C ~/Developer/claude-config show \
  80deb566a1362c9333b636118a61bba5fc1dd3f7:hooks/run-review.sh \
  | sed -n '705p'
# => if ! echo "${DIFF}" | grep -qE '^[+-][^+-]'; then
```

## Post-handoff audit (2026-08-27, orchestrating session)

The corpus was independently re-verified before use.

### Round-trip validation reproduced

All 48 members were re-checked by an independent script: read the recovered
file, take the recorded line, confirm it contains the recorded `evidence`.
Result **48/48**, confirming the rebuild agent's claim.

Eight members initially reported as mismatches were a JSON-escaping artifact
only - `evidence` strings carry doubled backslashes where the file has single
ones. After normalising backslashes, all 48 match. No corpus data is wrong;
the escaping is cosmetic and left as-is.

### One member removed: `dotfiles#205` (48 -> 47)

The rebuild agent flagged this as its single most arguable inclusion, and it
does not survive review. The issue body states plainly:

> This is not a bug given the stated design intent, but worth documenting as
> a known gap for the "personal collaborator on external org" case.

It is a "consider whether" finding about a deliberate design decision - the
exact shape the pipeline's anti-noise rules exist to reject. It was included
only because the design doc names it. Counting a non-defect in the denominator
would understate every variant's re-find rate.

### `scripts#45` confirmed as a bad entry in the original analysis

Independently verified. The issue body says:

> a later reviewer noted the code actually passes the URL via argv
> (heredoc + item 1 of argv), which is injection-safe. ... No action needed
> if argv pattern is already in use.

This was a reviewer disagreement that got auto-filed, then counted as a
genuine no-successor finding. It is not a defect. The rebuild agent correctly
excluded it.

**Two of the fifteen hand-picked named examples are not defects.** That is a
material correction to the design doc's evidence base, and it is consistent
with the doc's own caveat that the triage was a plausibility check rather
than a confirmation.

### Members audited and kept

- `claude-config#267` - genuine. A single-match regex means a second
  occurrence of the blocked subcommand in the same command string walks past
  the block.
- `dev-env#41` - genuine despite "worth noting" phrasing. A whitespace-only
  `DEP_NAMES` leaves `remainder` empty, which evaluates as a trusted-namespace
  match and auto-merges an unverified major bump. False-OK guard.

### Note on the hook that blocked this write

Writing this section initially tripped `hook-block-all.sh`, because the prose
describing claude-config#267 contained the literal blocked command string. The
guard matches command text without distinguishing a command from documentation
about one. Worth noting as a usability wrinkle, not filed - it is the very
guard #267 concerns.

### Final corpus: 47 CONFIRMED members

`corpus-48-preprune.json` preserves the pre-audit state for comparison.
