# Infrastructure project status

**As of 2026-09-08.** Point-in-time snapshot of the infrastructure backlog
(`docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md`). The
design doc is authoritative on *what* each item is and why; this file records
*where things stand* and what to pick up next.

Re-measure before acting on any number here. Every count below came from a
live query on the date shown, and the fleet drifts.

## Where the project is

The identity and migration layers are done. The fleet layer is unblocked and
partly done. Local review and runtime EOL have not started.

| Layer | State |
| --- | --- |
| Foundation (F) | F1, F3, F4 done. F2 open (latent hazard, not urgent). |
| Identity / billing (I) | I3 done. I0, I1, I2 open. |
| Fleet (W) | W0 done. W1, W2, W3 open — **critical path**. Design decisions taken 2026-09-08. |
| Local review (L) | L1 done. L2, L3, L4, L5 open. |
| Runtime EOL (N) | N1a done. N1b (product repos) open. |

**Critical path: W1 → W2 → W3.** I3 and W0 have left it. Everything in L and
N runs in parallel and depends on nothing.

## Done

### I3 — Org migration (dev-env#54, closed)

Executed 2026-09-04 as a **rename-then-reclaim**, not the six-phase transfer
the design sketched: the personal account `smartwatermelon` was renamed to
`twistedmelonman`, then `smartwatermelon` was re-created as an organization
and repos transferred in.

**25 of 30 repos moved. Five are blocked pending a support ticket.** `dotfiles`, `claude-config`,
`personify`, `huddle-transcribe`, `projectinsomnia` are blocked by GitHub's
**popular repository namespace retirement** — a path is retired
when the repo saw >100 clones or >100 Actions runs in the week before a
rename, or shipped a Marketplace action. Retirement binds the *string*, not
the account, so the new org inherited the old user account's retired paths.
It blocks transfer (HTTP 422) and creation alike. A support ticket is in
flight (4729524), reopened after the org's Team upgrade; Andrew is pursuing it.

Three platform behaviors found the hard way, all now documented:

- **Actions does not follow owner redirects** for reusable-workflow
  references — the literal `owner/repo` must exist. The REST API *does*
  follow them, so every `gh api` check read healthy while CI died at 0s with
  no jobs and no logs.
- **GitHub App installations do not follow repo transfers.**
  `anthropics/claude-code-action@v1` (a downloaded Action) is distinct from
  the Claude GitHub App (`github.com/apps/claude`, an account-level install).
  The action cannot install the app; only an account owner can.
- **Org secrets do not reach private repos on GitHub Free.** Both orgs
  currently read `plan=team`, but that plan was bought to file a support
  ticket and will be dropped. Every private repo running a Claude workflow
  keeps its own repo-level copy.

### F4 — Token scope resolution

Closed via a narrow escape hatch in `gh-wrapper.sh`, not the token router the
design proposed. The finding that made it cheap: `GH_TOKEN` was never the
*wrong identity*, only a *too-narrow scope* on the right one. The wrapper now
detects GitHub's own `needs the "admin:org" scope` on stderr and prints an
`env -u GH_TOKEN` re-run.

### W0 — Fleet brought to the exemplar settings

**33 of 37 non-archived repos enforce `claude-review / run-review`, up from
25.** Applied per-repo to 9 repos on 2026-09-05, matching
`twistedmelonman/dotfiles` and `twistedmelonman/claude-config` (byte-identical
to each other, which made the template unambiguous):

- required check `claude-review / run-review`, `strict: true`
- `required_conversation_resolution: true`, 0 approving reviews
- `enforce_admins: false`, force-pushes and deletions off
- `allow_auto_merge: true`, `delete_branch_on_merge: true`

W0 was filed on a wrong premise, corrected in #91. The design claimed
`cleanroom` was protected by a `nightowlstudiollc` "Claude blocking review"
org ruleset and that creating an equivalent was the missing work. **That
ruleset is `enforcement: disabled` and enforces nothing** —
`repos/nightowlstudiollc/cleanroom/rules/branches/main` returns `[]`. All
protection in both orgs is classic per-repo branch protection. The gap was
also smaller than reported: the transferred repos mostly carried their
required check through intact.

### Starter set — L1, N1a, F3 (2026-09-02/03)

Executed per `docs/superpowers/plans/2026-09-02-infrastructure-backlog-starter-set.md`
and previously unrecorded here:

- **L1 — dotfiles config contamination.** Remediation (`git-env-isolation.sh`,
  9 fixture tests, a known-bad control) had already landed; the starter set
  removed the `uchg` tripwire on `dotfiles/.git/config`. Verified 2026-09-08:
  no flag, `core.hooksPath` intact. Follow-up `dotfiles#304` records why the
  flag is intentionally absent.
- **N1a — local nvm default and infra-repo CI pins.** `~/.nvm/alias/default`
  is `lts/krypton` (v24.19.0). `claude-code-workflows-agents#16` merged.
- **F3 — `GH_TOKEN` precedence guard, cheap tier.** `dotfiles#302` merged:
  the wrapper fails closed when `GH_TOKEN` resolves to a login other than the
  one the repo owner maps to. Follow-up `dotfiles#303` (cache the lookup).

### Migration cleanup (Steps 5–7) and the other two machines

Org secret set (visibility `ALL`), `ralph-burndown` secret removed,
`claude-code-login` and `smartwatermelon.github.io` deleted, #85 filed, #54
closed. Runbook Part D verified on TILSIT and MIMOLETTE 2026-09-08 (both
authenticate as `twistedmelonman`); MIMOLETTE's dotfiles clone was 35 commits
behind and was fast-forwarded. The temporary login alias is now removable
(migration plan Task 12).

## Open work, in priority order

### Critical path: W1 → W2 → W3

Decisions taken 2026-09-08 (Andrew) that unblock W1 — see
`docs/superpowers/plans/2026-09-08-backlog-remainder-roadmap.md`:

- **No judgment reviewer stays in CI.** `standards-check.yml` replaces
  `claude-blocking-review.yml` outright; local hooks are the only judgment
  pass. `claude-assistant.yml` is out of scope and keeps its token.
- **`nightowl-restore-blocking-review.sh` is retired with W3.**

W2 pilots, re-picked from repos with no enforcement today: `repo-template`,
`pr-review`, `claude-code-workflows-agents`, `nightowlstudiollc/.github`.
`scripts` is not a pilot (see #85).

### Runs in parallel with W

- **I0** — `CLAUDE_CONFIG_DIR` billing-verification script. Deliverable is a
  script Andrew runs on the company machine.
- **F2** — owner-aware `git-identity.sh`. Latent hazard only; do after I0.
- **N1b** — product-repo Node bumps (`tensegrity`, `kebab-tax`,
  `Gmail-MCP-Server`, `reliquarist`). Confirm each job reaches its Node
  step before and after.
- **L2 → L3, L4, L5** — deploy/edit separation, the false-OK pair
  (claude-config#439, #451), doc hygiene, small unfiled items.
- **#89** — add `claude-blocking-review.yml` + exemplar protection to
  `smartwatermelon/.github` only; the other three stay ungated by decision.
- **#90** — evaluate org rulesets on one test repo against a known-bad PR.
- **#85** — full-history secret audit of `scripts`, then stop and report.
- **#94** — Netlify publish verification for six sites (needs the Netlify
  dashboard as the inventory of record).

### Filed 2026-09-05

- **#84** — three conditions the org-migration design's failure table does
  not cover.

## Deferred by decision

These are not oversights. Do not "fix" them without asking.

| Item | Decision |
| --- | --- |
| Runbook Part D on TILSIT and MIMOLETTE | **Done 2026-09-08.** Alias removal (migration plan Task 12) is unblocked. |
| Splitting and rotating the shared token | **Deferred.** One token is installed in five places; a single rotation covers all of them. See `docs/token-rotation.md`. |
| `dev-env` visibility | **Stays public.** Considered and rejected: gitleaks over 67 commits found nothing, there are 0 forks, and going private would spend Actions minutes against the private budget while breaking the calendar event's `blob/main` link. |
| `photo-game-poc` token copy | **Parked.** Its secret predates the 2026-06-29 mint, so it holds an older token with no recorded expiry. The repo is archived and runs nothing. |
| Five retired repo paths | **Support ticket 4729524.** Closed by GitHub 2026-09-04 as self-service-only; reopened after the org's Team upgrade; status requested 2026-09-08, no staff reply. **Not given up on.** The move-list records `twistedmelonman` as an interim shim; flip back and re-run `transfer.sh` if the paths are released. |

## Standing methodology

Two disciplines this project has paid for repeatedly, both worth re-reading
before any audit:

**Resolve the thing; don't match its label.** A name, tag, comment, or count
is a claim about state, not state. This session alone: a ruleset named "Claude
blocking review" that was `enforcement: disabled`; a green 8s CI check that
was a doc-only short-circuit (benign, but only confirmable by reading
per-step conclusions); a code search returning zeros because it never covered
the org where the repos actually lived.

**Validate every fix against a known-bad case.** The design catalogs six
infrastructure defects that report success while doing nothing. A clean
result from an unvalidated check proves nothing — that is precisely how those
six accumulated.

## Key references

| Document | Contents |
| --- | --- |
| `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md` | The backlog itself: every item, the dependency graph, the false-OK catalog |
| `docs/superpowers/specs/2026-09-03-org-migration-design.md` | Org migration design and runbook |
| `docs/token-rotation.md` | Where each `CLAUDE_CODE_OAUTH_TOKEN` copy lives; expiry 2027-06-29. Never contains a token |
| `docs/runbooks/org-migration-rename.md` | Manual UI steps; Part D still pending on two machines |
| `docs/WORKFLOW-DEEP-DIVE.md` | Enforcement layers: hooks, wrappers, CI/CD |
| `scripts/org-migration/` | Snapshot/transfer/verify tooling; 38-test hermetic stub-`gh` suite |
