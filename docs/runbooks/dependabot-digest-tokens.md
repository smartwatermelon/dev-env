# Dependabot digest: minting and installing the read tokens

The `Dependabot Digest` workflow (`.github/workflows/dependabot-digest.yml`)
reads open Dependabot pull requests across all three owners and rewrites one
issue in `smartwatermelon/dev-env` describing the queue. It cannot run until
the tokens below exist — until then the workflow fails loudly rather than
publishing a digest that silently omits an owner.

**These steps are yours, not an agent's.** Minting a credential and installing
a secret are human operations.

## Why three tokens

A fine-grained personal access token is, in GitHub's words, "limited to access
resources owned by a single user or organization." The fleet spans three
owners, so it needs three tokens:

| Owner | Kind | Token secret name |
| --- | --- | --- |
| `smartwatermelon` | org | `DIGEST_TOKEN_SMARTWATERMELON` |
| `nightowlstudiollc` | org | `DIGEST_TOKEN_NIGHTOWLSTUDIOLLC` |
| `twistedmelonman` | personal account | `DIGEST_TOKEN_TWISTEDMELONMAN` |

The one-token alternative is a classic PAT, which "will grant access to all
repositories within the organizations that you have access to, as well as all
personal repositories" — write access included. That is far more authority than
a read-only digest should hold, and the `gh` wrapper already warns against
widening the CCCLI PAT for the same reason. Three narrow tokens are the safer
shape even though it is three times the paperwork.

## Mint each token

For each of the three owners, at
<https://github.com/settings/personal-access-tokens/new>:

1. **Token name**: `dependabot-digest-<owner>`
2. **Resource owner**: the owner from the table above. If an org does not
   appear, it has fine-grained tokens disabled; enable them under the org's
   Settings → Personal access tokens first.
3. **Expiration**: one year is reasonable. Record the date — see *After
   installing* below.
4. **Repository access**: **All repositories**. The digest must see every repo
   under the owner, including ones created after the token was minted.
5. **Repository permissions** — exactly two, both read-only:
   - **Pull requests**: Read-only
   - **Metadata**: Read-only (mandatory; GitHub selects it automatically)

   Grant nothing else. The digest never writes to any surveyed repository.
6. For the two org tokens, the request may need org approval before it works.

## Install the secrets

All three go on `smartwatermelon/dev-env` as repository secrets, because that
is where the workflow runs:

```bash
gh secret set DIGEST_TOKEN_SMARTWATERMELON   --repo smartwatermelon/dev-env
gh secret set DIGEST_TOKEN_NIGHTOWLSTUDIOLLC --repo smartwatermelon/dev-env
gh secret set DIGEST_TOKEN_TWISTEDMELONMAN   --repo smartwatermelon/dev-env
```

Each command prompts for the value. Paste the token and press Enter; it is not
echoed and does not enter shell history.

Repository secrets rather than org secrets, deliberately: `dev-env` is the only
repo that runs this, and org-level secrets do not reach private repos on the
free plan (see `docs/token-rotation.md`).

## Verify

Trigger a run by hand — a scheduled workflow only runs on the default branch,
so this is also how the very first digest gets created:

```bash
gh workflow run dependabot-digest.yml --repo smartwatermelon/dev-env
sleep 30
gh run list --workflow dependabot-digest.yml --repo smartwatermelon/dev-env --limit 1
```

Then confirm the issue exists and reads correctly:

```bash
gh issue list --repo smartwatermelon/dev-env --search 'dependabot-digest in:body' --state open
```

A green run is not sufficient evidence on its own. Open the issue and check
that PRs from **all three owners** appear. A token that lost private-repo
access still answers searches successfully while returning only public results;
the collector asserts against a known private repo to catch exactly that, but
reading the issue is the check that matters.

## After installing

Add a row per token to `docs/token-rotation.md` with its expiry, and set one
calendar reminder two weeks before the earliest. An expired digest token does
not fail quietly — the workflow exits non-zero rather than publishing a partial
digest — but a failing scheduled workflow is easy not to notice.

## If the digest goes stale

GitHub disables scheduled workflows in public repositories after 60 days with
no repository activity. The digest issue carries its own generation timestamp
for this reason: a date more than a day or two old means the schedule stopped,
not that the queue is quiet. Re-enable it with `gh workflow enable
dependabot-digest.yml --repo smartwatermelon/dev-env`.
