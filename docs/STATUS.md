# Infrastructure project status

**As of 2026-09-05.** Point-in-time snapshot of the infrastructure backlog
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
| Foundation (F) | F1, F4 done. F2, F3 open. |
| Identity / billing (I) | I3 done. I0, I1, I2 open. |
| Fleet (W) | W0 done. W1, W2, W3 open — **critical path**. |
| Local review (L) | Not started. L1 gates whether local review is real. |
| Runtime EOL (N) | Not started. Node 20 past EOL since 2026-04-30. |

**Critical path: W1 → W2 → W3.** I3 and W0 have left it. Everything in L and
N runs in parallel and depends on nothing.

## Done

### I3 — Org migration (dev-env#54, closed)

Executed 2026-09-04 as a **rename-then-reclaim**, not the six-phase transfer
the design sketched: the personal account `smartwatermelon` was renamed to
`twistedmelonman`, then `smartwatermelon` was re-created as an organization
and repos transferred in.

**25 of 30 repos moved. Five never will.** `dotfiles`, `claude-config`,
`personify`, `huddle-transcribe`, `projectinsomnia` are blocked by GitHub's
**popular repository namespace retirement** — a path is retired permanently
when the repo saw >100 clones or >100 Actions runs in the week before a
rename, or shipped a Marketplace action. Retirement binds the *string*, not
the account, so the new org inherited the old user account's retired paths.
It blocks transfer (HTTP 422) and creation alike. A support ticket is in
flight; assume it will be denied.

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

## Open work, in priority order

### Blocking nothing, but on the critical path

**W1 — build `standards-check.yml`**, folding in `zizmor.yml` and branch
protection. Then **W2** (fleet rollout, pilots first) and **W3** (retire the
CI judgment reviewer). W2 now inherits a largely conformant fleet rather than
one it must protect from scratch, so re-scope it against current state rather
than the design's original numbers.

Re-pick the W2 pilot. The design chose `scripts` because its check was
"Pro-gated and therefore not enforced" — that reasoning expired at I3, and
`scripts` now enforces normally.

### Should be done early

- **L1 — dotfiles config contamination.** Gates whether local review is real
  at all. The design says do this first in the L track.
- **N1a — local nvm default + infra-repo CI pins.** One command plus two CI
  pins; removes an unpatched runtime from daily use. Node 20 has been past
  EOL since 2026-04-30 (dev-env#78).
- **F2 / F3** — owner-aware `git-identity.sh` and the `GH_TOKEN` precedence
  guard. Both consume F1, which is done.
- **I0** — `CLAUDE_CONFIG_DIR` billing-verification script; unblocks the
  billing control and then I1.

### Filed this session

- **#89** — four repos have no enforced review check because they have **no
  review workflow to require**: `smartwatermelon/.github`,
  `claude-config-backup`, `superpowers`, `superpowers-marketplace`. Protecting
  them as-is would report "protected" while enforcing nothing.
  `smartwatermelon/.github` is in exactly that state today.
- **#90** — evaluate org rulesets as the scaling mechanism. Per-repo
  protection does not scale to new repos, and `repo-template` cannot carry
  protection in the template. This is the real problem the disabled ruleset
  was presumably meant to solve. Validate any ruleset against a known-bad
  case before trusting it.
- **#84** — three conditions the org-migration design's failure table does
  not cover.
- **#85** — make `smartwatermelon/scripts` public: secret audit, history
  rewrite, branch protection.

## Deferred by decision

These are not oversights. Do not "fix" them without asking.

| Item | Decision |
| --- | --- |
| Runbook Part D on TILSIT and MIMOLETTE | **Postponed 2026-09-05.** The `gh` wrapper's temporary `twistedmelonman=smartwatermelon` login alias (`~/.config/bash/gh-wrapper.sh:188`) stays in place until both machines run it. |
| Splitting and rotating the shared token | **Deferred.** One token is installed in five places; a single rotation covers all of them. See `docs/token-rotation.md`. |
| `dev-env` visibility | **Stays public.** Considered and rejected: gitleaks over 67 commits found nothing, there are 0 forks, and going private would spend Actions minutes against the private budget while breaking the calendar event's `blob/main` link. |
| `photo-game-poc` token copy | **Parked.** Its secret predates the 2026-06-29 mint, so it holds an older token with no recorded expiry. The repo is archived and runs nothing. |
| Five retired repo paths | **Support ticket in flight.** Assume denial and plan around the five paths staying dead. |

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
