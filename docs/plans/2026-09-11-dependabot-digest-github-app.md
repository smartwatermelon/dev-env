# Dependabot digest: move from fine-grained PATs to a GitHub App

**Status**: planned, not started. Decided 2026-09-11.
**Prerequisite**: PR #134 merged (the nulled-checks guard).

## Why

A fine-grained PAT has no `Checks` permission at all
([community#129512](https://github.com/orgs/community/discussions/129512)).
GitHub Actions results are check runs, so a fine-grained token cannot read them
on a private repository, and nothing about how the token is scoped changes
that.

The failure is silent. GitHub answers `statusCheckRollup` with HTTP 200 and the
correct `totalCount`, then nulls every CheckRun. Measured 2026-09-11 on
`nightowlstudiollc/kebab-tax-netlify#280` with all four grantable permissions
in place:

| Endpoint | Result |
| --- | --- |
| `pulls/280` | ok — Pull requests |
| `commits/<sha>` | ok — Contents |
| `commits/<sha>/status` | ok — Commit statuses |
| `commits/<sha>/check-runs` | **DENIED — ungrantable** |

11 of 12 contexts came back null; only a Netlify StatusContext survived. Seven
failing builds and a green required check read as "1 failing check, 0 required
checks".

GitHub Apps **do** have a Checks permission, and one app installs on all three
owners — which also removes the reason there are three tokens.

### Why an app rather than a classic PAT

A classic PAT would work today but carries write access to every repository in
both orgs for a read-only report. Beyond that, the app wins on three counts
that outlive this digest:

- **One credential, three owners.** Fine-grained PATs are capped at one
  resource owner — that cap is *why* there are three tokens. An installation
  sidesteps it permanently.
- **No expiry.** The app's private key does not rot. The three PATs all expire
  within a year and need coordinated rotation.
- **Installation tokens are minted per run and live about an hour**, then are
  revoked at job end. A leaked one is nearly worthless; a leaked PAT is live
  until noticed.

Anything else cross-org and read-only — fleet audits, branch-protection
sweeps — hits the same one-owner wall, so this is reusable infrastructure
rather than a one-off fix.

## What does NOT change

Three pieces look like FGT artifacts and are not. They stay:

1. **The three-layer nulled-checks guard** (PR #134: `collect.sh` refuses,
   `classify.sh` buckets `checks-unreadable`, `render.sh` warns). It was found
   because of fine-grained tokens, but the property it enforces — an unreadable
   check is not an absent one — holds for any credential, including an app
   installation that is missing a permission. It is also the automatic proof
   that the migration worked: a digest that publishes at all means zero nulled
   contexts.

   One edit needed, in step 4 below: `collect.sh`'s message names fine-grained
   tokens specifically, which would misdirect if an app installation ever
   triggers it.

2. **`verify_private_visibility` and the `DIGEST_PROBE_*` variables.** An
   installation scoped to "selected repositories" degrades exactly the way an
   under-scoped PAT does — public results only, no error. The probe catches
   that.

3. **`run-digest.sh`'s per-owner `DIGEST_TOKEN_<OWNER>` indirection.** It reads
   the token from the environment and does not care how it was obtained. This
   is what makes the migration workflow-only: **no script changes.**

## Steps

Marked **HUMAN** (credential and UI operations) or **AGENT**.

### 1. Create the app — HUMAN (~5 min)

At <https://github.com/settings/apps/new>:

- **Name**: `dependabot-digest`
- **Homepage URL**: any valid URL; the dev-env repo URL is fine
- **Webhook**: **uncheck Active.** The app is never called; it only mints
  tokens.
- **Where can this GitHub App be installed?**: **Any account.** This is the
  trap — the default restricts installation to the owning account, and the app
  must install on all three owners.
- **Repository permissions**, all **Read-only**, nothing else:
  - Checks — the whole point
  - Pull requests
  - Contents
  - Commit statuses
  - Metadata (mandatory; selected automatically)

Record the **Client ID** from the app's settings page.

### 2. Generate and store the private key — HUMAN (~2 min)

On the app's page, *Private keys* → **Generate a private key**. A `.pem`
downloads.

Store in 1Password vault `Automation` as item `DIGEST_APP`:

- field `client_id` — not secret, but keep it together
- field `private_key` — the full `.pem` contents, `BEGIN`/`END` lines included

Delete the downloaded file afterwards.

### 3. Install on all three owners — HUMAN (~5 min)

*Install App* in the left sidebar, then for `smartwatermelon`,
`nightowlstudiollc` and `twistedmelonman`:

- Choose **All repositories**, not "Only select repositories". The digest must
  see repos created after installation.
- Org installs may need approval; you own all three, so this is a click.

No installation IDs are needed — the action resolves them from `owner`.

### 4. Workflow and script changes — AGENT

One PR, branched from main after #134 merges.

**`.github/workflows/dependabot-digest.yml`** — add three token-minting steps
before the digest step, keeping mint and use in one job so the tokens are
revoked at job end:

```yaml
      - name: Mint a token for smartwatermelon
        id: token-smartwatermelon
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.DIGEST_APP_CLIENT_ID }}
          private-key: ${{ secrets.DIGEST_APP_PRIVATE_KEY }}
          owner: smartwatermelon
```

Two more identical steps for the other owners. Then feed the outputs into the
existing environment variable names:

```yaml
          DIGEST_TOKEN_SMARTWATERMELON: ${{ steps.token-smartwatermelon.outputs.token }}
          DIGEST_TOKEN_NIGHTOWLSTUDIOLLC: ${{ steps.token-nightowlstudiollc.outputs.token }}
          DIGEST_TOKEN_TWISTEDMELONMAN: ${{ steps.token-twistedmelonman.outputs.token }}
```

Notes:

- `owner:` set with `repositories:` omitted grants the token every repo in that
  installation — verified against the action's `action.yml`.
- Use `client-id`, not `app-id`: v3 marks `app-id` deprecated.
- Pin to the full commit SHA with a version comment, matching the existing
  `actions/checkout` pin. Dependabot already covers `github-actions` in this
  repo, so it will be bumped.
- `skip-token-revoke` defaults to false — tokens are revoked when the job ends.
- Rewrite the block comment: the current one explains why there are three PATs,
  which stops being true.

**`scripts/dependabot-digest/collect.sh`** — generalize the refusal message
only. It currently reads "A fine-grained token cannot grant Checks: read", which
would misdirect if an app installation hit the same guard. Say instead that the
credential cannot read check runs, and name both causes: a fine-grained token
(which never can) or an app installation missing Checks: read.

Update `tests/test-classify.sh`'s comment block for the same reason. The
assertion itself does not change.

### 5. Install the two secrets — HUMAN (~2 min)

```bash
gh secret set DIGEST_APP_CLIENT_ID   --repo smartwatermelon/dev-env
gh secret set DIGEST_APP_PRIVATE_KEY --repo smartwatermelon/dev-env
```

The private key is multi-line; paste the whole `.pem` and press Ctrl-D.

Two secrets replacing three.

### 6. Verify — AGENT runs it, HUMAN reads the diff

```bash
gh workflow run dependabot-digest.yml --repo smartwatermelon/dev-env
```

The digest publishing **is** the proof: `collect.sh` refuses any rollup with a
nulled context, so a published digest means every check on every PR was read.
That is the assertion the whole FGT effort was missing.

Then the local-vs-CI comparison from the runbook — it is the only thing that
catches a credential scoped to the wrong owner:

```bash
bash scripts/dependabot-digest/run-digest.sh --dry-run > /tmp/digest-local.md
gh issue view <number> --repo smartwatermelon/dev-env --json body --jq '.body' > /tmp/digest-ci.md
diff /tmp/digest-local.md /tmp/digest-ci.md
```

Counts and timestamps will differ — the queue moves. **Which owners appear must
not.**

Do not trigger a second run within a few minutes of the first: the issue
lookup leans partly on GitHub's body-search index, which lags creation.

### 7. Cleanup — HUMAN, and only after step 6 passes

Nothing here happens until a digest has published and the diff is clean. If the
app path fails, the PATs are the way back.

```bash
gh secret delete DIGEST_TOKEN_SMARTWATERMELON   --repo smartwatermelon/dev-env
gh secret delete DIGEST_TOKEN_NIGHTOWLSTUDIOLLC --repo smartwatermelon/dev-env
gh secret delete DIGEST_TOKEN_TWISTEDMELONMAN   --repo smartwatermelon/dev-env
```

Then:

- Revoke the three PATs at
  <https://github.com/settings/personal-access-tokens> — deleting the secret
  does not revoke the credential.
- Delete the three `DIGEST_TOKEN_*` items from 1Password vault `Automation`.

### 8. Rewrite the runbook — AGENT, same PR as step 4

`docs/runbooks/dependabot-digest-tokens.md` becomes app-centric. Rename to
`dependabot-digest-credentials.md` with `git mv`.

Remove: the three-token table, the "Why three tokens" rationale, the FGT mint
steps, the four-endpoint probe, and the "After installing → add rows to
`docs/token-rotation.md`" step (no rows were ever added, and an app key does
not expire).

Keep, condensed to one paragraph: **why not a fine-grained PAT** — the missing
Checks permission, the discussion link, and the HTTP-200-with-nulled-CheckRuns
behaviour. That is the part worth not rediscovering.

Keep as-is: the verification section, the "if the digest goes stale" section
(60-day scheduled-workflow disabling is unrelated to credentials).

## Open items this does not resolve

- **dev-env#120** stays open until the digest produces a real run; Andrew's
  instruction was to close it on the grounds that surfacing was the fix.
- **PR #133** (the FGT runbook correction) is largely superseded by step 8.
  Recommend closing it unmerged when the app PR opens, carrying the "why not a
  fine-grained PAT" paragraph across. Less churn than merging a runbook that is
  then rewritten.
- Until the app PR lands, **main's runbook is wrong** — it still says "exactly
  two" permissions. #134's guard makes that safe: the digest refuses to publish
  rather than under-report.
