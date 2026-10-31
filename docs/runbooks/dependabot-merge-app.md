# Dependabot gate: merge App credentials

The reusable gate `smartwatermelon/github-workflows`
`dependabot-auto-merge.yml` (v3.1 and later) merges Dependabot PRs as a
GitHub App, `dependabot-merge-swm`, instead of with `GITHUB_TOKEN`. It mints a
short-lived installation token on each run with
`actions/create-github-app-token`.

**These steps are yours, not an agent's.** Creating an App, generating its
key and setting secrets are human operations.

## Why an App and not `GITHUB_TOKEN`

A merge made with `GITHUB_TOKEN` starts no `push` workflows. Measured
2026-10-29: the v3 canary merged smartwatermelon/projectinsomnia#211 as
`github-actions`, and its merge commit `7a83dda` got no Build or Netlify Site
Checks run on `main`. So nothing checks `main` after a gate merge, and
decision D on dev-env#229 ("a red `main` alerts") cannot fire. A merge made
with an App token starts `push` workflows as usual.

## Why a new App

The two existing Apps are read-only, and stay that way:

- `dependabot-digest-swm` (1Password `DIGEST_APP`): the digest and the site
  monitor.
- `CHECKS_APP`: the local pre-merge hook's CI reads (claude-config#687).

Andrew's rule (claude-config#687): read-only and write Apps are separate, so a
leaked read-only key cannot write. This App can write to every repo it is
installed on, so its key lives only in 1Password and in Actions secrets, never
on a dev machine.

## Security model

The private key is the risk. Whoever holds it can mint a token for **any**
repository the App is installed on, with every permission the App has. Scoping
the secret or the token does not limit a stolen key; only the installation
and the permission list do. So the installation list is the blast radius,
and the design keeps the key away from code that could leak it.

1. **The installation covers only caller repositories.** Install the App on
   **Only select repositories**: the same caller lists as the secrets in step
   4. A stolen key then writes only to repositories that already run the
   gate. When a repository gains a caller, add it to the installation and to
   both secrets.
2. **Only one step ever reads the key.** The gate is a reusable workflow, so
   it sees a caller secret only when the caller passes it. Each caller passes
   exactly the two secrets by name:

   ```yaml
   secrets:
     MERGE_APP_CLIENT_ID: ${{ secrets.MERGE_APP_CLIENT_ID }}
     MERGE_APP_PRIVATE_KEY: ${{ secrets.MERGE_APP_PRIVATE_KEY }}
   ```

   Never `secrets: inherit`, which would hand the gate every secret the caller
   can see. Inside the gate, only the token step
   (`actions/create-github-app-token`, pinned to a commit SHA) reads them.
   GitHub injects a secret only into a workflow that names it, so the
   repository's other workflows, and any third-party actions they run, cannot
   read it.
3. **The token step runs base-branch code only.** The gate runs on
   `pull_request_target` and never checks out or runs PR code. A Dependabot PR
   cannot change the gate, because the caller pins a tag in
   `smartwatermelon/github-workflows`.
4. **Each token covers one repository.** The gate asks for a token limited to
   the current repository (`repositories:`) and to the listed permissions
   (`permission-*:` inputs). A token that leaks from one run writes only to
   that repository, and expires within an hour.
5. **The secret reaches only caller repositories.** On smartwatermelon each
   caller has its own repository secret. On nightowlstudiollc the organization
   secret's visibility is **selected**: the repositories that have a gate
   caller. This keeps the key out of any repository without a caller.
6. **The key exists in two places only:** the 1Password `MERGE_APP` item, and
   the Actions secrets. It never goes on a dev machine; `op read` pipes
   it straight to `gh secret set`.

What a leaked key could still do: write code, PRs, labels and (with
Workflows) workflow files in every repository the App is installed on, until
the key is revoked on the App's page. Revoking the key stops it at once: the
next token request fails, and tokens already minted expire within an hour.

Who can reach the key: anyone who can push a workflow to the default branch
of a caller repository, because that workflow can name the organization
secret. Anyone who can move a gate tag in `smartwatermelon/github-workflows`
can reach it too. Both already have write access to the fleet. A pull request
alone cannot: `pull_request` runs from forks get no secrets, and
`pull_request_target` runs the base branch's workflow, not the PR's.

## 1. Create the App

At <https://github.com/settings/apps/new>, signed in as `twistedmelonman`
(the owner of the existing Apps):

- **Name**: `dependabot-merge-swm`
- **Homepage URL**: `https://github.com/smartwatermelon/github-workflows`
- **Webhook**: clear **Active**.
- **Repository permissions**. Set these and nothing else:

| Permission | Access | Why |
| --- | --- | --- |
| Contents | Read and write | `gh pr merge --squash --delete-branch` |
| Pull requests | Read and write | `gh pr review --approve`; add and remove labels |
| Issues | Read and write | `gh label create` for the `dependabot-blocked:*` labels |
| Workflows | Read and write | merge a PR that changes `.github/workflows/` (see below) |
| Checks | Read-only | the gate reads check runs |
| Commit statuses | Read-only | the gate reads commit statuses (Netlify) |
| Metadata | Read-only | mandatory |

- **Where can this App be installed**: **Any account**. A private App
  installs only on its owning account, and this one must install on two
  organizations.

**About Workflows.** Most Dependabot PRs on the fleet are GitHub Actions bumps,
which change `.github/workflows/`. GitHub refuses a workflow-file change from
an App that does not have the Workflows permission. That rule applies to
pushes. The v3.1 canary checks whether a merge needs it too. If an Actions
bump merges without it, an agent will propose removing it.

## 2. Generate the key and store it

1. On the App's page, note the **Client ID**.
2. Generate a private key. GitHub downloads a `.pem` file.
3. In 1Password vault `Automation`, create item `MERGE_APP`:
   - field `client_id`: the Client ID
   - attach the `.pem` file itself. Do not paste the key into a field:
     1Password flattens a pasted PEM to one line, which is unusable.
4. Delete the downloaded `.pem` from `~/Downloads`.

## 3. Install the App

Install it on `smartwatermelon` and on `nightowlstudiollc`, with **Only
select repositories** on each: the caller lists in step 4. The installation
list is the blast radius of a stolen key (see "Security model"), so keep it
equal to the caller list. `twistedmelonman` has no repository with a gate
caller (checked 2026-10-29), so it does not need the App yet.

## 4. Set the secrets

**`smartwatermelon` is a user account, not an organization.** A user account
has no organization secrets, so `gh secret set --org smartwatermelon` cannot
work there. The first version of this step used it, and on 2026-10-31 every
smartwatermelon caller except the canary ran with an empty
`MERGE_APP_CLIENT_ID` (dev-env#246's gate run: `client-id ... must be set to
a non-empty string`). smartwatermelon therefore takes **repository**
secrets, one set per caller. nightowlstudiollc is an organization and keeps
one organization secret with **selected** visibility.

Only the **Actions** store is needed. The gate run log for a Dependabot PR on
`pull_request_target` says `Secret source: Actions` (dev-env#246, 2026-10-31),
so the Dependabot store is not read. Copies set there earlier can be deleted.

The caller lists below were measured on 2026-10-29: every repository with
`.github/workflows/dependabot-auto-merge.yml`. When a repository gains a
caller, set its repository secrets (smartwatermelon) or add it to the
organization secret's repository list (nightowlstudiollc).

Run these in a terminal (not in Claude Code). The smartwatermelon loop needs
admin on each repository; the nightowlstudiollc command needs `admin:org`.
Replace `<PEM>` with the attachment's file name, as `op item get MERGE_APP`
shows it.

```bash
swm="projectinsomnia dev-env github-workflows huddle-transcribe claude-config dotfiles smartwatermelon-marketplace vpn-lan-bridge personify scripts claude-code-workflows-agents mac-server-setup mac-dev-server-setup slack-mcp gmail-newsletter-filter repo-template pr-review crazy-larry homebrew-tap archive-resolver lock-sync .github spokane-snow"
nos="financial-agent,tensegrity,reliquarist,kebab-tax,kebab-tax-netlify,night-owl-studio,cleanroom,jordan-paddock-pitch,amelia-boone,tnjcleaning,.github"
client_id="$(op read "op://Automation/MERGE_APP/client_id")"
for r in $swm; do
  gh secret set MERGE_APP_CLIENT_ID -R "smartwatermelon/$r" --app actions --body "$client_id"
  op read "op://Automation/MERGE_APP/<PEM>" \
    | gh secret set MERGE_APP_PRIVATE_KEY -R "smartwatermelon/$r" --app actions
done
gh secret set MERGE_APP_CLIENT_ID --org nightowlstudiollc --app actions --repos "$nos" \
  --body "$client_id"
op read "op://Automation/MERGE_APP/<PEM>" \
  | gh secret set MERGE_APP_PRIVATE_KEY --org nightowlstudiollc --app actions --repos "$nos"
```

The pipe from `op read` on the attachment keeps the PEM line breaks. The
client ID goes through `--body`, from a `$(...)` that strips the trailing
newline `op read` prints; the client ID is not a secret, so it may appear in
the process list.

## 5. Verify

Check that the names exist and reach every caller (`gh secret list` never
shows values):

```bash
for r in $swm; do
  n=$(gh secret list -R "smartwatermelon/$r" --app actions | grep -c '^MERGE_APP_')
  [ "$n" -eq 2 ] || echo "MISSING on smartwatermelon/$r ($n of 2)"
done
for s in MERGE_APP_CLIENT_ID MERGE_APP_PRIVATE_KEY; do
  have=$(gh api "orgs/nightowlstudiollc/actions/secrets/$s/repositories" \
    --jq '.repositories[].name' | sort)
  for r in ${nos//,/ }; do
    grep -qxF "$r" <<<"$have" || echo "$s does not reach nightowlstudiollc/$r"
  done
done
```

No output means every caller has both secrets. tnjcleaning ran with an empty
`MERGE_APP_CLIENT_ID` on 2026-10-31, so check it first. Also check that the
App is installed on every caller in both accounts (step 3). Then tell the
agent. The evidence is a `push` run on `main` for a gate merge commit. A green
gate run alone is not that evidence.

## What the agent does after

1. v3.1 of the gate declares the two secrets under `on.workflow_call.secrets`
   and mints a token for the current repository with
   `actions/create-github-app-token`, pinned to a commit SHA.
2. Every caller changes two things: its tag pin, and a `secrets:` block that
   passes the two secrets by name (see "Security model", item 2). So the
   rollout edits each caller; it is not a tag bump.
3. The canary (projectinsomnia) runs first. Its evidence is a `push` run on
   `main` for the merge commit.

## Rotation

The key does not expire. To rotate it, generate a new key on the App's page,
replace the attachment in `MERGE_APP`, run step 4 again, then delete the old
key on the App's page.
