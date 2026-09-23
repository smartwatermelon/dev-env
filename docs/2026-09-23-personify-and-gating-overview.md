# Personify pipeline and agent gating: overview

Point-in-time record, 2026-09-23. It describes what exists, not what should
exist. Each claim was checked against source on that date. The bypass list in
Part 2 was produced by piping crafted command strings through the live
`hook-block-all.sh` chain; none of the commands were executed for real.

Every bypass named here is already described as bypassable in the public hook
sources' own comments. This document collects them in one place.

## Part 1: the personify pipeline

### One artifact, end to end

1. **Voice lookup.** `SKILL.md` Step 0 reads `$PERSONIFY_VOICE`, then
   `~/.config/personify/VOICE.md`, then the skill's own directory.
2. **Draft.** The draft follows the voice guide and seven hard rules. The PR
   description structure and the code comment ratio outrank `VOICE.md`,
   because a detector cannot see structure.
3. **Write to the publish file.** The draft goes into the file that
   `git commit -F` or `gh pr create --body-file` will read.
4. **One Pangram check.** `python3 <skill-dir>/scripts/pangram_check.py <
   body.md`. The exit code decides:

   | Code | Meaning |
   |---|---|
   | 0 | Human. Stamp written. |
   | 2 | AI. Stop and report. |
   | 3 | Mixed. Stop and report. |
   | 4 | Under the 40-word floor. Skipped, never a pass. |
   | 5 | No verdict (no key, transport, credits). Fail closed. |

5. **Stamp.** A pass writes `~/.config/personify/stamps/<sha256>.json`, keyed
   to the raw bytes on stdin.
6. **No edit loop.** One submission per artifact. Editing toward the detector
   was measured and does not move the verdict.

### Desktop bridge (`personify/mcp-server`, 0.3.0)

- Claude Desktop calls the bridge. The bridge spawns the Claude Code CLI,
  which runs the skill and its own Pangram check.
- The bridge ignores the child's prose and decides from the stamp only. A
  stamp for the body's hash with verdict Human returns exactly the stamped
  bytes as Verified. Anything else is NOT VERIFIED. A real failure is
  `isError`, with the report fenced.
- The child runs under a narrow allowlist: read the skill install, the voice
  guide, and `body.md`; edit `body.md`; run `pangram_check.py`. It cannot read
  `~/.config/personify/token`.

### Built but not connected

1. Nothing except the bridge reads stamps. The commit and PR gate checks only
   visual approval (`SKILL.md` says the stamp-to-hook integration "does not
   exist yet"). The hashes would not match if connected: `gate-review.sh`
   strips trailing whitespace before hashing, the stamp hashes raw bytes.
2. No Human verdict has been recorded on the primary machine; the stamps
   directory is empty.
3. `pr-review` 1.4.0 (`SKILL.md:252`) and `calibrate-register` still run
   dumbify after personify. Personify 2.0 calls that follow-up pass stale,
   and dumbify rewrites the bytes, so a stamp would no longer match.
4. `VOICE.example.md:11` still carries 1.x wording ("the pattern list becomes
   a backstop").
5. Under Desktop the key lookup may fail. `pangram_check.py` resolves
   `PANGRAM_API_KEY`, then `~/.config/personify/pangram-key`, then `op read`,
   which needs a terminal. With none present every Desktop call would come
   back NOT VERIFIED. Not yet confirmed with a live Desktop call.
6. Desktop runs a gitignored `dist/` that `git pull` never rebuilds
   (personify#72). The current `dist/` also holds two unused files,
   `strip-preamble.js` and `strip-status-line.js`.

## Part 2: agent gating infrastructure

### Layers, in the order a change meets them

| # | Layer | Source | What it enforces |
|---|---|---|---|
| 1 | PreToolUse Bash chain | `claude-config/scripts/hook-block-all.sh` | Ten hooks in order: secret-leak, gate-dir-write, no-verify, short-no-verify, main-commit, personify (visual approval gate), commit-message format, merge-lock-authorize, api-merge, git-worktree. |
| 2 | Write/Edit hook | `hook-block-merge-locks-write.sh` | Write and Edit tools cannot touch `merge-locks/` or `gate-review/`. |
| 3 | Visual approval gate | `gate-review.sh`, `hook-block-personify.sh`, `gh-wrapper.sh` | Commit messages and PR/issue bodies must hash-match text approved in BBEdit by typing `APPROVED`. Absolute `-F`/`--body-file` only; inline text blocked; titles ungated. |
| 4 | git hooks (global `core.hooksPath`) | `dotfiles/git/hooks/` | pre-commit: no commits on main, pre-commit framework, `.project-hooks/`. commit-msg: conventional commits, then `run-review.sh`. post-commit: fixes the review log's commit hash. pre-push: full-diff review. |
| 5 | Commit review | `claude-config/hooks/run-review.sh` | code-reviewer (Haiku) and adversarial-reviewer (Sonnet 4.6); a Sonnet arbiter only when they disagree. Timeouts, parse failures, and diffs over 2500 lines block. |
| 6 | gh wrapper | `dotfiles/bash/gh-wrapper.sh`, sourced into the Bash tool via `BASH_ENV` and symlinked as `~/.local/bin/gh` | Identity switch by owner; REST and GraphQL merge blocked; `gh pr merge` runs `pre-merge-review.sh`, which checks the merge-lock; off-org PRs forced to draft; approval gate repeated. |
| 7 | Server side | GitHub branch protection | On personify: `validate` and `claude-review` required, 0 required reviews, `enforce_admins` false. |
| 8 | Budget guard | `hook-budget-guard.sh` on Stop and SubagentStop | Stops a session at its token budget. |

### Human-only actions

1. Typing `APPROVED` in a gate-review batch.
2. `merge-lock authorize`, `auth`, or `tui` (bulk picker, added in
   claude-config#513). All blocked for the Bash tool.
3. Promoting a draft PR in the GitHub UI.
4. Allowing `--no-verify` or `STRICT_PREPUSH=0`.

Agents may stage and open a review batch, commit and push to a branch, open a
PR, and run `gh pr merge` once a valid lock exists.

The approval check is by content hash and is not consumed. The hook and the
gh wrapper both call `gate-review.sh check` on the same file, so an identical
repeat passes both with no second approval.

### Unguarded paths

Exit 0 means the full PreToolUse chain let the command through.

**Tier 1: around the merge-lock entirely**

1. `sugh pr merge N` exits 0. `sugh` (`gh-wrapper.sh:1061`) is an exported
   escape hatch that calls the real gh, skipping pre-merge review, the
   merge-lock, and the approval gate. Server side does not stop it: 0 required
   reviews, and admins bypass required checks.
2. `/opt/homebrew/bin/gh pr merge N` and
   `_GH_REVIEW_DONE=1 command gh pr merge N` exit 0.
3. `sugh api -X PUT .../pulls/N/merge` and `curl` to the merge endpoint exit
   0. The same call through `gh api` is blocked.

**Tier 2: around review and approval**

4. `git -c core.hooksPath=/dev/null push` exits 0 and skips the pre-push
   review. The no-verify hooks do not check `core.hooksPath`. On a commit with
   an approved `-F` file, the same override would skip pre-commit and the
   commit-msg review.
5. `git config --local core.hooksPath /dev/null` exits 0 and disables the git
   hooks for that repo.
6. `sugh pr create|comment --body "..."` exits 0.
7. Writers the gate-dir hook does not name, such as `python3 -c` writing
   `APPROVED` into `batch.txt`. The hook header already states this limit.
8. `~/.claude/scripts/*` are symlinks into claude-config, so an Edit to a hook
   script takes effect immediately, with no commit and no review.

**Tier 3: text written without approval**

9. `gh pr review --body`, `gh pr merge --body`,
   `gh api .../comments -f body=`, `gh release create --notes`,
   `gh gist create`, `git tag -m`, and `git merge -m` all pass.
10. `commit-msg` skips review for `wip:`, `WIP`, `fixup!`, and `squash!`
    subjects. `commit-msg` and `pre-push` both skip review, rather than
    block, when `run-review.sh` is missing.

False positive found in passing: `git push -n` (dry run) is blocked, because
the short-no-verify hook treats push's `-n` as commit's `-n`.

### Stale documentation

Each row was checked by reading both the doc and the code.

| Doc | Says | Actually | Evidence |
|---|---|---|---|
| `claude-config/docs/INFRASTRUCTURE.md:20`, `:91` | AI review runs from the pre-commit hook | It runs from commit-msg | `dotfiles/git/hooks/commit-msg`; `pre-commit` has no review |
| `INFRASTRUCTURE.md:92-93`, `REFERENCE.md:161-166` | Security-critical paths get an "elevated scrutiny" note | Removed from `run-review.sh`; `is_security_critical` survives only in `pre-merge-review.sh` and the issue library, with a different pattern list | `run-review.sh:2409-2415`, `lib-review-issues.sh:41-44`, `pre-merge-review.sh:843` |
| `CHECKLISTS.md:48-51`, `:92-95` | pre-push runs a codebase review and files findings as issues | pre-push runs `--mode=full-diff` only, which files nothing | `pre-push:568-577`, `:605-609` |
| `CHECKLISTS.md:128-130` | A clean dry-run makes the push a cache hit | The push runs a different mode, so no cache hit | `pre-push:572-577` |
| `~/.claude/CLAUDE.md` Protocol 4 step 2 | A real push files findings as issues | A push files no issues | `pre-push:605-609` |
| `INFRASTRUCTURE.md:25-26`, `:135-136` | `~/.claude/lib/build-commons.sh`, `deploy-commons.sh` | Neither exists in either repo | `ls`, `find` |
| `INFRASTRUCTURE.md:27` | `~/.claude/scripts/audit-branches.sh` | Does not exist | `ls`, `find` |
| `INFRASTRUCTURE.md:119` | `useAutoModeDuringPlan` at `settings.json:133` | Line 299 | `settings.json:299` |

Missing rather than wrong: none of `INFRASTRUCTURE.md`, `CHECKLISTS.md`,
`REFERENCE.md`, or the global `CLAUDE.md` describe the visual approval gate,
`sugh`, `BASH_ENV` sourcing, the enter-worktree, budget-guard, secret-leak, or
secret-redaction hooks, `merge-lock auth`/`tui`, or the reviewer and arbiter
models. `INFRASTRUCTURE.md`'s enforcement table lists one of the ten Bash
chain hooks.
