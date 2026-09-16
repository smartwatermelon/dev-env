# Runbook: fine-grained token scopes for fleet probes

**Why**: a fleet-state probe run with an under-scoped token does not fail — it
returns wrong numbers that look like findings. On 2026-09-16 one reported "zero
of 32 repos require any status check" when the real answer was "38 of 42."

**Who**: Andrew. Minting and re-scoping tokens is a GitHub UI action; an agent
cannot do it.

**When**: before the next fleet probe, and whenever a new private repo is
created under an owner whose token uses *Selected repositories*.

## What to change

Three fine-grained PATs, one per owner (`smartwatermelon`,
`nightowlstudiollc`, `twistedmelonman`). Each needs **both** of the following.
Either one alone still produces wrong answers.

### 1. Permission: `Administration` → **Read-only**

Gates `GET /repos/{owner}/{repo}/branches/{branch}/protection`.

Read-only is sufficient and is the correct level: the probe reads protection,
it does not set it. Do **not** grant Read-and-write for this purpose.

### 2. Repository access → **All repositories**

Not a permission. A token set to *Selected repositories* returns **404** for
any repo outside its selection, and silently omits those repos from
`gh repo list`. No permission grant fixes this — it is a selection boundary.

As of 2026-09-16 this hid 10 private repos: `scripts`, `claude-config-backup`,
`infinite-yaks` (smartwatermelon); `cleanroom`, `financial-agent`, `kebab-tax`,
`kebab-tax-netlify`, `night-owl-studio`, `reliquarist`, `tensegrity`
(nightowlstudiollc).

*Selected repositories* is defensible if you prefer the tighter boundary — but
then every new private repo must be added by hand, and until it is, every fleet
count is quietly low. All-repositories is recommended for that reason.

## Steps

1. <https://github.com/settings/personal-access-tokens> → select the token.
2. **Repository access** → *All repositories*.
3. **Permissions → Repository permissions** → `Administration` →
   *Read-only*.
4. Save. GitHub does not re-issue the token value for a permissions change, so
   no secret rotation is needed and nothing needs redeploying.
5. Repeat for the other two owners.

## Verify — do not skip

A permissions change that silently did not apply looks exactly like one that
did. Check both properties against known-bad cases:

```bash
# 1. Repo count must be >= 42 (as of 2026-09-16).
for o in smartwatermelon nightowlstudiollc twistedmelonman; do
  gh repo list "$o" --limit 100 --json isArchived \
    --jq '[.[]|select(.isArchived==false)]|length'
done | paste -sd+ - | bc

# 2. A known private repo must resolve, not 404.
gh api repos/smartwatermelon/scripts --jq .full_name

# 3. Protection must return JSON, not 403.
gh api repos/smartwatermelon/dev-env/branches/main/protection \
  --jq '.required_status_checks.contexts'
```

Expected: `42` or more; `smartwatermelon/scripts`; and
`["standards-check / run-standards-check"]`.

If step 3 still 403s, the `Administration` permission did not save — re-check
that it was set under *Repository permissions*, not *Account permissions*.

## Do not use `env -u GH_TOKEN` instead

Unsetting `GH_TOKEN` falls back to the keyring OAuth token, which reads both
correctly today. That is a workaround, not a fix:

- it is being blocked deliberately (`claude-wrapper#124`), and
- it defeats the per-owner identity routing the `gh` wrapper exists to enforce,
  so a probe can silently run as the wrong account.

Fix the scope. See `docs/STATUS.md`, "Measuring fleet state," for the failure
signatures to recognize when a probe is under-scoped.
