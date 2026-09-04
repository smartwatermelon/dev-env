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

| Scope | Minted | Expires | Minted on |
| --- | --- | --- | --- |
| org `smartwatermelon` | 2026-09-04 | unrecorded | ASIAGO |
| org `nightowlstudiollc` | 2026-07-01 | unrecorded | unrecorded |
| repo `smartwatermelon/scripts` | 2026-07-29 | unrecorded | unrecorded |
| repo `nightowlstudiollc/photo-game-poc` | 2026-03-02 | unrecorded | unrecorded |
| repo `nightowlstudiollc/cleanroom` | 2026-08-31 | unrecorded | unrecorded |

Minted dates are the secret's `updated_at` from
`gh secret list`, which is when the value was last set — accurate for
rotation planning. **Expiry is not recoverable from the API.** It exists only
in what `claude setup-token` printed at mint time, so fill each row in at
step 4 of the runbook below rather than reconstructing it later. Until a row
has a real expiry, its calendar event cannot be scheduled.

Each row gets a Google Calendar event "Rotate CLAUDE_CODE_OAUTH_TOKEN
(<scope>)" two weeks before the expiry date, pointing here.

## Rotation runbook

Rotate **before** expiry. Do not revoke-then-mint: revocation can take days
to propagate (`dev-env#54` findings) and every Claude workflow fails in
between.

1. Mint, on your own machine:

   ```bash
   claude setup-token
   ```

   Copy the token from the terminal. Do not paste it anywhere but step 2.

2. Set it (the wrapper prints this exact line if you forget `env -u`):

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
