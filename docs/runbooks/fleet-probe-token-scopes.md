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
| `smartwatermelon` (org) | `op://Automation/CCCLI-SWM/token` | all org repos | read ✓ |
| `nightowlstudiollc` (org) | `op://Automation/CCCLI-NOS/token` | all org repos | read ✓ |
| `twistedmelonman` (user) | `op://Automation/GitHub - CCCLI/Token` | all user repos | read ✓ *(added 2026-09-16)* |

All three are now correctly scoped. **The remaining gap is routing, not
permissions**: `GH_TOKEN` in a session is the *`twistedmelonman` user token*,
and it gets used for every owner. `gh api user` returns `twistedmelonman`
regardless of whose repos are being read.

**A token reads only its own owner's repositories, whoever owns them.**
Verified 2026-09-16 with the user token, after it was granted
`Administration: Read-only`:

| Target | Result |
| --- | --- |
| `twistedmelonman/dotfiles` protection | reads correctly (403 before the grant) |
| `smartwatermelon/dev-env` protection — **public** | **403** |
| `smartwatermelon/scripts` — private | **404** |

So the boundary is **ownership, not visibility**. A user token cannot read an
org's protection even on a *public* repo. This is not a scope to widen and not
a selection to broaden: only `CCCLI-SWM` reads `smartwatermelon/*`, and only
`CCCLI-NOS` reads `nightowlstudiollc/*`.

Routing per owner reproduces the full fleet — **42 repos, verified
2026-09-16** (smartwatermelon 24, nightowlstudiollc 12, twistedmelonman 6),
with no OAuth fallback.

## Scope work: done

`Administration: Read-only` was added to the `twistedmelonman` user token on
2026-09-16, which also brought it to `actions, administration, metadata: read`
— matching both org tokens. **No token scope changes remain.**

## What remains: route by owner

A fleet probe must present the owning account's token for each request. Until
the `gh` wrapper routes fine-grained tokens by owner the way it already routes
identity, a probe does this itself:

```bash
token_for() {
  case "$1" in
    smartwatermelon)   op read 'op://Automation/CCCLI-SWM/token' ;;
    nightowlstudiollc) op read 'op://Automation/CCCLI-NOS/token' ;;
    twistedmelonman)   op read 'op://Automation/GitHub - CCCLI/Token' ;;
    *) return 1 ;;
  esac
}
```

Presenting the wrong owner's token fails as a **403** (protection) or **404**
(repo), never as an auth error — so a probe that silently uses one token for
everything reads as a clean run with wrong numbers.

## Verify — do not skip

A permissions change that silently did not apply looks exactly like one that
did. Check against known-bad cases, with each owner's own token.

**Step 1 — the user token reads its own protection.** *(Verified passing
2026-09-16.)*

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
