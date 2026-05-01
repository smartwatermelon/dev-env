# dev-env

**Specification, standards, and reference documentation for a local-first code-quality and Claude Code workflow system.**

This repo is the canonical written record of how code review, pre-commit enforcement, pre-push validation, pre-merge gating, branch protection, and CI workflows are organized across all `smartwatermelon` and `nightowlstudiollc` repositories.

It is **not** a tool, framework, or installable package. It does not contain the hooks, scripts, or workflows themselves — those live in the implementation repos listed below. This repo contains the *spec* those implementations follow and the *retrospective* of how the spec came to be.

---

## What's in here

| Document | Role |
| --- | --- |
| [`docs/WORKFLOW-DEEP-DIVE.md`](./docs/WORKFLOW-DEEP-DIVE.md) | **Live architecture reference.** Source-attributed walkthrough of every layer (Claude Code hooks, git hooks, shell wrappers, review scripts, merge authorization, GitHub Actions, pre-merge review). The "how does this work today" doc. |
| [`docs/local-first-code-quality-epic.md`](./docs/local-first-code-quality-epic.md) | **Canonical retrospective** of the multi-phase local-first epic (2026-03-25 → 2026-04-09). Includes the executive summary, phase-by-phase journey, full repo inventory, PR ledger, reference cards, validation evidence, and lessons learned. The "how did we get here and what's the complete state" doc. |
| [`docs/local-code-review-options.md`](./docs/local-code-review-options.md) | Research notes (2026-03) on local review tooling — Semgrep, Sentry/Seer, adversarial reviewer enhancements — that informed the eventual design. |
| [`docs/plans/2026-03-25-infrastructure-consolidation-design.md`](./docs/plans/2026-03-25-infrastructure-consolidation-design.md) | The umbrella plan: one repo, one clone, one install, with `install.sh` symlinking everything into place. |
| [`docs/plans/2026-04-02-phase2-local-whole-codebase-review.md`](./docs/plans/2026-04-02-phase2-local-whole-codebase-review.md) | Phase 2 design — *why* whole-codebase review and *what* it replaces from Seer. |
| [`docs/plans/2026-04-02-phase2-implementation.md`](./docs/plans/2026-04-02-phase2-implementation.md) | Phase 2 implementation plan, task by task. |

Plus a `.claude/` directory with project-local Claude Code configuration **templates** (`config.sh.template`, hook extension example) that other repos can copy and customize. See [`.claude/README.md`](./.claude/README.md) for the template setup guide.

---

## Where the implementations live

The spec in this repo is implemented across several other repositories. None of them duplicate logic — they reference each other through the symlinks established by the consolidation plan.

| Repo | What it contains |
| --- | --- |
| [`smartwatermelon/claude-config`](https://github.com/smartwatermelon/claude-config) | The actual Claude Code hooks: `pre-merge-review.sh`, `run-review.sh`, `merge-lock.sh`, `lib-review-issues.sh`. Symlinked into `~/.claude/` on each machine. |
| [`smartwatermelon/claude-wrapper`](https://github.com/smartwatermelon/claude-wrapper) | Bash wrapper around the `claude` CLI, symlinked to `~/.local/bin/claude` so it shadows the real binary in `$PATH`. Resolves per-project 1Password secrets via `op inject`, injects `--remote-control` session names for interactive sessions, and validates binary ownership/permissions before `exec`. |
| [`smartwatermelon/dotfiles`](https://github.com/smartwatermelon/dotfiles) | The global git hooks (`pre-commit`, `pre-push`, `commit-msg`, etc.) at `git/hooks/`, symlinked from `~/.config/git/hooks/`. Also hosts shared shell utilities like `lint-shell.sh`. |
| [`smartwatermelon/github-workflows`](https://github.com/smartwatermelon/github-workflows) | The reusable GitHub Actions workflows (`claude-blocking-review.yml`, `claude-assistant.yml`) called by every owned repo's `.github/workflows/` caller. Plus `claude-review-audit.sh` for fleet-wide configuration auditing. |
| [`smartwatermelon/ralph-burndown`](https://github.com/smartwatermelon/ralph-burndown) | The tech-debt burndown tool that picks up non-blocking issues filed by the local Phase 2 review and works through them overnight. |

The global pre-commit framework config lives at `~/.config/pre-commit/config.yaml` (sourced from the pre-commit setup, not currently in any repo by itself).

---

## The system in one paragraph

Every commit goes through a global git pre-commit hook that runs format/lint/security checks (`prettier`, `eslint` where local, `shellcheck`, `yamllint`, `markdownlint`, `html-tidy`, `black`, `flake8`, `semgrep`, plus per-repo overrides) followed by two Claude-powered review agents (`code-reviewer` and `adversarial-reviewer`, with elevated scrutiny for security-critical files). Every push goes through a pre-push hook that runs Claude in two more modes — full-diff review and whole-codebase review with full filesystem access — and files non-blocking findings as GitHub issues for the burndown tool. Every merge is gated by `pre-merge-review.sh`, which fetches PR comments, CI status, and inline review threads, and uses Claude to produce a `SAFE_TO_MERGE` / `BLOCK_MERGE` verdict. CI on the GitHub side runs only the *focused summarizer review* (the reusable `claude-blocking-review.yml` workflow), tests, and deploys — every other CI lint job has been removed because it was duplicating local enforcement. Sentry/Seer findings flow through as advisory inline-comment input but never block.

For the full architecture, see [`docs/WORKFLOW-DEEP-DIVE.md`](./docs/WORKFLOW-DEEP-DIVE.md). For the journey that produced it, see [`docs/local-first-code-quality-epic.md`](./docs/local-first-code-quality-epic.md).

---

## Status

| Phase | Date | Status |
| --- | --- | --- |
| Phase 1 — Enhanced local review | 2026-03-25 | ✅ Complete |
| Phase 2 — Whole-codebase review | 2026-04-02 | ✅ Complete |
| Phase 3 — Final alignment | 2026-04-09 | ✅ Complete |

The spec is considered stable. Future work tracked as issues in this repo or in the implementation repos linked above.

---

## Working in this repo

- All content is Markdown — no build step, no tests, no lint commands beyond `markdownlint`
- Documents follow the existing structure: design plans use date-prefixed names under `docs/plans/`, reference docs live in `docs/` directly
- When updating reference docs, prefer **adding** sections to **rewriting** them — the goal is a permanent record, not a moving target
- The `.claude/` directory contains *templates* meant to be copied into other repos; do not add project-specific values to them

When Claude is making changes here, it follows the same protocols as everywhere else: feature branch, pre-commit review, pre-push codebase review, two-turn merge with `merge-lock auth`. See [`CLAUDE.md`](./CLAUDE.md) for the project-specific guidance Claude receives when working in this repo.

---

## Why this repo exists

Originally framed as "one canonical reusable workflow," but in practice the more useful artifact turned out to be the *spec and standards* themselves — the written record of what the system does, what it doesn't do, and why. The reusable workflow lives at [`smartwatermelon/github-workflows`](https://github.com/smartwatermelon/github-workflows); this repo is the documentation that explains how it fits into a larger local-first code quality system, what the constraints are, and how to add new repos to the fleet without re-deriving the design.
