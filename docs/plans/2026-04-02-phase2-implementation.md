# Phase 2 Implementation Plan: Local Whole-Codebase Review

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace remote AI review (Seer/Claude CI) with local whole-codebase review that gives agents full tool access at pre-push time.

**Architecture:** Extract shared issue-creation library from `pre-merge-review.sh`, add `--mode=codebase` to `run-review.sh` that invokes Claude CLI with tool access, wire it into the pre-push hook in parallel with existing full-diff review.

**Tech Stack:** Bash 5.x, Claude CLI (`claude --agent`), `gh` CLI, git hooks

---

## Task 1: Extract shared issue library from pre-merge-review.sh

**Files:**

- Create: `~/.claude/hooks/lib-review-issues.sh`
- Modify: `~/.claude/hooks/pre-merge-review.sh`

### Step 1: Create `lib-review-issues.sh` with extracted functions

Extract these functions verbatim from `pre-merge-review.sh` (lines 153-316):

- `parse_nonblocking_issues()` (lines 158-175)
- `build_issue_body()` (lines 179-208)
- `needs_security_label()` (lines 212-217)
- `create_nonblocking_issues()` (lines 222-254)
- `_process_issue_block()` (lines 257-316)

The library also needs `is_security_critical()` since `needs_security_label()` calls it. That function is at lines 126-151 of `pre-merge-review.sh`.

Write `lib-review-issues.sh` with:

```bash
#!/usr/bin/env bash
# =========================================================
# lib-review-issues.sh — Shared non-blocking issue creation
# =========================================================
#
# Sourced by run-review.sh and pre-merge-review.sh.
# Requires these variables set by the caller:
#   REPO_OWNER, REPO_NAME  — GitHub repo coordinates
#   PR_NUMBER, PR_TITLE     — PR metadata (optional; used in issue body)
#
# Requires these functions from the caller:
#   log_success, log_warn   — logging helpers
#
# =========================================================

# Guard: only source once
[[ -n "${_LIB_REVIEW_ISSUES_LOADED:-}" ]] && return 0
_LIB_REVIEW_ISSUES_LOADED=1

# <paste is_security_critical from pre-merge-review.sh lines 126-151>
# <paste parse_nonblocking_issues from lines 158-175>
# <paste build_issue_body from lines 179-208>
#   NOTE: build_issue_body references PR_NUMBER, PR_TITLE, REPO_OWNER,
#   REPO_NAME. For run-review.sh (no PR context), the caller must set
#   these vars before calling create_nonblocking_issues. If PR_NUMBER
#   is empty, build_issue_body should produce a body without PR reference.
#   Add a guard: if PR_NUMBER is unset, omit the PR line and change
#   "Merged:" to "Detected:" and "pre-merge review" to the SOURCE field.
# <paste needs_security_label from lines 212-217>
# <paste create_nonblocking_issues from lines 222-254>
# <paste _process_issue_block from lines 257-316>
```

Make `build_issue_body` flexible for non-PR context:

```bash
build_issue_body() {
  local title="$1"
  local source="$2"
  local location="$3"
  local details="$4"
  local detected_date
  detected_date=$(date +%Y-%m-%d)

  # PR context (set by pre-merge-review.sh) or standalone (run-review.sh)
  local pr_line=""
  if [[ -n "${PR_NUMBER:-}" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
    local pr_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"
    pr_line="**PR:** #${PR_NUMBER} — ${PR_TITLE:-} (${pr_url})"
  fi

  cat <<BODY_EOF
## Non-Blocking Review Concern: ${title}

**Source:** ${source}
**Location:** \`${location}\`
${pr_line:+${pr_line}$'\n'}**Detected:** ${detected_date}

## What was flagged

${details}

## Context

This issue was automatically created from a non-blocking concern
identified during ${source}. It was not blocking but worth tracking.

---
*Created by ${source}*
BODY_EOF
}
```

### Step 2: Make it executable

```bash
chmod +x ~/.claude/hooks/lib-review-issues.sh
```

### Step 3: Run shellcheck

```bash
shellcheck ~/.claude/hooks/lib-review-issues.sh
```

Expected: clean (0 warnings, 0 errors)

### Step 4: Commit

```bash
git add ~/.claude/hooks/lib-review-issues.sh
git commit -m "feat(hooks): extract shared issue library from pre-merge-review

Extracts parse_nonblocking_issues, build_issue_body,
create_nonblocking_issues and helpers into lib-review-issues.sh
for reuse by run-review.sh (Phase 2 codebase review mode)."
```

---

## Task 2: Update pre-merge-review.sh to source the shared library

**Files:**

- Modify: `~/.claude/hooks/pre-merge-review.sh`

### Step 1: Replace extracted functions with source line

At `pre-merge-review.sh` line ~153 (where `# --- Non-Blocking Issue Functions ---` begins), replace everything through line ~316 (end of `_process_issue_block`) with:

```bash
# --- Non-Blocking Issue Functions (shared library) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-issues.sh
source "${_LIB_DIR}/lib-review-issues.sh"
```

Keep `is_data_file()` and any other functions above line 153 that are NOT part of the extracted set. The `is_security_critical()` function moves to the library, so remove it from `pre-merge-review.sh` as well (but verify nothing else in `pre-merge-review.sh` calls it directly outside the library functions — `needs_security_label` calls it, which is now in the library).

### Step 2: Run shellcheck

```bash
shellcheck ~/.claude/hooks/pre-merge-review.sh
```

Expected: clean

### Step 3: Smoke test — verify pre-merge still works

Create a throwaway PR in a test repo, or use an existing open PR:

```bash
# Dry-run: source the script's parsing functions and test them
bash -c '
  source ~/.claude/hooks/lib-review-issues.sh
  test_input="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Test issue
SOURCE: test
LOCATION: foo.sh:1
DETAILS: This is a test
END_ISSUE"
  result=$(parse_nonblocking_issues "$test_input")
  echo "Parsed: ${result}"
  if [[ -n "${result}" ]]; then
    echo "PASS: parse_nonblocking_issues works"
  else
    echo "FAIL: no output"
    exit 1
  fi
'
```

Expected: prints the parsed issue block and "PASS"

### Step 4: Commit

```bash
git add ~/.claude/hooks/pre-merge-review.sh
git commit -m "refactor(hooks): source shared lib-review-issues.sh in pre-merge

Replaces inline non-blocking issue functions with shared library.
No behavior change — same functions, now sourced from
lib-review-issues.sh for reuse by run-review.sh."
```

---

## Task 3: Add `--mode=codebase` to run-review.sh

**Files:**

- Modify: `~/.claude/hooks/run-review.sh`

### Step 1: Add mode parsing

At line 59 (the mode case statement), add the new mode:

```bash
    --mode=codebase) REVIEW_MODE="codebase" ;;
```

### Step 2: Source the shared library

After the helpers section (~line 75), add:

```bash
# --- Shared issue library (for --mode=codebase non-blocking issues) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-issues.sh
source "${_LIB_DIR}/lib-review-issues.sh"
```

### Step 3: Add repo metadata resolution

The issue library needs `REPO_OWNER` and `REPO_NAME`. Add after the source line:

```bash
# Resolve repo metadata for issue creation (best-effort)
if [[ -z "${REPO_OWNER:-}" ]]; then
  _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "${_remote_url}" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    REPO_OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  fi
fi
```

### Step 4: Add the codebase review mode block

Insert after the `full-diff` mode block (after line 550, before `# --- Detect when adversarial review is warranted ---`):

```bash
# --- Codebase review mode (pre-push whole-codebase review with tool access) ---
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  log_info "Codebase review: analyzing with full tool access"
  log_info "Diff size: ${DIFF_LINES} lines"

  CODEBASE_CACHE="${CACHE_DIR}/codebase-${DIFF_HASH}"

  # Check cache
  if [[ -f "${CODEBASE_CACHE}" ]]; then
    CACHED_VERDICT=$(head -1 "${CODEBASE_CACHE}")
    if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
      log_success "Codebase review cached: identical diff previously passed"
      printf 'codebase: cached PASS\n' >>"${REVIEW_LOG}" || true
      exit 0
    fi
    rm -f "${CODEBASE_CACHE}"
  fi

  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # Write diff to temp file so the agent can reference it
  DIFF_FILE=$(mktemp)
  echo "${DIFF}" >"${DIFF_FILE}"
  trap 'rm -f "${DIFF_FILE}"; [[ -n "${REVIEW_LOG:-}" ]] && printf "exit_code: %d\n" "$_ec" >> "${REVIEW_LOG}" || true' EXIT

  CODEBASE_PROMPT="You are performing a whole-codebase review with full tool access.

IMPORTANT: You are being invoked as a focused analysis tool.
Do NOT output Protocol 0 environment check or any preamble.
Begin your analysis immediately.

## Your task

The diff below shows all changes on this feature branch (main...HEAD).
You have full access to the codebase at: ${REPO_ROOT}
The diff is also saved at: ${DIFF_FILE}

Use your tools (Read, Grep, Glob) to explore the codebase and find bugs
that are invisible from the diff alone.

## What to look for

For each changed file in the diff:
1. Read the FULL file for surrounding context
2. Find all consumers/callers of changed functions or interfaces
3. Check that field contracts are honored (fields set match fields read)
4. Verify data flow: are values passed correctly across file boundaries?
5. Check date/time handling consistency (UTC vs local, timezone awareness)
6. Look for dead UI elements (handlers, buttons, links with no behavior)
7. Verify cache key consistency (keys used to write match keys used to read)
8. Check platform-specific code (bash arrays, sed syntax, path separators)

## Classification rules

**BLOCK** — Issue is introduced or worsened by this diff:
- A field the diff adds/changes is not consumed correctly downstream
- A function the diff modifies has callers that expect the old behavior
- The diff introduces a dead code path or unreachable UI element

**NON_BLOCKING_ISSUE** — Pre-existing issue discovered while exploring:
- Issue exists independent of this diff
- Worth fixing but should not block this push

## Output format

Start with your exploration notes (which files you read, what you found).
Then output your verdict:

If no blocking issues found:
\`\`\`
VERDICT: PASS

No blocking issues found.

[Optionally, NON_BLOCKING_ISSUE blocks:]

NON_BLOCKING_ISSUE:
TITLE: <short title>
SOURCE: pre-push whole-codebase review
LOCATION: <file:line>
DETAILS: <explanation>
END_ISSUE
\`\`\`

If blocking issues found:
\`\`\`
VERDICT: FAIL

ISSUE: <one-line description>
SEVERITY: BLOCKING
LOCATION: <file:line>
DETAILS: <explanation and fix suggestion>

[Additional ISSUE blocks as needed]

[Optionally, NON_BLOCKING_ISSUE blocks as above]
\`\`\`

## The diff

\`\`\`diff
${DIFF}
\`\`\`"

  log_info "Running codebase review agent (with tool access)..."
  printf 'diff_lines: %d\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true

  local start_time
  start_time=$(date +%s)

  # Invoke Claude CLI WITH tools (unlike other modes which use --tools "")
  # The agent gets Read, Grep, Glob access to explore the codebase.
  local codebase_output exit_code=0
  codebase_output=$(echo "${CODEBASE_PROMPT}" \
    | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" \
        --agent "adversarial-reviewer" \
        -p \
        --no-session-persistence \
        2>&1) || exit_code=$?

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  log_info "Codebase review completed in ${elapsed}s"

  if [[ ${exit_code} -eq 124 ]]; then
    log_error "Codebase review timed out after ${TIMEOUT_SECONDS}s"
    printf 'codebase: FAIL (timeout)\n' >>"${REVIEW_LOG}" || true
    exit 1
  elif [[ ${exit_code} -ne 0 ]]; then
    log_error "Codebase review agent error (exit ${exit_code})"
    printf 'codebase: FAIL (agent error)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi

  [[ -n "${codebase_output}" ]] || codebase_output="VERDICT: FAIL (agent error: no output)"

  echo "=== CODEBASE REVIEW (adversarial-reviewer + tools) ===" >&2
  echo "${codebase_output}" >&2
  echo "" >&2
  { printf '=== CODEBASE REVIEW ===\n%s\n' "${codebase_output}"; } >>"${REVIEW_LOG}" || true

  # File non-blocking issues (best-effort, don't block on failure)
  create_nonblocking_issues "${codebase_output}" || true

  # Parse verdict
  if echo "${codebase_output}" | grep -q "VERDICT: PASS"; then
    # Cache the PASS
    echo "PASS" >"${CODEBASE_CACHE}" 2>/dev/null || true
    printf 'codebase: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Codebase review passed"
    exit 0
  elif echo "${codebase_output}" | grep -q "VERDICT: FAIL"; then
    if echo "${codebase_output}" | grep -q "SEVERITY: BLOCKING"; then
      printf 'codebase: FAIL (blocking)\n' >>"${REVIEW_LOG}" || true
      log_error "Codebase review found blocking issues"
      exit 1
    else
      printf 'codebase: FAIL (warnings only)\n' >>"${REVIEW_LOG}" || true
      log_warn "Codebase review found warnings (non-blocking)"
      exit 0
    fi
  else
    log_error "Could not parse codebase review verdict"
    echo "${codebase_output}" | head -20 >&2
    printf 'codebase: FAIL (unparseable)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi
fi
```

**Key difference from `--mode=full-diff`:** The Claude CLI invocation does NOT pass `--tools ""`. This gives the agent default tool access (Read, Grep, Glob) so it can explore the codebase.

### Step 5: Update TIMEOUT_SECONDS for codebase mode

The codebase review needs more time than a diff-only review. Add after the timeout config line (line 48):

```bash
# Codebase review gets more time (agent explores files)
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  TIMEOUT_SECONDS=$(git config --get --type=int review.codebaseTimeout 2>/dev/null || echo "300")
fi
```

### Step 6: Run shellcheck

```bash
shellcheck ~/.claude/hooks/run-review.sh
```

Expected: clean

### Step 7: Smoke test — verify mode=codebase runs

```bash
# Quick test: run on a trivial diff in a real repo
cd ~/Developer/dev-env
echo "# test" >> /tmp/test-codebase-review.md
echo "--- a/test.md
+++ b/test.md
@@ -0,0 +1 @@
+# test" | ~/.claude/hooks/run-review.sh --mode=codebase
echo "Exit code: $?"
rm /tmp/test-codebase-review.md
```

Expected: agent runs with tool access, produces VERDICT: PASS, exits 0

### Step 8: Commit

```bash
git add ~/.claude/hooks/run-review.sh
git commit -m "feat(hooks): add --mode=codebase to run-review.sh

Whole-codebase review mode gives the adversarial-reviewer agent
full tool access (Read, Grep, Glob) to explore the codebase from
the diff. Catches cross-file semantic bugs that diff-only review
misses. Non-blocking findings filed as GitHub issues via shared
lib-review-issues.sh."
```

---

## Task 4: Wire codebase review into pre-push hook

**Files:**

- Modify: `~/Developer/dotfiles/git/hooks/pre-push`

### Step 1: Add parallel codebase review alongside full-diff

Replace the `run_full_diff_review` function (lines 136-196) with a version that runs both modes in parallel:

```bash
run_full_diff_review() {
  local current_branch
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

  if [[ "${current_branch}" == "main" || "${current_branch}" == "master" ]]; then
    return 0
  fi

  local merge_base
  merge_base=$(git merge-base main HEAD 2>/dev/null || echo "")
  if [[ -z "${merge_base}" ]]; then
    log_warning "Could not find merge-base with main — skipping full-diff review"
    return 0
  fi

  local full_diff
  full_diff=$(git diff main...HEAD 2>/dev/null || echo "")
  if [[ -z "${full_diff}" ]]; then
    return 0
  fi

  local diff_lines
  diff_lines=$(echo "${full_diff}" | wc -l | tr -d ' ')

  local REVIEW_SCRIPT="${HOME}/.claude/hooks/run-review.sh"
  if [[ ! -x "${REVIEW_SCRIPT}" ]]; then
    log_warning "run-review.sh not found — skipping full-diff review"
    return 0
  fi

  log "Running full-diff + codebase review in parallel (${diff_lines} lines)"

  # Run both reviews in parallel
  local fulldiff_exit=0 codebase_exit=0
  local fulldiff_log codebase_log
  fulldiff_log=$(mktemp)
  codebase_log=$(mktemp)

  # Full-diff review (existing, diff-only)
  (echo "${full_diff}" | "${REVIEW_SCRIPT}" --mode=full-diff >"${fulldiff_log}" 2>&1) &
  local fulldiff_pid=$!

  # Codebase review (new, with tool access)
  (echo "${full_diff}" | "${REVIEW_SCRIPT}" --mode=codebase >"${codebase_log}" 2>&1) &
  local codebase_pid=$!

  # Wait for both
  wait "${fulldiff_pid}" || fulldiff_exit=$?
  wait "${codebase_pid}" || codebase_exit=$?

  # Show output from both
  if [[ -s "${fulldiff_log}" ]]; then
    cat "${fulldiff_log}" >&2
  fi
  if [[ -s "${codebase_log}" ]]; then
    cat "${codebase_log}" >&2
  fi
  rm -f "${fulldiff_log}" "${codebase_log}"

  # Evaluate results
  local has_failure=false
  if [[ ${fulldiff_exit} -ne 0 ]]; then
    has_failure=true
    log_warning "Full-diff review found issues"
  fi
  if [[ ${codebase_exit} -ne 0 ]]; then
    has_failure=true
    log_warning "Codebase review found issues"
  fi

  if [[ "${has_failure}" == true ]]; then
    echo "" >&2
    log_warning "Review found issues. Fix before pushing."
    echo "" >&2

    if [[ "${POSTPUSH_LOOP:-}" == "1" ]]; then
      log "Post-push loop active — continuing despite review findings"
      return 0
    fi

    if [[ -t 0 ]]; then
      local push_anyway
      read -t 30 -p "[PRE-PUSH] Push anyway? (y/N): " -n 1 -r push_anyway || true
      echo
      if [[ ! ${push_anyway} =~ ^[Yy]$ ]]; then
        exit 1
      fi
    else
      log_warning "Non-interactive mode — continuing despite review findings"
      return 0
    fi
  else
    log_success "Full-diff + codebase review passed"
  fi
}
```

### Step 2: Run shellcheck

```bash
shellcheck ~/Developer/dotfiles/git/hooks/pre-push
```

Expected: clean

### Step 3: Commit (in dotfiles repo)

```bash
cd ~/Developer/dotfiles
git checkout -b claude/phase2-codebase-review-<session-id>
git add git/hooks/pre-push
git commit -m "feat(hooks): add parallel codebase review to pre-push

Runs --mode=codebase alongside --mode=full-diff in parallel.
Both must pass for push to succeed. Codebase review gives the
agent full tool access to explore the repo and catch cross-file
semantic bugs."
```

---

## Task 5: End-to-end test

### Step 1: Make a real change in a test repo and push

Pick a repo with real code (e.g., archive-resolver or spokane-snow). Create a branch, make a small change, commit (pre-commit review runs), then push (both full-diff and codebase review should run in parallel).

```bash
cd ~/Developer/<test-repo>
git checkout -b test/phase2-validation
# Make a small code change
git add <file>
git commit -m "test: validate phase 2 codebase review"
git push -u origin test/phase2-validation
```

Expected output should show:

```
[PRE-PUSH] Running full-diff + codebase review in parallel (N lines)
```

Both reviews should complete and produce verdicts.

### Step 2: Verify non-blocking issues are filed

If the codebase review finds non-blocking issues, check:

```bash
gh issue list --repo <owner>/<repo> --label tech-debt
```

Or check the fallback directory:

```bash
ls ~/.claude/pending-issues/
```

### Step 3: Clean up test branch

```bash
git push origin --delete test/phase2-validation
git checkout main
git branch -D test/phase2-validation
```

---

## Task 6: Push and PR both repos

### Step 1: Push dotfiles changes

```bash
cd ~/Developer/dotfiles
git push -u origin claude/phase2-codebase-review-<session-id>
gh pr create --title "feat(hooks): parallel codebase review at pre-push" --body "..."
```

### Step 2: Push dev-env changes (if any hook files live there)

The hook files live in `~/.claude/hooks/` (managed via claude-config or dotfiles).
Determine where `run-review.sh` and `pre-merge-review.sh` are tracked and push to the appropriate repo.

### Step 3: Run /post-push-loop on both PRs

### Step 4: Merge after CI green

---

## Task 7: Update design doc status

**Files:**

- Modify: `~/Developer/dev-env/docs/plans/2026-04-02-phase2-local-whole-codebase-review.md`

### Step 1: Update status

Change `**Status**: Design` to `**Status**: Implemented — validation week active`

### Step 2: Commit in dev-env

```bash
git add docs/plans/2026-04-02-phase2-local-whole-codebase-review.md
git commit -m "docs: mark Phase 2 as implemented, begin validation"
```
