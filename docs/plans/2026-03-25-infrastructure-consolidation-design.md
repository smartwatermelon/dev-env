# Infrastructure Consolidation & Local Review Enhancement

**Date**: 2026-03-25
**Status**: Design — approved, decisions resolved
**Goal**: One repo, one clone, one install. Replace remote AI review with enhanced local review. Cut CI costs to near-zero.

---

## Current State

The development safety environment is spread across 4 locations with significant duplication:

```
~/.config/git/hooks/        ← 4 git hooks
~/.config/bash/functions.sh ← gh() wrapper (buried in a larger file)
~/.claude/hooks/            ← 3 review scripts (run-review.sh, pre-merge-review.sh, merge-lock.sh)
~/.claude/scripts/          ← 10+ Claude Code PreToolUse hooks + utilities
~/.claude/settings.json     ← wiring
~/.local/bin/gh             ← redundant gh wrapper
smartwatermelon/github-workflows ← reusable CI workflow (separate repo)
```

**Problems**:
- No single source of truth
- 5 identified redundancies (see Section 1)
- Paying for remote AI review that duplicates local review
- New machine setup requires manually recreating this structure
- Updating a hook means knowing which of 4 locations to edit

---

## Target State

One repo — `smartwatermelon/dev-env` — containing:

```
dev-env/
├── install.sh                    # Symlinks everything into place, blue/green settings merge
├── uninstall.sh                  # Clean removal
│
├── git-hooks/                    # Global git hooks
│   ├── pre-commit                # Branch protection + pre-commit tool + Semgrep + AI review
│   ├── commit-msg                # Conventional commits validation
│   └── pre-push                  # Branch protection + full-diff AI review + PR iteration check
│
├── claude-hooks/                 # Claude Code PreToolUse hooks
│   ├── hook-block-all.sh         # Master chain (consolidated, see Section 1)
│   ├── hook-block-merge-locks.sh # Merged: authorize + directory + write blocks
│   ├── hook-block-api-merge.sh   # Unchanged (3 bypass patterns)
│   ├── hook-block-no-verify.sh   # Merged: --no-verify + -n
│   └── hook-block-enter-worktree.sh # Unchanged (also covers git worktree)
│
├── review/                       # Review scripts
│   ├── run-review.sh             # Pre-commit review orchestrator
│   ├── pre-merge-review.sh       # Pre-merge analysis
│   └── merge-lock.sh             # Merge authorization
│
├── shell/                        # Shell integration
│   └── gh-wrapper.sh             # gh() function (extracted from functions.sh)
│
├── ci-workflows/                 # Reusable GitHub Actions workflows
│   ├── ci-gate.yml               # Lightweight lint+test+semgrep gate (reusable, called by repos)
│   └── claude-assistant.yml      # Interactive @claude (moved from github-workflows)
│
├── settings/                     # Claude Code configuration
│   ├── settings.json.template    # Template with hook paths
│   └── project-config.sh.template # Per-project config template
│
└── docs/
    ├── ARCHITECTURE.md           # This design doc (post-implementation)
    └── CUSTOMIZATION.md          # How to extend for specific projects
```

**Agent dependencies** (external, not bundled):
- `adversarial-reviewer`: `code-critic@smartwatermelon-marketplace` — Andrew's own agent, published separately so others can use it standalone
- `code-reviewer`: `comprehensive-review@claude-code-workflows` (wshobson/agents) — third-party, installed via Claude Code plugin system

Both are referenced by name in hook invocations but do not live in this repo.

---

## Section 1: Deduplication

### 1A. Eliminate `~/.local/bin/gh` wrapper

**Action**: Delete. The `BASH_ENV` setting ensures `gh()` loads in all shells Claude Code spawns. No other shells are used.

**Files removed**: `~/.local/bin/gh` (69 lines)

### 1B. Merge `hook-block-no-verify.sh` + `hook-block-short-no-verify.sh`

**Action**: Single script checking both `--no-verify` and `-n` on `git commit`/`git push`.

**Files removed**: `hook-block-short-no-verify.sh`
**Files changed**: `hook-block-no-verify.sh` (gains one additional regex)

### 1C. Merge merge-lock blocking scripts

Three scripts currently:
- `hook-block-merge-lock.sh` (blocks directory references)
- `hook-block-merge-lock-authorize.sh` (blocks authorize/revoke commands)
- `hook-block-merge-locks-write.sh` (blocks Write/Edit to directory)

**Action**: One script `hook-block-merge-locks.sh` with three check functions. The Write/Edit hook config in `settings.json` points to the same script with a mode flag or detects tool type from input.

**Files removed**: 2
**Files added**: 1 (replacing 3)

### 1D. Fold `hook-block-main-commit.sh` into `hook-block-no-verify.sh` or remove

The git `pre-commit` hook already blocks commits to main. The PreToolUse hook is a faster error message in Claude Code but not a unique safety layer.

**Action**: Remove. The git hook is the authoritative enforcement.

**Files removed**: `hook-block-main-commit.sh`
**Chain updated**: `hook-block-all.sh` drops from 6 hooks to 3:
1. `hook-block-no-verify.sh` (covers `--no-verify`, `-n`)
2. `hook-block-merge-locks.sh` (covers authorize, directory, write)
3. `hook-block-api-merge.sh` (covers REST, GraphQL, global-flag)

`hook-block-git-worktree.sh` is folded into `hook-block-enter-worktree.sh` (one script, checks both Bash `git worktree` commands and the EnterWorktree tool via input detection).

### 1E. Consolidate `smartwatermelon/github-workflows`

The reusable `claude-assistant.yml` workflow moves into `dev-env/ci-workflows/`. The `github-workflows` repo becomes unnecessary (or archived).

**Repos removed**: `smartwatermelon/github-workflows` (archived)

### Net result

| Metric | Before | After |
|--------|--------|-------|
| Blocking scripts in PreToolUse chain | 6 | 3 |
| Total hook/script files | ~18 | ~12 |
| Source locations | 4 directories + 2 repos | 1 repo |
| Redundant gh wrapper | yes (`~/.local/bin/gh`) | removed |
| Redundant branch protection layers | 3 | 1 (git hook) |

---

## Section 2: Enhanced Local Review (Replacing Seer + Remote AI)

### 2A. Adversarial reviewer enhancements (Option 4 from research doc)

**4A — Production failure patterns checklist** added to agent prompt:
- Platform guards without dual-path testing
- Silent env var failures
- Test isolation (missing afterEach cleanup)
- Selector/ID uniqueness collisions
- Feature discoverability (removed entry points)
- Async error boundaries across file boundaries
- RLS policy changes (auto-critical)

**4B — Cross-file awareness prompts** added to agent prompt:
- When diff removes user-facing strings: "Is this feature still discoverable?"
- When diff adds platform guards: "Is the other platform path tested?"
- When diff modifies shared state/IDs: "What else uses this identifier?"
- When diff changes error handling: "Where does this error propagate to?"
- Framed as Questions, not assumptions

**4C — Severity recalibration**:
- Promote to Critical: missing afterEach cleanup, untested platform paths, unguarded env vars
- Promote to Concern: removed UI entry points, unchecked testID collisions

**4D — Increased diff context**:
- `git diff --cached -U10` in `run-review.sh` (was default -U3)

**Estimated effort**: ~1 hour, prompt edits + one line in run-review.sh

### 2B. Semgrep integration (Option 3 from research doc)

Add Semgrep to pre-commit hook, after linting and before AI review:

```bash
# In pre-commit hook, after pre-commit tool:
if command -v semgrep &>/dev/null; then
  semgrep scan --config auto --error --quiet --staged 2>/dev/null
fi
```

- Deterministic, fast (<30s), offline
- Catches known vulnerability patterns AI reviewers miss
- Same rules run in CI for consistency

**Install**: `pip install semgrep` (added to install.sh)

### 2C. Full-diff pre-push review (NEW — replaces Seer's cross-file value)

Add to `pre-push` hook: after branch protection, before PR iteration check:

```bash
# Full feature-branch diff review (catches cross-file integration issues)
if [[ "${remote_ref}" != *main* ]] && [[ "${remote_ref}" != *master* ]]; then
  full_diff=$(git diff main...HEAD)
  if [[ -n "${full_diff}" ]]; then
    echo "${full_diff}" | ~/.claude/hooks/run-review.sh --mode=full-diff
  fi
fi
```

`run-review.sh` gains a `--mode=full-diff` flag that:
- Uses the adversarial-reviewer only (not code-reviewer — that already ran per-commit)
- Passes the full `main..HEAD` diff instead of staged changes
- Focuses the prompt on cross-file integration issues specifically
- Has its own cache (keyed on full-diff SHA256, invalidated on any new commit)
- Respects the same size thresholds (chunked >1000 lines, blocked >2500 lines)

This is the key new layer. It sees everything Seer saw — the complete PR surface — but runs locally for free.

**Estimated effort**: ~2 hours (run-review.sh mode flag + pre-push hook integration + prompt tuning)

---

## Section 3: Lightweight CI Gate

### What it replaces

| Removed | Reason |
|---------|--------|
| `claude-code-review.yml` | Replaced by enhanced local review |
| `anthropics/claude-code-action` dependency | No longer needed for PR review |
| Sentry/Seer CI integration | Already removed (unreliable) |

### What the new CI gate does

This is a **reusable workflow** in `dev-env`. Repos call it with a one-line `uses:` reference. Updates to the gate propagate to all repos immediately.

```yaml
# ci-workflows/ci-gate.yml (in smartwatermelon/dev-env)
name: CI Gate

on:
  workflow_call:
    inputs:
      node_version:
        description: 'Node.js version (if applicable)'
        required: false
        type: string
        default: ''
      python_version:
        description: 'Python version (if applicable)'
        required: false
        type: string
        default: ''
      test_command:
        description: 'Project-specific test command'
        required: false
        type: string
        default: ''
      lint_command:
        description: 'Project-specific lint command'
        required: false
        type: string
        default: ''

jobs:
  gate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # need full history for diff

      - name: Verify commit messages
        run: |
          git log --format='%s' origin/main..HEAD | while read -r msg; do
            echo "$msg" | grep -qE '^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)\(' \
              || { echo "FAIL: '$msg'"; exit 1; }
          done

      - name: Verify review attestation
        run: |
          git log --format='%b' origin/main..HEAD | grep -q 'AI review:' \
            || { echo "FAIL: No AI review attestation found in commits"; exit 1; }

      - name: Run Semgrep
        run: |
          pip install semgrep
          semgrep scan --config auto --error --quiet .

      - name: Run project lint
        if: inputs.lint_command != ''
        run: ${{ inputs.lint_command }}

      - name: Run project tests
        if: inputs.test_command != ''
        run: ${{ inputs.test_command }}
```

**Caller example** (in any repo's `.github/workflows/ci.yml`):

```yaml
name: CI
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

jobs:
  gate:
    permissions:
      contents: read
    uses: smartwatermelon/dev-env/.github/workflows/ci-gate.yml@main
    with:
      node_version: '22'
      test_command: 'pnpm test'
      lint_command: 'pnpm lint'
```

**Key properties**:
- No AI API calls — purely deterministic
- Fast — lint + test + Semgrep, typically <2 minutes
- Cheap — minimal Actions minutes, no external API costs
- Verifiable — confirms local review ran (attestation check)
- Reusable — one update to `dev-env` propagates to all repos
- Extensible — project-specific lint/test commands passed as inputs

### What stays unchanged

- `claude-assistant.yml` — interactive @claude assistant (on-demand, useful, also reusable from dev-env)
- `pre-merge-review.sh` — local Claude analysis before merge (runs on developer's machine)

---

## Section 4: The Install Script

### Design: Blue/Green settings.json merge

The riskiest part of install is modifying `~/.claude/settings.json`. The install script uses a blue/green strategy:

```
1. Read live settings.json (blue)
2. Merge hook configuration into a copy (green)
3. Validate green copy (jq syntax check + dry-run hook invocation)
4. Back up blue to settings.json.backup.<timestamp>
5. Replace blue with green
6. Validate live file (claude --version or similar smoke test)
7. If validation fails: revert blue from backup, report error
```

### Full install.sh sketch

```bash
#!/usr/bin/env bash
# install.sh — Set up development safety environment
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[0;32m[dev-env]\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m[dev-env]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[dev-env]\033[0m %s\n' "$1"; exit 1; }

# --- Git hooks (symlink directory) ---
log "Setting global git hooks path → ${REPO_DIR}/git-hooks/"
git config --global core.hooksPath "${REPO_DIR}/git-hooks"

# --- Claude Code hooks (symlinks into ~/.claude/scripts/) ---
mkdir -p ~/.claude/scripts
for hook in "${REPO_DIR}"/claude-hooks/*.sh; do
  ln -sf "${hook}" ~/.claude/scripts/"$(basename "${hook}")"
  log "Linked: claude-hooks/$(basename "${hook}")"
done

# --- Review scripts (symlinks into ~/.claude/hooks/) ---
mkdir -p ~/.claude/hooks
for script in "${REPO_DIR}"/review/*.sh; do
  ln -sf "${script}" ~/.claude/hooks/"$(basename "${script}")"
  log "Linked: review/$(basename "${script}")"
done

# --- Shell integration ---
if ! grep -q "source.*gh-wrapper.sh" ~/.config/bash/functions.sh 2>/dev/null; then
  echo "source '${REPO_DIR}/shell/gh-wrapper.sh'" >> ~/.config/bash/functions.sh
  log "Added gh-wrapper.sh source to ~/.config/bash/functions.sh"
else
  log "gh-wrapper.sh already sourced in ~/.config/bash/functions.sh"
fi

# --- Blue/green settings.json merge ---
SETTINGS=~/.claude/settings.json
TEMPLATE="${REPO_DIR}/settings/settings.json.template"
if [[ -f "${SETTINGS}" && -f "${TEMPLATE}" ]]; then
  log "Merging hook configuration into settings.json (blue/green)..."
  GREEN=$(mktemp)
  # Deep-merge template hooks into existing settings (template values win for hooks)
  jq -s '.[0] * .[1]' "${SETTINGS}" "${TEMPLATE}" > "${GREEN}"
  # Validate syntax
  jq empty "${GREEN}" || fail "Green settings.json is invalid JSON"
  # Backup blue
  cp "${SETTINGS}" "${SETTINGS}.backup.${BACKUP_TS}"
  log "Backed up → settings.json.backup.${BACKUP_TS}"
  # Swap
  mv "${GREEN}" "${SETTINGS}"
  log "Settings.json updated with dev-env hook paths"
  # Smoke test: can Claude Code parse it?
  if command -v claude &>/dev/null; then
    claude --version &>/dev/null || {
      warn "Smoke test failed — reverting settings.json"
      cp "${SETTINGS}.backup.${BACKUP_TS}" "${SETTINGS}"
      fail "Settings.json reverted. Check ${TEMPLATE} for issues."
    }
  fi
else
  warn "Skipped settings.json merge (file or template missing)"
fi

# --- Cleanup: remove deprecated files ---
[[ -f ~/.local/bin/gh ]] && {
  log "Removing deprecated ~/.local/bin/gh wrapper"
  rm ~/.local/bin/gh
}

# --- Dependencies ---
log "Checking dependencies..."
command -v semgrep &>/dev/null || warn "INSTALL NEEDED: pip install semgrep"
command -v shellcheck &>/dev/null || warn "INSTALL NEEDED: brew install shellcheck"
command -v shfmt &>/dev/null || warn "INSTALL NEEDED: brew install shfmt"
command -v jq &>/dev/null || warn "INSTALL NEEDED: brew install jq"

log "Done. All hooks point to ${REPO_DIR}/"
log "Update all hooks: git -C ${REPO_DIR} pull"
```

**Key design choices**:
- **Symlinks, not copies** — `git pull` in the repo updates everything instantly. No re-install needed.
- **Blue/green settings merge** — never lose a working settings.json. Backup + revert on failure.
- **Deprecated file cleanup** — removes `~/.local/bin/gh` and other superseded artifacts.
- **Idempotent** — safe to re-run.

---

## Section 5: Migration Path

### Phase 1: Enhance local review (Week 1)

No repo changes needed. Edit existing files in place:

1. Update adversarial-reviewer agent prompt (4A, 4B, 4C)
2. Update `run-review.sh` diff context to -U10 (4D)
3. Install Semgrep, add to pre-commit hook
4. Add full-diff pre-push review mode

**Validation**: Run for 1-2 weeks alongside existing remote review. Compare what each catches.

### Phase 2: Reduce remote review (Week 2-3)

1. Change `claude-code-review.yml` trigger: remove `synchronize` (only `opened` + `ready_for_review`)
2. Monitor: does local review now catch what remote was catching?

### Phase 3: Create the consolidated repo (Week 3-4)

1. Create `smartwatermelon/dev-env` (private)
2. Move all hooks, scripts, review infrastructure, CI templates
3. Write `install.sh` and `uninstall.sh`
4. Apply deduplication (Section 1)
5. Test on a fresh machine or clean user account

### Phase 4: Cut over (Week 4-5)

1. Run `install.sh` on primary machine
2. Replace per-repo `claude-code-review.yml` with `ci-gate.yml` template
3. Archive `smartwatermelon/github-workflows`
4. Delete `~/.local/bin/gh`
5. Remove redundant scripts from `~/.claude/scripts/`

### Phase 5: Validate and clean up (Week 5-6)

1. Confirm CI costs dropped
2. Confirm local review catches what remote used to catch
3. Remove `claude-code-review.yml` entirely from all repos
4. Document in `dev-environment/docs/`

---

## Cost Impact Summary

| Item | Before | After | Savings |
|------|--------|-------|---------|
| `claude-code-review.yml` (Actions + Claude API) | Every PR event | Eliminated | 100% |
| Sentry/Seer CI integration | Already removed | N/A | Already saved |
| CI gate (lint + test + Semgrep) | N/A | Every PR event | ~$0.001-0.005/run |
| `claude-assistant.yml` (@claude) | On-demand | Unchanged | $0 |
| Local AI review | Every commit (FREE) | Every commit + pre-push full-diff (FREE) | $0 |
| Semgrep | N/A | Every commit (FREE) | $0 |
| Net Actions spend | ~$0.01-0.03/PR event | ~$0.001-0.005/PR event | ~80-95% reduction |

The real savings are in eliminating Claude API token consumption on the remote side, which is likely the larger cost than Actions minutes alone.

---

## Risks

| Risk | Mitigation |
|------|------------|
| Local review still misses cross-file bugs | Full-diff pre-push review addresses this directly |
| Semgrep false positives slow down commits | `--error` flag with `--quiet`; tune rules if noisy |
| Install script breaks on edge cases | Test on clean account; idempotent design |
| Removing remote review loses unexpected value | Phase 2 runs both in parallel first |
| Full-diff pre-push is slow on large branches | Cache by diff SHA256; skip if cached PASS |

---

## Resolved Decisions

1. **Repo name**: `dev-env` — boring but easy.
2. **Agent prompts**: External dependencies, not bundled.
   - `adversarial-reviewer`: Andrew's own, published in `code-critic@smartwatermelon-marketplace`. Kept separate so others can use it standalone.
   - `code-reviewer`: Third-party (`comprehensive-review@claude-code-workflows`, wshobson/agents). Left as-is.
   - If code-reviewer were a local custom, it would be migrated to the same marketplace as adversarial-reviewer. It isn't, so no action needed.
3. **Settings.json**: Blue/green merge. Install script merges into a copy, validates, backs up live file, swaps, smoke tests, reverts on failure. See Section 4 for implementation.
4. **Per-project CI**: Reusable workflow. `ci-gate.yml` lives in `smartwatermelon/dev-env` and repos call it with `uses:`. Updates propagate everywhere immediately. The runtime dependency on dev-env being cloned is acceptable since Andrew is the primary audience and will always have it installed.
