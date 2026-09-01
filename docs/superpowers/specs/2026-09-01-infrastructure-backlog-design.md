# Design: Infrastructure Backlog Consolidation

Status: DESIGN — approved in session 2026-09-01. No implementation started.

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

### A cross-org identity leak that was never filed

`claude-wrapper/lib/git-identity.sh:12-15` exports `GIT_AUTHOR_NAME`,
`GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL` as
`Claude Code Bot <claude-code@smartwatermelon.github>` — unconditionally,
with no repo or owner awareness. Git environment variables outrank all
gitconfig, including `includeIf`.

Consequence: every commit made in a `beacon-biosignals` repo through Claude
Code is authored at a `smartwatermelon` address, and the
`includeIf gitdir:.../beacon-biosignals/` block in `dotfiles/git/config:55-56`
is dead. The file has not changed since the original modularization commit
(`1d081f6`, #16); it predates the entire beacon-identity effort and was never
revisited. Verified: both `dev-env` and `tensegrity` commit as
`676392+smartwatermelon@users.noreply.github.com`.

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
| `claude-config` pre-commit | configured | `repos: []`, nothing runs |
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
```

## Foundation layer

### F1 — Extract a shared owner-resolver

`gh-wrapper.sh:60-96` already parses the repo owner out of
`remote.origin.url`, handling both `git@host:` and `https://` forms. Three
pending changes need exactly this logic: F2, F3, and I1. Extract it once.

No behavior change. Testable in isolation against fake git remotes, mirroring
the existing style in `claude-wrapper/tests/test-wrapper.sh`.

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
`nightowlstudiollc/.github`, `scripts`. Start with `scripts` — its
`claude-review` check is Pro-gated and therefore not enforced, so a mistake
breaks nothing.

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
local review hook — **including the detector that would notice.** Analysis
complete; remediation untouched.

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
- **shellcheck does not run in `claude-config`** — `.pre-commit-config.yaml`
  is `repos: []`. The repo containing the review infrastructure is the one
  repo not linting its own shell.

Treat as one project, not three bugs. Each fix validated against a known-bad
case.

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

Also: `docs/data/corpus-440/RESULTS.md` already answered the narrowed-prompt
question (baseline 29/47, narrowed 27/47, blind control 1/47 — keep the
unscoped prompt), but `docs/plans/2026-08-26-review-pipeline-redesign-design.md`
still lists it open. And `github-workflows/CLAUDE.md` is a 0-byte file.

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
2. `git-identity.sh` org-blindness / cross-org identity leak (F2).
3. Missing `admin:org` scope blocking org secret management (F4).
4. dotfiles root-directory junk files (L5).
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

## Execution notes

**Three tracks run in parallel.** Foundation + identity (F, I) and local
review (L) are independent. Fleet (W) waits on I3.

**Critical path** is I3 → W1 → W2 → W3. Everything else fits around it.

**Start with:** L1 (gates whether local review is real), F1 → F2/F3 (stops
wrong-identity actions), I0 (unblocks the billing control). These three are
independent of each other and of the critical path.

**Validate every fix against a known-bad case.** Six of the defects here
report success while doing nothing. A clean result from an unvalidated check
is exactly the evidence that produced them.
