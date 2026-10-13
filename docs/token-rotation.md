# CLAUDE_CODE_OAUTH_TOKEN rotation — retired

**This file never contains a token, a token prefix, or `claude setup-token`
output.**

**Retired 2026-10-12.** No repo runs Claude in CI. Andrew deleted
`CLAUDE_CODE_OAUTH_TOKEN` (the token minted 2026-06-29, expiring
2027-06-29), so there is nothing left to rotate.

- Every fleet `claude.yml` caller was removed on 2026-10-12, one PR per
  repo. The CI reviewer that also used the token was retired on 2026-10-01
  (`github-workflows#154`).
- `nightowlstudiollc/kebab-tax` and `kebab-tax-netlify` still have
  `claude.yml`, plus their own changelog workflows that call Claude. They
  are out of scope for this repo and fail at the token check until the
  kebab work removes them. `github-workflows`' `claude-assistant.yml` stays,
  deprecated, until those callers are gone.
- Not verified from agent tokens (they cannot list secrets): that no org- or
  repo-level copy of the secret remains. The 2026-09-04 baseline under
  `docs/data/org-migration/` lists the repo-level copies that existed then.
- The Google Calendar event "Rotate CLAUDE_CODE_OAUTH_TOKEN (all scopes)"
  has nothing left to remind about.

The rotation runbook that used to live here is in git history before this
change.
