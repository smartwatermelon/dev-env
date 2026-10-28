# Plan: keep per-machine Claude settings in sync across machines

**Status:** proposal, deferred; not scheduled
**Date:** 2026-10-28
**Author:** arich (drafted by Claude Code)

## Problem

Claude Code reads `autoMode` only from `~/.claude/settings.json`, managed
settings and `--settings`. `~/.claude/settings.json` ships to every machine
through claude-config, so per-machine settings go in
`~/.config/claude-code/machine-settings.json`, which claude-wrapper (or
claude-wrapper-lite) passes with `--settings`. That file is in no repo.

Each machine's copy was written separately, mostly by `/auto-mode-setup`, which
describes only the repo it ran in. On 2026-10-28:

- MIMOLETTE's overlay described one private repo, so every session on that
  machine told the classifier that repo was the only trusted one.
- ASIAGO had a hand-written machine-wide block the others lacked.
- TILSIT had no `autoMode` at all.
- A `/auto-mode-setup` run wrote into the claude-config deploy clone and
  blocked every deploy (claude-config#804).

## What was done on 2026-10-28

1. The available lists (MIMOLETTE's two generated blocks, ASIAGO's
   hand-written one) were merged into one base: trust follows the `origin`
   owner (`smartwatermelon`, `twistedmelonman`, `nightowlstudiollc`), not a
   repo list; visibility is checked live with `gh`; per-repo specifics are
   labeled with their repo; one "Host containment" line per machine.
2. MIMOLETTE, ASIAGO and TILSIT got the base, with every non-`autoMode` key
   (plugins, hooks, sandbox, permissions) kept. Backups:
   `machine-settings.json.bak-20261028-merge`.
3. arich-mac is a company machine with its own company-repo rules. It gets an
   additive merge only: existing entries stay first and unchanged; base
   entries are appended if missing.

From here each machine can diverge. Nothing carries a later change to the
base to the other machines. This plan is about that gap.

## Proposal

Use `smartwatermelon/claude-config-backup` (private), which already snapshots
machine-local Claude config files unattended.

1. **Host-prefix the layout.** Today it holds one machine's files at `cli/`
   and `desktop/`. Move them to `ASIAGO/cli/…` and `ASIAGO/desktop/…`; each
   host writes only its own folder, so hosts cannot collide.
2. **Track the overlay.** Add `<HOST>/machine-settings.json` to `TRACKED` in
   `scripts/claude-config-backup.sh`. Each overlay then gets history, an
   off-machine copy and the same gitleaks gate.
3. **Run it on every personal machine.** Today the LaunchAgent exists only on
   ASIAGO.
4. **Later, if drift matters:** a hand-maintained `shared/automode-base.json`
   plus a small per-host fragment, combined into the live overlay by an
   additive merge (the same rule as arich-mac: existing first, append what is
   missing). The backup keeps recording the combined result, so the two
   directions never write the same file.

## Constraints

- **arich-mac is excluded** from the backup. Company configuration must not
  go into a personal repo.
- The base names private-repo details, so it must never go into a public repo
  (claude-config, dotfiles, dev-env are public).
- `--settings` does not stack (last flag wins) and arrays concatenate with
  `settings.json`, so each machine's overlay must stay one complete file.

## Found while checking (fix before building on it)

ASIAGO's backup job runs and commits, but its clone was **1024 commits ahead
of `origin`** on 2026-10-28; nothing has pushed since 2026-09-08 PDT. The
history exists only on ASIAGO. Find out why the push fails before relying on
this repo as an off-machine copy.
