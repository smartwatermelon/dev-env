# Plan: build machine settings from claude-config

**Status:** plan, not started
**Date:** 2026-11-05
**Issue:** smartwatermelon/dev-env#249 (decision: option A, 2026-11-05)
**Supersedes:** `2026-10-28-machine-settings-sync.md` (its backup-repo
proposal is dropped; the backup job may keep recording the built file)

## Goal

A change to sandbox domains, permissions or `autoMode` is a claude-config PR.
Andrew approves it in GitHub. The deploy job applies it to every personal Mac
within 10 minutes. Nobody edits a settings file by hand, and an agent cannot
change its live settings except through that PR.

## Current state

- claude-wrapper passes `~/.config/claude-code/machine-settings.json` with
  `--settings` (`lib/machine-settings.sh`). It skips the file unless it is
  owned by the user, not group- or world-writable, and a JSON object.
- `--settings` does not stack: one complete file per machine.
- The file holds `sandbox`, `permissions`, `autoMode` and a
  `hooks.PermissionDenied` entry. It is in no repo.
- The sandbox denies agent writes to that path. `~/.config/claude-code` is not
  in `sandbox.filesystem.allowWrite`.
- claude-config deploys through `scripts/claude-config-deploy.sh` (LaunchAgent
  every 10 minutes; cron on a host with no GUI login), which runs the deploy
  clone's `install.sh --sync`. The deploy clone is outside the sandbox's
  writable paths. claude-config `main` needs Andrew's approval (ruleset,
  2026-11-05).

## Design

### Source, in claude-config (public)

```text
machine-settings/
  base.json            # shared: sandbox, permissions, autoMode, hooks
  hosts/ASIAGO.json    # host-only keys, e.g. the "Host containment" line
  hosts/TILSIT.json
  hosts/MIMOLETTE.json
```

Nothing private goes in:

- The `autoMode` per-repo lines move to each repo's own `CLAUDE.md`. They name
  a private repo today.
- Paths that differ per machine are placeholders filled in at build time:
  `${TMPDIR}` (the `/var/folders/...` temp dir) and `${GDRIVE_HANDOFF}` (the
  Google Drive `Claude Handoff` folder, found by glob under
  `~/Library/CloudStorage/GoogleDrive-*`; its name holds an email address).
  The placeholder list is fixed in the build script. An unknown placeholder
  fails the build.

### Build, run by `install.sh --sync` in the deploy clone

1. Read the short host name. If `hosts/<HOST>.json` does not exist, do
   nothing and leave any existing file alone. This keeps arich-mac (company
   machine, out of scope) on its own file.
2. Merge `base.json` and the host file with `jq`: objects merge deep; the
   host file's arrays append to the base's arrays.
3. Fill in the placeholders.
4. Check the result: a JSON object, no `${` left.
5. Write it to a temp file in `~/.config/claude-code/`, `chmod 600`, then
   `mv` over `machine-settings.json`. A failed check leaves the old file and
   fails the deploy, which shows `[DEPLOY: <key>]` in the status line.
6. The first run on each machine saves the old file as
   `machine-settings.json.bak-<date>-pre-build`, once.

The build runs only from the deploy clone, never from a `--dev` checkout. Dev
mode links `~/.claude` to an agent-writable checkout; building settings from
there would let an agent change its own sandbox. Dev mode keeps the last
built file.

claude-wrapper needs no change: the output path is the one it already reads.

## Steps

1. **Inventory.** Read the overlay on ASIAGO, TILSIT and MIMOLETTE (read-only,
   over SSH) and diff them. Classify each key: shared, host-only, or private.
   Output: the three source files, reviewed before step 3.
2. **Check, then move the per-repo lines.** First check whether the
   auto-mode classifier reads a repo's `CLAUDE.md`. The 2026-10-28 plan says
   Claude Code reads `autoMode` only from settings and `--settings`, so
   moving a line to `CLAUDE.md` may drop it from the classifier's context.
   Test it: in a scratch repo, put a permissive rule in `CLAUDE.md` only,
   then see whether the classifier allows an action that rule covers.
   - If it reads `CLAUDE.md`: for each per-repo line, add its content to
     that repo's `CLAUDE.md` where it is missing. One PR per repo.
   - If it does not: stop and bring the choice back to Andrew before step 3.
     The per-repo context needs another home outside the public repo.
3. **Build script and tests** (claude-config). Bats tests with a temp `HOME`:
   merge order, array append, placeholders, unknown placeholder fails, no
   host file means no write, bad JSON keeps the old file, mode 600, backup
   once, `--dev` skips.
4. **Canary on ASIAGO.** Merge with only `hosts/ASIAGO.json` present. Check:
   the built file matches the old one, apart from the moved per-repo lines;
   a new session starts with the same sandbox (`/sandbox` view) and the
   status line has no deploy warning.
5. **Rollout.** Add the TILSIT and MIMOLETTE host files in one PR. Check each
   machine over SSH after the next deploy run.
6. **Prove the loop.** Add one sandbox domain through a PR only. See it live
   on all three machines with no hand edit. Then close dev-env#249.

## Risks

- **Array settings concatenate** with `~/.claude/settings.json`. The build
  must not copy entries that `settings.json` already has, or they appear
  twice. Step 1 checks for overlap.
- **Per-repo context may stop reaching auto mode.** It is not known whether
  the classifier reads `CLAUDE.md`. If it does not, moving the per-repo
  lines could make auto mode block actions it allows today. Step 2 checks
  this first.
- **The merge App gap** (`docs/runbooks/dependabot-merge-app.md`, "Known
  gap") applies here too: an agent that gets the merge App key could approve
  and merge its own settings PR. Accepted 2026-11-05. This plan does not
  widen it.
- **A bad merge breaks every machine** within 10 minutes. Step 4 of the build
  keeps the old file on a failed check; it cannot catch a valid but wrong
  setting. The canary step is the guard for that.

## Out of scope

- arich-mac.
- Changing what `/sandbox` writes. It stays refused while `--settings` is in
  use; the PR is the way to change settings.
