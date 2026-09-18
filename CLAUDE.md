# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is the **dev-env infrastructure repository** — it contains documentation, design plans, templates, and hook extensions for Andrew's Claude Code development environment. It is not an application codebase and there is no build step, but it is not command-free either:

- **Tests**: `bash scripts/org-migration/tests/run-tests.sh` runs the hermetic stub-`gh` suite for the org-migration tooling. Run it after any change under `scripts/org-migration/`. `bash scripts/dependabot-digest/tests/run-tests.sh` covers the Dependabot digest classifier and renderer; run it after any change under `scripts/dependabot-digest/`.
- **Lint**: `shellcheck -S info <script>` applies to every shell script in the repo, and must be clean with no `# shellcheck disable` directives.

## Repository Structure

- `docs/` — Design documents, workflow deep dives, and research notes
  - `docs/STATUS.md` — Point-in-time project status: what's done, what's next, what's deferred by decision. Start here.
  - `docs/plans/` — Implementation plans (e.g., infrastructure consolidation)
  - `docs/WORKFLOW-DEEP-DIVE.md` — Comprehensive reference for all enforcement layers (hooks, wrappers, CI/CD)
  - `docs/local-code-review-options.md` — Research on local review tooling (Semgrep, Sentry/Seer, adversarial reviewer enhancements)
  - `docs/runbooks/` — Step-by-step manual procedures (UI actions the agent cannot perform)
  - `docs/token-rotation.md` — Where each `CLAUDE_CODE_OAUTH_TOKEN` lives and when it expires; never contains a token
  - `docs/runbooks/fleet-probe-token-scopes.md` — The two fine-grained-PAT properties a fleet probe needs (`Administration: Read-only` + All-repositories), and why an under-scoped token returns wrong numbers instead of errors
- `scripts/org-migration/` — Snapshot/transfer/verify tooling for the 2026-09 org migration; tests in `scripts/org-migration/tests/run-tests.sh`
- `scripts/dependabot-digest/` — Collects open Dependabot PRs across all three owners and upserts one digest issue describing the queue; run by `.github/workflows/dependabot-digest.yml`. Tokens are installed by hand: see `docs/runbooks/dependabot-digest-tokens.md`
- `.claude/` — Project-specific Claude Code configuration templates
  - `.claude/config.sh.template` — Template for project configuration (Node version, required tools, deployment secrets, build/deploy hooks)
  - `.project-hooks/pre-commit` and `.project-hooks/pre-push` — Project-specific git hook extensions, run by the global hooks at `~/.config/git/hooks/` when executable
  - `.claude/README.md` — Setup guide for using the `.claude/` directory in other projects

## Key Concepts

**Global infrastructure lives at `~/.claude/` and `~/.config/git/hooks/`** — this repo documents and plans changes to that infrastructure, but the live infrastructure is installed globally, not here. Changes here are design docs and templates meant to be copied/symlinked into the global locations.

**`docs/STATUS.md` is the active roadmap** — it records where the infrastructure backlog stands and what to pick up next. The design docs under `docs/superpowers/specs/` are authoritative on *what* each item is and why; `STATUS.md` is authoritative on *where things stand*.

**The March 2026 infrastructure consolidation plan** (`docs/plans/2026-03-25-infrastructure-consolidation-design.md`) is **superseded — Phases 3–5 are abandoned.** Do not resurrect its repo layout, its `ci-gate.yml`, or its step archiving `smartwatermelon/github-workflows` (now the load-bearing home of `standards-check.yml`). Its `install.sh`/`uninstall.sh` target state also contradicts `README.md:7`, which says this repo is "not a tool, framework, or installable package."

## Working in This Repo

- Documents are Markdown — no build step required
- When editing design plans, preserve the existing structure and status markers
- Hook extensions follow the contract: exit 0 = pass, exit 1 = block. They live in `.project-hooks/`, named for the hook they extend, and must be executable to run
- `config.sh.template` is a reference template — don't add project-specific values to it
