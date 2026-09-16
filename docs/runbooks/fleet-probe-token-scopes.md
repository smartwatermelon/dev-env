# Runbook: fine-grained token scopes for fleet probes

**Why**: a fleet-state probe run with an under-scoped token does not fail — it
returns wrong numbers that look like findings. On 2026-09-16 one reported "zero
of 32 repos require any status check" when the real answer was "38 of 42."

**Who**: Andrew. Minting and re-scoping tokens is a GitHub UI action; an agent
cannot do it.

**When**: before the next fleet probe, and whenever a new private repo is
created under an owner whose token uses *Selected repositories*.

## The actual problem: one token is doing three tokens' work

Measured 2026-09-16. There are three fine-grained PATs, one per owner:

| Owner | 1Password item | Repository access | Administration |
| --- | --- | --- | --- |
| `smartwatermelon` (org) | `op://Automation/CCCLI-SWM/token` | all org repos | **read** ✓ |
| `nightowlstudiollc` (org) | `op://Automation/CCCLI-NOS/token` | all org repos | **read** ✓ |
| `twistedmelonman` (user) | `op://Automation/GitHub - CCCLI/Token` | all user repos | **missing** ✗ |

**Both org tokens are already scoped correctly.** The gap is that `GH_TOKEN`
in a session is the *`twistedmelonman` user token*, and it is used for every
owner. `gh api user` returns `twistedmelonman` regardless of which owner's
repos are being read.

That single substitution produces both failure modes:

- **403 on `branches/*/protection`, for every owner including its own.** The
  user token lacks `Administration: Read-only`. This is the one real scope gap.
- **404 on org-owned private repos** (`scripts`, `reliquarist`, and the other
  eight). *This is not a scope or selection problem and no permission fixes
  it*: "all repositories owned by you" does not include repositories owned by
  an organization. Only that org's own token can read them.

So a correctly-scoped user token still cannot probe the fleet. Route to the
owner's token, or accept a 10-repo blind spot.

## What to change

### 1. Add `Administration: Read-only` to the `twistedmelonman` user token

`op://Automation/GitHub - CCCLI/Token`. Gates
`GET /repos/{owner}/{repo}/branches/{branch}/protection`. Read-only is correct
and sufficient — the probe reads protection, it never sets it.

While there: that token also carries `commit statuses: read`, which neither org
token has, and lacks `actions: read`, which both org tokens have. Worth
reconciling so the three are comparable, though neither difference affects the
probe.

### 2. Use the owning account's token per request

The org tokens need no changes. What needs to change is *selection*: a probe of
`smartwatermelon/*` must present `CCCLI-SWM`, not the user token. Until the
`gh` wrapper routes fine-grained tokens by owner the way it routes identity,
a fleet probe must switch tokens per owner itself.

## Steps

1. <https://github.com/settings/personal-access-tokens> → select the
   `twistedmelonman` user token (`GitHub - CCCLI`).
2. **Permissions → Repository permissions** → `Administration` →
   *Read-only*.
3. Save. GitHub does not re-issue the token value for a permissions change, so
   no secret rotation is needed and nothing needs redeploying.
4. The two org tokens need no change.

## Verify — do not skip

A permissions change that silently did not apply looks exactly like one that
did. Check against known-bad cases, with each owner's own token.

**Step 1 — the user token now reads its own protection** (this is what the
change fixes):

```bash
GH_TOKEN="$(op read 'op://Automation/GitHub - CCCLI/Token')" \
  gh api repos/twistedmelonman/dotfiles/branches/main/protection \
  --jq '.required_status_checks.contexts'
```

Expected `["standards-check / run-standards-check"]`. **A 403 here means the
permission did not save** — re-check that `Administration` was set under
*Repository permissions*, not *Account permissions*.

**Step 2 — each org token reaches its own private repos** (no change needed;
this confirms the routing premise):

```bash
GH_TOKEN="$(op read op://Automation/CCCLI-SWM/token)" \
  gh api repos/smartwatermelon/scripts --jq .full_name
GH_TOKEN="$(op read op://Automation/CCCLI-NOS/token)" \
  gh api repos/nightowlstudiollc/reliquarist --jq .full_name
```

Expected the two full names. A **404** means that token is not the owner's, or
lost its all-repositories access.

**Step 3 — the fleet counts 42** only when each owner is enumerated with its
own token. With any single token it will read low, and that is expected, not a
regression:

```bash
total=0
for pair in "smartwatermelon:op://Automation/CCCLI-SWM/token" \
            "nightowlstudiollc:op://Automation/CCCLI-NOS/token" \
            "twistedmelonman:op://Automation/GitHub - CCCLI/Token"; do
  o="${pair%%:*}"; ref="${pair#*:}"
  n=$(GH_TOKEN="$(op read "$ref")" gh repo list "$o" --limit 100 \
        --json isArchived --jq '[.[]|select(.isArchived==false)]|length')
  printf '%-22s %s\n' "$o" "$n"; total=$((total + n))
done
printf 'total %s (expect >= 42)\n' "$total"
```

> These snippets pass a secret on the command line deliberately and only for
> one-shot verification. Do not build them into a script or a hook: an
> exported token is what created the confusion this runbook documents.

## Do not use `env -u GH_TOKEN` instead

Unsetting `GH_TOKEN` falls back to the keyring OAuth token, which reads both
correctly today. That is a workaround, not a fix:

- it is being blocked deliberately (`claude-wrapper#124`), and
- it defeats the per-owner identity routing the `gh` wrapper exists to enforce,
  so a probe can silently run as the wrong account.

Fix the scope. See `docs/STATUS.md`, "Measuring fleet state," for the failure
signatures to recognize when a probe is under-scoped.
