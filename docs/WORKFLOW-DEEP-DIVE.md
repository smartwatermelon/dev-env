# Developer Workflow Deep Dive

**Generated**: 2026-03-25
**Scope**: All hooks, scripts, wrappers, and CI/CD that execute during the development lifecycle on this machine, with source attribution.

---

## Table of Contents

1. [Execution Timeline](#execution-timeline)
2. [Layer 1: Claude Code PreToolUse Hooks](#layer-1-claude-code-pretooluse-hooks)
3. [Layer 2: Git Hooks (Global)](#layer-2-git-hooks-global)
4. [Layer 3: Shell Wrappers](#layer-3-shell-wrappers)
5. [Layer 4: Review Scripts](#layer-4-review-scripts)
6. [Layer 5: Merge Authorization](#layer-5-merge-authorization)
7. [Layer 6: GitHub Actions (Remote CI/CD)](#layer-6-github-actions-remote-cicd)
8. [Layer 7: Pre-Merge Review](#layer-7-pre-merge-review)
9. [Complete Flow Diagrams](#complete-flow-diagrams)
10. [File Inventory](#file-inventory)
11. [Environment Variables](#environment-variables)
12. [Known Gaps & Limitations](#known-gaps--limitations)

---

## Execution Timeline

Here is the **complete chronological order** of what fires during a typical development cycle:

```
1. WRITE CODE (in Claude Code session)
   ├─ PreToolUse hooks fire on EVERY Bash/Write/Edit tool call
   │   Source: ~/.claude/settings.json → ~/.claude/scripts/
   │
2. git commit
   ├─ [Claude Code layer] PreToolUse Bash hook → hook-block-all.sh
   │   Source: ~/.claude/scripts/hook-block-all.sh
   │   Chains: 6 blocking scripts (see Layer 1)
   │
   ├─ [Git layer] pre-commit hook
   │   Source: ~/.config/git/hooks/pre-commit
   │   ├─ Branch protection (blocks main/master)
   │   ├─ pre-commit tool (linting/formatting)
   │   └─ run-review.sh (code-reviewer + adversarial-reviewer agents)
   │       Source: ~/.claude/hooks/run-review.sh
   │
   └─ [Git layer] commit-msg hook
       Source: ~/.config/git/hooks/commit-msg
       └─ Conventional commits format validation

3. git push
   ├─ [Claude Code layer] PreToolUse Bash hook (same as step 2)
   │
   └─ [Git layer] pre-push hook
       Source: ~/.config/git/hooks/pre-push
       ├─ Branch protection (blocks push to main/master)
       └─ PR review iteration check (CI status + reviewer comments)

4. GITHUB ACTIONS (remote, costs $$$)
   ├─ claude-code-review.yml → automated PR code review
   │   Source: .github/workflows/claude-code-review.yml (this repo)
   │   Uses: anthropics/claude-code-action@v1
   │
   └─ claude.yml → @claude mention handler
       Source: .github/workflows/claude.yml (this repo)
       Delegates to: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1

5. gh pr merge <number>
   ├─ [Shell layer] gh() bash function or ~/.local/bin/gh wrapper
   │   Source: ~/.config/bash/functions.sh (lines 799-878)
   │   Source: ~/.local/bin/gh (69 lines)
   │   ├─ Blocks REST API merge bypass
   │   ├─ Blocks GraphQL merge bypass
   │   ├─ Blocks global-flag-prefix bypass
   │   └─ Routes to pre-merge-review.sh
   │
   ├─ [Claude Code layer] PreToolUse hook-block-api-merge.sh
   │   Source: ~/.claude/scripts/hook-block-api-merge.sh
   │   (Redundant layer — same blocks as shell wrapper)
   │
   └─ [Review layer] pre-merge-review.sh
       Source: ~/.claude/hooks/pre-merge-review.sh (959 lines)
       ├─ Check merge-lock authorization (30-min TTL)
       ├─ Hard block: CHANGES_REQUESTED review state
       ├─ Hard block: Unresolved CI issues
       ├─ Fetch PR data + smart diff extraction
       ├─ Invoke Claude CLI for analysis
       ├─ Parse SAFE_TO_MERGE / BLOCK_MERGE verdict
       └─ Create non-blocking GitHub issues for tech debt
```

---

## Layer 1: Claude Code PreToolUse Hooks

**Configured in**: `~/.claude/settings.json` (under `"hooks"`)
**When they fire**: Before EVERY tool invocation in Claude Code

### Bash Tool — `hook-block-all.sh`

Master wrapper that chains 6 independent checks. Reads stdin once, pipes to each sub-hook, exits on first failure.

| # | Script | Source | What It Blocks | Exit |
|---|--------|--------|----------------|------|
| 1 | `hook-block-no-verify.sh` | `~/.claude/scripts/` | `--no-verify` on any command | 2 |
| 2 | `hook-block-short-no-verify.sh` | `~/.claude/scripts/` | `-n` on `git commit` / `git push` | 2 |
| 3 | `hook-block-main-commit.sh` | `~/.claude/scripts/` | `git commit` on main/master | 2 |
| 4 | `hook-block-merge-lock-authorize.sh` | `~/.claude/scripts/` | `merge-lock.sh authorize` | 2 |
| 5 | `hook-block-api-merge.sh` | `~/.claude/scripts/` | REST/GraphQL/global-flag merge bypasses | 2 |
| 6 | `hook-block-git-worktree.sh` | `~/.claude/scripts/` | `git worktree` commands | 2 |

### Write/Edit Tool — `hook-block-merge-locks-write.sh`

| Script | Source | What It Blocks |
|--------|--------|----------------|
| `hook-block-merge-locks-write.sh` | `~/.claude/scripts/` | Any write to `merge-locks/` directory |

### EnterWorktree Tool — `hook-block-enter-worktree.sh`

| Script | Source | What It Blocks |
|--------|--------|----------------|
| `hook-block-enter-worktree.sh` | `~/.claude/scripts/` | The `EnterWorktree` built-in tool (unconditional) |

### SessionStart — `hook-session-start.sh`

Currently a no-op placeholder. Reserved for project-specific setup.

### Audit Trail

All blocked commands are logged to `~/.claude/blocked-commands.log` with timestamps. Viewable via `~/.claude/scripts/blocked-audit.sh`.

---

## Layer 2: Git Hooks (Global)

**Configured in**: `~/.config/git/config` (`core.hooksPath = ~/.config/git/hooks`)
**Source directory**: `~/.config/git/hooks/`

### pre-commit

**Source**: `~/.config/git/hooks/pre-commit`

**Execution order**:

1. **Branch protection** — Blocks commits on `main` or `master` (inline check)
2. **pre-commit tool** — Runs linting/formatting
   - Prefers repo-local `.pre-commit-config.yaml`
   - Falls back to `~/.config/pre-commit/config.yaml`
3. **Code review** — Invokes `~/.claude/hooks/run-review.sh` via stdin
   - Passes staged diff
   - Runs both `code-reviewer` and `adversarial-reviewer` agents
   - Blocks commit on BLOCKING severity findings

### commit-msg

**Source**: `~/.config/git/hooks/commit-msg`

**Validates**: Conventional commits format
```
^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\([a-z0-9-]+\))?: .{1,}
```
- Warns (but doesn't block) if subject > 72 chars
- Skips merge commits

### pre-push

**Source**: `~/.config/git/hooks/pre-push`

**Execution order**:

1. **Branch protection** — Blocks pushes to `main` or `master` (reads refs from stdin)
2. **PR review iteration check** — If `gh` CLI available and PR exists:
   - Checks CI status via `gh pr checks`
   - Checks for bot review comments (sentry, claude, coderabbit)
   - If issues found + interactive terminal: prompts "Local review clean? (y/N)"
   - Bypass: `POSTPUSH_LOOP=1` skips the interactive prompt

### lint-shell.sh (supplementary)

**Source**: `~/.config/git/hooks/lint-shell.sh`

Not auto-triggered by git. Runs `shellcheck` and `shfmt` on shell scripts.

---

## Layer 3: Shell Wrappers

Two layers intercept `gh` commands before they reach the real binary.

### gh() Bash Function

**Source**: `~/.config/bash/functions.sh` (lines 799-878)
**Loaded by**: Interactive bash/zsh sessions via `BASH_ENV`

**Intercepts**:

| Pattern | Action |
|---------|--------|
| `gh api ...pulls/NNN/merge` | BLOCKED (REST API bypass) |
| `gh api graphql...mergePullRequest` | BLOCKED (GraphQL bypass) |
| `gh -R owner/repo pr merge` | BLOCKED (global flag prefix bypass) |
| `gh pr merge <number>` | Routes through `~/.claude/hooks/pre-merge-review.sh` |
| `gh ... --help` | Passes through (documented bypass) |
| All other `gh` commands | Pass through unchanged |

### ~/.local/bin/gh Wrapper Script

**Source**: `~/.local/bin/gh` (69 lines)
**When**: Non-interactive shells, or shells without the bash function loaded

**Same interception logic** as the bash function, plus:
- Uses `_GH_REVIEW_DONE=1` env var to prevent double-review
- Finds real `gh` by scanning PATH and excluding itself
- Routes token via `CLAUDE_GH_TOKEN_ROUTER` if set

### Why Two Layers?

| Context | Which fires |
|---------|-------------|
| Interactive bash session | `gh()` function (higher priority than PATH) |
| Non-interactive shell, zsh without functions | `~/.local/bin/gh` wrapper |
| Claude Code Bash tool | Both (PreToolUse hook + whichever shell wrapper) |

---

## Layer 4: Review Scripts

### run-review.sh (Pre-Commit Code Review)

**Source**: `~/.claude/hooks/run-review.sh` (736 lines)
**Called by**: `pre-commit` hook
**Cost**: FREE (local Claude CLI invocation)

**Strategy by diff size**:

| Diff Size | Strategy |
|-----------|----------|
| 0 lines | Skip (no changes) |
| Markdown/lockfile only | Skip |
| Cached identical diff | Skip (SHA256 cache in `.git/claude-review-cache/`) |
| <= 1000 lines | Full review (both agents) |
| 1000-2500 lines | Chunked file-by-file review |
| > 2500 lines | **BLOCKED** — must split commits |

**Agent invocations** (always both, sequentially):

1. `code-reviewer` — Looks for BLOCKING severity issues
2. `adversarial-reviewer` — Runs on every commit regardless

**Security-critical file detection**:
- Path patterns: auth, oauth, jwt, password, payment, billing, database, crypto, etc.
- Content patterns: API_KEY, SELECT/INSERT, eval(), fetch(), subprocess, etc.
- File extensions: .sql, .env, .key, .pem, .crt
- Logs "elevated scrutiny" for these files

**Review logs**:
- Per-repo: `$(git rev-parse --git-dir)/last-review-result.log`
- Global pointer: `~/.claude/last-review-result.log`
- Fields: timestamp, repo, branch, commit, verdict

**Claude CLI flags**: `--no-session-persistence`, `--agent code-reviewer` / `--agent adversarial-reviewer`
**Timeout**: Configurable via `git config review.timeout` (default 120s)

### post-push-status.sh

**Source**: `~/.claude/scripts/post-push-status.sh` (134 lines)
**Called by**: Post-push loop automation
**Purpose**: Fetch CI status + bot review comments for a pushed PR

**Output format**:
```
CI_STATE=<SUCCESS|PENDING|FAILURE>
FINDING source=<bot> file="<path>" line=<line> comment=<text>
```

---

## Layer 5: Merge Authorization

### merge-lock.sh

**Source**: `~/.claude/hooks/merge-lock.sh` (150 lines)
**Lock directory**: `~/.claude/merge-locks/pr-<number>.lock`
**TTL**: 30 minutes (1800 seconds)

**Commands**:

| Command | Who Can Run | Purpose |
|---------|-------------|---------|
| `authorize <pr> [reason]` | Human only (blocked from Claude Code) | Create time-limited merge authorization |
| `check <pr>` | Any process | Check if PR is authorized (exit 0/1) |
| `status <pr>` | Any process | Show detailed status with time remaining |
| `list` | Any process | List all active authorizations |

**Protection layers preventing Claude from self-authorizing**:

1. `hook-block-merge-lock-authorize.sh` — PreToolUse Bash hook blocks the command
2. `hook-block-merge-locks-write.sh` — PreToolUse Write/Edit hook blocks file creation
3. `hook-block-merge-lock.sh` — Blocks shell bypass attempts (`bash -c "merge-lock.sh authorize"`)

---

## Layer 6: GitHub Actions (Remote CI/CD)

**Source repo**: `smartwatermelon/claude-wrapper` (this repo)
**Cost**: ~$0.008/minute on `ubuntu-latest`

### claude-code-review.yml — Automated PR Code Review

**Source**: `.github/workflows/claude-code-review.yml`
**Triggers**: `pull_request` — opened, synchronize, ready_for_review, reopened

**Steps**:
1. `actions/checkout@v4` (shallow clone, `fetch-depth: 1`)
2. `anthropics/claude-code-action@v1` with plugin `code-review@claude-code-plugins`

**Permissions**: contents:read, pull-requests:read, issues:read, id-token:write
**Secret**: `CLAUDE_CODE_OAUTH_TOKEN`

### claude.yml — Interactive Claude Assistant (@claude mentions)

**Source**: `.github/workflows/claude.yml`
**Triggers**: issue_comment, pull_request_review_comment, issues, pull_request_review

**Security guards** (in `if:` condition):
- Comment/issue must contain `@claude`
- Author must be OWNER, MEMBER, or COLLABORATOR

**Delegates to reusable workflow**:
```
smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v1
```

### Reusable Workflow: claude-assistant.yml

**Source repo**: `smartwatermelon/github-workflows`
**Version**: `v1` tag (currently identical to `main`)

**Steps**:
1. `actions/checkout@v4` (pinned SHA: `34e11487...`, `fetch-depth: 1`)
2. `anthropics/claude-code-action@v1` (pinned SHA: `26ec0412...`)

**Permissions**: contents:read, pull-requests:read, issues:read, id-token:write
**Additional permissions**: actions:read (for reading CI results on PRs)

### External Dependencies

| Dependency | Version | Source |
|------------|---------|--------|
| `actions/checkout` | v4 (pinned SHA) | github.com/actions/checkout |
| `anthropics/claude-code-action` | v1 (pinned SHA) | github.com/anthropics/claude-code-action |
| `code-review@claude-code-plugins` | latest | Anthropics plugin marketplace |
| `smartwatermelon/github-workflows` | v1 tag | Private org reusable workflows |

---

## Layer 7: Pre-Merge Review

### pre-merge-review.sh

**Source**: `~/.claude/hooks/pre-merge-review.sh` (959 lines)
**Called by**: `gh()` wrapper / `~/.local/bin/gh` wrapper
**Cost**: FREE (local Claude CLI) but gates an expensive action (merge)

**Execution order**:

```
1. FAST CHECKS (< 1 second each, before Claude invocation)
   ├─ merge-lock.sh check <pr>     → exit 1 if not authorized
   ├─ CHANGES_REQUESTED check      → exit 1 if unresolved reviews
   └─ NEUTRAL CI status check      → exit 1 if unresolved CI issues

2. DATA GATHERING
   ├─ GraphQL: PR metadata (title, reviews, reviewDecision, statusCheckRollup)
   ├─ REST: Inline PR comments (filtered: outdated + resolved removed)
   ├─ REST: Conversation PR comments (filtered by commit timestamp)
   └─ Diff: Smart extraction based on size
       ├─ <= 1000 lines: full diff
       └─ > 1000 lines: commented files full + security files full + others truncated

3. CLAUDE ANALYSIS
   ├─ Invoke Claude CLI with --no-session-persistence
   ├─ Timeout: 120 seconds
   └─ Parse verdict: SAFE_TO_MERGE or BLOCK_MERGE

4. POST-ANALYSIS
   ├─ If SAFE_TO_MERGE:
   │   ├─ Create non-blocking GitHub issues (tech-debt, security labels)
   │   └─ Exit 0 (merge proceeds)
   └─ If BLOCK_MERGE:
       ├─ Print blocking issues
       └─ Exit 1 (merge halted)
```

**Non-interactive enforcement**: When `CLAUDECODE` env var is set, requires `--squash` and `--delete-branch` flags.

**Non-blocking issue creation**:
- Parses `NON_BLOCKING_ISSUE:...END_ISSUE` blocks from Claude output
- Creates GitHub issues via `gh issue create`
- Labels: `tech-debt` (yellow), `security` (red) for security-critical files
- Fallback: saves to `~/.claude/pending-issues/` if API fails

---

## Complete Flow Diagrams

### The Commit Flow

```
Developer writes code in Claude Code
         │
         ▼
┌─────────────────────────────────────────────┐
│  Claude Code PreToolUse (every Bash call)   │
│  Source: ~/.claude/settings.json            │
│  ┌─────────────────────────────────────┐    │
│  │ hook-block-all.sh chains:           │    │
│  │  1. --no-verify block               │    │
│  │  2. -n shorthand block              │    │
│  │  3. main branch commit block        │    │
│  │  4. merge-lock authorize block      │    │
│  │  5. API merge bypass block          │    │
│  │  6. git worktree block              │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Write/Edit: merge-locks-write block │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ EnterWorktree: unconditional block  │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
         │ (if not blocked)
         ▼
┌─────────────────────────────────────────────┐
│  git commit                                 │
│  Source: ~/.config/git/hooks/               │
│  ┌─────────────────────────────────────┐    │
│  │ pre-commit hook                     │    │
│  │  1. Branch protection (main block)  │    │
│  │  2. pre-commit tool (lint/format)   │    │
│  │  3. run-review.sh                   │    │
│  │     → code-reviewer agent (FREE)    │    │
│  │     → adversarial-reviewer (FREE)   │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ commit-msg hook                     │    │
│  │  → Conventional commits validation  │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### The Push Flow

```
┌─────────────────────────────────────────────┐
│  git push                                   │
│  ┌─────────────────────────────────────┐    │
│  │ PreToolUse: same 6 checks as commit │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ pre-push hook                       │    │
│  │  1. Branch protection (main block)  │    │
│  │  2. PR review iteration check       │    │
│  │     → CI status via gh pr checks    │    │
│  │     → Bot comments check            │    │
│  │     → Interactive prompt if issues   │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
         │ (if not blocked)
         ▼
    Code arrives on GitHub
         │
         ▼
┌─────────────────────────────────────────────┐
│  GitHub Actions ($$$)                       │
│  Source: .github/workflows/ (this repo)     │
│  ┌─────────────────────────────────────┐    │
│  │ claude-code-review.yml              │    │
│  │  → anthropics/claude-code-action@v1 │    │
│  │  → code-review plugin              │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ claude.yml (on @claude mention)     │    │
│  │  → smartwatermelon/github-workflows │    │
│  │    /claude-assistant.yml@v1         │    │
│  │  → anthropics/claude-code-action@v1 │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### The Merge Flow

```
         Human says "merge it"
              │
              ▼
┌────────────────────────────────────────────────────┐
│  Human runs: merge-lock.sh authorize <PR> "reason" │
│  Source: ~/.claude/hooks/merge-lock.sh              │
│  Creates: ~/.claude/merge-locks/pr-<PR>.lock        │
│  TTL: 30 minutes                                    │
└────────────────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────┐
│  gh pr merge <number> --squash --delete-branch     │
│                                                     │
│  Layer A: PreToolUse hook                           │
│    Source: ~/.claude/scripts/hook-block-api-merge.sh │
│    Blocks: REST, GraphQL, global-flag bypasses       │
│                                                     │
│  Layer B: Shell wrapper                              │
│    Source: ~/.config/bash/functions.sh gh()          │
│       OR: ~/.local/bin/gh                            │
│    Blocks: Same 3 patterns (redundant safety)        │
│    Routes: → pre-merge-review.sh                     │
│                                                     │
│  Layer C: pre-merge-review.sh                        │
│    Source: ~/.claude/hooks/pre-merge-review.sh       │
│    1. merge-lock check (authorized? TTL valid?)      │
│    2. CHANGES_REQUESTED block                        │
│    3. Unresolved CI block                            │
│    4. Claude analysis (SAFE_TO_MERGE / BLOCK_MERGE)  │
│    5. Non-blocking issue creation                    │
│                                                     │
│  Layer D: Real gh pr merge                           │
│    Only reached if all layers pass                    │
│    Source: Homebrew gh binary                         │
└────────────────────────────────────────────────────┘
```

---

## File Inventory

### Source: `~/.claude/scripts/` (Claude Code hooks)

| File | Lines | Purpose |
|------|-------|---------|
| `hook-block-all.sh` | ~30 | Master chain for all Bash blocking hooks |
| `hook-block-no-verify.sh` | ~30 | Blocks `--no-verify` |
| `hook-block-short-no-verify.sh` | ~20 | Blocks `-n` on git commit/push |
| `hook-block-main-commit.sh` | ~35 | Blocks commits on main/master |
| `hook-block-merge-lock-authorize.sh` | ~35 | Blocks `merge-lock.sh authorize` |
| `hook-block-merge-lock.sh` | ~20 | Blocks merge-lock directory references |
| `hook-block-api-merge.sh` | 84 | Blocks REST/GraphQL/global-flag merge bypasses |
| `hook-block-git-worktree.sh` | ~40 | Blocks `git worktree` |
| `hook-block-enter-worktree.sh` | ~30 | Blocks EnterWorktree tool |
| `hook-block-merge-locks-write.sh` | ~25 | Blocks Write/Edit to merge-locks/ |
| `hook-session-start.sh` | 10 | No-op session start placeholder |
| `status-line.sh` | 35 | Terminal status line (branch + status) |
| `blocked-audit.sh` | 35 | View blocked command log |
| `post-push-status.sh` | 134 | Fetch CI status + bot comments for PR |
| `update-tools.sh` | 55 | Update git-sourced Claude Code components |

### Source: `~/.config/git/hooks/` (Git hooks)

| File | Purpose |
|------|---------|
| `pre-commit` | Branch protection + pre-commit tool + code review |
| `commit-msg` | Conventional commits format validation |
| `pre-push` | Branch protection + PR review iteration check |
| `lint-shell.sh` | Supplementary shellcheck + shfmt (not auto-triggered) |

### Source: `~/.claude/hooks/` (Review infrastructure)

| File | Lines | Purpose |
|------|-------|---------|
| `run-review.sh` | 736 | Pre-commit code review (two agents) |
| `pre-merge-review.sh` | 959 | Pre-merge analysis (Claude CLI) |
| `merge-lock.sh` | 150 | Merge authorization management |

### Source: `~/.config/bash/` (Shell configuration)

| File | Relevant Content |
|------|-----------------|
| `functions.sh` | `gh()` wrapper function (lines 799-878) |

### Source: `~/.local/bin/` (PATH wrappers)

| File | Lines | Purpose |
|------|-------|---------|
| `gh` | 69 | Non-interactive shell gh wrapper |

### Source: `.github/workflows/` (this repo)

| File | Triggers | Uses |
|------|----------|------|
| `claude-code-review.yml` | PR opened/sync/reopen | `anthropics/claude-code-action@v1` |
| `claude.yml` | @claude mentions | `smartwatermelon/github-workflows/claude-assistant.yml@v1` |

### Source: `smartwatermelon/github-workflows` (external repo)

| File | Purpose |
|------|---------|
| `.github/workflows/claude-assistant.yml` | Reusable Claude Code Action invocation |

### Source: `~/.config/git/config` (Git configuration)

| Setting | Value | Effect |
|---------|-------|--------|
| `core.hooksPath` | `~/.config/git/hooks` | All repos use global hooks |
| `core.fsmonitor` | true | File system monitoring |
| `push.autoSetupRemote` | true | Auto-setup remote tracking |
| `pull.rebase` | true | Rebase on pull |
| `diff.algorithm` | histogram | Better rename detection |
| `rerere.enabled` | true | Reuse recorded resolutions |

### Source: `~/.claude/settings.json` (Claude Code settings)

| Setting | Value | Effect |
|---------|-------|--------|
| `BASH_ENV` | `~/.config/bash/functions.sh` | Loads gh() wrapper in all shells |
| `CLAUDE_CODE_SHELL` | `/opt/homebrew/bin/bash` | Uses Homebrew bash (5.x) |
| `includeCoAuthoredBy` | true | Adds co-author to commits |
| `alwaysThinkingEnabled` | true | Extended thinking for analysis |

---

## Environment Variables

| Variable | Set By | Checked By | Purpose |
|----------|--------|------------|---------|
| `CLAUDECODE` | Claude Code runtime | pre-merge-review.sh, run-review.sh | Detect Claude Code context |
| `POSTPUSH_LOOP` | Post-push automation | pre-push hook | Skip interactive Protocol 4 prompt |
| `BASH_ENV` | settings.json | Bash | Load shell functions in non-interactive shells |
| `CLAUDE_CODE_SHELL` | settings.json | Claude Code | Use Homebrew bash 5.x |
| `CLAUDE_CLI` | (optional) | run-review.sh, pre-merge-review.sh | Override Claude CLI path (default: ~/.local/bin/claude) |
| `_GH_REVIEW_DONE` | ~/.local/bin/gh wrapper | Same wrapper | Prevent double pre-merge review |
| `CLAUDE_GH_TOKEN_ROUTER` | (optional) | ~/.local/bin/gh | Token routing for multi-account setups |
| `REVIEW_LOG` | (optional) | run-review.sh | Override review log location |
| `PENDING_ISSUES_DIR` | (optional) | pre-merge-review.sh | Override pending issues fallback dir |

---

## Known Gaps & Limitations

| Gap | Layer | Risk | Mitigation |
|-----|-------|------|------------|
| `gh api graphql --input file.json` with `mergePullRequest` mutation | Shell wrapper + PreToolUse | Medium | Protocol 6 (behavioral rule) — Claude must not construct such files |
| Non-interactive shells that skip both wrappers | Shell layer | Low | PreToolUse hook provides redundant coverage |
| Review cache allows skipping re-review of identical diff | run-review.sh | Low | Cache is SHA256 of exact diff; any change invalidates |
| Merge-lock TTL is clock-based | merge-lock.sh | Low | 30-min window is short; human must re-authorize if expired |
| pre-commit tool not installed in repo | pre-commit hook | Low | Falls back to global config; warns if neither found |
| Shellcheck SC2312 excluded | lint-shell.sh | Negligible | Intentional suppression of specific warning |

---

## Cost Model

| Stage | Where | Cost | Frequency |
|-------|-------|------|-----------|
| PreToolUse hooks | Local | FREE | Every tool call |
| pre-commit (lint + review) | Local | FREE | Every commit |
| commit-msg validation | Local | FREE | Every commit |
| pre-push checks | Local | FREE | Every push |
| claude-code-review.yml | GitHub Actions | ~$0.01-0.03/run | Every PR event |
| claude.yml | GitHub Actions | ~$0.004-0.01/run | Every @claude mention |
| pre-merge-review.sh | Local | FREE | Every merge attempt |
| merge-lock.sh | Local | FREE | Every merge authorization |

**Design principle**: Maximize free local checks to minimize expensive remote CI iterations.
