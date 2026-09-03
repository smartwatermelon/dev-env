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

## F. The other two machines (TILSIT, MIMOLETTE)

Run section D on each, before the alias-removal PR (plan Task 12) merges.
Until then the alias keeps the old `hosts.yml` name working.

## Undo

Rename back at <https://github.com/settings/admin> → `smartwatermelon`. If
the org was created, delete it first at
<https://github.com/organizations/smartwatermelon/settings/profile> (bottom,
**Delete this organization**), because the name must be free.
