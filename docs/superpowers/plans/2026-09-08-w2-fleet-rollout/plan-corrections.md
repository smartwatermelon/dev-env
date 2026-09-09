# W2 plan corrections to fold into the final docs PR (Task 10)

Accumulated 2026-09-08 during execution. Each item is a deviation from
`docs/superpowers/plans/2026-09-08-w2-fleet-rollout.md` as written.

1. **github-workflows classifies DIFFERS, not CURRENT.** That path holds the
   reusable workflow itself, not a caller stub. DIFFERS is correct by design.
2. **zizmor.yml is seeded in every wave-2 PR.** Any repo without a root
   zizmor.yml blocks local commits that touch a first-party `@vN` ref, since
   the global pre-commit hook runs zizmor without the canonical config.
3. **Pilots were fixed before the fleet waves.** Andrew asked that the three
   red pilots (pr-review, claude-code-workflows-agents, nightowlstudiollc/.github)
   get their remediation PRs first. Done: pr-review#17/#18, workflows-agents#21,
   .github#13.
4. **Wave-2 branch name is `claude/ci-zizmor-019HDRKL`**, not the plan's
   `claude/ci-pin-actions-019HDRKL`. Commit/PR title:
   `ci: pin third-party actions to SHAs, persist-credentials: false, seed zizmor.yml`.
5. **Pin comments must be exact tags** (`# v7.0.1`, not `# v7`). The
   pre-commit hook runs zizmor's online ref-version-mismatch audit, which
   fails on major-only comments.
6. **Merge locks are no longer typed per PR.** Andrew merges from the GitHub
   UI (dev-env#101 tracks a TUI improvement). The "at most 10 open" round
   limit existed for lock sittings; it was exceeded briefly during wave 2.
7. **The four "policy decision" zizmor cases resolved as standard fixes**, no
   policy change: kebab-tax-netlify scopes `pull-requests: write` /
   `issues: write` to the job; swift-progress-indicator passes `SHA256` via
   `env:` and uses `"$SHA256"`; huddle-transcribe gains the canonical stub's
   `# zizmor: ignore[dangerous-triggers]` comment; claude-config gets
   `persist-credentials: false`.
8. **Company machine (arich-mac.local) needs its own runbook section** for
   the smartwatermelon -> twistedmelonman gh re-login. Dual identities there;
   Andrew runs auth changes himself. Nothing propagates automatically.
9. **Wave 2 was interrupted by a session rate limit** (2026-09-08 18:03).
   Nine of fourteen PRs had landed; archive-resolver and the four round-2
   repos were re-dispatched after 18:20.
10. **dependabot.yml gaps** found during pilots: superpowers, x-thread-reader,
    superpowers-marketplace, claude-config-backup lack one (reliquarist got
    its in wave 1, pr-review in #18). Remaining ones ride wave 3.
11. **Wave 3 gate reminder:** post "Starting wave 3 (~28 lint PRs in rounds
    of 10) unless you say otherwise" before dispatching; do not start it on
    the heels of wave 2.
12. **Artifacts relocated to `docs/superpowers/plans/2026-09-08-w2-fleet-rollout/`.**
    `.superpowers/sdd/.gitignore` is a blanket `*`, so the scan directory,
    this corrections file, and `w3-readiness.tsv` could not be committed from
    `.superpowers/sdd/2026-09-08-w2-fleet-rollout/`, per the plan's Task 10
    File Structure line and Task 6's Files line. Copied instead; the
    `.superpowers/sdd/` originals remain as the working scratch copy and are
    not tracked by git.
13. **Task 10 Step 1's `--branch main` filter returns nothing.** The caller
    stub's `on:` trigger is `pull_request` only (never `push`), so
    `gh run list --workflow 'Standards Check' --branch main` finds zero runs
    on every repo regardless of actual status. The readiness table instead
    uses each repo's latest `standards-check.yml` run on any branch
    (typically the remediation-wave PR branch), which the task's Facts
    section directs explicitly.
