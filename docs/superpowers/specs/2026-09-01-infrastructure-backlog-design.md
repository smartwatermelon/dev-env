# Design: Infrastructure Backlog Consolidation

Status: STARTER SET LANDED — design approved 2026-09-01; re-confirmed
2026-09-02 after folding in the issue delta below. The starter set executed
2026-09-02/03; the rest of the backlog below is not started.

Starter set outcome (see `docs/superpowers/plans/2026-09-02-infrastructure-backlog-starter-set.md`):

| Task | Item | Outcome |
| --- | --- | --- |
| 1 | nvm default off EOL Node 20 | Done — `lts/krypton` (v24.19.0). Local change, no commit. |
| 2 | `claude-code-workflows-agents` CI off Node 20 | Merged — `smartwatermelon/claude-code-workflows-agents#16`. |
| 3 | — | Withdrawn before execution. |
| 4 | Retire the `.git/config` `uchg` tripwire | Done — flag removed on validated known-bad-case evidence. No commit (chflags on an untracked file). Follow-up: `smartwatermelon/dotfiles#304`. |
| 5 | Fail closed when `GH_TOKEN` overrides the resolved identity | Merged — `smartwatermelon/dotfiles#302`. Follow-up: `smartwatermelon/dotfiles#303`. |

Two findings from the execution are worth carrying forward, because both are
instances of the false-OK pattern this design exists to attack — and both
appeared *inside* the work meant to fix it:

- Task 4's first proof was vacuous. It ran the suite from a linked worktree
  by direct `bash` invocation, which never receives the `GIT_DIR` git exports
  only when dispatching a hook. The run would have passed identically with
  the guard deleted. Caught in review, confirmed by measurement, and redone
  with an injected `GIT_DIR` plus a negative control.
- Task 5's regression test had never been observed failing before its fix was
  written. Proven retroactively against a pristine pre-fix copy. Its guard
  also exposed a real gap in `test-gh-wrapper-identity.sh`, which sandboxed
  `HOME` but inherited the developer's ambient `GH_TOKEN`.

The `git-identity.sh` org-blindness item named under "Items needing GitHub
issues" was **not** filed: the 2026-09-02 audit disproved it as an active
defect.

## Purpose

Infrastructure work across the dev-env repos has accumulated faster than it
has been executed, in three forms that do not share a tracker: open GitHub
issues, design/plan documents in `docs/plans/`, and defects that were found,
verified, and never filed at all. This document consolidates that backlog
into one dependency-ordered plan.

Scope is infrastructure and development environment only — getting the
infrastructure into a stable, working, usable state across multiple workflow
environments. Product-level work (Personify features, Kebab, new
applications) is explicitly out of scope. Product repos surveyed and excluded:
`cleanroom` (7 issues), `projectinsomnia` (7), `tensegrity` (3),
`financial-agent` (5), `amelia-boone` (2), `kebab-tax` (200).

**One deliberate exception to that boundary (decided 2026-09-02):** the Node
EOL remediation (N1) covers product repos as well as infrastructure repos.
Runtime EOL is a security-patch property of the whole fleet, not of a repo's
category, and splitting the audit by category would leave the larger half of
the exposure untracked. The exclusion above still governs every other item —
N1 does not open product repos to unrelated work.

Sources: open issues across 8 infrastructure repos; `docs/plans/` in
`dotfiles`, `claude-wrapper`, `github-workflows`, `scripts`, `claude-config`,
and `dev-env`; and direct verification against live system state.

## What verification changed

Three findings came from testing live state rather than reading the existing
reports. Each one changes the plan.

### The `GH_TOKEN` bug is inverted from how it was described

The defect was carried as "the gh wrapper overrides `GH_TOKEN`." The wrapper
never assigns `GH_TOKEN` — grep across all four wrapper repos confirms it.
The precedence runs the other way: **`GH_TOKEN` overrides the wrapper.**

`claude-wrapper/lib/credentials.sh:112` exports a single restricted-scope
CCCLI PAT unconditionally at session start. `gh` gives that environment
variable absolute precedence over the keyring identity that
`gh auth switch` selects. Inside a Claude Code session:

1. `_gh_wrapper_sync_identity()` resolves the repo owner and picks an identity.
2. `gh auth switch` succeeds and updates `~/.config/gh/hosts.yml`.
3. The fail-closed check at `gh-wrapper.sh:231-233` reads the `user:` field
   from `hosts.yml`, sees the correct name, and passes.
4. `command gh` runs and authenticates as the CCCLI PAT, ignoring all of it.

Step 3 is what makes this a defect rather than a missing feature. That check
exists specifically to refuse running as the wrong identity. It reads
`hosts.yml` — which the wrapper just wrote — so it verifies its own output,
not the auth `gh` will actually use. It reports success while the guarantee
it enforces is void.

The intended fix is stubbed and dead. `CLAUDE_GH_TOKEN_ROUTER`
(`gh-wrapper.sh:487-491`, introduced in dotfiles `9781898`/#126) is defined
nowhere in the fleet, and sits only in the standalone-executable branch —
the bash-function branch (lines 496-548) has no equivalent, so the seam
would not fire for the common path even if implemented.

Seven closed dotfiles issues (#131, #135, #138, #140, #151, #159, #205)
address `_gh_wrapper_sync_identity` correctness. Every one reasons about the
`hosts.yml` switch in isolation; none mentions `GH_TOKEN` precedence.

### A latent cross-org identity hazard — **NOT an active leak**

**Corrected 2026-09-02.** This section previously claimed that "every commit
made in a `beacon-biosignals` repo through Claude Code is authored at a
`smartwatermelon` address" and that the `includeIf` block is dead. **Both
claims are false.** They are recorded here rather than deleted because the way
they were reached is the exact failure this document warns about.

**What is true.** `claude-wrapper/lib/git-identity.sh:12-15` exports
`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and
`GIT_COMMITTER_EMAIL` as `Claude Code Bot
<claude-code@smartwatermelon.github>`, unconditionally, sourced from
`bin/claude-wrapper:26`. Git environment variables do outrank all gitconfig,
including `includeIf`. Measured on a scratch repo with
`user.email=arich@beacon.bio` configured: with the wrapper's variables set the
commit authors as `Claude Code Bot`; with them unset, `Andrew Rich
<arich@beacon.bio>`. The precedence is real.

**Why it harms nothing today.** Verified on `arich-mac.local` 2026-09-02:

- `claude-wrapper` is **not installed** there — no
  `~/Developer/claude-wrapper/lib/git-identity.sh`, and no wrapper on `PATH`.
  The code that exports the bot identity does not exist on the machine that
  has beacon checkouts.
- `~/.gitconfig-beacon` exists and sets `andrew.rich@beacon.bio`.
  `git config user.email` in `beacon-biosignals/infra` resolves to it. The
  `includeIf` block works.
- Bot-authored commits across all five beacon repos (`beabot`, `infra`,
  `knowledge-base`, `platform-datastore`, `platform-production`): **zero.**

**How the false claim was reached.** The original "Verified:" line cited
`dev-env` and `tensegrity` committing as
`676392+smartwatermelon@users.noreply.github.com`. Those are personal repos on
the personal machine — they confirm the bot identity applies where it is
*supposed* to. The beacon consequence was inferred from that and written up as
though measured. Neither `~/Developer/beacon-biosignals/` nor
`~/.gitconfig-beacon` exists on the personal machine, so the beacon half could
not have been checked from where it was written.

This is the "resolve the thing; don't match its label" failure applied to a
consequence rather than a state check, and it is the same shape as
claude-config#465 (asserting behavior in prose without opening the code).

**What remains.** A latent hazard, conditional on installing `claude-wrapper`
on the work machine — at which point beacon commits would silently author at a
`smartwatermelon` address. Worth fixing before that happens, not urgent now.
Removed from the starter set on that basis.

The fix, if taken: export the bot identity only where the repo configures no
`user.email`, deferring to gitconfig where it has an answer. Note
`claude-wrapper/README.md:299` documents the current unconditional behavior as
correct; it would change with the fix.

### The active token lacks `admin:org`, which blocks the org migration

| Identity | scopes |
| --- | --- |
| `GH_TOKEN` (Active: true) | `repo`, `workflow`, `read:org`, and others — **no `admin:org`** |
| keyring account (Active: false) | **`admin:org`**, `admin:public_key`, `repo`, `workflow` |

`gh api orgs/nightowlstudiollc/actions/secrets` returns HTTP 403: "This API
operation needs the 'admin:org' scope." `gh auth switch` refuses to act while
`GH_TOKEN` is set. This blocks dev-env#54 Phase 4 — `gh secret set --org` —
which is the entire purpose of the org migration.

## Cross-cutting theme: false-OK failures

Six independently-discovered defects share one shape: **a check reports
success while the thing it checks is not happening.**

| Defect | Reports | Actually |
| --- | --- | --- |
| `_gh_wrapper_sync_identity` | identity switched | `GH_TOKEN` used instead |
| dotfiles config contamination | hooks configured | `core.hooksPath` blanked |
| `--repair` (#439) | healthy | guards down |
| chunked review (#451) | PASS | skipped the files that mattered |
| ~~`claude-config` pre-commit~~ | ~~configured~~ | **FIXED 2026-08-26** — see the verification audit |
| `tolerate_upgrade_failure` (dotfiles#247) | upgrade succeeded | failure swallowed |

This is the backlog's defining pattern, and it has a direct methodological
consequence: **every fix in this plan must be validated against a
known-bad case.** A clean result from an unvalidated check proves nothing —
that is precisely how these six accumulated. This restates the standing
"resolve the thing; don't match its label" discipline; these are six live
instances of it.

## Dependency graph

```text
FOUNDATION (start here; no upstream dependencies)
  F1  Extract shared owner-resolver from gh-wrapper.sh:60-96
       ├──> F2  git-identity.sh owner-awareness
       ├──> F3  GH_TOKEN precedence guard (cheap tier)
       └──> I1  account-switching module
  F4  Token scope resolution (admin:org)
       └──> I3 Phase 4

IDENTITY / BILLING (parallel with foundation)
  I0  CLAUDE_CONFIG_DIR billing-verification script
       └──> I1  account-switching module
              └──> I2  one-time company-machine setup
  I3  Org migration (dev-env#54)
       ├──> I1  (owner mapping must be updated in the same change)
       └──> ALL of FLEET

FLEET (after I3; one pass per repo)
  W1  Build standards-check.yml  [+ zizmor.yml + branch protection folded in]
       └──> W2  Roll out to fleet (pilots first)
              └──> W3  Retire CI judgment reviewer

LOCAL REVIEW (independent; parallel with everything)
  L1  dotfiles config contamination  [do first — gates whether review is real]
  L2  Deploy/edit separation (claude-config#453)
       └──> L3  False-OK cluster (#439, #451, empty pre-commit)
  L4  Doc hygiene  [no dependencies]

RUNTIME EOL (independent; parallel with everything)
  N1  Node EOL migration (dev-env#78)
       ├──> N1a  local nvm default + infra-repo CI pins   [no dependencies]
       └──> N1b  product-repo CI, Dockerfiles, manifests  [no dependencies]
       └──> (feeds W1: Node-version assertion in standards-check)
```

## Foundation layer

### F1 — Extract a shared owner-resolver — **DONE (verified 2026-09-02)**

`_gh_wrapper_resolve_owner()` exists at `dotfiles/bash/gh-wrapper.sh:61-96`.
It handles both `git@host:` and `scheme://host/` remote forms plus
`-R`/`--repo`/`--repo=`/`-R<value>` parsing, and is already shared by
`_gh_wrapper_sync_identity` and `_gh_wrapper_force_draft_for_off_org`. Its
header comment states the anti-drift purpose this item was written to serve.

No work remains. F2, F3, and I1 consume it as-is.

### F2 — Make `git-identity.sh` owner-aware

Consumes F1. Stops the cross-org identity leak. Two viable shapes: resolve the
owner and select the identity, or read `git config user.email` after
`includeIf` resolution and override only when unset. The second is smaller and
defers to gitconfig, which is where the per-repo identity is already correctly
expressed.

Open question deferred to implementation: whether a distinct bot identity is
still wanted at all, now that sessions are attributed via `Claude-Session:`
trailers.

Note `claude-wrapper/README.md:299` documents the current wrong behavior as
correct ("`git config user.name` should show `Claude Code Bot`"). It changes
with F2.

### F3 — `GH_TOKEN` precedence guard (cheap tier)

**Decision (2026-09-01): cheap tier now; full router deferred.**

Cheap tier: `_gh_wrapper_sync_identity` detects `GH_TOKEN` and warns or fails
closed when the resolved owner maps to an identity the token does not
represent. This does not fix routing. It converts a silent wrong-identity into
a visible error — independently valuable even if the router never ships.

**Expected consequence:** operations that currently succeed as the wrong
identity will begin failing visibly. That is the intent, but it will surface on
first use rather than at deploy time.

Full router (deferred, not scheduled): implement `CLAUDE_GH_TOKEN_ROUTER` in
**both** wrapper branches, mint a second PAT for `andrewmrich` in 1Password,
and reverse the documented product decision in `claude-wrapper/README.md:75`
and `docs/SECRETS.md:169-171`, which currently state the wrapper "does not
perform per-org routing."

### F4 — Token scope resolution

Resolve the missing `admin:org` scope, either by adding it to the CCCLI PAT or
by routing org-level operations to the keyring identity. The choice is forced
by F3's design, so treat them as one decision.

**Decision (2026-09-02): route org-level operations to the keyring identity.**
Widening the CCCLI PAT was rejected: that token is exported into every session
unconditionally (`credentials.sh:112`), so adding `admin:org` to it widens the
blast radius of precisely the credential whose over-reach is the F3 defect.
Routing keeps the session token narrow.

Consequence to carry into implementation: this couples F4 to the router work
F3 deliberately deferred. F3's cheap tier does not route — it only fails
closed. So F4 needs either the full `CLAUDE_GH_TOKEN_ROUTER` (both wrapper
branches, plus a second PAT) or a narrower escape hatch that unsets `GH_TOKEN`
for org-scoped calls only. Decide that shape when I3 is planned; it is not
settled here.

Blocks I3 Phase 4.

## Identity and billing layer

The motivation here is not convenience. Work on personal repos performed on
the company machine draws on the Beacon-owned Anthropic account, billed at
Enterprise rates. Routing that work to the personal account is a business and
ethics control, not an ergonomic improvement. This raises I1's priority and
its correctness bar.

### I0 — `CLAUDE_CONFIG_DIR` billing-verification script

`CLAUDE_CONFIG_DIR` redirects which stored credential Claude Code uses, which
should route billing with it. That has not been verified against a machine
with Beacon Enterprise provisioning. For a control whose entire purpose is
billing, confirm it rather than assume it.

Deliverable is **a script Andrew runs on the company machine**, not an answer.
Requirements:

- Read-only with respect to the existing `~/.claude`. Test config dirs go in a
  temp location it removes, or are named explicitly for manual deletion.
- Never prints or copies token material. Reports *which account* a session
  authenticates as.
- Requires one interactive `claude login` under the test config dir. The script
  states this up front and stops for confirmation — no surprise browser launch.
- Reports both directions: default (no override) and personal-override, so the
  delta is visible rather than a single data point.
- Exits nonzero and says so plainly if it cannot determine the account. The
  failure mode to avoid is a script that reports "looks fine" having learned
  nothing — the false-OK pattern this backlog is full of.

If the account cannot be determined from the CLI at all, that is a valid and
important result: `CLAUDE_CONFIG_DIR` cannot be verified locally, and I1 needs
a different confirmation path (billing console, or Anthropic support) before
it can be relied on.

### I1 — Account-switching module

Design already drafted at
`claude-config/docs/plans/2026-09-01-claude-account-switching-design.md`.
Three conditions, confirmed 2026-09-01:

1. Work explicitly Beacon-owned → Beacon account. Not expected to arise on
   personal machines.
2. Work explicitly Andrew-owned (`smartwatermelon`, `nightowlstudiollc`) →
   personal account. This does happen on the company machine, and is the case
   the module exists for.
3. Neither applies → the machine default. Company machine defaults to Beacon;
   personal machines default to personal.

Condition 3 falls back to the machine default deliberately. The personal repos
are an enumerable set that can be checked by owner; unresolvable-owner work on
the company laptop is more likely to be company work. Checking what can be
named is a tighter control than guessing at unpredictable future use.

This resolves open question 2 in the draft: the module **should** recognize
`beacon-biosignals` by name, because condition 1 requires it.

Shape (from the draft, unchanged): one standalone script, no dependency on
other `claude-wrapper/lib/*` beyond a debug helper; owner resolution from F1;
data-driven owner mapping in a config file rather than branches in shell; one
entry point that either exports `CLAUDE_CONFIG_DIR` or emits nothing.

`CLAUDE_CONFIG_DIR` relocates everything under `~/.claude` — settings, hooks,
skills, plugins, agents, global CLAUDE.md, `.claude.json` — not just
credentials. The personal-side config dir must be symlink-bootstrapped the way
`install.sh` bootstraps `~/.claude`, or every Mandatory Protocol silently
disappears from those sessions.

**Dependency on I3:** the org migration changes the owner names. I1's
personal-owner set is what decides billing. If the rename lands without
updating that mapping, personal repos fall from condition 2 into condition 3
and silently bill Beacon on the company machine. Same change, or I1 first with
I3 updating it — but not independent.

Open questions carried forward from the draft: mapping-config file format and
location; test approach for the parsing logic.

### I2 — One-time company-machine setup

Manual, not code. Create the personal-side config dir, symlink-bootstrap it,
run one interactive `claude login` as the personal account. Company machine
only; nothing needed on personal machines.

### I3 — Org migration (dev-env#54)

Six phases, not started. Phase 4 blocked by F4.

**Decision (2026-09-01): migrate early, before the fleet passes.**

The migration rewrites `smartwatermelon/*` references in `zizmor.yml:49`,
every caller stub across ~35 repos, the owner table at `gh-wrapper.sh:216`,
and the `nightowlstudiollc → smartwatermelon` mapping. It also rewrites
`repo-template`: all three of its workflow callers carry `smartwatermelon/*`
refs, and its README hardcodes
`gh api repos/smartwatermelon/<name>/actions/permissions/workflow`. Miss the
template and every repo created after the rename points at the old org. Running an org rename
through 35 repos while separately rewriting workflows in those same repos
makes every conflict ambiguous — a rename artifact is indistinguishable from a
workflow bug. Doing it first means the refs written by the fleet pass are the
final ones.

Cost: #54's phases are the long pole of the entire plan.

**Additional benefit, identified 2026-09-02:** the migration is also the only
way three private user-owned repos (`scripts`, `claude-config-backup`,
`cleanroom`) can ever carry branch protection — GitHub does not offer it for
private repos under a personal account at this tier. Moving them into the org
converts them from "cannot be protected" to ordinary fleet repos, with no
separate remediation. That is a real argument for the migrate-early decision
above, beyond the conflict-ambiguity reasoning already recorded.

Three approaches already ruled out and recorded in the issue: `grll/claude-
code-login` (Anthropic returns 429 to third parties), Workload Identity
Federation (moves billing off the Max flat rate), and the undocumented token
list/revoke API (broken pagination).

## Fleet layer

All of this runs after I3, as **one pass per repo**.

### Fleet state (audited 2026-08-29, dev-env#75)

All 39 non-archived repos across both orgs:

| Configuration | Count |
| --- | --- |
| `strict: true`, requires `claude-review` only | 27 |
| `strict: true`, requires **nothing** | 5 |
| `strict: true`, requires `validate` + `claude-review` | 1 (`personify`) |
| **No protection at all** | 6 |

Five repos force a rebase and then gate on nothing — Dependabot churn with no
safety benefit. Six have no protection at all, including `scripts`,
`repo-template`, `pr-review`, and both `.github` repos.

> **Superseded by the 2026-09-02 verification audit.** Re-measured: **44**
> non-archived repos, **26** with exactly one required check, **8** with no
> protection (404), and **3** returning 403 — `scripts` is in the 403 group,
> *not* the unprotected group. The `strict: true`-gating-nothing count of 5
> holds. Use the audit's numbers.
>
> The 3 in the 403 group are private repos owned by the **user account**, not
> an org, which is why protection cannot be set on them at all. **I3 resolves
> that category by moving them into the org** — they are not a gap to close
> separately. See "The 403 group is an org-migration artifact" in the audit.

A separate measurement (2026-08-19, github-workflows#154): 35 non-archived
repos carry a `claude-blocking-review.yml` caller; 27 have it as a required
check; **26 of those 27 have it as their only required check.**

Together these say the fleet is less protected than either measurement alone
suggests. `standards-check.yml` is not merely a replacement for the judgment
reviewer — for 11 repos it is the first required check they will ever have.

**This audit is from 2026-08-29. Re-run `claude-review-audit.sh` before
acting.**

### W1 — Build `standards-check.yml`

Greenfield; verified absent (`github-workflows` contains only `zizmor.yml` at
root). Runs shellcheck, yamllint, actionlint, zizmor, markdownlint, plus repo
tests.

`personify` is the only repo already requiring `validate` + `claude-review`.
Read its configuration as the reference implementation rather than designing
from scratch.

Three decisions listed in github-workflows#154 block Phase 1 and must be
answered first.

### W2 — Roll out to the fleet

Pilots, named in #154: `dumbify`, `x-thread-reader`, `networth-agent`,
`claude-code-workflows-agents`, `pr-review`, `repo-template`,
`nightowlstudiollc/.github`, `scripts`. The original rationale was to start
with `scripts`, because its `claude-review` check is not enforced so a
mistake breaks nothing.

**That rationale expires at I3** (corrected 2026-09-02). `scripts` is
unenforced because it is a *private repo under a user account*, where branch
protection cannot be set — not because of a check-level gate. W2 runs after
I3, by which point `scripts` is org-owned and its checks enforce normally.
Re-pick a genuinely low-stakes pilot at that point instead of inheriting this
one.

Existing tooling does the fan-out: `claude-review-audit.sh` (read-only, walks
both orgs, classifies workflow files per repo) and
`bulk-install-claude-review.sh` (write side). `docs/plans/2026-04-18-v2-
rollout-playbook.md` is a reusable playbook written for exactly this.

### Folded into the same pass

Per decision 2026-09-01, one pass per repo delivers all of:

1. **`standards-check.yml`** (W1).
2. **`zizmor.yml` propagation.** zizmor is a step *inside* the standards
   check and `zizmor.yml` is its config; propagating it separately means
   touching every repo twice. Currently present in one repo
   (`github-workflows`) and running in no repo's pre-commit — no repo has a
   populated `.pre-commit-config.yaml` (`claude-config` has one, but it is
   `repos: []`). The two-tier policy itself is settled and correct:
   `smartwatermelon/github-workflows/*: ref-pin`, `"*": hash-pin`.
3. **Branch-protection normalization** (dev-env#75): set required checks,
   reconsider `strict` where it currently gates nothing.
4. **`scripts` caller-stub conversion.**
   `scripts/.github/workflows/claude.yml` carries the only two unpinned
   third-party refs found — `actions/checkout@v7` (line 25) and
   `anthropics/claude-code-action@v1` (line 31). The second is the exact
   action whose compromise motivated the zizmor policy. The file is a
   hand-rolled inline job; the rest of the fleet migrated to the
   `claude-assistant.yml@v3` caller stub. Convert rather than SHA-pin.

5. **`repo-template` pin correction — highest priority of the fold-ins.**
   The template pins its first-party callers exactly:
   `claude-blocking-review.yml@v3.2.1` and `claude-assistant.yml@v3.1.1`.
   This contradicts the settled policy (`zizmor.yml:49`,
   `smartwatermelon/github-workflows/*: ref-pin`), which is floating `@v3`
   precisely so a security fix reaches consumers by repointing one tag —
   the mechanism by which GHSA-8q5r-mmjf-575q reached consumers while ~19
   repos pinned to exact `@v3.1.0` received nothing. The fleet already
   migrated: `claude-wrapper` in #112/#116/#118, `scripts` in #119/#121,
   with the docs corrected in github-workflows#138. The template was missed,
   so every repo created from it is seeded with the pin shape the fleet
   moved away from — at two different stale versions, so a first-party fix
   reaches neither. Float both to `@v3`.

6. **`repo-template` self-linting.** The template has no `zizmor.yml` and no
   `.pre-commit-config.yaml`. Once `standards-check.yml` is the fleet's
   required check, the template must seed it and its config, or every new
   repo starts out failing the check it was born with.

7. **`repo-template` update.** The template seeds every new repo with
   `.github/workflows/claude-blocking-review.yml`, `claude.yml`,
   `dependabot-auto-merge.yml`, `dependabot.yml`, and `CLAUDE.md`. Whatever
   the fleet pass changes must change here too, or every repo created
   afterward is seeded with the old configuration. (`CLAUDE.md` is an
   11-line scaffold with fill-in prompts — a genuine starting point,
   needing no change. It is unrelated to the 0-byte
   `github-workflows/CLAUDE.md` in L4.) Its README also documents
   branch protection as "optional but recommended" (step 3) — which is how
   the fleet arrived at 6 repos with no protection and 5 with `strict: true`
   gating nothing. Make it non-optional, set by
   `new-smartwatermelon-repo.sh` at creation time.

New-repo creation is handled separately by extending
`new-smartwatermelon-repo.sh`, per the 2026-08-31 settings-app evaluation
(Option 3). That evaluation's recommendation stands: do not install
`apps/settings`; revisit Terraform only if fleet-wide drift becomes a real
pain point.

### W3 — Retire the CI judgment reviewer

Only after W2 covers the 27 repos where blocking review is required. This is
the item the sequencing exists to make safe.

`repo-template` ships `claude-blocking-review.yml` as one of its five tracked
files, so it is a *source* of the workflow being retired. W3 must update the
template in the same change, or every repo created after the retirement is
seeded with a dead caller.

### Deliberately not folded in

**The `nightowlstudiollc` required-workflows ruleset.** Attempted and rolled
back; three open questions must be answered on a single test PR first. Five
verified gotchas are recorded in
`github-workflows/docs/plans/2026-04-30-required-workflows-nightowlstudiollc.md`:

- `enforcement: "evaluate"` is Enterprise-only; Team plans silently enforce as
  active.
- A PR that deletes the workflow gating it is unmergeable.
- `gh pr merge --admin` bypasses branch protection but **not** rulesets.
- Expanding ruleset scope does not retroactively fire on open PRs; only a push
  does.
- The check name is `claude-review / run-review`, not the workflow's `name:`.

Folding an unresolved rollback into a 35-repo pass risks a fleet-wide stall.

`nightowl-ruleset-rollout.sh.broken` is deliberately unexecutable: step 1
unconditionally sets `enforcement="active"`, re-arming the intentionally-
disabled ruleset on every `--apply`. Fix the state assertions before any reuse.

### Do not use `zizmor --fix=all`

Per dev-env#77: experimental, no-op offline, classified an *unsafe* fix, and it
silently resolves floating majors to specific patches — a mass version bump,
not a notation change. Blanket hash-pin findings are persona-gated to
`pedantic`/`auditor`; a default-persona run reports nothing and looks clean.

## Local review layer

Independent of everything above; can run in parallel.

### L1 — dotfiles config contamination (do first)

An inherited `GIT_DIR` from an agent worktree makes fixture tests write to the
real `.git/config`, blanking `core.hooksPath`. That silently disables every
local review hook — **including the detector that would notice.**

**Remediation has landed (verified 2026-09-02).** `bash/tests/lib/git-env-
isolation.sh` exists and is used by 9 fixture tests.
`test-git-env-isolation.sh` validates it the right way: it injects the
condition (a throwaway repo with a linked worktree and an exported `GIT_DIR`,
because git exports `GIT_DIR` to a hook only from a linked worktree — which is
why three prior investigations found nothing) and includes a control case
requiring the *unguarded* operation to contaminate. Suite: 23 passed, 0
failed. Only the `uchg` removal below is outstanding.

Currently held closed by a `chflags uchg` tripwire on
`dotfiles/.git/config` — verified still engaged 2026-09-01. `core.hooksPath`
currently reads `~/.config/git/hooks` in `dotfiles`, `claude-config`, and
`dev-env`.

A `uchg` flag is a load-bearing manual workaround on the file controlling
whether review infrastructure runs at all. Acceptable as a stopgap, not as a
steady state: it will be forgotten, and the failure it prevents is invisible.
Fix the tests to not inherit `GIT_DIR`, validate against a known-bad case,
then remove the flag.

This goes first because it determines whether any other local-review fix is
actually being verified.

### L2 — Deploy/edit separation (claude-config#453)

`install.sh` creates 36 symlinks from `~/.claude` into the
`~/Developer/claude-config` working tree. Every fix to the review pipeline is
therefore made *through* the thing being fixed: editing a hook makes it live
mid-session, on the uncommitted version, including on the commit testing it.

This is the architectural root of the review-pipeline cluster, and the most
plausible mechanism behind the recurring "green suite over broken code"
pattern. Sequence it before the rest of the cluster.

### L3 — Close the false-OK cluster

- **`--repair` reports healthy while guards are down** (#439).
- **Chunked review reports PASS while skipping the files that mattered**
  (#451). `review.skipThreshold` 2500, `review.chunkSize` 800.
- ~~**shellcheck does not run in `claude-config`**~~ — **no longer true.**
  `.pre-commit-config.yaml` was fixed 2026-08-26 and now runs `shell-lint-fix`
  (shellcheck + shfmt). Verified 2026-09-02.

Treat as one project, **two bugs** (was three). Each fix validated against a
known-bad case.

### L4 — Doc hygiene

No dependencies. Roughly an hour. Prevents re-planning shipped work.

Stale status markers, each currently reading as unstarted work:

| File | Says | Actually |
| --- | --- | --- |
| `scripts/docs/plans/2026-04-16-ssh-wrapper-spec.md` | not implemented | `scripts/ssh` exists, 22KB, maintained |
| `scripts/docs/plans/2026-04-24-ssh-keychain-unlock.md` | not implemented | shipped in #64 |
| `scripts/docs/plans/2026-08-19-shared-repo-core-design.md` | awaiting review | landed in #128/#171 |
| `dev-env/docs/plans/2026-08-27-workflow-sha-pinning.md` | proposed, not started | Phase 1 + Task 2.2 shipped; supersede with #77 |
| `dev-env/CLAUDE.md:24` | March plan is "the active roadmap" | Phases 3-5 abandoned; contradicts `README.md:7` |

Also folded in (claude-config#465, filed 2026-09-02): a `CLAUDE.md` section
covering factual claims in prose drafted for the user to publish under their
own identity. The existing "Verifying agent claims" rule scopes to "I did X"
statements and "resolve the thing; don't match its label" reads as being
about state checks, so neither fires while writing prose — which is the
highest-stakes output, since it carries the user's name in front of senior
reviewers. Doc-only change; it belongs in this layer rather than as its own
track.

Also: `docs/data/corpus-440/RESULTS.md` already answered the narrowed-prompt
question (baseline 29/47, narrowed 27/47, blind control 1/47 — keep the
unscoped prompt), but `docs/plans/2026-08-26-review-pipeline-redesign-design.md`
still lists it open. And `github-workflows/CLAUDE.md` is a 0-byte file.

## Runtime EOL layer

### N1 — Node EOL migration (dev-env#78)

Filed 2026-09-01, after the rest of this design was written. Independent of
every other track; nothing here blocks it and it blocks nothing except a W1
detail.

Node 20 reached EOL 2026-04-30 and receives no security patches. It is pinned
across CI workflows, Dockerfiles, and manifests fleet-wide. One repo is still
on Node 18 (EOL 2025-04-30) and one manifest floor admits Node 14 (EOL
2023-04-30). EOL dates in #78 are from `nodejs/Release` `schedule.json`,
fetched 2026-09-01.

**Scope decision (2026-09-02): all repos, product included.** See the
exception recorded under Purpose.

**N1a — local default and infrastructure repos.**
`~/.nvm/alias/default` holds `20`, and nvm prepends its version at `PATH`
position 1, ahead of Homebrew at position 6 — so v20.20.2 shadows the v22,
v24, and Homebrew v26 installs that are all present and idle. Nothing is
missing; the pin is the cause. Low-risk: all three nvm versions carry only
`corepack` and `npm` globally, so nothing needs reinstalling.
`nvm alias default lts/krypton` (v24.19.0), then `hash -r`.

Verify with `which node`, **not** `command -v node` or `type node` — those
read bash's hash table and will report the stale path. This is the standing
PATH-shim gotcha; it applies here exactly.

Infrastructure-repo CI pins: `claude-code-workflows-agents`
(`code-quality.yml:80`, `validate.yml:233`).

**N1b — product repos.** `tensegrity` (`ci.yml:18`, Node 18);
`kebab-tax` (`deploy-workers.yml:37,68,139`, `release-gate.yml:47`,
`ci.yml:65,149`, `mobile/Dockerfile.test:2`, `.nvmrc` at `20.19.4` — also
consumed by `publish-changelog.yml:27` via `node-version-file`);
`Gmail-MCP-Server` (`ci.yml:171`, `Dockerfile:1`, `engines.node: >=14.0.0`;
note `publish.yml:34,66` is already on 22, so CI and publish disagree);
`reliquarist` (`ci.yml:31`, `engines.node: >=20.0.0`).

**Known-bad validation:** a version bump is exactly the kind of change that
reports success while proving nothing — a workflow can pass because its Node
step was never reached. Before each bump, confirm the job actually executes
the Node step and that the pre-bump version is what it reports. Line numbers
above are from #78 as of 2026-09-01; re-resolve them before editing.

**Feeds W1:** once `standards-check.yml` exists, it should assert a
supported Node line, and `repo-template` should seed one — otherwise the
fleet drifts back. Do not block N1 on W1; the audit is worth doing now and
the assertion is a later addition.

### L5 — Small unfiled items

- dotfiles root junk from an unquoted `> $(date)`: files named `08:57:30`,
  `31`, `Aug`, `PDT`, `2026.log` (all 24038 bytes, identical), plus stray
  transcripts and `.patch` files. Check whether they are tracked.
- dotfiles#247: `tolerate_upgrade_failure=true` swallows all
  `brew upgrade --formula` failures non-interactively
  (`functions.sh:368,371,409`). A broken formula silently no-ops nightly,
  forever. Another false-OK.
- The mutable-tag concern in dotfiles#247 is superseded by the settled
  `zizmor.yml` policy; close as resolved-by-policy.
- Redundant `# zizmor: ignore[unpinned-uses]` comments in `claude-wrapper`,
  now superseded by the policy file.
- `dotfiles`: `git init` does not fire `post-checkout` despite hook comments
  claiming it does (`git/template/hooks/post-checkout:6-21`).

## Items needing GitHub issues

These are verified defects with no issue filed:

1. `GH_TOKEN` precedence defeats `_gh_wrapper_sync_identity` (F3).
2. ~~`git-identity.sh` org-blindness / cross-org identity leak (F2).~~
   **Do not file as a defect** — disproven 2026-09-02. If filed at all, it is
   a latent-hazard note conditional on installing `claude-wrapper` on the work
   machine.
3. Missing `admin:org` scope blocking org secret management (F4).
4. dotfiles root-directory junk files (L5). Confirmed **untracked**; safe to
   delete.
5. Empty `github-workflows/CLAUDE.md` (L4).
6. Unpinned actions in `scripts/.github/workflows/claude.yml` (folded into W2).

## Deferred, with reasons

| Item | Why deferred |
| --- | --- |
| `CLAUDE_GH_TOKEN_ROUTER` full router | Needs a second PAT and reverses a documented decision. Cheap tier first. |
| `nightowlstudiollc` required-workflows ruleset | Rolled back once; three open questions need a test PR. |
| Terraform for repo settings | Only if fleet-wide drift becomes a real pain point (2026-08-31 evaluation). |
| `claude-wrapper#57` per-project model/effort selection | Cost optimization, not stability. Depends on `.claude/config.sh.template` as config surface. |
| dotfiles TCC/sudo Root Cause 2 | Partially done; remaining half is unrelated to this plan's throughline. |

Standing constraint, recorded so it is not revisited: repointing
`com.andrewrich.updates` off `/bin/bash` 3.2 was **abandoned by design** —
`/bin/bash` is the only SIP-protected, stably-FDA-grantable interpreter. Do
not revisit without an FDA-stability plan.

## Verification audit (2026-09-02)

Prompted by the F2 correction above: if one "Verified:" claim was an inference
written as a measurement, the others needed re-testing before anything was
built on them. Every such claim in this document was re-checked against live
state, including over SSH to `arich-mac.local` where the claim concerned the
work machine.

**Claims that HOLD, re-measured:**

| Claim | Evidence |
| --- | --- |
| `GH_TOKEN` active, lacks `admin:org` | `gh auth status`: active `GH_TOKEN` account, scopes list has no `admin:org` |
| keyring account has `admin:org`, inactive | same output: `admin:org`, `admin:public_key`, `repo`, `workflow`, Active: false |
| `admin:org` 403 blocks org secrets | `gh api orgs/nightowlstudiollc/actions/secrets` → HTTP 403, verbatim message |
| `credentials.sh` exports `GH_TOKEN` unconditionally | `credentials.sh:111` (spec said :112 — trivial drift) |
| env vars outrank `includeIf` | measured on a scratch repo; see the F2 section |
| `CLAUDE_GH_TOKEN_ROUTER` is dead | only `gh-wrapper.sh:488-490`, standalone branch, defined nowhere |
| 5 repos `strict: true` gating nothing | `huddle-transcribe`, `dumbify`, `x-thread-reader`, `smartwatermelon/.github`, `networth-agent` |
| `scripts` unpinned actions | `claude.yml:25` `actions/checkout@v7`, `:31` `anthropics/claude-code-action@v1` |
| `github-workflows/CLAUDE.md` is 0 bytes | confirmed |
| `install.sh` symlinks into the working tree | 37 symlinks under `~/.claude` resolve into `~/Developer/claude-config` |
| dotfiles root junk exists | `08:57:30`, `31`, `Aug`, `PDT`, `2026.log` all present |

**Claims that are now FALSE:**

1. **The cross-org identity leak.** See the corrected section above. No beacon
   repo is affected; `claude-wrapper` is not installed on the work machine.

2. **`claude-config`'s `.pre-commit-config.yaml` is `repos: []`.** It is not,
   and has not been since **2026-08-26**. The file now runs `shell-lint-fix`
   (shellcheck + shfmt) among other hooks, and its header documents the empty
   version as a mistake in the exact terms the spec uses against it. This
   appears **twice** in the spec — in the false-OK table and as the third item
   of L3 — and both are stale. **L3 is two bugs, not three.**

3. **"6 repos with no protection at all," including `scripts`.** The real
   count is 8 (404 Branch-not-protected): `repo-template`, `pr-review`,
   `claude-code-workflows-agents`, `superpowers-marketplace`,
   `Instapaper-MCP`, `superpowers`, `homebrew-brew`,
   `nightowlstudiollc/.github`. `scripts` is **not** among them — it returns
   403. Three repos are in that state: `claude-config-backup`, `cleanroom`,
   `scripts`. Conflating "no protection" with "protection I cannot see" is the
   same label-matching error as the rest of this section.

### The 403 group is an org-migration artifact, not a gap to fix

Established 2026-09-02 (Andrew), verified the same day. The 403 is not a
generic "Pro-gated" limit — it is specifically **private repos owned by a
user account** rather than an organization. Measured:

| Repo | visibility | owner type | protection |
| --- | --- | --- | --- |
| `scripts` | private | **User** | 403 |
| `claude-config-backup` | private | **User** | 403 |
| `cleanroom` | private | **User** | 403 |
| `nightowlstudiollc/kebab-tax` | private | Organization | readable |
| `nightowlstudiollc/financial-agent` | private | Organization | readable |

All three 403s share `private=true` + `owner.type=User`; the private repos
that *do* carry protection are org-owned. GitHub does not offer branch
protection on private repos under a personal account at this tier.

**Consequence for the plan: I3 dissolves this category.** Once these repos
move to the new org, protection becomes settable on them and they join the
normal fleet. So the 403 group needs no remediation of its own — it needs
I3, which is already the critical path. Do not file work against it, and do
not treat the three as a branch-protection gap in the W2 pass; they will be
ordinary org repos by the time W2 runs.

This also revises the W2 pilot rationale below, which picks `scripts` on the
grounds that its `claude-review` check is "Pro-gated and therefore not
enforced." That reasoning is right about the effect and wrong about the
cause, and it expires at I3 — after migration `scripts` is a normal
org-owned repo whose checks do enforce. Re-pick the safe pilot then rather
than inheriting this one.

**Also resolved:** the L5 open question "check whether they are tracked" —
all five junk files are **untracked**. Safe to delete.

**Fleet totals have drifted** from the 2026-08-29 audit: 44 non-archived repos
now (spec says 39), 26 with exactly one required check (spec says 27). The
standing instruction to re-run `claude-review-audit.sh` before acting is
correct and now has numbers behind it.

**Method note.** The correct required-check context is
`claude-review / run-review`, not `claude-review`. A first pass of this audit
matched the bare name, returned "0 repos require claude-review," and would
have read as a catastrophic fleet regression. The spec already records this
gotcha in the ruleset section; it caught the auditor anyway.

## Issue delta since this design was written

Swept 2026-09-02 across both orgs for issues opened after 2026-09-01. Six
found; the sweep is recorded so the next reader knows the window that was
checked rather than re-deriving it.

| Issue | Disposition |
| --- | --- |
| dev-env#78 — Node 20 past EOL | **New scope.** Became N1; product repos included by decision. |
| dev-env#77 — SHA-pinning plan stale | Already cited (L4, and the `--fix=all` section). No change. |
| claude-config#465 — verify claims in published drafts | Folded into L4 as a `CLAUDE.md` change. |
| claude-config#458 — non-blocking findings from PR #457 | Routine review-findings batch. Not this backlog's throughline. |
| dotfiles#298, #296 — non-blocking findings from PRs #297/#295 | Finicky PWA config. Unrelated to this plan; left to their own issues. |

Nothing in the delta reverses a decision or changes the critical path.

## Execution notes

**Four tracks run in parallel.** Foundation + identity (F, I), local
review (L), and runtime EOL (N) are independent. Fleet (W) waits on I3.

**Critical path** is I3 → W1 → W2 → W3. Everything else fits around it.

**Start with:** L1 (gates whether local review is real), F1 → F2/F3 (stops
wrong-identity actions), I0 (unblocks the billing control), and N1a (one
command plus two CI pins; removes an unpatched runtime from daily use). All
four are independent of each other and of the critical path.

**Validate every fix against a known-bad case.** Six of the defects here
report success while doing nothing. A clean result from an unvalidated check
is exactly the evidence that produced them.
