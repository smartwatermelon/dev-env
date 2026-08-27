# Workflow SHA-Pinning via Centralized Reusable Workflows

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Status:** Proposed — not started.

**Goal:** Satisfy zizmor and independent reviewers' "unpinned floating tag" complaints on `uses:` references to `smartwatermelon/github-workflows`, without losing the zero-touch propagation we already have, and without turning every version bump back into 16 individually-reviewed PRs.

**Non-goal:** Building a new alias/manifest indirection mechanism. GitHub Actions has no runtime indirection for `uses:` — every consuming repo's YAML must contain a literal ref. The fix works *with* that constraint, not around it.

---

## Current State (verified against this repo, 2026-08-27)

The propagation-without-manual-review problem is already solved end to end; only the *pin format* is wrong.

- `smartwatermelon/github-workflows` publishes reusable workflows, tagged (`v3`, etc.) — a separate repo, not attached to this session.
- Every consumer repo (16, per `docs/plans/2026-04-28-dependabot-auto-merge-c2.md`) references reusable workflows by **floating tag**:
  ```yaml
  # .github/workflows/claude-blocking-review.yml:21
  uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@v3
  ```
  This is what zizmor flags — the ref is mutable, not a pin.
- Every consumer repo has `.github/dependabot.yml` (github-actions ecosystem, `directory: "/"`, weekly) which already watches these `uses:` lines and opens bump PRs automatically.
- Every consumer repo has its own copy of `.github/workflows/dependabot-auto-merge.yml`, which auto-approves and auto-merges patch/minor bumps, and — per the C2 rollout — major bumps too, as long as every dependency in the bump is in a trusted namespace (`dependabot/`, `actions/`, `smartwatermelon/`).

Net effect today: a new `github-workflows` release already reaches all 16 repos within the week, unattended. The only thing wrong is that the pinned ref is a tag, which is exactly what triggers the linter complaints this plan exists to fix.

**Known duplication called out but not yet addressed** (bottom of the C2 plan): `dependabot-auto-merge.yml` itself is 16 hand-copied files, not a single source of truth.

---

## Target State

1. Consumer `uses:` lines are pinned to a full commit SHA, with a trailing version comment for humans and for Dependabot's resolver:
   ```yaml
   uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@<40-char-sha> # v3.0.1
   ```
   Dependabot's github-actions updater reads the comment to resolve the semantic version, and on a new `github-workflows` release opens a PR bumping both the SHA and the comment — the same weekly job already running, now producing a ref zizmor accepts as pinned (it checks the literal ref, not the comment).

2. The auto-merge policy itself becomes a single reusable workflow in `github-workflows`, called by SHA-pinned reference from each consumer, instead of 16 copies of the policy logic:
   ```yaml
   uses: smartwatermelon/github-workflows/.github/workflows/dependabot-auto-merge.yml@<sha> # v1.0.0
   ```
   Editing the merge policy becomes one PR + release in `github-workflows`, which then propagates itself the same Dependabot-driven way.

3. `.github/dependabot.yml` needs no changes — it already covers this.

---

## Architecture

```
smartwatermelon/github-workflows          (central repo — not yet attached to this session)
├── .github/workflows/
│   ├── claude-blocking-review.yml        (existing reusable workflow)
│   └── dependabot-auto-merge.yml         (NEW — extracted from the 16 per-repo copies)
└── releases: vX.Y.Z tags → immutable commit SHAs

each of 16 consumer repos (dev-env first, then the rest)
├── .github/dependabot.yml                (unchanged)
└── .github/workflows/
    ├── claude-blocking-review.yml        (uses: ...@<sha> # vX.Y.Z  — was @v3)
    └── dependabot-auto-merge.yml         (shrinks to a 2-line pointer at ...@<sha> # v1.0.0)
```

---

## Phase 1: Extract the auto-merge policy into `github-workflows`

**Prerequisite:** `smartwatermelon/github-workflows` must be added to the session (`add_repo`) before this phase can execute — it is out of scope for the current session.

### Task 1.1: Add a `dependabot-auto-merge.yml` reusable workflow to `github-workflows`

- Port the policy logic currently living in `dev-env/.github/workflows/dependabot-auto-merge.yml` (the version-delta computation, trusted-namespace allowlist for major bumps, approve + auto-merge steps) into a `workflow_call`-triggered reusable workflow.
- Keep the trusted-namespace allowlist (`dependabot/`, `actions/`, `smartwatermelon/`) as an input with today's list as the default, so consumers can override if they ever need to.
- Cut a `v1.0.0` release; note the resulting commit SHA.

### Task 1.2: Confirm zizmor is clean on the new reusable workflow itself

- Any actions the new workflow calls internally must also be SHA-pinned.

**Checkpoint — report to Andrew before touching consumer repos.**

---

## Phase 2: Validate on `dev-env` first

Consistent with how the C2 rollout was sequenced (dev-env validated end-to-end before propagating).

### Task 2.1: Re-pin `claude-blocking-review.yml`

- Resolve the commit SHA behind the current `v3` tag on `github-workflows`.
- Edit `dev-env/.github/workflows/claude-blocking-review.yml:21`:
  ```yaml
  uses: smartwatermelon/github-workflows/.github/workflows/claude-blocking-review.yml@<sha> # v3.0.1
  ```
- Preserve the existing comment above it explaining the floating-@v3-not-a-job-level-if rationale — that reasoning is unrelated to the pin format and still applies.

### Task 2.2: Point `dependabot-auto-merge.yml` at the new reusable workflow

- Replace the body of `dev-env/.github/workflows/dependabot-auto-merge.yml` with a `uses:` call to the Phase 1 workflow, pinned by SHA + version comment.
- Diff the old inline policy against the reusable workflow's inputs to confirm behavior is unchanged (same trusted namespaces, same patch/minor-always-merge rule).

### Task 2.3: Run zizmor locally against dev-env's `.github/workflows/`

- Confirm the floating-tag findings are gone and nothing new is introduced.

### Task 2.4: Open PR, validate end-to-end

- Open the PR, wait for CI + `merge-lock auth`, merge.
- Confirm a subsequent Dependabot PR (triggered by bumping the tracked SHA, or by waiting for the next `github-workflows` release) correctly updates the SHA + comment and auto-merges via the now-centralized policy.

**Checkpoint — report to Andrew. Do not proceed to Phase 3 if this fails.**

---

## Phase 3: Propagate to the remaining 15 repos

Same shape as Phase 4 of the C2 rollout: a script clones each repo, rewrites the two workflow files, opens a PR.

**Repos** (from the C2 rollout's scope table): archive-resolver, claude-config, claude-wrapper, crazy-larry, dotfiles, homebrew-tap, lock-sync, mac-dev-server-setup, projectinsomnia, ralph-burndown, scripts, slack-mcp, smartwatermelon-marketplace, spokane-snow, swift-progress-indicator.

### Task 3.1: Generate one PR per repo

- Reuse the `/tmp/propagate-automerge.sh` pattern from the C2 plan: clone, branch, overwrite the two files, commit, push, open PR.
- Each PR needs a human `merge-lock auth` (it's a workflow-permissions change, not a Dependabot PR, so it isn't auto-merge eligible under the existing trust rules).

### Task 3.2: Collect PR URLs, request merge-lock auth, merge once authorized

**Checkpoint — report to Andrew with the PR list.**

---

## Phase 4: Retire the per-repo policy copies

- Confirm no repo still has inline auto-merge policy logic (all 16 should now be 2-line pointers).
- Update `docs/plans/2026-04-28-dependabot-auto-merge-c2.md`'s "Future improvement" note to point at this plan as the completed follow-up.

---

## Open questions

- Does zizmor's specific ruleset/version in use flag anything about the trailing `# vX.Y.Z` comment format, or only the ref itself? Worth a quick local zizmor run against a hand-edited sample before Phase 2 rather than assuming.
- Should `github-workflows` protect its release tags (GitHub's tag-protection / immutable-releases feature) as defense in depth, even though zizmor pins by SHA regardless? Cheap to add, not required for this plan to work.
