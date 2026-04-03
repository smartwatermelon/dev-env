# Phase 2: Local Whole-Codebase Review

**Date**: 2026-04-02
**Status**: Design
**Parent**: [Infrastructure Consolidation Design](2026-03-25-infrastructure-consolidation-design.md)
**Goal**: Replace all remote AI review (Claude CI + Sentry/Seer) with local whole-codebase review that catches the same classes of bugs.

---

## Motivation

Phase 1 validation (2026-03-25 through 2026-04-02) showed:

- Local review (adversarial-reviewer + code-reviewer) catches more than before Phase 1
- But remote review still catches things local misses — almost entirely **Sentry/Seer** findings
- Seer catches cross-file semantic bugs that diff-only local review cannot see

The gap is not model capability — local agents use the same Claude Opus. The gap is **context**: local agents only see the diff, while Seer reasons about the whole codebase.

### Why not keep Seer?

Seer's backend (Sentry) is unreliable — it gets overloaded and rate-limited. This creates an impossible choice:

- **Blocking Seer**: merge gates on something we can't control
- **Non-blocking Seer**: findings get missed because we don't wait for them

The only sustainable path is replacing Seer's capabilities with local review that we fully control.

### What Seer catches that local doesn't (from PR evidence)

| Bug class | Example | Root cause of gap |
|-----------|---------|-------------------|
| Cross-file field mismatches | DropboxProvider missing `mediaUri` expected by detail view | Agent only sees diff, not consumers |
| Dead UI elements | Button without `onPress` handler | Agent doesn't see full component |
| Date/timezone inconsistencies | UTC vs local date causing wrong-day cache keys | Agent doesn't see how dates flow between modules |
| Data flow ordering | Diff calculated after file already overwritten | Agent doesn't see surrounding workflow steps |
| Platform-specific gotchas | Bash array export only passing first element | Agent doesn't see how variable is consumed |
| Cache invalidation bugs | Refresh using wrong date key for cache lookup | Agent doesn't see cache key construction elsewhere |

### What Semgrep covers (and doesn't)

| Category | Semgrep | Needs agent reasoning |
|----------|---------|----------------------|
| Known vulnerability patterns | Yes | No |
| Supply chain / dependency issues | Yes (pre-push) | No |
| Cross-file semantic bugs | Partial (pro rules) | **Yes** |
| Application logic bugs | No | **Yes** |
| Platform gotchas | No | **Yes** |

Semgrep is complementary but does not close the gap. The agent needs codebase access.

---

## Design

### Core change: agent-driven codebase exploration at pre-push

Today's pre-push full-diff review sends the diff to agents and asks them to reason about cross-file issues. The agents can only speculate — they don't have tool access to verify.

**New behavior**: Pre-push whole-codebase review gives agents full tool access (Read, Grep, Glob) and instructs them to actively explore the codebase, following references from the diff to understand downstream impact.

### Hook pipeline (unchanged tiers, new pre-push capability)

```
PRE-COMMIT (fast gate, every commit):
  1. pre-commit framework (formatters, linters)
  2. Semgrep scan (all files, --config auto --error --quiet)
  3. run-review.sh --mode=commit (diff-only, code-reviewer + adversarial-reviewer)

PRE-PUSH (thorough gate, once before push):
  1. Semgrep supply-chain scan (lockfile changes)
  2. run-review.sh --mode=full-diff (diff against main, diff-only review)
  3. NEW: run-review.sh --mode=codebase (diff + full tool access, whole-codebase review)
```

### Agent behavior in `--mode=codebase`

The agent receives:

- The full diff (main...HEAD)
- The repo root path
- Tool access: Read, Grep, Glob (via Claude Code subagent)

The agent is instructed to:

1. Read the diff to identify what changed
2. For each changed file, read the full file for surrounding context
3. Follow imports/references one level out — find consumers, callers, and related modules
4. Look for the specific bug classes Seer catches (field contracts, data flow, platform semantics, cache coherence, dead code paths)
5. Classify findings as BLOCK or NON_BLOCKING_ISSUE

### Finding classification and output format

**BLOCK findings** — directly related to the diff, must fix before push:

```
VERDICT: BLOCK
ISSUE: <title>
SEVERITY: <CRITICAL|HIGH|MEDIUM>
LOCATION: <file:line>
DETAILS: <explanation and fix suggestion>
```

**NON_BLOCKING_ISSUE findings** — tangential or pre-existing, filed as GitHub issues:

Uses the same structured format that `pre-merge-review.sh` already parses:

```
NON_BLOCKING_ISSUE:
TITLE: <short title>
SOURCE: pre-push whole-codebase review
LOCATION: <file:line>
DETAILS: <explanation>
END_ISSUE
```

### Shared issue-creation library

Extract from `pre-merge-review.sh` into a shared library sourced by both scripts:

- `parse_nonblocking_issues()` — parse NON_BLOCKING_ISSUE blocks
- `build_issue_body()` — construct GitHub issue body
- `create_nonblocking_issues()` — create issues via `gh` with fallback to `~/.claude/pending-issues/`
- `needs_security_label()` — label routing
- `_process_issue_block()` — individual issue processing

**Source file**: `~/.claude/hooks/lib-review-issues.sh`

Both `run-review.sh` and `pre-merge-review.sh` source this library. No behavior change for pre-merge; pre-push gains issue-creation capability.

### Parallelism

Pre-push already runs full-diff review. The new codebase review runs **in parallel** with it:

```
pre-push:
  ├── semgrep supply-chain (if lockfile changed)
  ├── run-review.sh --mode=full-diff (existing, parallel)
  └── run-review.sh --mode=codebase  (new, parallel)
```

Both must pass for push to proceed. Non-blocking issues from either are filed.

---

## Implementation plan

### Step 1: Extract shared issue library

- Create `~/.claude/hooks/lib-review-issues.sh` from `pre-merge-review.sh` functions
- Update `pre-merge-review.sh` to source the library
- Verify pre-merge behavior unchanged

### Step 2: Add `--mode=codebase` to `run-review.sh`

- New mode that invokes a Claude Code subagent with tool access
- Agent prompt focuses on the six bug classes identified from Seer findings
- Output format: BLOCK findings (same as existing) + NON_BLOCKING_ISSUE blocks
- Sources `lib-review-issues.sh` to file non-blocking issues

### Step 3: Wire into pre-push hook

- Add `--mode=codebase` call in parallel with existing `--mode=full-diff`
- Both verdicts must pass; non-blocking issues filed from both

### Step 4: Validation (1 week)

- Run with both local whole-codebase review and remote Seer active
- Compare: does local now catch what Seer catches?
- Track false positive rate — agent with full codebase access may over-flag

### Step 5: Remove remote AI review

- Remove `claude-code-review.yml` from all repos
- Remove Seer integration (if any remaining)
- Archive `smartwatermelon/github-workflows` (or reduce to ci-gate only)

---

## Risks

| Risk | Mitigation |
|------|------------|
| Codebase review is slow (large repos) | Parallel execution; agent explores selectively, not exhaustively |
| Agent over-flags pre-existing issues as BLOCK | Prompt instructs: BLOCK only for issues introduced or worsened by the diff |
| Non-blocking issue spam | Ralph burndown addresses issues; tune threshold if volume too high |
| Token usage on Max subscription | Max 200 covers typical usage; monitor for extreme cases |
| Shared library extraction breaks pre-merge | Step 1 validates with existing pre-merge tests before proceeding |

---

## Success criteria

1. Local whole-codebase review catches the same categories of bugs Seer was catching
2. No merge-blocking dependency on external services (Sentry, GitHub Actions AI)
3. Non-blocking findings flow automatically into GitHub issues for Ralph burndown
4. Pre-push completes in under 3 minutes for typical branches (parallel execution)
5. CI costs reduced to lint + test + Semgrep only (~$0.001-0.005/PR)

---

## What this replaces in the original roadmap

The original Phase 2 was "reduce remote review" by changing CI triggers. This design replaces that with a more ambitious goal: **eliminate remote AI review entirely** by closing the local coverage gap first. Phases 3-5 (consolidated repo, install.sh, cutover) remain unchanged.
