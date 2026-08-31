# Evaluating the GitHub "Settings" App for Repo Setup Automation

_August 31, 2026 — Research report_

---

## Problem statement

New-repo setup across the `smartwatermelon` fleet is handled by two pieces today:

- **`smartwatermelon/repo-template`** — seeds file content (`CLAUDE.md`, the three
  `claude*.yml` workflows, `dependabot.yml`) into a new repo at creation time via
  `gh repo create --template` or the `new-smartwatermelon-repo.sh` wrapper.
- **`smartwatermelon/.github`** — org-wide defaults GitHub inherits automatically
  (`FUNDING.yml`) plus a workflow-template gallery (`claude-blocking-review.yml`) repos
  opt into from the Actions tab.

Neither touches **repository _settings_** — the GitHub-side configuration (branch
protection, merge options, feature toggles, labels, collaborators) that lives in the
repo's Settings UI, not in its file tree. `repo-template`'s own README lists three
manual steps every new repo still needs, one of which is exactly this gap:

1. Set the `CLAUDE_CODE_OAUTH_TOKEN` secret.
2. Set `can_approve_pull_request_reviews` (Actions → General → Workflow permissions).
3. **Add `claude-review / run-review` as a required branch-protection status check**
   ("optional but recommended" — i.e., usually skipped).

Beyond that unaddressed item, nothing in the fleet manages labels, repo feature
toggles (wiki/projects/issues), squash-only merge + delete-branch-on-merge, or topics —
these are either left at GitHub's defaults or set by hand, inconsistently, per repo.
The question: does <https://github.com/apps/settings> close this gap, and is it the
right way to close it?

---

## Option 1: `apps/settings` (Probot "Settings" app, `repository-settings/app`)

**What it is**: A hosted GitHub App, built on Probot, maintained by the
`repository-settings` org. Once installed, it watches for pushes to
`.github/settings.yml` in any repo it's granted access to and syncs the declared
state to GitHub via the REST API.

**Schema coverage**: repository metadata (description, homepage, topics,
visibility), feature toggles (issues/projects/wiki/downloads), merge strategy
options (squash/merge-commit/rebase, and — per later versions —
delete-branch-on-merge), `enable_automated_security_fixes` /
`enable_vulnerability_alerts`, labels, milestones, collaborators and team
permissions, and classic branch-protection rules (required status checks, required
reviews, `enforce_admins`, push restrictions).

**Org-wide defaults**: if installed at the org level and `smartwatermelon/.github`
carries a `.github/settings.yml`, that file becomes the *default* applied to every
repo that doesn't ship its own override — array fields (labels, branch rules) merge
by name rather than replacing wholesale. This is a direct, better-fitting answer to
what `.github` already does for `FUNDING.yml`.

**What it does *not* cover**: Actions permissions
(`default_workflow_permissions`, `can_approve_pull_request_reviews`, allowed-actions
policy), Actions/Dependabot secrets and variables, environments, webhooks, GitHub
Pages, and the newer repository **rulesets** feature (a distinct, more capable
successor to classic branch protection). So even fully adopted, it would still leave
items 1 and 2 of `repo-template`'s manual-steps list untouched — those need a
scripted `gh api` call regardless of what handles item 3.

**Risk — privilege surface**: the app requires **Administration: write** on every
repo it's installed on, the single highest-privilege scope GitHub exposes (branch
protection, collaborator/team management, visibility, deletion-adjacent settings).
Installing it hands that scope to a third party's hosted infrastructure across the
whole org, not just the repos being actively managed. The project's own docs flag a
related concern: anyone with push access to a repo can edit its `settings.yml` and
thereby self-grant admin-equivalent changes, and recommend a CODEOWNERS rule on that
file as the only mitigation — a workaround, not a control.

**Risk — maintenance**: fetching the project page did not surface recent-activity
signals (release cadence, open-issue triage) strong enough to treat it as a
confidently-maintained dependency; this should be re-checked at adoption time rather
than assumed from this report.

**Fit for our workflow**: Solves exactly one of three manual steps
(branch protection), extends further into never-automated territory (labels, merge
options, feature toggles) that's genuinely useful, but does so by installing a
permanently-running, admin-scoped, third-party-hosted webhook service across the
entire org. That's a materially larger and more persistent trust surface than
anything currently in the fleet — and directly cuts against the fleet's own
recent direction (the 2026-03-25 infrastructure consolidation deliberately *removed*
remote dependencies — Sentry/Seer, `claude-code-review.yml`'s per-commit remote
calls — in favor of local, deterministic, self-hosted automation). Adopting a
standing admin-privileged external app to save a handful of `gh api` calls at repo
creation time is a worse trade than it looks.

---

## Option 2: `github/safe-settings` (self-hosted)

**What it is**: A more capable, actively-maintained fork of the same idea from
`github-community-projects`, designed for exactly the blast-radius problem Option 1
has. Config lives centrally in one admin repo (not distributed across every repo's
own `settings.yml`), and the app itself is **self-hosted** — deployed as your own
GitHub App registration on your own infrastructure (Lambda, Docker, or k8s), so the
admin-privileged actor is infrastructure you control, not a third party's.

**Safety features Option 1 lacks**: dry-run/plan mode (PRs against the config repo
are validated before merge, similar in spirit to `terraform plan`),
`overridevalidators` that can pin a floor on settings (e.g. reject a per-repo
override that lowers `required_approving_review_count`), and `restrictedRepos`
glob patterns to scope which repos the app is even allowed to touch.

**Broader coverage**: adds environments, autolinks, custom repository properties,
and the newer rulesets feature — closer to (though still short of) what Terraform's
GitHub provider covers, and closer to closing the Actions-permissions gap than
Option 1, though secrets management remains out of scope for both.

**Fit for our workflow**: Meaningfully better than Option 1 on the trust dimension
— it's the same "declarative repo settings" idea without handing admin scope to
someone else's hosted service — but it introduces a new piece of always-on
infrastructure (a webhook receiver) to operate and keep patched, which is exactly
the kind of standing surface the fleet has been shrinking, not growing.

---

## Option 3: Extend `new-smartwatermelon-repo.sh` (no new infrastructure)

**What it is**: The creation-time wrapper already referenced by `repo-template`'s
README already sets `can_approve_pull_request_reviews`. The same script can grow a
few more `gh api` / `gh repo edit` calls to also set, at creation time:

- Branch protection: require `claude-review / run-review` as a status check
  (closes the one manual step `repo-template` explicitly calls out).
- Merge options: squash-only, delete-branch-on-merge.
- Feature toggles: disable wiki/projects if unused by convention.
- Topics/description, if the fleet wants repo metadata standardized.

**What it doesn't do**: fix drift on the ~50 existing repos already in the fleet, or
correct settings changed by hand after creation — it's a creation-time script, not a
continuously-reconciling controller.

**Fit for our workflow**: Zero new trust surface (extends a script already trusted
with `gh` credentials), zero new standing infrastructure, and directly closes the
one gap `repo-template` already flags as unresolved. This is the natural
next increment given what already exists.

---

## Option 4: Terraform (`integrations/github` provider)

**What it is**: Declarative repo-settings-as-code, run transiently in CI (plan on
PR, apply on merge) rather than via a permanently-installed webhook app. Covers
everything Options 1 and 2 cover, plus Actions permissions, environments, rulesets,
and secret *existence* (not values) — using a token minted per-run rather than a
standing installation.

**Fit for our workflow**: This is the option that actually matches the fleet's
stated philosophy — "one repo, one source of truth" — extended from local
dev-machine config (`install.sh`) to org-wide repo config. It's also the only option
here that could reconcile drift across the *existing* fleet, not just new repos. The
cost is real, though: authoring HCL, an initial `terraform import` pass across
~30+ active repos, and picking a state backend. This is a larger, separate project,
not a drop-in replacement for `repo-template`/`.github` — worth its own design doc if
pursued, not a corollary of this evaluation.

---

## Recommendation

- **Do not install `apps/settings`.** The gap it closes (branch protection) is real
  but narrow, and the price — a permanently-installed, third-party-hosted app with
  Administration:write across the org — is disproportionate, especially given the
  fleet's explicit recent history of removing standing remote dependencies for
  exactly this kind of trust/cost reason.
- **Short term: extend `new-smartwatermelon-repo.sh`** (Option 3) to set branch
  protection and merge/feature options at creation time. This fully closes the one
  manual step `repo-template` already flags, adds the never-automated pieces
  (labels, merge strategy, feature toggles) that Options 1/2 would otherwise be the
  first thing in the fleet to manage, and needs no new infrastructure or trust grant.
- **Medium term, only if fleet-wide drift correction becomes a real pain point**
  (settings changed by hand across the existing ~30+ repos, not just new ones):
  evaluate Terraform (Option 4) as a proper repo-settings-as-code layer — it
  subsumes everything the Settings app offers and fits the existing
  single-source-of-truth model this repo already champions. `github/safe-settings`
  (Option 2) is worth a second look only if the declarative-YAML ergonomics are
  specifically wanted and self-hosting a webhook receiver is acceptable; it is
  strictly safer than Option 1 but still a standing service to operate.
