# Dependabot digest: GitHub App credentials

The `Dependabot Digest` workflow (`.github/workflows/dependabot-digest.yml`)
reads open Dependabot pull requests across all three owners and rewrites one
issue in `smartwatermelon/dev-env` describing the queue. It authenticates as a
GitHub App, `dependabot-digest-swm`, and mints one short-lived installation
token per owner on each run with `actions/create-github-app-token`.

**These steps are yours, not an agent's.** Creating an app, generating its key
and installing a secret are human operations.

## Why a GitHub App and not a fine-grained PAT

A fine-grained PAT has no Checks permission at all
(<https://github.com/orgs/community/discussions/129512>), so it cannot read
GitHub Actions results on a private repository however it is scoped. GitHub
does not error: it answers `statusCheckRollup` with HTTP 200 and the correct
`totalCount`, then nulls every CheckRun. Measured 2026-09-11 on
`nightowlstudiollc/kebab-tax-netlify#280`, 11 of 12 contexts came back null, so
seven failing builds read as "1 failing check". An app does have Checks, and
one installation per owner covers all three owners, which a PAT cannot.
`collect.sh` still refuses any rollup with a nulled context, which is the
proof that this path works: a published digest means every check was read.

## The app

- **Name**: `dependabot-digest-swm`, installed on `smartwatermelon`,
  `nightowlstudiollc` and `twistedmelonman`, **All repositories** each.
- **Repository permissions**, all read-only: Checks, Contents, Metadata,
  Pull requests, Commit statuses. Nothing else. Webhook inactive.
- The private key lives in 1Password vault `Automation`, item `DIGEST_APP`
  (fields `client_id`, `private_key`).

## Install the secrets

Both go on `smartwatermelon/dev-env` as repository secrets, because that is
where the workflow runs:

```bash
gh secret set DIGEST_APP_CLIENT_ID   --repo smartwatermelon/dev-env
gh secret set DIGEST_APP_PRIVATE_KEY --repo smartwatermelon/dev-env
```

The private key is multi-line: paste the whole `.pem` and press Ctrl-D.

Repository secrets rather than org secrets, deliberately: `dev-env` is the only
repo that runs this, and org-level secrets do not reach private repos on the
free plan (see `docs/token-rotation.md`). The key does not expire, so there is
no rotation row to add; rotate it by generating a new key on the app's page.

## Verify

Trigger a run by hand — a scheduled workflow only runs on the default branch,
so this is also how the very first digest gets created:

First capture what the answer should be, using your own credentials as the
reference. Your local `gh` login can read all three owners, so this is the
known-good result the workflow must reproduce:

```bash
bash scripts/dependabot-digest/run-digest.sh --dry-run > /tmp/digest-local.md
grep -c '^| ' /tmp/digest-local.md   # rows in the queue table
```

Then trigger a run by hand — a scheduled workflow only runs on the default
branch, so this is also how the very first digest gets created:

```bash
gh workflow run dependabot-digest.yml --repo smartwatermelon/dev-env
sleep 30
gh run list --workflow dependabot-digest.yml --repo smartwatermelon/dev-env --limit 1
```

**Do not trigger a second run within a few minutes of the first.** The digest
finds its issue partly through GitHub's body-search index, which lags creation
by an unbounded amount. A second run landing before the index catches up is
covered by an unindexed issue listing, but there is no reason to lean on the
fallback while verifying.

Then compare the published issue against the local reference:

```bash
gh issue list --repo smartwatermelon/dev-env --search 'dependabot-digest in:body' --state open
gh issue view <number> --repo smartwatermelon/dev-env --json body --jq '.body' > /tmp/digest-ci.md
diff /tmp/digest-local.md /tmp/digest-ci.md
```

Differences in counts and timestamps are expected — the queue moves between the
two runs. What must **not** differ is which owners appear. An installation that
is missing from one owner, or limited to selected repositories, can still
return an empty result set rather than an error.

The comparison, not the green run, is the evidence. A green run means the
scripts did not crash; only the diff shows the workflow saw the same fleet you
can see. The collector's private-repo probe catches a credential that lost private
access, but it cannot catch one that was scoped to the wrong owner.

## If the digest goes stale

GitHub disables scheduled workflows in public repositories after 60 days with
no repository activity. The digest issue carries its own generation timestamp
for this reason: a date more than a day or two old means the schedule stopped,
not that the queue is quiet. Re-enable it with `gh workflow enable
dependabot-digest.yml --repo smartwatermelon/dev-env`.
