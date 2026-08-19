# Cost/Performance Follow-Ups: Model Tiering Gaps

**Date**: 2026-07-31
**Purpose**: Track the three findings from a review of this environment against Anthropic's
["Claude model and effort level in Claude Code"](https://claude.com/blog/claude-model-and-effort-level-in-claude-code)
and ["Steering Claude Code"](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)
guidance that were **not** quick wins — each needs either a script change with a design
decision, a cross-repo workflow edit, or new functionality in `claude-wrapper`.

Two related quick wins were already applied directly (see `claude-config` branch
`claude/cost-perf-tuning-6c1fb7d3`):

- `pre-merge-review.sh` now documents its intentional model inheritance and exposes a
  `review.mergeModel` override, instead of silently riding the caller's model by omission.
- `alwaysThinkingEnabled` flipped from a global `true` to `false` in `settings.json`, so
  extended thinking is opt-in per repo rather than forced everywhere including docs-only
  repos like this one.

This doc's three items are more involved and are tracked as GitHub issues (linked below)
rather than applied immediately.

---

## 1. `adversarial-reviewer` shares a model tier with `code-reviewer`

**Where**: `~/.claude/hooks/run-review.sh` (`claude-config` repo), `invoke_agent()` /
`MODEL_ARGS` construction around lines 100-124.

**Problem**: `REVIEW_MODEL` is computed once per review run and applied uniformly to both
agents. `code-reviewer` (mechanical issue-spotting: style, obvious bugs, missing null
checks) is a legitimate Haiku task. `adversarial-reviewer` (assume-wrong-until-proven,
failure-mode/architecture reasoning per `docs/local-code-review-options.md`) is exactly the
"ambiguous, needs-to-know-more" case the model article says should get a bigger model —
yet it runs on the same Haiku default for every commit.

**Proposed fix**: Add a second override, `review.adversarialModel`, defaulting to Sonnet
(`claude-sonnet-4-6`) regardless of `REVIEW_MODE`, while leaving `code-reviewer`'s existing
mode-based default (Haiku for `commit`, Sonnet for `full-diff`/`codebase`) untouched.
`invoke_agent()` would need to accept a model-args parameter per call instead of one shared
`MODEL_ARGS` global.

**Open question**: this doubles the cost of the adversarial pass specifically on
commit-mode runs (the highest-frequency case). Worth checking actual commit volume before
committing to "always Sonnet for adversarial" vs. a cheaper middle ground (e.g. Sonnet only
in `full-diff`/`codebase` mode, Haiku still for pure commit-mode WIP).

**Tracking**: to be filed as a GitHub issue in `smartwatermelon/claude-config`.

---

## 2. Advisory PR-review workflow's trigger scope and model

**Where**: `claude-code-review.yml` pattern (per `docs/WORKFLOW-DEEP-DIVE.md` — the
non-blocking companion to `claude-blocking-review.yml`, which lives in app repos, not this
one). Reusable workflow presumably in `smartwatermelon/github-workflows`.

**Problem**: Per the deep-dive doc, this workflow fires on `synchronize` (every push), not
just `opened`/`reopened`, with no `model:` input pinned (defaults to whatever
`anthropics/claude-code-action@v1` uses by default — likely pricier than Haiku). By
contrast, `claude-blocking-review.yml` was deliberately pinned to
`claude-haiku-4-5-20251001` in commit #27 of this repo. The advisory workflow is the
highest-frequency, lowest-marginal-value spend in the pipeline: local `run-review.sh` and
the blocking CI review already cover every commit/PR-open, so an advisory re-review on
every incremental push mostly restates prior findings.

**Note**: this is a distinct question from the 2026-05-18 spend audit's Tier-4
recommendation to eliminate the *blocking* review entirely — per
[CI review strategy](../../CLAUDE.md) memory, that decision was already made to **keep**
Claude blocking review and target Seer for removal instead. This item is scoped to the
advisory workflow's trigger frequency and model, not re-litigating that decision.

**Proposed fix** (pick one, or both):

- Drop `synchronize` from the advisory workflow's `on.pull_request.types`, keeping only
  `opened`/`ready_for_review`/`reopened` — matches the intent of "review once per PR
  lifecycle event that actually changes reviewer scope," not every incremental push.
- Pin `model: claude-haiku-4-5-20251001` on the advisory workflow, same as the blocking one.

**Cross-repo scope**: workflow YAML likely lives in `smartwatermelon/github-workflows`
(reusable) and/or per-repo `.github/workflows/claude-code-review.yml` — needs the actual
file located before editing (not present in this repo's `.github/workflows/`, confirmed
2026-07-31).

**Tracking**: to be filed as a GitHub issue in `smartwatermelon/github-workflows` (or the
first app repo where the file is found, if it's not centralized).

---

## 3. `claude-wrapper` has no per-project model/effort awareness

**Where**: `~/Developer/claude-wrapper` — already project-aware (session naming keys off
repo/directory in `lib/remote-session.sh`), already intercepts every `claude` invocation.

**Problem**: Model/effort selection is currently all-or-nothing via the global
`~/.claude/settings.json` (`effortLevel`, and until today `alwaysThinkingEnabled`). There's
no mechanism for e.g. defaulting `dev-env` (docs-only, no build/test/lint) to a cheaper
tier and an app repo with active debugging to a stronger one, short of hand-editing a local
`.claude/settings.json` per repo.

**Proposed fix**: Extend `claude-wrapper` to read an optional per-repo hint (e.g. a
`.claude/config.sh` value already templated in this repo's
`.claude/config.sh.template`, or a new key) and inject `--model`/`--effort-level` alongside
the existing `--remote-control` injection in `bin/claude-wrapper`. Needs a new
`lib/model-selection.sh` module, tests (mirroring `tests/test-remote-session.sh`'s
pattern), and a decision on the default tiering rules (e.g. by repo language/build
tooling, or an explicit opt-in list).

**Scope note**: this is the largest of the three — new functionality, not a config
tweak — and should go through the usual plan → subagent-driven execution flow, not be
done inline.

**Tracking**: to be filed as a GitHub issue in `smartwatermelon/claude-wrapper`.

---

## Summary Table

| # | Item | Repo | Effort | Status |
|---|------|------|--------|--------|
| — | Pin `pre-merge-review.sh` model intent + override | claude-config | Quick win | ✅ Done (branch `claude/cost-perf-tuning-6c1fb7d3`) |
| — | Disable global `alwaysThinkingEnabled` | claude-config | Quick win | ✅ Done (same branch) |
| 1 | Differentiate `adversarial-reviewer` model from `code-reviewer` | claude-config | Small (script change + design call) | 📋 Issue to file |
| 2 | Advisory PR-review: trim `synchronize` trigger, pin model | github-workflows (or app repo) | Small (once file is located) | 📋 Issue to file |
| 4 | `claude-wrapper` per-project model/effort selection | claude-wrapper | Medium (new module + tests) | 📋 Issue to file |
