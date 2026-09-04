# CLAUDE_CODE_OAUTH_TOKEN rotation

**This file never contains a token, a token prefix, or `claude setup-token`
output.** Dates and locations only. If a token appears here, treat it as
leaked: revoke and rotate.

Org-level secrets (design:
`docs/superpowers/specs/2026-09-03-org-migration-design.md`, Step 5). Free-plan
org secrets do not reach private repos, so every private repo that runs a
Claude workflow keeps its own repo-level copy. Both orgs currently read as
`plan=team`, which *would* deliver org secrets to private repos — do not rely
on that. The Team plan was bought to file a support ticket and will be
dropped; a repo whose copy was deleted on that basis fails silently at the
downgrade.

**One token is installed in several places.** It was minted 2026-06-29 and
expires **2027-06-29**. The migration copied the existing token rather than
minting new ones, deliberately, to avoid adding a variable mid-migration.
So a single rotation covers every row below that names it — these are
locations, not separate credentials.

| Scope | Token | Expires | Secret last set |
| --- | --- | --- | --- |
| org `smartwatermelon` | 2026-06-29 | 2027-06-29 | 2026-09-04 |
| org `nightowlstudiollc` | 2026-06-29 | 2027-06-29 | 2026-07-01 |
| repo `smartwatermelon/scripts` | 2026-06-29 | 2027-06-29 | 2026-07-29 |
| repo `nightowlstudiollc/cleanroom` | 2026-06-29 | 2027-06-29 | 2026-08-31 |
| repo `nightowlstudiollc/photo-game-poc` | unknown | unknown | 2026-03-02 |

"Secret last set" is the secret's `updated_at` from `gh secret list` — when
that copy was written, which is not when the token behind it was minted.
Do not read it as an expiry input.

`photo-game-poc` is the exception: its copy predates 2026-06-29, so it holds
an older token whose expiry is not recorded anywhere. The repo is archived
and runs nothing, so this is not urgent; resolve it by re-setting that
secret from the current token, at which point the row folds into the block
above.

Expiry is not recoverable from the API — it exists only in what
`claude setup-token` printed at mint time. When a future rotation splits
these into separate tokens, give each its own row and record the expiry at
step 4 of the runbook below.

One Google Calendar event, "Rotate CLAUDE_CODE_OAUTH_TOKEN (all scopes)",
sits two weeks before 2027-06-29 and points here. One token, one reminder.

## Rotation runbook

Rotate **before** expiry. Do not revoke-then-mint: revocation can take days
to propagate (`dev-env#54` findings) and every Claude workflow fails in
between.

1. Mint, on your own machine:

   ```bash
   claude setup-token
   ```

   Copy the token from the terminal. Do not paste it anywhere but step 2.

2. Set it in **every** location below — they currently share one token, so a
   rotation that updates only some of them leaves the rest on a credential
   that is about to expire. (The wrapper prints this exact line if you
   forget `env -u`.)

   ```bash
   env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all
   # or --org nightowlstudiollc
   # private repos each keep their own copy -- an org secret does not reach
   # them on the Free plan:
   #   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R smartwatermelon/scripts
   #   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R nightowlstudiollc/photo-game-poc
   #   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R nightowlstudiollc/cleanroom
   ```

   Paste when prompted.

3. Re-run one Claude workflow on a repo in that scope and read the log: the
   `claude-code-action` step must authenticate, not skip.

   ```bash
   gh run list -R smartwatermelon/dev-env --workflow claude-blocking-review.yml --limit 1 --json databaseId --jq '.[0].databaseId' | xargs -I{} gh run rerun {} -R smartwatermelon/dev-env
   ```

4. Update the table row (minted date, expiry = minted + the lifetime
   `setup-token` printed, machine).

5. Move the calendar event to two weeks before the new expiry.
