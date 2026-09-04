# Runbook: rename `smartwatermelon` → `twistedmelonman`, create org `smartwatermelon`

Design: `docs/superpowers/specs/2026-09-03-org-migration-design.md`, Step 2.
One sitting, one browser session. The window between A4 and B3 is the only
moment the name `smartwatermelon` is claimable by someone else. Do A and B
back to back.

## Before you start

- [ ] dotfiles PR "twistedmelonman owner table, login alias, F4 scope hint" is
      merged and `~/Developer/dotfiles` is on `main` at or after it.
      Check: `grep -c twistedmelonman ~/Developer/dotfiles/bash/gh-wrapper.sh`
      prints a number ≥ 4.
- [ ] Baseline snapshot committed under `docs/data/org-migration/`.
- [ ] You are signed in to github.com as `smartwatermelon` in the browser.
- [ ] Nothing is pushing or running CI right now (check
      `gh run list -R smartwatermelon/github-workflows --limit 3`).

## A. Rename the user

1. Open <https://github.com/settings/admin> ("Account" settings).
2. Under **Change username**, click **Change username**.
3. Read the warning dialog, click **I understand, let's change my username**.
4. Type `twistedmelonman`, click **Change my username**.
5. Confirm the page header shows `twistedmelonman`.

## B. Create the org (immediately)

1. Open <https://github.com/account/organizations/new?plan=free>.
2. Organization name: `smartwatermelon`. If the form says the name is taken,
   **stop**: go back to A and rename to `smartwatermelon` again. The design's
   failure table covers what happens next (a new spec).
3. Contact email: your gmail. "This organization belongs to": **My personal
   account**. Complete the verification, click **Next**.
4. Skip "Add organization members" (**Skip this step**). Skip the survey.
5. Confirm <https://github.com/smartwatermelon> shows the org page with you
   as owner.

## C. Org settings

1. <https://github.com/organizations/smartwatermelon/settings/actions>:
   **Actions permissions** must be "Allow all actions and reusable workflows"
   (the Free default). Under **Workflow permissions**, leave "Read
   repository contents and packages permissions" (repos carry their own
   setting across the transfer).
2. <https://github.com/organizations/smartwatermelon/settings/member_privileges>:
   leave defaults. You are the only member.

## D. Re-login the keyring on THIS machine

The keyring token still works after the rename, but `hosts.yml` records the
login name and the wrapper compares it. Re-login rewrites it.

```bash
env -u GH_TOKEN gh auth login -h github.com --web --scopes admin:org,repo,workflow,delete_repo
env -u GH_TOKEN gh auth logout -h github.com -u smartwatermelon   # stale entry, if listed
env -u GH_TOKEN gh auth status
```

Expected: the active github.com account is `twistedmelonman`, scopes include
`admin:org`. `delete_repo` is for Step 6's repo deletions; drop it from the
list if you would rather add it later with `gh auth refresh -s delete_repo`.

## E. Verify from a shell (paste the output back to the agent)

```bash
gh api user --jq .login                                  # GH_TOKEN: twistedmelonman
env -u GH_TOKEN gh api user --jq .login                  # keyring: twistedmelonman
gh api orgs/smartwatermelon --jq '.login + " " + .type'  # smartwatermelon Organization
gh api orgs/smartwatermelon/memberships/twistedmelonman --jq .role   # admin
gh api repos/smartwatermelon/dotfiles --jq '.owner.login + " " + .owner.type'  # twistedmelonman User (redirect)
cd ~/Developer/dotfiles && gh pr list --limit 1           # identity guard passes, no error
```

## Stop: the transfer happens outside this runbook

Parts A–E cover **Step 2** of the design only: the rename and the org. No
repo has moved yet. Parts F and G below verify a transfer, so do not run
them here — every repo would still report `owner is twistedmelonman (User)`,
which is correct for this moment and looks like 31 failures.

Go to `docs/superpowers/specs/2026-09-03-org-migration-design.md` and do:

- **Step 3** — transfer `github-workflows` alone and prove one consumer per
  org still runs green. It is the cross-org dependency: both orgs reference
  `uses: smartwatermelon/github-workflows/...`. Read the run log to confirm
  the reusable workflow resolved from the new owner; a green check by itself
  is not evidence.

  ```bash
  bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt \
    --only github-workflows --dry-run
  bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt \
    --only github-workflows
  ```

- **Step 4** — transfer the remaining repos:

  ```bash
  bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt --dry-run
  bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt
  ```

Come back to Part F when Step 4 is done.

## F. Verify the transfer (`verify.sh`)

Run this **after** design Steps 3 and 4, not before.

```bash
bash scripts/org-migration/verify.sh scripts/org-migration/move-list.txt \
  docs/data/org-migration/2026-09-04-baseline "$(mktemp -d)"
```

The baseline directory is dated. `verify.sh` fails and names the path if you
get it wrong, rather than reporting every repo as a missing snapshot.

**Always give `verify.sh` a fresh, empty after-dir.** It refuses a directory
that already holds files, because a leftover JSON from an earlier run would be
compared as though this run had just written it — a repo whose snapshot failed
now could still be reported ok from stale state. A `mktemp -d` per run is the
simplest way to get one.

**`cleanroom` is the one repo that moves to a *different* owner name**
(`nightowlstudiollc`, not `smartwatermelon`), so its URL-bearing fields may
legitimately differ: `protection.url`, a ruleset's `source` and `_links`, and
`pages.html_url` all embed the owner. A `fields changed besides owner` report
naming only those fields, for `cleanroom` only, is expected — not drift to
"restore". Inspect it before deciding:

```bash
diff <(jq -S . docs/data/org-migration/baseline/cleanroom.json) \
     <(jq -S . <after-dir>/cleanroom.json)
```

If every difference is an owner name inside a URL, the transfer is correct.
The same report for any other repo, or a difference in a non-URL field, is
real drift.

## G. The other two machines (TILSIT, MIMOLETTE)

Run section D on each, before the alias-removal PR (plan Task 12, design
Step 6) merges. Until then the alias keeps the old `hosts.yml` name working.

Section D re-logins the keyring. On a machine whose shell was already open
before the rename, the sourced `gh` wrapper is also stale: reload it with
`exec bash -l` before verifying, or the old wrapper still tries to switch to
`smartwatermelon` and fails closed. `which gh` and `hash -t gh` show the
staleness; `command -v` does not.

Steps 5–7 of the design (org secret, cleanup, docs) are not covered by this
runbook.

## Undo

Rename back at <https://github.com/settings/admin> → `smartwatermelon`. If
the org was created, delete it first at
<https://github.com/organizations/smartwatermelon/settings/profile> (bottom,
**Delete this organization**), because the name must be free.
