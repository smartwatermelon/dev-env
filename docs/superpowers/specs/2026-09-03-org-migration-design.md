# Design: Org Migration (I3) and Token Scope Escape Hatch (F4)

Status: APPROVED IN CHAT 2026-09-03 — spec under review before the
implementation plan. Executes items I3 and F4 of
`2026-09-01-infrastructure-backlog-design.md`. Supersedes the phase plan in
`smartwatermelon/dev-env#54` while keeping its goal.

## Purpose

Move the active `smartwatermelon/*` repositories from a personal account
into a GitHub organization **named `smartwatermelon`**, so that
`CLAUDE_CODE_OAUTH_TOKEN` is set once at org level instead of once per repo.
Annual token mints drop from ~30 to 2 (one per org).

Do it without changing a single repository URL. Every `uses:` reference,
Dependabot target, Homebrew tap name, plugin-marketplace name, local remote,
and blog link continues to point at `smartwatermelon/<repo>` and is correct
before, during, and after the migration.

## Decisions, with reasons

| Decision | Reason |
| --- | --- |
| The org is named `smartwatermelon`; the personal account is renamed to `twistedmelonman`. | Users and orgs share one global namespace. Freeing the name and re-claiming it as an org is the recipe GitHub's own docs give for "I want my org to have my current username." Every existing reference stays valid. |
| Rename-then-create, not "convert user to organization". | Conversion destroys the personal account (keys, tokens, gists, sign-in) and needs a replacement account. A rename keeps all of it. |
| Rename-then-create, not a new org under a different name. | A different name means rewriting `uses:` refs across ~35 repos, `zizmor.yml`, every `dependabot.yml`, `repo-template`, docs, and the blog. That was the entire Phase 3 of #54. It disappears. |
| Free plan for the org. | Every active repo is public except three. Free covers public-repo branch protection and org-level secrets. Team ($4/month) would only buy protection on private repos that take almost no PR traffic. |
| `scripts` moves, stays private, stays unprotected; going public is a follow-up issue. | Andrew wants it public, but it needs a secret audit and a history rewrite first. Not this migration's work. |
| `claude-config-backup` moves, stays private, no protection. | Fully automated backup target. Protection would break the automation and guards nothing. |
| `cleanroom` transfers to `nightowlstudiollc`, not to the new org. | Commercial product repo; that org is on Team and already gives it private-repo protection. |
| Archived repos (27) and active forks (2) stay under `twistedmelonman`. | Archived repos cannot run CI, so they need no org secret. Their old URLs redirect indefinitely because the org will never reuse those names. Forks stay attached to the person. |
| Delete `KEBAB_TAX_GITHUB_TOKEN` from the archived `ralph-burndown`. | Only non-Claude secret in the account. Nothing consumes it. |
| Delete the archived `smartwatermelon.github.io` repo. | Not in use. After the rename it would become `twistedmelonman.github.io`, a Pages host nothing points at. Deleting is simpler than carrying it. |
| F4 shape: explicit escape hatch, no routing, no second PAT. | Both tokens are the **same login** — see "What verification changed." Only the scope differs. A command that needs `admin:org` runs with `GH_TOKEN` unset; the wrapper then falls through to the keyring token, which has it. |
| Loud failure on a scope error. | Andrew: "so we don't have to re-derive every time." The wrapper detects GitHub's scope error in `gh`'s stderr and prints the exact fix. |
| Calendar reminders for token expiry are created by the agent via the Google Calendar connector, after minting. | The expiry date only exists once the token does. |

## What verification changed

**F4 is a scope split, not an identity split.** `gh auth status` on
2026-09-03:

| Token | Login | Active | `admin:org` |
| --- | --- | --- | --- |
| `GH_TOKEN` (CCCLI PAT from 1Password) | `smartwatermelon` | yes | no |
| keyring (`gho_`) | `smartwatermelon` | no | **yes** |

The backlog design assumed the org-level calls needed a different
*identity* and reached for a router. They need a different *token of the
same identity*. Unsetting `GH_TOKEN` for one command is the whole fix.

**Free orgs do not get private-repo branch protection.** GitHub's plans page
lists "Protected branches" and "Code owners" under Team for private
repositories only. The backlog design's claim that moving `scripts`,
`claude-config-backup`, and `cleanroom` into the org "converts them from
cannot-be-protected to ordinary fleet repos" is **false on Free** and is
struck. The migrate-early decision stands on its remaining reasoning.

**Inventory (2026-09-03, `gh repo list smartwatermelon`).** 60 repos: 31
active non-fork, 2 active forks (`homebrew-brew`, `Instapaper-MCP`), 27
archived. Move list is the 31, with `cleanroom` targeting
`nightowlstudiollc`.

**Name-bound repos that the rename approach keeps intact:** `homebrew-tap`
(tap name `smartwatermelon/tap`), `smartwatermelon-marketplace` and
`superpowers-marketplace` (referenced by owner in Claude settings), `.github`
(becomes the org's community-health and profile repo), `projectinsomnia`
(Pages site; its `smartwatermelon.github.io` Pages *host* becomes the org's
Pages host with the same name. The archived *repo* of that name is
unrelated and is deleted in Step 6).

## Sequence

Seven steps. Each has a verification that must pass before the next starts.

### Step 1 — Pre-flight (no GitHub state changes)

1. Ship the `gh-wrapper.sh` change (see "gh-wrapper changes"). Merged and
   live on this machine before anything is renamed.
2. Record the org-level Actions policy the new org will need: "Allow all
   actions and reusable workflows." Free orgs default to this; the runbook
   has a check.
3. Snapshot every repo on the move list (see "Transfer tooling"). Commit the
   snapshot to `dev-env/docs/data/org-migration/<date>/`.
4. Confirm no CODEOWNERS file in any moving repo names `@smartwatermelon`
   as a *user* (post-rename that resolves to the org, which is not a valid
   reviewer). `grep -l smartwatermelon **/CODEOWNERS` across local clones.

**Verified when:** wrapper PR merged; snapshot committed; CODEOWNERS grep
clean or fixed.

### Step 2 — Rename the user, create the org (manual, UI, one sitting)

Andrew follows `docs/runbooks/org-migration-rename.md` (a plan deliverable):

1. Settings → Account → Change username → `twistedmelonman`.
2. Immediately: New organization → Free → name `smartwatermelon`.
3. Verify from a shell.

The window between 1 and 2 is the only moment the name is claimable by
someone else. Back-to-back in one browser session keeps it to seconds. If
the org name is taken in that window, rename back and stop.

**Verified when:** `gh api user --jq .login` prints `twistedmelonman` for
both the `GH_TOKEN` and the keyring token; `gh api orgs/smartwatermelon`
returns the org with Andrew as owner; a wrapped `gh` call in a
`smartwatermelon/*` clone passes the identity guard; `gh api
repos/smartwatermelon/dotfiles` returns the repo (via redirect) with owner
`twistedmelonman`.

### Step 3 — Transfer `github-workflows` alone

It is the cross-org dependency: every Claude-consuming repo in **both** orgs
calls `uses: smartwatermelon/github-workflows/...`. Move it first and prove
the redirect-then-real-repo path on one consumer per org before the batch.

**Verified when:** `gh api repos/smartwatermelon/github-workflows --jq
.owner.type` is `Organization`; one `smartwatermelon/*` consumer and one
`nightowlstudiollc/*` consumer each run their `claude-blocking-review`
workflow green, and the run log shows the reusable workflow resolved from
`smartwatermelon/github-workflows` (read the log; the green check alone is
not evidence).

### Step 4 — Transfer the remaining 30 repos by script

`scripts/org-migration/transfer.sh` (in dev-env) walks the checked-in move
list. `cleanroom` targets `nightowlstudiollc`.

**Verified when:** every repo on the list has `owner.type ==
Organization` under its target; the post-transfer snapshot diffs against the
step-1 snapshot with **owner as the only difference**; `git ls-remote` on
every local clone under `~/Developer` succeeds without a remote change.

### Step 5 — Org-level secret

```bash
claude setup-token                                   # mint once
env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN \
  --org smartwatermelon --visibility all
```

Then delete every repo-level `CLAUDE_CODE_OAUTH_TOKEN` in the org (they
shadow the org secret). On `nightowlstudiollc`, delete the shadowing copies
on `networth-agent` and `photo-game-poc`.

**Verified when:** `gh secret list` on a moved repo shows no repo-level
`CLAUDE_CODE_OAUTH_TOKEN`; one workflow on a moved repo and one on
`networth-agent` re-run green, and each run's log shows the token was
present (the `claude-code-action` step authenticated rather than skipped).

### Step 6 — Cleanup

- Delete `KEBAB_TAX_GITHUB_TOKEN` from `twistedmelonman/ralph-burndown`.
- Delete the `claude-code-login` fork (dead end, 429 from Anthropic).
- Delete the archived `smartwatermelon.github.io` repo (unused; Andrew's
  decision 2026-09-03). Confirm it is not `projectinsomnia`'s Pages source
  first: `gh api repos/smartwatermelon/projectinsomnia/pages`.
- Write `dev-env/docs/token-rotation.md` (see "Token tracking").
- Create two Google Calendar events, one per org, two weeks before each
  token's expiry, description pointing at the rotation runbook.
- File the `scripts`-goes-public issue: secret audit, history rewrite,
  then flip visibility and add branch protection.
- Remove the temporary `smartwatermelon` login alias from the wrapper (see
  "gh-wrapper changes") in a follow-up PR.

### Step 7 — Docs

- `dev-env#54`: comment with the outcome and close.
- Backlog design: rewrite the I3 and F4 sections to point here; strike the
  private-repo-protection benefit; note F4's scope-not-identity finding.
- `WORKFLOW-DEEP-DIVE.md` and `gh-wrapper.sh` header comments: owner mapping
  now yields `twistedmelonman`.

## gh-wrapper changes (dotfiles, one PR, before Step 2)

### Owner table

```bash
case "${owner,,}" in
  smartwatermelon | nightowlstudiollc | twistedmelonman) desired="twistedmelonman" ;;
  beacon-biosignals | andrewmrich) desired="andrewmrich" ;;
  # ... existing default branch unchanged
esac
```

The force-draft in-org list gains `twistedmelonman`, so PRs on the
archived/fork repos left under the personal account are not forced to
draft.

### Temporary login alias

Between this PR merging and Step 2 completing, both tokens still report
`smartwatermelon`. With `desired="twistedmelonman"` every wrapped call
would fail closed for the whole window. So the identity comparison accepts
a single dated alias:

```bash
# TEMPORARY until the 2026-09 rename lands (dev-env org-migration design,
# Step 2). Remove in the Step 6 follow-up. Both logins are the same person.
_GH_WRAPPER_LOGIN_ALIASES="twistedmelonman=smartwatermelon"
```

The comparison treats `desired` and its alias as equal in both the
`hosts.yml` check and the F3 `GH_TOKEN` guard. This is the **only** place
the design tolerates two answers, and it has a removal step.

### F4 scope-error hint

After `command gh "$@"` returns non-zero, if stderr matched
`needs the '([a-z:_]+)' scope`, print to stderr:

```text
[gh] GH_TOKEN is set and lacks the 'admin:org' scope. The keyring identity
[gh] for twistedmelonman has it. Re-run this one command without GH_TOKEN:
[gh]   env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon ...
[gh] (Do not add the scope to the CCCLI PAT — it is exported into every session.)
```

Stderr is duplicated to a temp file with `tee` via process substitution so
the user still sees it live. No command classification: the hint fires only
on GitHub's own scope error, so a misclassification cannot exist. The
original exit code is preserved.

### Tests

- Extend `test-gh-wrapper-identity.sh` for the new table and the alias.
- New `test-gh-wrapper-scope-hint.sh`: a fake `gh` on `PATH` that writes
  GitHub's 403 scope text to stderr and exits 1. Assert the hint is printed,
  the original stderr is preserved, and the exit code passes through.
  Negative control: a non-scope 403 prints no hint.
- **Known-bad:** both tests are observed failing against the current
  wrapper before the fix is applied, and the plan records the failing
  output.

## Transfer tooling (dev-env, `scripts/org-migration/`)

- `move-list.txt`: checked in, one `repo<TAB>target-org` per line, reviewed
  in the PR that adds it. The script never derives the list at run time.
- `snapshot.sh <outdir>`: for each repo on the list, writes JSON for
  default branch, branch protection, secret **names**, Pages config,
  `isArchived`, topics, visibility. Read-only.
- `transfer.sh`: for each line, if `gh api repos/<target>/<repo> --jq
  .owner.login` already equals the target, skip (idempotent). Otherwise
  `POST /repos/<current-owner>/<repo>/transfer` with `new_owner`, then poll
  until the repo resolves under the target as `Organization`. A failed
  transfer is reported and skipped; the loop continues. Redirects make
  partial completion safe.
- `verify.sh`: re-run `snapshot.sh`, diff against the baseline, fail unless
  owner is the only change; then `git ls-remote` every clone under
  `~/Developer` whose remote is `smartwatermelon/*`.

All three scripts: Bash 5, `shellcheck -S info` clean, use the wrapped
`gh` (the transfer endpoint needs `repo` scope, which `GH_TOKEN` has).

## Token tracking

`dev-env/docs/token-rotation.md`:

| Org | Minted | Expires | Minted on |
| --- | --- | --- | --- |

plus the rotation runbook: mint, `env -u GH_TOKEN gh secret set --org`,
re-run one workflow, update the table, move the calendar event.

**Not sensitive by construction:** no token, no token prefix, no
`setup-token` output. The file carries a header stating that rule. Rotate
before expiry rather than revoke-then-mint — revocation can take days to
propagate (dev-env#54 findings).

## Failure handling

| Failure | Response |
| --- | --- |
| Org name claimed in the rename window | Rename the user back to `smartwatermelon`. The alias means the wrapper never broke. Fall back to the original #54 plan: a differently named org plus a fleet-wide reference rewrite. That is a new spec, not a retry of this one. |
| Consumer CI fails after Step 3 | Stop. Nothing else has moved. Diagnose the redirect on the single moved repo. |
| Transfer fails mid-loop | Re-run `transfer.sh`; it skips completed repos. Report the refusing repo. |
| Org Actions policy blocks reusable workflows | Set "Allow all actions and reusable workflows" at org level; re-verify Step 3. |
| Post-transfer diff shows more than owner | Finding. Restore the setting by hand from the snapshot; record which setting GitHub dropped. |
| Undo everything | Transfer repos back to the user, rename the user back. Both are supported operations. Wrapper changes are harmless if left. |

## Out of scope

- Rewriting any reference to `smartwatermelon/` — by design, none change.
- Making `scripts` public (follow-up issue).
- Recovering or deleting the old `andrewrichpalm`, `andrewrich-oracle`,
  `andrewrichmeraki` accounts. They hold no repos; nothing depends on them.
- W1/W2/W3 fleet work. Still blocked on `github-workflows#154`.
- Any change to `andrewmrich` / `beacon-biosignals` handling.

## Effect on the backlog design

- I3: done by this spec. F4: done by the escape hatch. The router stays
  deferred.
- "Private repos gain branch protection by moving" — **struck**.
- W2's note to re-pick a pilot after I3 stands; `scripts` remains
  unprotected until it goes public.
- I1's owner mapping must add `twistedmelonman` to the personal set in the
  same change as I1, since condition 2 keys on owner names.
