# Anthropic Spending Audit

**Date**: 2026-05-18
**Purpose**: Identify all automated/autonomous/secondary Claude/Anthropic usage across developer infrastructure, evaluate necessity, and recommend cost reduction.

---

## Executive Summary

Your infrastructure has **four major cost centers** for Anthropic usage:

| # | Cost Center | Auth Method | Frequency | Est. Monthly Invocations |
|---|------------|-------------|-----------|--------------------------|
| 1 | **GitHub Actions: Blocking Review** | OAuth | Every PR push | ~250/month |
| 2 | **GitHub Actions: @claude Assistant (cascading)** | OAuth | Every ralph issue creation | ~250/month (unintentional) |
| 3 | **Ralph Night-Shift** (local, mimolette) | OAuth | Nightly, 8 repos x 5 issues | ~6,000+/month |
| 4 | **Local Git Hooks** (pre-commit + pre-push) | OAuth via CLI | Every commit/push | ~300-600/month |

Plus two minor cost centers:

- **Pre-merge review**: ~30/month (manual merge gating)
- **Headroom-learn-all**: Monthly (1st), ~20 sub-agent invocations

---

## Detailed Findings

### 1. GitHub Actions: Claude Blocking Review (29 repos)

**What**: Every PR in 29 repos triggers `claude-blocking-review.yml`, which runs `anthropics/claude-code-action@v1` with Sonnet 4.6 (auto-estimated 10-30 min timeout, no max-turns cap since v3).

**Measured**: 383 runs across 19 repos in 48 days (Apr 1 - May 18) = ~240/month

**Trigger**: PR `opened`, `synchronize`, `ready_for_review`, `reopened`

**Key issue**: Many of these PRs are created by Ralph (autonomous night-shift) and Dependabot. Each push to a Ralph branch triggers a fresh blocking review run on CI — **in addition to** the local pre-push review that already ran.

**Does it need AI?** The blocking review duplicates local pre-push review (`run-review.sh --mode=full-diff`). The rationale was "belt and suspenders" — CI catches anything local review missed. In practice, the local review is already blocking; CI just adds latency and cost.

**Recommendation**:

- **ELIMINATE** for repos where the only committer is you/Ralph (all smartwatermelon repos)
- **KEEP** only for repos with external collaborators (if any)
- This is pure duplication of local review

---

### 2. GitHub Actions: @claude Assistant (Cascading Invocations)

**What**: `claude.yml` fires on `issue_comment`, `pull_request_review_comment`, and **`issues`** events. Ralph's nightly creates issues (Label Audit Reports, nightly reports) which triggers this workflow.

**Measured**: 375+ runs across just 4 repos in 48 days — likely 500+ across all repos

**The cascade**:

```
Ralph nightly runs locally (mimolette)
  → creates "Label Audit Report" issue on GitHub
  → triggers claude.yml (issues event)
  → Claude Code Action spins up, reads issue, potentially comments
```

**Does it need AI?** **No.** Ralph's Label Audit Reports and nightly reports are informational issues. They don't need Claude to comment on them. This is an unintentional trigger — the `issues` event in `claude.yml` was meant for when a human mentions `@claude` in an issue, but it fires on ALL issue events.

**Recommendation**:

- **FIX IMMEDIATELY**: Add `if: contains(github.event.comment.body, '@claude') || ...` guard to the `issues` trigger in `claude.yml`, or remove the `issues` event type entirely (keep only `issue_comment` for @-mention handling)
- This is free savings — purely unintentional cascading

---

### 3. Ralph Night-Shift (Largest Single Consumer)

**What**: Runs nightly at 23:00 on `mimolette.local`. For each of 8 repos:

- Label Audit: 2 Claude calls per repo (issues in batches of 25)
- Night-Shift: Up to 5 issues per repo, up to 15 iterations each via `ralph run --autonomous --backend claude`

**Estimated nightly**:

- Label audit: 8 repos x 2 batches = 16 invocations
- Night-shift: 8 repos x 5 issues x ~5 avg iterations = ~200 invocations
- **Total: ~216 invocations per night = ~6,500/month**

**Auth**: Uses `CLAUDE_CODE_OAUTH_TOKEN` (OAuth subscription, NOT API key). The script explicitly strips `ANTHROPIC_API_KEY` to prevent accidental API billing.

**Does it need AI?**

- **Night-shift issue fixes**: Yes — autonomous code changes require LLM reasoning
- **Label audit classification**: Partially — could use a cheaper model or local LLM for label taxonomy matching
- **Triage (monthly)**: Partially — semantic classification could use a cheaper model

**Recommendation**:

- **REDUCE night-shift scope**: 5 issues x 8 repos = 40 issues/night is aggressive. Most nights probably have fewer than 40 actionable tech-debt issues. Consider: only process repos with recent activity, or cap at 2-3 issues/repo
- **DOWNGRADE label audit model**: Label taxonomy matching is a structured classification task. Could use Haiku or even a local LLM (Llama 3.2 via Ollama)
- **DOWNGRADE triage model**: Similar — Haiku should handle 6-bucket classification
- **Night-shift itself**: Must remain on a capable model (Sonnet minimum) since it writes code

---

### 4. Local Git Hooks (Every Commit/Push)

**What**: Your commit and push workflows invoke Claude CLI agents:

| Hook | Agents | When | Parallel? |
|------|--------|------|-----------|
| commit-msg | code-reviewer + adversarial-reviewer | Every commit | Yes (2 parallel) |
| pre-push (full-diff) | adversarial-reviewer | Every push | No |
| pre-push (codebase) | adversarial-reviewer | Every push | No |

**Auth**: Claude CLI (OAuth subscription via logged-in session)

**Does it need AI?**

- **Per-commit review**: Debatable. Catches issues early but runs on every single commit including WIP commits. High frequency, often redundant with the pre-push review that runs on the full branch.
- **Pre-push review**: More defensible — reviews the full branch diff before it goes remote.
- **Codebase review**: Expensive (300s timeout, full Read/Grep/Glob access). Checks for systemic issues.

**Recommendation**:

- **ELIMINATE per-commit review for WIP commits**: Add a `--wip` or `fixup!` prefix check — skip review for WIP commits
- **KEEP pre-push full-diff**: This is the primary quality gate
- **MAKE codebase review opt-in**: Only run on pushes to PRs, not on every force-push during development. Or gate it to "first push of a branch" only
- **Consider Haiku for commit-level review**: Per-commit review sees small diffs and needs fast turnaround. Haiku could handle "does this obviously break something?" at 1/10th the cost

---

### 5. Pre-Merge Review

**What**: Runs when you invoke `gh pr merge`. Analyzes PR comments, CI status, review state. Single Claude CLI invocation with 180s timeout.

**Does it need AI?** Partially. The structured checks (CHANGES_REQUESTED, CI pass/fail, merge-lock) are deterministic. The "analyze comments for unresolved concerns" piece benefits from AI.

**Recommendation**: **KEEP** — low frequency (~30/month), high value, already gated behind human authorization.

---

### 6. Headroom-Learn-All (Monthly)

**What**: On the 1st of each month, scans all repos for headroom pattern changes, then spawns Claude Code sub-agents to integrate patterns and create PRs.

**Does it need AI?** The pattern detection (`headroom learn`) is local/non-AI. The integration (creating PR with CLAUDE.md changes) does require AI to reason about where to place patterns.

**Recommendation**: **KEEP** — monthly frequency is negligible cost. Could downgrade to Haiku since it's writing structured CLAUDE.md updates, not complex code.

---

## Cascade Analysis: How Ralph Multiplies Costs

Ralph's nightly run triggers a **cascade** of additional AI invocations:

```
1. Ralph runs locally on mimolette (OAuth CLI) ← ~200 invocations/night
   ↓
2. Ralph creates issues (Label Audit, Nightly Report)
   ↓
3. Issue creation triggers claude.yml on GitHub ← ~16 invocations/night (wasted)
   ↓
4. Ralph pushes branches for PRs
   ↓
5. PR push triggers claude-blocking-review.yml ← ~40 invocations/night (duplicative)
   ↓
6. Local pre-push hook ALSO reviews before push ← already counted in #1
```

**Total cascade per night**: 200 (ralph) + 16 (issue cascade) + 40 (CI review of ralph PRs) = **~256 invocations**, when only ~200 are actually needed.

---

## Prioritized Recommendations

### Tier 1: Free Wins (eliminate waste, no functionality loss)

| Action | Savings | Effort |
|--------|---------|--------|
| Fix `claude.yml` issue trigger (stop cascade) | ~250 runs/month | 1 line per repo (or fix in reusable workflow) |
| Disable blocking-review for Ralph-created PRs | ~40 runs/night = ~1,200/month | Add `if: github.actor != 'ralph-bot'` or similar |
| Skip commit-level review for `fixup!`/`wip` commits | ~30-50% of commit reviews | Add prefix check in commit-msg hook |

### Tier 2: Model Downgrades (reduced cost, same functionality)

| Action | Current Model | Recommended | Reasoning |
|--------|--------------|-------------|-----------|
| Label audit classification | Sonnet 4.6 | Haiku 4.5 | Structured taxonomy matching |
| Monthly triage | Sonnet 4.6 | Haiku 4.5 | 6-bucket classification |
| Per-commit review (if kept) | Opus 4.6 (CLI default) | Haiku 4.5 | Small diffs, fast feedback |
| Headroom-learn integration | CLI default | Haiku 4.5 | Structured CLAUDE.md edits |

### Tier 3: Scope Reductions (reduced coverage, cost savings)

| Action | Impact | Savings |
|--------|--------|---------|
| Reduce night-shift to 3 issues/repo (from 5) | 40% fewer ralph iterations | ~80 invocations/night |
| Only run night-shift on repos with recent issues | Skip idle repos | Variable |
| Make codebase review opt-in (not every push) | Lose systemic analysis on routine pushes | ~50 invocations/month |
| Remove blocking-review from low-activity repos | Repos with <1 PR/month don't need it | ~30 runs/month |

### Tier 4: Architecture Changes (larger effort, major savings)

| Action | Impact | Savings |
|--------|--------|---------|
| Replace label audit with local LLM (Ollama + Llama 3.2) | Eliminates 16 cloud calls/night | ~480/month |
| Replace triage with local LLM | Eliminates 16 cloud calls/month | ~16/month |
| Remove GitHub blocking review entirely (trust local review) | Eliminates all CI review | ~250/month |

---

## Usage Flow Diagram

```
                    ┌─────────────────────────────────────────┐
                    │           OAUTH (Subscription)           │
                    └─────────────┬───────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
   LOCAL CLI                 GITHUB ACTIONS            RALPH NIGHTLY
   (your machine)            (29 repos)               (mimolette)
        │                         │                         │
   ┌────┴────┐              ┌─────┴─────┐            ┌─────┴─────┐
   │commit-msg│              │ blocking  │            │night-shift│
   │(2 agents)│              │  review   │            │ (5 issues │
   │pre-push  │              │(per PR    │            │  x 8 repos│
   │(2 agents)│              │  push)    │            │  x 15 iter│
   │pre-merge │              │           │            │  max)     │
   │(1 agent) │              │ @claude   │←───────────│           │
   └──────────┘              │(CASCADING)│  issues    │label-audit│
                             └───────────┘  trigger   │(16 calls) │
                                                      └───────────┘
```

---

## Questions for Decision

1. **Do you want to eliminate the GitHub blocking review entirely?** Local review is already mandatory and blocking. The CI review is redundant.

2. **Should ralph night-shift be throttled?** 5 issues x 8 repos x 15 max iterations is generous. Many of those iterations may be retries on hard problems that end up `blocked` anyway.

3. **Are you willing to accept reduced accuracy on label audit/triage with Haiku or local LLM?** The classification tasks are structured enough that a smaller model should handle them.

4. **Should the @claude assistant workflow be removed entirely?** If you never manually @-mention claude in issues (vs. doing it in Claude Code locally), the whole workflow is just noise.
