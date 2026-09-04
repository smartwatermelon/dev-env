# CLAUDE_CODE_OAUTH_TOKEN rotation

**This file never contains a token, a token prefix, or `claude setup-token`
output.** Dates and locations only. If a token appears here, treat it as
leaked: revoke and rotate.

Org-level secrets (design:
`docs/superpowers/specs/2026-09-03-org-migration-design.md`, Step 5). Free-plan
org secrets do not reach private repos, so `scripts` keeps a repo-level
token until it goes public.

| Scope | Minted | Expires | Minted on |
| --- | --- | --- | --- |
| org `smartwatermelon` | | | |
| org `nightowlstudiollc` | | | |
| repo `smartwatermelon/scripts` | | | |

Each row has a Google Calendar event "Rotate CLAUDE_CODE_OAUTH_TOKEN (<scope>)"
two weeks before the expiry date, pointing here.

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
   # or, for scripts:  gh secret set CLAUDE_CODE_OAUTH_TOKEN -R smartwatermelon/scripts
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
