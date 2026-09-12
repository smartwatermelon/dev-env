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
two runs. What must **not** differ is which owners appear. A fine-grained token
is restricted to a single resource owner, and an owner whose token is missing a
permission can still return an empty result set rather than an error.

The comparison, not the green run, is the evidence. A green run means the
scripts did not crash; only the diff shows the workflow saw the same fleet you
can see. The collector's private-repo probe catches a token that lost private
access, but it cannot catch a token that was scoped to the wrong owner.

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
