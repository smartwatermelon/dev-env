# Design: a GitHub App for desktop agent work on the personal owners

Status: DRAFT, 2026-10-01. Decided: build after the 2026-10-07 hard stop.

Scope decision (Andrew, 2026-10-01): **option B now, option A later.**

- **B (this design):** one GitHub App replaces the three per-owner PATs for
  desktop agent work on `smartwatermelon`, `nightowlstudiollc` and
  `twistedmelonman`.
- **A (later):** add the machine account from
  `2026-09-27-agent-identity-merge-gate-design.md` for the claude.ai GitHub
  connection only. That connector logs in as a user, so an App cannot stand in
  for it.

Beacon (`beacon-biosignals`, `andrewmrich`) is out of scope. It keeps the
keyring switch in `gh-wrapper.sh`.

## Why

There are three tokens only because a fine-grained PAT is limited to one
resource owner. GitHub's docs say: "Each token is limited to access resources
owned by a single user or organization." A classic PAT spans owners, but its
only private-repo scope, `repo`, grants read **and** write everywhere. There is
no read-only private-repo scope. (Both checked against docs.github.com,
2026-10-01.)

The Dependabot digest already moved to an App (dev-env#169). One App, one
private key, one installation per owner. It ran green once on 2026-10-01
(`workflow_dispatch`); its first scheduled run is 2026-10-02 14:00 UTC.

What the App gives over the PATs:

1. **One credential.** A private key, with no expiry. Today's three PATs each
   expire and need rotation.
2. **Short-lived tokens.** Installation tokens live about 1 hour. A leaked one
   is nearly worthless.
3. **Checks: read.** Fine-grained PATs have no Checks permission, and GitHub
   returns nulled CheckRuns with HTTP 200 instead of an error. App tokens can
   read check runs.

## What B does NOT fix

B changes convenience, not trust. The agent can still act as Andrew on the
desktop:

- `git push` goes over SSH with Andrew's key, so pushes stay `twistedmelonman`.
- The `gh` keyring still holds Andrew's logins (Beacon, and admin work).
- Cloud sessions still use Andrew's claude.ai GitHub connection.

Closing that is the job of option A plus the superuser mode in the
2026-09-27 design. Do not describe B as an identity boundary.

## Design

### The App

A **new** App, not the digest App. The digest App is read-only on purpose; this
one needs writes. Separate Apps keep each one least-privilege.

- Name: `twm-agent` (or similar). Installable on **any account**: the default
  limits installation to the owning account, and it must install on all three
  owners (same trap as the digest plan, step 1).
- Installed on all three owners, **all repositories**, so new repos are
  covered.
- Repository permissions:

| Permission | Level | Why |
| --- | --- | --- |
| Metadata | Read | Required by GitHub |
| Contents | Read and write | API file reads; branch create/delete via API |
| Pull requests | Read and write | Open, edit, comment on, merge PRs |
| Issues | Read and write | File, comment, close |
| Checks | Read | CI state (PATs cannot) |
| Actions | Read | Run lists and logs |
| Commit statuses | Read | Older status contexts |
| Administration | Read | Fleet probes read branch protection |
| Workflows | **None** | Blocks API writes to workflows (1) |

- (1) Only API writes to `.github/workflows/`. SSH pushes are Andrew's and
  are not limited by this.
- Organization permissions: Projects **Read and write**, for the
  `smartwatermelon` board. Members **Read**, if a lookup needs it.
- Not granted: Administration write, Secrets, Environments. Protection and
  secret changes stay superuser work, done as Andrew.

### Key storage

- Private key in 1Password vault `Automation`, as a `.pem` **attachment**.
  `op read` of a pasted PEM field returns it flattened onto one line; read the
  attachment (same as `DIGEST_APP`).
- `claude-wrapper/lib/credentials.sh` already loads the per-owner PATs at
  launch through the 1Password service account (`_load_owner_gh_tokens`). Swap
  that for loading the App's client ID and key. Fail closed per item, as today.
- Where the key lives during a session is an open question (see below).
  Either way, add the key's variable name to the secret-leak hook's list.

### Minting

1. Sign a JWT (RS256, `iss` = client ID, `exp` ≤ 10 min) with the key.
2. `POST /app/installations/{id}/access_tokens`. Resolve each installation ID
   once per owner (`GET /users/{owner}/installation` or
   `/orgs/{owner}/installation`) and cache it.
3. Cache each owner's token with its `expires_at`. Mint again when less than
   5 min remain.

Build the minter as one small script (`gh-app-token <owner>`) with its own
tests. `openssl` signs RS256; no new dependency is needed. Verify the JWT
format against GitHub's docs at build time; do not rely on this summary.

### Wrapper integration

`gh-wrapper.sh` already resolves the owner per call and picks that owner's
token for the one real `gh` process (`_gh_wrapper_sync_identity`,
`_gh_wrapper_owner_token_var`). Replace "read `GH_TOKEN_SWM`" with "call the
minter for this owner". Everything else stays.

Remove the `gh auth switch` call on every path where a token was selected. The
switch rewrites `~/.config/gh/hosts.yml`, which every shell shares, so it races
(dotfiles#336). When a token is passed to the one `gh` process, the keyring
identity is irrelevant.

## What changes for Andrew

- **PRs, issues and comments the agent opens show as `twm-agent[bot]`**, not
  `twistedmelonman`. Commits pushed over SSH still show Andrew.
- A PR opened by the App can be approved by Andrew, because the author is a
  different account. **Verify at build time** that the App's install does not
  change who can approve.
- One item to rotate (the key) instead of three expiring PATs.

## Things to check before building

These may assume the actor is `twistedmelonman`. Grep each for login checks:

1. `merge-lock.sh` and `pre-merge-review.sh`
2. The Personify gate's destination routing (`gate-rules.conf`)
3. `gh-wrapper.sh` identity checks: `CLAUDE_GH_TOKEN_LOGIN`, and the
   `gh api user` fallback. An installation token has no user, so `gh api user`
   fails with it.
4. Scripts that use `GH_TOKEN_SWM`/`_NOS`/`_TWM` directly:
   `dotfiles/bash/functions.sh`, `claude-config/scripts/merge-audit.sh`, and
   the tests that name them.
5. Dependabot auto-merge: unaffected (it runs in Actions), but confirm.
6. `gh search` and other cross-owner reads. An installation token sees one
   owner, so a search across all three needs one call per owner.
7. `gh project item-list` and other Projects commands. Confirm `gh` accepts an
   installation token with org Projects permission; it checks token scopes.
8. `gh pr create`'s viewer lookup. It works with `GITHUB_TOKEN` in Actions,
   which is also an installation token, so it probably works. Test it first.

## Open questions

1. **Key at rest during a session.** Keep the PEM in an environment variable
   from launch, or write it to a `0600` file under `~/.cache` and pass the
   path? The env var never touches disk; the file survives a wrapper re-exec.
2. **Unresolved owner (dotfiles#336, Q4).** With no owner there is no
   installation to mint for. Proposed: writes refuse; reads mint for
   `twistedmelonman`. This is the recommendation already put to Andrew;
   answer pending.
3. **Merge as the App or as Andrew?** `gh pr merge` with the App token makes
   the App the merger. The merge-lock still gates it locally. Fine for B;
   revisit under A.
4. **Keep the PATs as a fallback** for one release, or revoke them at once?
5. **Two agent identities break the A gate as written. Resolve before A.**
   Under A, the App (desktop) and the machine account (cloud) both hold
   pull-request write, which includes submitting reviews. Each could approve
   the other's PR, so "require 1 approving review" no longer means Andrew
   approved. A must require the review from Andrew specifically (CODEOWNERS
   naming only `twistedmelonman`, plus "require review from code owners"), or
   one identity must lose the ability to review.

## Order of work

1. HUMAN: create the App, generate the key, store it in 1Password, install on
   all three owners (about 15 min; same steps as the digest plan, 1–3).
2. AGENT: the minter script and tests.
3. AGENT: `credentials.sh` loads the App instead of the PATs; `gh-wrapper.sh`
   calls the minter; the auth switch goes away on token paths.
4. AGENT: fix what the "Things to check" grep finds.
5. Verify: one PR on each owner, opened, checked and merged through the App.
6. HUMAN: revoke the three PATs and delete their 1Password items.
7. Close dotfiles#336 if steps 3–5 cover it; otherwise record what remains.
