# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo is the **dev-env infrastructure repository** — it contains documentation, design plans, templates, and hook extensions for Andrew's Claude Code development environment. It is not an application codebase; there are no build, test, or lint commands.

## Repository Structure

- `docs/` — Design documents, workflow deep dives, and research notes
  - `docs/plans/` — Implementation plans (e.g., infrastructure consolidation)
  - `docs/WORKFLOW-DEEP-DIVE.md` — Comprehensive reference for all enforcement layers (hooks, wrappers, CI/CD)
  - `docs/local-code-review-options.md` — Research on local review tooling (Semgrep, Sentry/Seer, adversarial reviewer enhancements)
- `.claude/` — Project-specific Claude Code configuration templates
  - `.claude/config.sh.template` — Template for project configuration (Node version, required tools, deployment secrets, build/deploy hooks)
  - `.claude/hooks/extensions/` — Project-specific git hook extensions (discovered and run by global hooks at `~/.config/git/hooks/`)
  - `.claude/README.md` — Setup guide for using the `.claude/` directory in other projects

## Key Concepts

**Global infrastructure lives at `~/.claude/` and `~/.config/git/hooks/`** — this repo documents and plans changes to that infrastructure, but the live infrastructure is installed globally, not here. Changes here are design docs and templates meant to be copied/symlinked into the global locations.

**The infrastructure consolidation plan** (`docs/plans/2026-03-25-infrastructure-consolidation-design.md`) is the active roadmap. It aims to make this repo the single source of truth with an `install.sh` that symlinks everything into place (blue/green settings merge, idempotent installs).

## Working in This Repo

- Documents are Markdown — no build step required
- When editing design plans, preserve the existing structure and status markers
- Hook extensions follow the contract: exit 0 = pass, exit 1 = block; see `example.sh.disabled` for the template
- `config.sh.template` is a reference template — don't add project-specific values to it
