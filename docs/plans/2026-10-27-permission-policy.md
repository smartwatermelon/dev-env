# Plan: one permission policy for sandbox, rules, classifier and hooks

**Status:** proposal; Andrew's decisions recorded 2026-10-27
**Date:** 2026-10-27
**Author:** arich (drafted by Claude Code)

## Problem

Since the Bash sandbox went live (2026-10-22 20:49 PDT) and auto mode before
it (2026-10-15), agents keep hitting blocks, and the usual fallback is "ask
Andrew to run it." That fallback does not scale. On 2026-10-27 it also caused
harm: `git worktree add` failed on a sandbox write, the agent kept going, and a
`git -C <not-a-worktree> reset --hard HEAD` ran in the shared primary checkout
of `scripts`.

## The rule this policy adds

Every blocked action gets exactly one of two answers:

- **A. Agents should be able to do it.** Change the configuration, hook or
  tool so that it works.
- **B. Agents should not do it.** Change the procedure so that it never needs
  to happen, and make the block say what to do instead.

"The agent fails and asks the operator to do it" is not an allowed answer.
An agent that still hits a block stops, and the block is treated as a bug in
this policy: policy (A or B not yet decided) or misconfiguration.

A related rule: **no error output that cannot be acted on.** Either fix the
cause, or stop the condition that prints it. Noise trains agents to skip
error lines, and that is how the 2026-10-27 `worktree add` failure was missed.

## Evidence

A script read all 413 transcripts under `~/.claude/projects` (subagents
included) and paired every tool call with its result. Output, kept outside the
repo: `scratchpad/denials-v2/` (`denials.jsonl`, `patterns.csv`,
`report.md`) in session `cbe34707`. Probes were counted separately (43).

| Layer | Denials | Sessions |
| --- | --- | --- |
| Hooks | 220 | 29 |
| Sandbox network | 307 rows from 89 calls | 8 |
| Harness guards | 42 | 9 |
| Sandbox filesystem | 37 | 8 |
| Auto-mode classifier | 15 (matches `auto-denials.jsonl`) | 8 |
| User rejected the call | 8 | 7 |

No permission-rule denials were found. **Andrew's own PreToolUse hooks are
the largest source: 220 blocks, in every affected session.** The classifier
caused 15. A hook block runs before permission rules and wins over any allow
rule, so new allow rules cannot remove these blocks. The hooks themselves have
to change.

Known gaps: blocks inside headless reviewer runs, output hidden by
`2>/dev/null`, and the 11,138 `blocked-commands.log` records (only 38 match a
transcript block; the rest are probably hook test fixtures, not verified).

## How the layers fit together

From the Claude Code docs (2.1.312), quoted in the session report:

1. **PreToolUse hooks run first.** A hook that blocks (exit 2) stops the call
   before permission rules are read, so an allow rule cannot override it.
2. **Permission rules** (`deny` > `ask` > `allow`) resolve next. Deny blocks in
   every mode.
3. **Auto mode** then approves edits in the working directory and sends the
   rest to the classifier. Entering auto mode drops broad rules (`Bash(*)`,
   interpreter wildcards, package-manager run commands, `Agent` and `Monitor`
   allow rules). Narrow rules stay.
4. **Protected paths** (`.git`, `.claude`, `.gitconfig`, shell rc files and
   others) always go to the classifier in auto mode. Allow rules do not
   pre-approve them.
5. **The Bash sandbox** limits what a command can write and reach.
   `autoAllowBashIfSandboxed` runs sandboxed Bash without a prompt. Inside the
   working directory, it always denies writes to `.git/config` and
   `.git/hooks`, and no setting except `filesystem.disabled` lifts that.
6. **`excludedCommands`** run fully outside the sandbox, still through
   permission rules and the classifier. They match only the text of a bare
   command: `cd x && gh pr merge 5 | grep y` stays sandboxed.

## Decisions by pattern

### Worktrees (sandbox `.git/config`, 7 + harness guard 31)

**A, through the harness.** Tested end to end on 2026-10-27 in dev-env, a repo
where `.git/config` was confirmed write-protected first.

1. Create: `EnterWorktree`, then `git switch -c <prefix>/<name>`
   (`claude/...` on personal repos, `arich/...` on beacon-biosignals).
   `git branch -m` is not used: it renames the ref but exits 128 on the config
   update. The remote sees only the branch name.
2. Work, commit, `git push origin <branch>` (no `-u`; it writes `.git/config`),
   `gh pr create --head <branch>`.
3. After the merge: check that `gh pr view --json state,headRefName` shows
   `MERGED` for the current branch and `git status` is clean. Then
   `ExitWorktree` with `remove` and `discard_changes: true`. This rule
   pre-authorizes that flag under those two conditions only. A squash merge
   never puts the branch's commits on `main`, so the tool always asks for it.
4. Delete the branch made in step 1. **Test first:**
   `git update-ref -d refs/heads/<branch>` should delete it without touching
   `.git/config`. If it works, it replaces `git branch -D`, which deletes the
   ref but prints an unactionable config warning.
5. `ExitWorktree remove` works only while the session is still inside the
   worktree it created. It cannot remove a worktree left with `keep`, one
   from an earlier session, or one re-entered by `path`. A sandboxed
   `git worktree remove` fails too: Claude Code's own `.claude/.cc-writes`
   folder inside the worktree is write-denied. It also leaves an empty
   `.git/worktrees/<name>/` folder that the sandbox will not remove (rule not
   identified).

   **B: agents never remove a kept worktree.** When the PR is still open, the
   agent leaves with `keep`. A nightly `worktree-reaper.sh` (scripts repo, own
   LaunchAgent, outside the sandbox) checks every worktree under
   `~/Developer/*/.claude/worktrees/`. If the tree is clean and `gh` shows its
   branch's PR as `MERGED`, it runs `git worktree remove`, deletes the branch
   and runs `git worktree prune`. Anything else (dirty, no PR, PR open), it
   only reports. Nothing is scheduled today: the nightly `updates` job runs
   package updates only, and `my-repos` is not scheduled.
6. Coming back to a kept worktree (for example to fix a review finding)
   uses `EnterWorktree` with `path`. **A:** `hook-block-enter-worktree.sh`
   rejects `path` today, because it only validates the `name` of a new
   worktree. It must accept a `path` that is an existing worktree under that
   repo's `.claude/worktrees/`.

Constraints learned:

- Do not call `EnterWorktree` while background agents are running in the main
  checkout. The isolation checks cover every subagent, and an agent whose
  working directory is the main checkout loses Bash entirely. Start agents
  after entering, or with `isolation: "worktree"`.
- Inside a worktree session, git commands must be simple: one git call, a
  literal path, no `GIT_CONFIG_*`, no loops or `bash -c` around git.
- `hook-block-git-worktree.sh` (10 false positives on `$W/.claude/worktrees`)
  becomes simpler: block raw `git worktree add` and point to `EnterWorktree`.
- Protocol 6's `git -C <primary> pull` after a merge is dropped. Primary
  checkouts are updated by `my-repos`, not by agents (it also hit the
  protected `CLAUDE.md` 4 times).

### Hooks

Hooks are the main source of friction, so they get the most change. Two
principles:

1. **Check at the layer that has the facts.** A PreToolUse hook sees only
   command text, before anything runs. A check about what a commit contains
   belongs in git's own pre-commit hook, which sees the real staged index.
2. **Documentation is not a fix for a repeating block.** The repo-resolution
   blocks below kept happening while CLAUDE.md already stated the rule. A
   block that recurs across sessions is a hook to change (A), not a rule to
   restate.

| Pattern | Denials / sessions | Answer |
| --- | --- | --- |
| Copy gate: `git add` and `git commit` in one call | 56 / 20 | **A.** The PreToolUse hook reads the index before the call, so it cannot see what `git add` will stage. Move the copy check into the git pre-commit hook, which sees the final index. Then the call shape no longer matters. Until that ships, the hook message already names the split. |
| Repo cannot be resolved: `git -C $VAR`, `cd …`, `env -C` (personify, main-commit hooks) | 57 / 15+ | **A.** Most cases assign the variable in the same command (`W=/abs/path; git -C "$W" …`). Resolve literal assignments made earlier in the same command text, and `cd <literal>` before git. Block only what stays unresolved, and say which part could not be resolved. |
| Worktree path check on `$W/...` | 10 / 7 | **B**, see Worktrees. |
| Copy gate: no approval for public copy | 31 / up to 17 | Correct block. No change. |
| Secret-leak hook | 15 / 10 | Mostly correct. One false positive on `env \| grep -c` (prints a count). No change; the hook message already gives the safe forms. |
| `merge-lock.sh authorize` matched inside quoted text | 3 / 2 | **A.** Match the command position, not a substring. Low priority. |
| Fail-closed when a hook cannot run | 3 / 2 | Correct block (deploy ordering). |

### Sandbox filesystem

| Pattern | Denials | Answer |
| --- | --- | --- |
| `gh pr merge` in a compound or piped command cannot write `~/.claude/merge-locks` | 10 | **B.** Excluded commands are written bare: no `cd`, pipe or `&&`. Add a PreToolUse check that rejects the compound form *before* it runs, with the bare form in the message, so the failure is instant and says what to do. |
| `gate-review.sh` compound form cannot write `~/.claude/gate-review` | 5 | **B**, same check. |
| Scripts that hard-code `/tmp` (`post-push-status.sh`, gh-wrapper tests) | 8 | **A.** Fix the scripts to use `$TMPDIR`. Do not add `/tmp` to `allowWrite`. |
| `ps` blocked | 1 | **A** (decided 2026-10-27): add `ps *` to the shared `excludedCommands`. It only reads the process list. |

### Sandbox network

| Pattern | Volume | Answer |
| --- | --- | --- |
| Hook reviewers (`claude -p` from git hooks) try MCP and telemetry hosts | ~280 rows, ~3,900 lines; nothing fails | **B.** Start reviewers with no MCP servers and no telemetry. Do not allow these hosts. The exact flags need checking against the docs. |
| `.local` names do not resolve when `ssh`/`rsync` is not the leading command | 21 | **Test.** This also decides whether `dotall-fleet` (ssh in a loop) can run from Claude. Options: add the script to `excludedCommands`, or find why mDNS fails in the sandbox. |
| pypi.org, my.1password.com | 1 each | Decide when they recur. |

### Classifier (15 denials)

Correct: Credential Materialization, Self-Approval, Security Weaken,
Credential Exploration (ssh to the company machine). False positives, fixed
with `autoMode.allow` prose in the per-machine settings:

- "Auto-Mode Bypass" (3) and "Unrequested Commit" (2) on plain commits in
  `.claude/worktrees/`.
- "External System Writes" (1) on closing an issue in Andrew's own repo
  (already allowed in prose; re-check the wording).
- "Remote Shell Writes" (1) on `ssh tilsit.local 'git pull'`, which the
  `dotall-fleet` work needs.

### Noise with no action

| Source | Answer |
| --- | --- |
| `fsmonitor_ipc__send_query` on every git command | The sandbox blocks the daemon socket, so sandboxed git already runs without fsmonitor. **Decided 2026-10-27: off for Claude sessions only**, on for Andrew's terminal. Candidate: `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0` in the shared settings `env`. **Test first:** the worktree guard refuses inline `GIT_CONFIG_COUNT`; whether it also refuses when the value comes from settings `env` is not known. If it does, look for another Claude-only switch (for example a `GIT_CONFIG_GLOBAL` file that includes the real config and overrides `core.fsmonitor`). Fallback, only with Andrew's approval: off everywhere (measured 20 ms or less for `git status` on the largest local repo, 1,163 files). |
| `branch -D` config warning | Worktrees step 4 (`update-ref -d`). |
| Reviewer network denials | Sandbox network, first row. |
| Pre-push reviewer: "Credit balance is too low; retrying on subscription" | Working as designed (Andrew, 2026-10-27): `claude -p` uses the monthly $100 Max API credit first and falls back to the subscription when it runs out. Optional: reword the line so it reads as expected behavior, not a failure. |

## General permission rules

These rules are the smaller lever: none of the 633 denials came from a
missing permission rule. They make the boundary explicit and remove classifier
false positives. Scope: with `autoAllowBashIfSandboxed`, Bash allow rules
change little. The
rules that change behavior are Edit path rules, `autoMode` prose and
`excludedCommands`. Rules are written by intent, not by file or line.

**One write boundary.** Whatever sandboxed Bash may write, the Edit tool may
write. `Edit` rules cover every built-in file-editing tool (`Write(...)` rules
never match). Protected paths stay protected regardless.

```json
{
  "permissions": {
    "allow": [
      "Edit(~/Developer/**)",
      "Edit(~/.local/state/**)"
    ],
    "deny": [
      "Bash(gh pr merge * --admin*)",
      "Bash(gh pr merge * --auto*)"
    ]
  }
}
```

The deny rules guard the `autoMode.allow` merge entry below: a `*` in a Bash
rule matches spaces, so a narrower allow rule could still match `--admin`.

`autoMode.allow` additions (prose, per machine, alongside `$defaults`):

- "Committing and pushing on a branch inside `<repo>/.claude/worktrees/` in a
  repo owned by smartwatermelon, nightowlstudiollc or twistedmelonman is
  normal development work."
- "Running dev-environment sync commands (`my-repos`, `dotall`, `git pull`)
  over ssh on asiago.local, tilsit.local, mimolette.local and parmesan.local
  is allowed. arich-mac.local stays read-only."

## Where the settings live

The sandbox block and the `autoMode` block are in
`~/.config/claude-code/machine-settings.json`, a plain file with no repo and
no history. The 2026-10-20 plan keeps `autoMode` per machine (the Beacon
leak). Several sandbox entries are also specific to this Mac: its
`/var/folders/...` temp folder, the personal Google Drive path, and
`/private/tmp/claude-501` (a user ID that differs on the work Mac).

**Rule: global settings everywhere, with a local overlay per machine.**
`--settings` arrays concatenate with the shared file and objects merge by key
(measured 2026-10-20), so an overlay can add entries but never remove shared
ones. That makes the shared file a floor every machine gets. **Decided
2026-10-27.** Before the move, audit the fleet: each Mac may already have its
own `machine-settings.json`, `settings.local.json` or other drift, and each
must be compared with the split below so that nothing it relies on is lost.

- **Shared (`claude-config` `settings.json`, tracked and reviewed):** the
  sandbox switches (`enabled`, `failIfUnavailable`, `allowUnsandboxedCommands`,
  `autoAllowBashIfSandboxed`); `allowWrite` entries written with `~` and
  valid on every Mac (`~/Developer`, `~/.local/state`, `~/.cache`,
  `~/Library/Caches`); shared `excludedCommands`, network domains,
  `permissions` rules; and `autoMode` entries true on every machine.
- **Per machine (the overlay, `machine-settings.json`):** host-specific paths
  (temp folder, Drive folder, user-ID paths), `defaultMode`, and `autoMode`
  `environment` text that names this machine's hosts and trust. Each host's
  overlay is generated from a tracked per-host file by an installer (the
  lock-sync pattern), so it has a source and history.
- The settings move needs a check on each machine before it ships: a session
  on the work Mac must start with the shared sandbox and no ASIAGO paths.

## Follow-up work, by repo

None of this is done in this PR.

- **claude-config, hooks (largest gain):** copy check moved to the git
  pre-commit hook; repo resolution of same-command assignments and
  `cd <literal>`; the compound excluded-command check;
  `hook-block-git-worktree.sh` simplified; the `merge-lock` substring fix.
  Each hook change is validated against the matching rows of
  `denials.jsonl`: replay the blocked commands and confirm the false
  positives pass and the correct blocks still block.
- **claude-config, policy:** Protocol 1 and 6 rewritten for the worktree
  procedure; the shared half of the settings split.
- **claude-wrapper:** tracked per-host overlay files and the installer that
  writes `machine-settings.json` from them.
- **claude-config:** `hook-block-enter-worktree.sh` accepts `path`
  re-entry into an existing worktree.
- **scripts:** `worktree-reaper.sh` and its LaunchAgent; `dotall-fleet`
  waits on the `.local` test.
- **dotfiles / claude-config:** the Claude-only fsmonitor switch (after its
  test); gh-wrapper test `/tmp` paths.
- **Fleet audit:** inventory each Mac's existing settings files and drift
  before the settings split ships.
- **review hooks:** reviewers without MCP or telemetry.
- **Tests to run first:** `update-ref -d` branch delete; `.local` resolution
  in the sandbox; settings `env` versus the worktree guard.
