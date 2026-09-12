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
5. **Repository permissions** — all four, all read-only:
   - **Pull requests**: Read-only
   - **Contents**: Read-only
   - **Commit statuses**: Read-only
   - **Metadata**: Read-only (mandatory; GitHub selects it automatically)

   Grant nothing else. The digest never writes to any surveyed repository.

   **These four are the most a fine-grained token can be given, and they are
   not enough to run the digest on private repositories.** Read the next
   section before minting anything.

   The collector reads each PR's checks through
   `pullRequest.commits(last:1).commit.statusCheckRollup`. Each hop needs its
   own permission, and `statusCheckRollup` merges two REST resources:
   `commits/<sha>/status` (**Commit statuses**), which these four grants do
   cover, and `commits/<sha>/check-runs` (**Checks**), which they cannot —
   see below.
6. For the two org tokens, the request may need org approval before it works.
   Approval can be **per repository**: a token minted for "All repositories"
   can still answer for some repos and return 403 for others, which looks
   exactly like a permissions error and is not one. If one repo fails while
   its neighbours succeed, check the org's Settings → Personal access tokens →
   Active tokens for that token's actual repository list before re-minting.

## What a fine-grained token cannot do

**A fine-grained PAT has no Checks permission.** It is not a grant that was
overlooked; the permission does not exist on the fine-grained list at all
(<https://github.com/orgs/community/discussions/129512>). Since GitHub Actions
results are check runs, a fine-grained token cannot read them on a private
repository no matter how it is scoped.

The failure is silent, which is what makes it dangerous. GitHub does not
return an error for the unreadable part. It answers `statusCheckRollup` with
HTTP 200 and the correct `totalCount`, then sets every CheckRun's fields to
null. Measured 2026-09-11 on `nightowlstudiollc/kebab-tax-netlify#280`, with
all four permissions above granted:

| Endpoint | Result |
| --- | --- |
| `pulls/280` | ok |
| `commits/<sha>` | ok |
| `commits/<sha>/status` | ok — this is why one Netlify status survived |
| `commits/<sha>/check-runs` | **DENIED — and ungrantable** |

That PR has 12 contexts. Eleven came back null and one Netlify StatusContext
survived. Mapped naively, seven failing builds and one green required check
read as "1 failing check, 0 required checks". A PR with no Netlify status at
all — most of the fleet — reads as entirely green and lands in
`ready-to-merge` with a paste-ready merge-lock line under it.

`collect.sh` therefore refuses any rollup containing a nulled context rather
than publishing an under-reporting digest, `classify.sh` buckets such a PR as
`checks-unreadable`, and `render.sh` says so in the body. The digest fails
loudly instead of quietly telling you to merge broken code.

Public repositories are unaffected: check results there are readable without
Checks or Commit statuses at all. That is why an under-scoped token appears to
work until it meets a private repo — and why testing against a public repo
proves nothing.

**This is an open design decision, not a step to follow.** Three ways forward:

| Option | Trade-off |
| --- | --- |
| Classic PAT | One token reads everything, including check runs. But it carries write access across every repo in both orgs for a read-only report. |
| GitHub App | Apps *do* have a Checks permission. Correct scoping and the right long-term shape; more setup than a PAT. |
| Public-only coverage | Keep the fine-grained tokens and have the digest state plainly that private repos are unsurveyed. Honest, and incomplete. |

Until that is decided, the workflow will keep failing on the private repos
rather than publishing a partial digest.

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

## If a run fails with FORBIDDEN

The run log names the repo, the PR, and GitHub's own reason:

```
collect.sh: nightowlstudiollc/kebab-tax-netlify#280: could not read PR detail (exit 1)
collect.sh:   stderr: gh: Resource not accessible by personal access token
collect.sh:   graphql: FORBIDDEN: Resource not accessible by personal access token
```

The collector stops at the first failure and publishes nothing, so a later repo
succeeding is **not** evidence its access is fine — it was never attempted.
Diagnose by probing the token directly rather than reasoning from which repos
appear to work.

The tokens live in 1Password (vault `Automation`, item
`DIGEST_TOKEN_<OWNER>`, field `token`), so a probe can read one directly
instead of pasting it. Run against the **private** repo that failed:

```bash
t="$(op read "op://Automation/DIGEST_TOKEN_NIGHTOWLSTUDIOLLC/token")"
sha="$(GH_TOKEN="$t" gh api repos/OWNER/REPO/pulls/NNN --jq '.head.sha')"
for path in \
  "pulls/NNN" \
  "commits/${sha}" \
  "commits/${sha}/check-runs" \
  "commits/${sha}/status"
do
  if GH_TOKEN="$t" gh api "repos/OWNER/REPO/${path}" >/dev/null 2>&1; then
    echo "  ${path##*/}: ok"
  else
    echo "  ${path##*/}: DENIED"
  fi
done
unset t
```

Each line maps to exactly one permission:

| Denied endpoint | Missing permission |
| --- | --- |
| `pulls/NNN` | **Pull requests: Read-only** |
| `commits/<sha>` | **Contents: Read-only** |
| `commits/<sha>/status` | **Commit statuses: Read-only** |
| `commits/<sha>/check-runs` | **Checks: Read-only** — which a fine-grained token cannot be given. On one, this line reads DENIED on every private repo and no grant changes it. See *What a fine-grained token cannot do*. |

Two traps, both of which cost time on 2026-09-11:

- **Test a private repo.** Check results on public repositories read without
  Checks or Commit statuses, so a probe against a public repo passes with an
  under-scoped token and proves nothing.
- **Editing a token's permissions does not change its value**, so the stored
  secret stays valid and needs no reinstall. If a run still fails after a
  grant change, re-run the probe before suspecting the secret — the token
  string is almost certainly fine.

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
