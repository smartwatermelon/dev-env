# GitHub Actions Security Audit — Methodology

Audits Andrew's GitHub Actions workflows for the dangerous patterns
catalogued in the source article. This document is read by:

1. A human running an ad-hoc audit (Andrew, or anyone he hands the work to).
2. The recurring remote agent that re-runs this audit quarterly (see
   [Recurring Audit](#recurring-audit)).

Both consumers MUST follow this doc — drift in the methodology will produce
non-comparable results and break the quarter-over-quarter delta.

## Source

Nesbitt, *"GitHub Actions Is The Weakest Link"*, 2026-04-28.
<https://nesbitt.io/2026/04/28/github-actions-is-the-weakest-link.html>

The article catalogs nine concrete attack patterns observed across recent
GHA supply-chain incidents (tj-actions/changed-files, Ultralytics, nx,
spotbugs, Trivy, prt-scan, elementary-data) and recommends `zizmor` as the
detection tool. Our methodology codifies the manual scan equivalent.

## In-scope filter

A repo is in scope iff ALL of:

- Owner is `smartwatermelon` or `nightowlstudiollc`.
- Not archived (`isArchived: false`).
- Not a fork of someone else's project (`isFork: false` — exception: if
  the user owns the original, but practically isFork is the right gate).

Enumerate via:

```bash
gh repo list smartwatermelon --limit 200 \
  --json name,isArchived,isFork,visibility,defaultBranchRef \
  --jq '.[] | select(.isArchived == false and .isFork == false) | .name'
gh repo list nightowlstudiollc --limit 200 \
  --json name,isArchived,isFork,visibility,defaultBranchRef \
  --jq '.[] | select(.isArchived == false and .isFork == false) | .name'
```

The April 2026 inaugural audit found 29 in-scope repos (19 + 10).

## The 9 vulnerability patterns

Each pattern below has: a one-line description, what makes it dangerous,
how to detect it, and how to remediate.

### Pattern 1 — `pull_request_target` + untrusted checkout

**Danger:** `pull_request_target` runs in the BASE-branch context with full
secrets and a write-scoped token. If the workflow then checks out PR-
controlled code, that code executes with secrets in scope.

**Detect:** `grep -l 'pull_request_target' .github/workflows/*.yml`. For
any match, check whether the same workflow has an `actions/checkout` step
that takes the PR ref. A match WITHOUT checkout is usually safe — verify
no other step executes PR-controlled content.

**Remediate:** Use `pull_request` instead. If `pull_request_target` is
genuinely required (e.g., to update a comment with secrets), do not check
out the PR.

### Pattern 2 — Mutable action references (git tags)

**Danger:** Tags like `@v3` are mutable; an attacker who compromises the
action repo can move the tag to a malicious commit, and 23,000+ repos
auto-pull on next run (tj-actions). Trivy had 76 of 77 historical tags
hijacked.

**Detect:**

```bash
grep -nE '^\s*uses:\s*' .github/workflows/*.yml \
  | grep -vE 'uses:\s*[^@]+@[a-f0-9]{40}'  # not SHA-pinned
```

Filter out `./...` (local references) and `<repo>/<workflow>@<tag>`
(reusable workflows in the user's own repos — separate trust boundary).

**Remediate:** Pin to commit SHA with a tag comment so Dependabot can
update:

```yaml
uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
```

Resolve the tag with: `gh api /repos/<owner>/<repo>/git/refs/tags/<tag>
--jq '.object.sha'` (and dereference if `.object.type == "tag"`).

### Pattern 3 — Cache poisoning across trust boundaries

**Danger:** GHA caches are scoped by branch and shared down to children.
A `pull_request_target` job that restores a cache may pull entries written
by an untrusted PR run.

**Detect:** Any `actions/cache@` step in a workflow that uses
`pull_request_target`, OR any cache restore that runs in base context with
keys derived from PR-controlled paths.

**Remediate:** Don't restore caches in `pull_request_target` jobs, or use
disjoint cache key namespaces.

### Pattern 4 — Imposter commits from forks

**Danger:** Runners resolve action SHAs against the entire fork network,
not just the upstream branches. An attacker can push a malicious commit
to a fork (where it lives as a dangling object), then reference its SHA
as if it were upstream.

**Detect:** Hard to detect without git verification. Mitigation is
prevention: only pin to SHAs that are reachable from upstream branches.
For audit-time spot-checks, run `git fetch <upstream-action-repo> && git
branch --contains <pinned-sha>` against each pinned SHA.

**Remediate:** When pinning, verify reachability. Long term: rely on
zizmor or GitHub's planned workflow lockfile.

### Pattern 5 — Template injection in `run:` blocks

**Danger:** `${{ github.event.* }}` is expanded BEFORE the shell parses
the script, so PR titles, branch names, issue comments, etc. become code
execution. nx leaked 5,000+ private repos via this exact path.

**Detect:**

```bash
# Find run: blocks that contain GitHub-event interpolation
awk '
  /^[[:space:]]*run:/ { in_run=1; next }
  /^[[:space:]]*[a-z][a-zA-Z_-]*:/ && !/^[[:space:]]*-/ { in_run=0 }
  in_run && /\$\{\{[[:space:]]*github\.event\./ { print FILENAME ":" NR ": " $0 }
' .github/workflows/*.yml
```

The April 2026 audit found ZERO instances. Maintain that invariant.

**Remediate:** Move the value into an `env:` mapping at the step level,
then use the env var inside the script. The shell sees a regular `$VAR`
reference, not a pre-expanded string.

```yaml
run: |
  echo "Title: $PR_TITLE"
env:
  PR_TITLE: ${{ github.event.pull_request.title }}
```

### Pattern 6 — Overpermissive default `GITHUB_TOKEN`

**Danger:** Repos created before February 2023 default to write-scoped
`GITHUB_TOKEN`. Repos created after still inherit that default if it was
explicitly set at the org or repo level. A workflow with no
`permissions:` block runs with whatever the repo default is.

**Detect:**

```bash
gh api /repos/<owner>/<repo>/actions/permissions/workflow \
  --jq '.default_workflow_permissions'
```

For each in-scope repo, check this and flag any returning `"write"`.

**Remediate:**

```bash
gh api -X PUT /repos/<owner>/<repo>/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true  # preserve current setting
```

The April 2026 audit found 2 outliers (`ralph-burndown`, `mac-server-setup`),
both flipped to read.

### Pattern 7 — `issue_comment` and similar untrusted-event triggers

**Danger:** The `issue_comment` event fires for any comment on any
issue/PR by any GitHub user. If the workflow uses comment content
without a sender-identity gate, an unauthenticated user can trigger code
execution on the repo's behalf (elementary-data).

**Detect:** Any workflow with `issue_comment:` in `on:`. Audit each for an
`if:` condition that checks `author_association` against
`["OWNER", "MEMBER", "COLLABORATOR"]`.

**Remediate:** Use the same author_association gate the canonical
`claude.yml` uses:

```yaml
if: |
  contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'),
           github.event.comment.author_association)
```

### Pattern 8 — Unpinned third-party actions (general)

This is Pattern 2 stated as a coverage rule rather than a one-off
incident. The article's data: 91% of PyPI packages using third-party
actions reference at least one by mutable tag. The remediation and
detection are identical to Pattern 2.

### Pattern 9 — Missing workflow `permissions:` block

**Danger:** Workflows without an explicit `permissions:` block inherit
the repo default (Pattern 6). Even when the repo default is `read`, an
explicit declaration is best practice — it documents intent and survives
future default changes.

**Detect:**

```bash
for f in .github/workflows/*.yml; do
  if ! grep -qE '^permissions:' "$f"; then
    # Workflow has no top-level permissions
    # Check if every job has its own permissions block; if so, that's fine.
    echo "$f: no top-level permissions"
  fi
done
```

**Remediate:** Add `permissions: { contents: read }` (or scoped tighter)
at the workflow top level, or per-job.

## Severity rubric

A finding's severity is `(blast radius) × (exploitability)`:

| Severity | Examples |
|----------|----------|
| **Critical** | Pattern 1 with checkout; Pattern 5 in a workflow with secrets; tag-pinned action with cross-repo write secret in scope |
| **High** | Pattern 6 (default=write) on a repo with non-trivial workflows; Pattern 2 on a third-party action with cross-repo secrets |
| **Medium** | Pattern 2 on a low-reputation third-party action; Pattern 9 on a workflow that touches secrets |
| **Low** | Pattern 9 on a read-only test workflow; Pattern 2 on a GitHub-owned action |

## Mitigation framework

Findings are sorted into three tiers based on cost-to-fix and exposure:

### Tier 1 — Immediate, no review (≈30 min)

Reversible operations and config flips. Examples: `gh api -X PUT
.../actions/permissions/workflow`, syncing a drifted workflow file from
canonical. No human review required because the change is recoverable.

### Tier 2 — Targeted PRs (≈2 hr)

Code changes with material security impact. Examples: SHA-pinning a
high-blast-radius action, adding permissions blocks to workflows that
were inheriting `write`. One PR per repo, batched. Each PR runs through
the standard review path (claude-blocking-review).

### Tier 3 — GitHub issues for later (≈4 hr or backlog)

Defense-in-depth and tooling-adoption work. Examples: adopting `zizmor`,
SHA-pinning low-reputation actions, secret rotation reminders, guardrails
preventing future regressions. Tracked as issues, not blocking on the
audit.

## Tooling pointers

- **[zizmor](https://github.com/woodruffw/zizmor)** — Rust static
  analyzer for GHA. Detects all 9 patterns above plus more. Recommended
  by the source article. Adoption tracked in `dev-env#19`.
- **[pinact](https://github.com/suzuki-shunsuke/pinact)** /
  **[ratchet](https://github.com/sethvargo/ratchet)** — auto-rewrite
  tag refs to SHA refs with `# vX` comments. Use after zizmor identifies
  unpinned-uses violations.

## Recurring audit

A claude.ai routine re-runs this audit quarterly:

- **Routine:** *Quarterly GitHub Actions Security Audit*
- **Routine ID:** `trig_01JaKYSFQhPJoc3jADyQPBgM`
- **URL:** <https://claude.ai/code/routines/trig_01JaKYSFQhPJoc3jADyQPBgM>
- **Cadence:** `0 17 1 1,4,7,10 *` UTC = 9am PST / 10am PDT on Jan 1, Apr 1,
  Jul 1, Oct 1
- **Output:** A single GitHub issue at `smartwatermelon/dev-env` titled
  `Quarterly GitHub Actions security audit — <YYYY> Q<N>`, plus draft
  PRs for any NEW findings.

The agent runs unattended; its prompt instructs it to read THIS doc as
the canonical methodology. To change what the agent does, edit this doc
(humans-only — the agent is instructed not to modify it). The agent's
prompt itself is updated via the routine settings, not via this repo.

If the methodology needs a change the agent can't make on its own (a new
attack pattern, a deprecated check), the agent files an issue labeled
`audit-methodology-update`. Triage those as you would any backlog item.

## Execution environment notes

The recurring agent runs in a sandboxed cloud environment that may not
have the same tooling assumed by this methodology. The 2026-04-29 Q2
run surfaced two such constraints — these are environment-level, not
methodology-level, and the agent is correct to note them as partial
coverage rather than treat them as findings.

### Constraint 1 — `gh` CLI may be unavailable

When `gh` isn't present, the agent falls back to MCP GitHub tools (read
via `search_code` and direct file reads). That covers Patterns 1, 2, 3,
5, 7, 8, and 9 — they're all detectable from workflow file content
that's reachable via code search. It does NOT cover:

- **Pattern 6** (`default_workflow_permissions`) — the
  `/repos/{owner}/{repo}/actions/permissions/workflow` endpoint isn't
  reachable through MCP code search.
- **Pattern 4** (imposter commits) — requires git reachability analysis
  the cloud sandbox cannot perform.

When the audit issue marks a pattern as **PARTIAL**, run this locally
to verify Pattern 6 across all in-scope repos:

```bash
for repo in $(
  gh repo list smartwatermelon --limit 200 \
    --json name,isArchived,isFork \
    --jq '.[] | select(.isArchived == false and .isFork == false) | "smartwatermelon/" + .name'
  gh repo list nightowlstudiollc --limit 200 \
    --json name,isArchived,isFork \
    --jq '.[] | select(.isArchived == false and .isFork == false) | "nightowlstudiollc/" + .name'
); do
  perms=$(gh api "repos/$repo/actions/permissions/workflow" \
            --jq '.default_workflow_permissions' 2>/dev/null)
  [[ "$perms" == "write" ]] && echo "WRITE: $repo"
done
```

Anything that returns `WRITE` is a real finding; flip via:

```bash
gh api -X PUT "/repos/<owner>/<repo>/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

Pattern 4 has no cheap human substitute; rely on SHA pinning hygiene
and (eventually) zizmor. See [`dev-env#19`](https://github.com/smartwatermelon/dev-env/issues/19).

### Constraint 2 — MCP write scope may be narrow

Issue creation typically works against `smartwatermelon/dev-env`.
Cross-repo `gh pr create --draft` may fail. The routine prompt
instructs the agent to skip cleanly with a `PR creation skipped for
repo X: <reason>` line in the issue body — not to retry, escalate, or
abort the audit.

When that line appears, apply the proposed remediation snippets from
the issue body manually. The audit report contains them inline for
exactly this purpose; manual application is typically a one-line edit
plus a regular branch + PR cycle.

### When to upgrade the environment

These constraints are tolerable as long as the audit's NEW-finding
count stays low. Re-evaluate the `environment_id` (in the routine
settings, not in this repo) if any of these hold:

- A quarter produces 5+ NEW findings that would have warranted draft
  PRs, and manual application becomes the bottleneck.
- Pattern 6 verification keeps reporting PARTIAL, and the local-verify
  workflow above starts getting skipped.
- A new pattern emerges that requires API access the MCP scope can't
  provide.

The full inventory of available environments is in the routine
configuration UI. `GitHub swm` and `GitHub NOS` are likely scoped to
their respective orgs; `Default` is org-agnostic but read-leaning.
Switching environments may require the routine prompt to re-establish
its legitimacy anchor — the methodology doc reference covers this, but
test with a one-shot run before relying on a quarterly cron.

## Audit history

| Date | Repos | Findings (severity) | PRs landed | Issues filed |
|------|-------|---------------------|------------|--------------|
| 2026-04-29 (Q2 auto, validation run) | 29 | 0 new (1 unchanged Low, tracked) | 0 | 1 ([dev-env#23](https://github.com/smartwatermelon/dev-env/issues/23)) |
| 2026-04-29 (inaugural manual) | 29 | 0 critical, 4 high, 10 medium | 9 | 5 |

The 2026-04-29 inaugural audit was performed manually. The full report
lives in the conversation that produced it; key outcomes:

- Patterns 1, 3, 4, 5, 7 were already clean across all in-scope repos.
- Patterns 2, 6, 8, 9 had remediable findings; all critical/high were
  closed in nine PRs (mac-server-setup#134, swift-progress-indicator#12,
  github-workflows#63, ralph-burndown#130, homebrew-tap#8, yesteryear#62,
  juliet-cleaning#35, tensegrity#84, kebab-tax#1217).
- Five Tier-3 issues filed: `dev-env#19`, `dev-env#20`, `dev-env#21`,
  `github-workflows#64`, `swift-progress-indicator#13`.

When the next audit runs, prepend its row to this table.
