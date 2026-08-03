# Local AI Code Review: Options for Production-Bug Awareness

_March 23, 2026 — Research report for Kebab Tax project_

---

## Problem Statement

The Sentry Seer Code Review agent (running in GitHub Actions) consistently catches
bugs that local review layers miss — particularly logic errors, cross-file integration
issues, and patterns known to cause production failures. Each CI run costs Actions
minutes. The question: **can we get comparable production-bug-aware review running
locally, before pushing?**

Seer's advantage isn't project-specific production telemetry (it rarely references our
Sentry issues directly). It draws on a broad knowledge base of what causes production
failures across codebases — null refs in edge cases, race conditions, missing error
handling, async pitfalls, platform-specific assumptions. That's a learnable skill, not
a proprietary dataset.

---

## Option 1: CodeRabbit CLI

**What it is**: Free CLI tool that reviews staged/unstaged changes locally before push.

**Install**:

```bash
curl -fsSL https://cli.coderabbit.ai/install.sh | sh
```

**How it works**: Runs in terminal against local diffs. Line-by-line suggestions with
one-click fixes. Has a Claude Code plugin (as of Feb 2026) for tighter integration.

**Strengths**:

- Zero-config — install and run
- Free tier available (rate-limited)
- Reviews uncommitted changes (no PR needed)
- Production-bug-aware: trained on broad codebase patterns

**Weaknesses**:

- Cloud-dependent: code is sent to CodeRabbit's servers for analysis
- Not self-hostable without Enterprise plan ($15k+/month, 500-seat minimum)
- Rate limits on free tier may be restrictive for heavy commit workflows
- Known for verbosity (most common complaint across G2/Reddit/DevTools Academy reviews)

**Fit for our workflow**: Low friction to try. Could run as a pre-push check alongside
existing hooks. The cloud dependency is the main concern — our code leaves the machine.

**References**:

- <https://www.coderabbit.ai/cli>
- <https://docs.coderabbit.ai/cli/cli-with-self-hosted-CodeRabbit>

---

## Option 2: Qodo PR-Agent (Self-Hosted)

**What it is**: Open-source AI PR review agent. Fully self-hosted, bring your own LLM.

**Install**:

```bash
pip install pr-agent
export ANTHROPIC_API_KEY=your_key_here
```

**How it works**: Can run locally against a PR URL or be configured as a local service.
Supports Anthropic, OpenAI, and local models via Ollama. You control what leaves your
machine (only LLM API calls).

**Strengths**:

- Fully open source (Apache 2.0)
- Self-hosted at no software cost — you pay only LLM API charges
- Supports Claude as the backing model
- Rich review output: security, correctness, performance
- Can be integrated into git hooks or run on-demand

**Weaknesses**:

- Designed primarily for PR-URL-based review (GitHub/GitLab), not raw local diffs
- Ollama integration has a known config bug (Issue #2098) that can cause it to
  ignore local endpoint settings and default to OpenAI — a blocker for air-gapped use
- More setup overhead than CodeRabbit CLI
- Community-maintained; Qodo's commercial focus has shifted to Qodo Merge (hosted)

**Fit for our workflow**: Best option if we want full control over data flow. Would
need some integration work to run against local diffs in our pre-commit hook rather
than requiring a PR URL. The Anthropic API cost is minimal per review.

**References**:

- <https://github.com/qodo-ai/pr-agent>
- <https://qodo-merge-docs.qodo.ai/installation/locally/>

---

## Option 3: Semgrep (Deterministic Static Analysis)

**What it is**: Pattern-matching static analysis with 600+ pro rules covering
known vulnerability and bug patterns. Fully offline, no AI, no cloud.

**Install**:

```bash
pip install semgrep
semgrep scan --config auto .
```

**How it works**: Scans code against a rule database of known anti-patterns. Rules
are written by Semgrep's security research team based on real-world production
incidents. Supports TypeScript/TSX/React.

**Strengths**:

- Entirely local — code never leaves the machine
- Deterministic: same input always produces same output (no LLM variance)
- Fast — runs in seconds, not minutes
- 600+ pro rules (free with login) covering injection, deserialization, race
  conditions, and more
- Custom rules are easy to write for project-specific patterns
- Excellent CI integration if we want both local and CI coverage

**Weaknesses**:

- Pattern-matching, not reasoning — catches known anti-patterns but not novel logic bugs
- React Native coverage is partial (React web is better supported)
- Cannot reason about cross-file data flow or architectural concerns
- Won't catch "this works but will break in production under load" style issues

**Fit for our workflow**: Complementary to AI review, not a replacement. Worth adding
to pre-commit alongside existing hooks. It catches a different class of bugs
(known vulnerability patterns) that our AI reviewers might miss, and vice versa.

**References**:

- <https://semgrep.dev/docs/getting-started/cli>
- <https://semgrep.dev/docs/semgrep-code/pro-rules>

### Convention: scoping out pre-existing findings with `.semgrepignore`

`semgrep scan --staged` is not a valid flag — it doesn't exist. Our pre-commit
hook therefore runs `semgrep scan --config auto --error --quiet .`, which scans
the whole tracked repo on every commit, not just the staged diff. This means
pre-existing findings on files unrelated to the current change can block a
commit that never touched those files (see
[smartwatermelon/dev-env#1](https://github.com/smartwatermelon/dev-env/issues/1)
for the full analysis of alternatives).

The recommended fix, validated in practice in `smartwatermelon/tensegrity`
(2026-04-09) when pre-existing findings in a standalone PoC/scratch HTML
directory — pulling Three.js from a CDN without SRI — blocked an unrelated
commit, is a per-repo `.semgrepignore` file at the repo root:

- Scope it narrowly — specific paths, not broad excludes. The goal is to mask
  known, accepted findings on files that don't ship or aren't security-relevant,
  not to weaken scanning generally.
- Put an inline comment above each entry explaining _why_ it's excluded (e.g.,
  non-shipped scratch/PoC code, never loaded by the app, not exposed to users).
  A bare path with no justification is not reviewable.
- Land it as its own `chore:` commit, separate from whatever cleanup or feature
  work prompted the discovery — this keeps the carve-out easy to review and
  easy to revert independently.

This is the recommended alternative to filtering the `semgrep scan` invocation
itself to staged-file targets (e.g. `git diff --cached --name-only`), which was
considered and rejected in issue #1 in favor of this approach, because
`.semgrepignore`:

1. Is explicit, reviewable, and version-controlled — the exclusion is visible
   in the diff, not implicit in how the hook happens to invoke semgrep.
2. Travels with the repo, not the developer's machine — anyone who clones the
   repo gets the same exclusion, so the hook behaves consistently everywhere.
3. Leaves security-critical paths scanned by default — only paths explicitly
   listed are skipped, so a mistake here is narrow and visible in the diff.
4. Still surfaces new finding classes on non-excluded paths — only
   pre-existing findings on the excluded path are masked, not future ones
   elsewhere.

Example (illustrative, not tied to any specific repo):

```
# Standalone PoC demo pulling Three.js from a CDN without SRI hashes.
# Non-shipped scratch code: never bundled, never loaded by the app, not
# exposed to users. Pinning to integrity hashes here would be churn with
# no security benefit — excluding rather than fixing.
poc/three-js-demo/
```

---

## Adopted: zizmor (GitHub Actions Security Linting)

**Status**: Landed via pre-commit (Tier 3 follow-up to the 2026-04-29 GitHub
Actions security audit — see
[smartwatermelon/dev-env#19](https://github.com/smartwatermelon/dev-env/issues/19)).

**What it is**: [`zizmor`](https://github.com/woodruffw/zizmor) is a Rust
static analyzer purpose-built for GitHub Actions workflows. It catches classes
of risk that generic linters don't reason about:

- `dangerous-triggers` — insecure trigger patterns (`pull_request_target` with
  checkout, `issue_comment` combined with untrusted input)
- `cache-poisoning` — untrusted cache restoration paths
- `unpinned-uses` — third-party actions pinned to a mutable tag instead of a
  commit SHA
- `template-injection` — `${{ github.event.* }}` interpolated directly into a
  `run:` block
- `excessive-permissions` — overly broad `permissions:` blocks

**Why adopted**: The 2026-04-29 audit found instances of several of these
patterns across 31 workflow files in 29 repos (see issue #19 for the full
list of landed fix PRs). Tier 1 and Tier 2 fixed what the manual scan found;
this (Tier 3) automates the scan so future drift is caught at commit time
instead of waiting for the next manual audit.

**How it's wired up**: Added as a `repo: local` hook in the shared
pre-commit-framework config (`~/.config/pre-commit/config.yaml`, symlinked
from `dotfiles/pre-commit/config.yaml`), following the same convention as the
existing `yamllint`/`markdownlint`/`luacheck` entries in that file — shell out
to a Homebrew-installed binary rather than depend on a hosted pre-commit
hooks repo. The hook is scoped with `files: ^\.github/workflows/.*\.ya?ml$`
so it only runs when a commit touches workflow files, not on every commit in
every repo:

```yaml
- repo: local
  hooks:
    - id: zizmor
      name: "GitHub Actions Security Lint (zizmor)"
      entry: zizmor
      language: system
      files: ^\.github/workflows/.*\.ya?ml$
      pass_filenames: true
      verbose: true
```

**Prerequisite**: `language: system` hooks expect the binary to already be on
`PATH`. Run `brew install zizmor` once per machine before this hook can fire;
it is not installed automatically by the pre-commit-framework itself.

**Scope note — CI-side enforcement is NOT done**: Issue #19 also proposed a
second integration path — a reusable `zizmor.yml` GitHub Action in
`smartwatermelon/github-workflows` that repos could call as a second-line CI
catch on PRs (in addition to, not instead of, the pre-commit hook). **That
work has not been started.** Only the pre-commit path above has landed. Do
not treat CI-side zizmor coverage as in progress or partially done — it is a
distinct, not-yet-scoped follow-up.

**References**:

- <https://github.com/woodruffw/zizmor>
- <https://docs.zizmor.sh/>
- <https://docs.zizmor.sh/audits/> (full list of audit rules referenced above)

---

## Option 4: Enhance the Adversarial Reviewer

**What it is**: Upgrade our existing `adversarial-reviewer` agent with lessons learned
from what CI review catches that local review misses.

### Current State

The adversarial reviewer (v1.3.0) is a 203-line agent prompt that runs on every commit
via the `~/.config/git/hooks/pre-commit` hook. It's invoked through `run-review.sh`
(736 lines of orchestration). Key characteristics:

- **Persona**: Senior staff engineer, 25+ years experience, assumes code is wrong
  until proven otherwise
- **Review hierarchy**: Purpose > Data model > Architecture > Failure modes >
  Maintenance > Implementation
- **Failure mode checklist**: 8 categories (concurrency, resources, distributed
  systems, error handling, security, data integrity, observability, domain-specific)
- **Severity calibration**: Critical (blocks) / Concern (should fix) / Question
  (needs justification)
- **Scope**: Per-commit diff with limited surrounding context

### What CI Review Catches That Local Review Misses

Analysis of recent PR reviews (#1028, #1030, #1032, #1042) reveals consistent gaps:

| Gap | Example | Root Cause |
| ----- | --------- | ------------ |
| **Cross-file integration** | Feature mention removed from HomeScreen without checking discovery elsewhere | Per-commit scope can't see full feature surface |
| **Platform-specific paths** | Android code path untested when `Platform.OS` guard added | Diff review doesn't consider both platform paths |
| **Silent failure modes** | `ANDROID_HOME` silently passes empty string instead of failing | Requires reasoning about what happens when env vars are unset |
| **Test interaction bugs** | Missing `afterEach` timer cleanup breaks downstream tests | Requires understanding test runner shared state |
| **ID/selector collisions** | `testID` collision when both new and existing items render | Requires knowing what other components use the same ID |
| **Async chain gaps** | Missing `await` in promise chains | Diff may not show the full async call stack |
| **RLS policy weakening** | Supabase auth bypass when policy conditions relaxed | Requires domain-specific security awareness |

### Documented Local Review Shortcomings

From `ci-reviewer-shortcomings.md` and MEMORY.md:

- **Code-order analysis errors**: Has issued false BLOCKs claiming execution order
  was wrong when it was actually correct
- **First BLOCK misdiagnosis**: May correctly identify a real gap but point to the
  wrong root cause
- **Inconsistent verdict calibration**: Unclear threshold between BLOCK and PASS
- **Cross-cutting blindness**: Per-commit diffs cannot see feature-level implications

### Proposed Enhancements

#### 4A. Add a "production patterns" checklist section

Encode the specific patterns CI review repeatedly catches. Add to the failure mode
checklist:

```markdown
### Production Failure Patterns (learned from CI review gaps)

- **Platform guards without dual-path testing**: When `Platform.OS` or similar
  guards are added, flag if the non-default path lacks test coverage
- **Silent env var failures**: When environment variables are read, flag if there's
  no validation/fallback for empty or undefined values
- **Test isolation**: When test setup/teardown uses timers, mocks, or global state,
  flag if cleanup is missing in afterEach/afterAll
- **Selector/ID uniqueness**: When testIDs or query selectors are added, flag
  potential collision with existing components that render in the same context
- **Feature discoverability**: When user-facing text or UI entry points are removed
  or renamed, flag if the feature is still discoverable through other paths
- **Async error boundaries**: When promise chains cross file boundaries, flag if
  errors can silently swallow without propagating to a handler
- **RLS policy changes**: Any modification to Supabase RLS policies is automatically
  critical — flag for explicit security review
```

#### 4B. Add a cross-file awareness prompt section

The current reviewer explicitly states it only sees the diff. We can improve this
by instructing it to request context:

```markdown
### Cross-File Awareness (diff-only mode)

When reviewing changes that:
- Remove or rename user-facing strings → ask: "Is this feature still discoverable?"
- Add platform-specific guards → ask: "Is the other platform path tested?"
- Modify shared state or IDs → ask: "What else uses this identifier?"
- Change error handling → ask: "Where does this error propagate to?"

Frame these as Questions in the review output, not assumptions. The developer
can answer them before pushing.
```

#### 4C. Calibrate severity based on CI findings

Adjust the severity thresholds based on what actually caused CI blocks:

```markdown
### Severity Calibration Update

Promote to Critical (was Concern):
- Missing afterEach cleanup when test modifies global state (timers, mocks)
- Platform-specific code path with no test for the non-default platform
- Environment variable read with no empty/undefined guard

Promote to Concern (was Question):
- Removed UI copy that was the only entry point to a feature
- testID/selector added without checking for existing usage
```

#### 4D. Increase diff context window

The `run-review.sh` script passes diffs with default git context (3 lines). For
production-pattern detection, more context helps:

```bash
# In run-review.sh, change diff generation to:
git diff --cached -U10  # 10 lines of context instead of 3
```

This gives the reviewer more surrounding code to reason about without requiring
full file reads.

### Estimated Effort

| Enhancement | Effort | Impact |
| ------------- | -------- | -------- |
| 4A: Production patterns checklist | ~30 min (prompt edit) | High — directly addresses known gaps |
| 4B: Cross-file awareness prompts | ~15 min (prompt edit) | Medium — generates useful questions |
| 4C: Severity recalibration | ~15 min (prompt edit) | Medium — fewer false negatives |
| 4D: Increased diff context | ~5 min (script edit) | Low-medium — marginal improvement |

Total: ~1 hour of work, no new tooling, no new dependencies, no cost increase.

---

## Comparison Matrix

| Criterion | CodeRabbit CLI | PR-Agent | Semgrep | Enhanced Adversarial |
| ----------- | --------------- | ---------- | --------- | --------------------- |
| **Cost** | Free (rate-limited) | LLM API only | Free | Free (existing) |
| **Code leaves machine** | Yes (cloud) | Yes (LLM API) | No | Yes (LLM API) |
| **Setup effort** | 1 min | 30 min | 5 min | 1 hour |
| **Novel logic bugs** | Good | Good | No | Good |
| **Known vuln patterns** | Some | Some | Excellent | Some |
| **Cross-file reasoning** | Limited | Good (PR-scoped) | No | Limited (but improved) |
| **React Native aware** | General | General | Partial | Yes (custom) |
| **Integrates with hooks** | Manual | Manual | Easy | Already integrated |
| **Production-pattern aware** | General | General | Rule-based | Custom to our gaps |

---

## Recommendation

**Do all of these, in order of effort**:

1. **Option 4 first** (~1 hour): Enhance the adversarial reviewer with production
   patterns learned from CI review gaps. Zero new dependencies, zero new cost,
   directly targets the specific classes of bugs we're missing. This is the highest
   ROI action.

2. **Option 3 next** (~5 min): Add Semgrep to pre-commit. It's orthogonal — catches
   deterministic vulnerability patterns that no AI reviewer reliably catches. One
   `pip install` and a hook addition.

3. **Option 1 to evaluate** (~1 min): Try CodeRabbit CLI on a few commits to
   benchmark against our enhanced adversarial reviewer. If it consistently finds
   things ours misses, keep it. If not, drop it.

4. **Option 2 if needed**: PR-Agent is the nuclear option — full self-hosted AI
   review with your own Claude API key. Only worth the setup cost if Options 1-4
   aren't closing the gap.

The goal isn't to replace CI review entirely — some things genuinely require the full
PR surface. The goal is to **catch locally what CI review catches that shouldn't
require full PR context**, and reduce the expensive push-fix-push iterations.
