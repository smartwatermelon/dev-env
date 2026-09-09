# zizmor findings, fleet-wide (measured 2026-09-08)

Scan provenance: `github-workflows` at `main`@`6f759f1`; zizmor 1.30.0,
`--min-severity low --no-online-audits`; config resolution is
`<repo>/zizmor.yml` if present, else the canonical
`github-workflows/standards/../zizmor.yml`.

17 of 42 scanned repos fail zizmor. Rule counts across all findings (any
severity, including `help`/`warning` that do not fail the check):

| Rule | Repos failing zizmor because of this rule | Fix |
| --- | --- | --- |
| `unpinned-uses` (error) | 13: `nightowlstudiollc/.github`, `nightowlstudiollc/kebab-tax`, `nightowlstudiollc/tensegrity`, `smartwatermelon/.github`, `smartwatermelon/archive-resolver`, `smartwatermelon/claude-code-workflows-agents`, `smartwatermelon/dumbify`, `smartwatermelon/lock-sync`, `smartwatermelon/pr-review`, `smartwatermelon/scripts`, `smartwatermelon/slack-mcp`, `smartwatermelon/spokane-snow`, `twistedmelonman/personify` | SHA-pin the third-party action, keep the `# vX.Y.Z` comment, let Dependabot move it. |
| `excessive-permissions` (error) | 1: `nightowlstudiollc/kebab-tax-netlify` | Repo-specific: a caller workflow requests more than the reusable workflow needs, or uses a non-standard filename not in the canonical ignore list. Needs per-repo look, not a fleet fix. |
| `dangerous-triggers` (error) | 1: `twistedmelonman/huddle-transcribe` | Needs a look at the trigger (likely `pull_request_target`); if it needs the same treatment as canonical's ignored callers, that is a policy addition to `zizmor.yml` — do not silence locally. **Policy decision needed from Andrew before Task 8 touches this repo.** |
| `template-injection` (help severity) | 1: `smartwatermelon/swift-progress-indicator` (co-occurs with `artipacked` in this repo; both are non-`unpinned-uses` rules) | Repo-specific: check for unsanitized `${{ }}` interpolation of PR-controlled input into a shell step. Needs a look, not a mechanical fix. |
| `adhoc-packages` (help severity) | 1: `smartwatermelon/claude-code-workflows-agents` (this repo also fails for `unpinned-uses` and `artipacked`) | Already covered by canonical policy comment for the standard filenames; this repo's own workflow likely installs a tool ad hoc under a non-standard name. Non-blocking, fold into wave 2's pass on this repo. |
| `artipacked` (warning/help severity) | 16 repos carry this finding: every one of the 13 `unpinned-uses` repos, plus `nightowlstudiollc/kebab-tax-netlify`, `smartwatermelon/swift-progress-indicator`, and `twistedmelonman/claude-config` | **Not incidental — see the blocking note below.** Fix: add `persist-credentials: false` to the flagged `uses: actions/checkout@...` step (confirmed via `smartwatermelon/dumbify`'s finding: `help[artipacked]: credential persistence through GitHub Actions artifacts ... does not set persist-credentials: false`). Only `twistedmelonman/claude-config` has this as its sole zizmor cause; every other artipacked-carrying repo also needs its `unpinned-uses` (or other) fix. |

## Blocking note for Task 8: SHA-pinning alone will not turn zizmor green

All 13 `unpinned-uses` repos also carry `artipacked` (`warning`/`help`
severity, and `--min-severity low` means it still fails the check).
Task 8 Step 3 expects `run-standards.sh ... | grep -A20 '== zizmor'` to show
no findings after the SHA-pin pass — that will NOT be true for these 13
repos unless the same PR also adds `persist-credentials: false` to the
`actions/checkout` step being pinned. Add this as a companion edit in the
same PR, not a separate wave: one line next to the `uses:` line already
being touched.

Repos whose zizmor failure is **not (only) `unpinned-uses`**:
`nightowlstudiollc/kebab-tax-netlify` (excessive-permissions + artipacked),
`smartwatermelon/swift-progress-indicator` (template-injection +
artipacked), `twistedmelonman/claude-config` (artipacked, sole cause),
`twistedmelonman/huddle-transcribe` (dangerous-triggers, sole cause). These
four are outside the "SHA-pin third-party actions" scope Task 8 describes
and need separate handling; flag to Andrew before folding them into wave 2's
mechanical pin pass.

## Delta from the plan's Task 8 repo list (16 named there; 17 measured here)

The plan's Task 8 repo list and this scan's 17-repo zizmor-failing set
differ:

- **Missing from the plan's list:** `smartwatermelon/.github`.
- **Ambiguous owner in the plan's list, resolved by this scan:** the plan
  names bare `claude-config` and `huddle-transcribe` with no owner; the
  actual failing repos are `twistedmelonman/claude-config` and
  `twistedmelonman/huddle-transcribe` (not `smartwatermelon/`).

Re-derive Task 8's repo list from `scan/summary.tsv` (as its own gate
already says), not from the plan's Live State table — the plan itself notes
that table needs re-measurement.

## `unpinned-uses` targets (39 findings, all third-party, all bucket (b))

| Action | Count |
| --- | --- |
| `actions/checkout@v7` | 21 |
| `anthropics/claude-code-action@v1` | 6 |
| `actions/setup-python@v7` | 4 |
| `actions/setup-node@v7` | 4 |
| `codecov/codecov-action@v7` | 1 |
| `astral-sh/setup-uv@v5` | 1 |
| `actions/upload-artifact@v4` | 1 |
| `actions/checkout@v4` | 1 |

No `smartwatermelon/github-workflows/...@vN` reusable-workflow ref appears in
any `unpinned-uses` finding — canonical policy's `ref-pin` exemption for that
namespace is working correctly fleet-wide. Every flagged target is a genuine
third-party action at a floating tag; the fix is uniformly (b) SHA-pin with a
version comment, exactly as Task 8 Step 2 describes. No policy change needed
for this rule.

## Does seeding the canonical `zizmor.yml` at repo root resolve the findings?

**No, for 16 of the 17 repos** — this scan already ran under the canonical
config (`<repo>/zizmor.yml` absent, so `run-standards.sh` fell back to
`github-workflows/standards/../zizmor.yml`, confirmed: only
`smartwatermelon/github-workflows` and `smartwatermelon/gmail-newsletter-filter`
have a root `zizmor.yml`, and `gmail-newsletter-filter` passes zizmor
entirely). Seeding the same file at repo root would not change the outcome
for any currently-failing repo; the findings are real gaps in those repos'
workflows (unpinned third-party actions, one permissions question, one
trigger question), not a config-selection artifact.

**One exception, informational, not a currently-failing repo:**
`smartwatermelon/gmail-newsletter-filter` has its own `zizmor.yml`, a strict
prefix of canonical (identical `unpinned-uses`/`excessive-permissions`
policy, missing canonical's later `dependabot-cooldown`, `self-repository`,
and `adhoc-packages` ignore blocks). It currently passes zizmor regardless,
so this is drift worth noting for Task 10, not a remediation item — but if
its own workflows ever add a `dependabot.yml`-style cooldown or a
`self-*.yml` caller, its stale local config would start failing where
canonical would not.

## Classification

- (a) Seeding canonical config: **not the fix** for any of the 17 failing repos (see above).
- (b) SHA-pin third-party actions: **the fix for `unpinned-uses`**, 13 repos, 39 findings, table above.
- (c) Needs a policy decision from Andrew: `excessive-permissions` (kebab-tax-netlify) and `dangerous-triggers` (huddle-transcribe) — do not fold into the mechanical Task 8 pin pass without a look first.

Do not propose silencing any rule in `zizmor.yml`.
