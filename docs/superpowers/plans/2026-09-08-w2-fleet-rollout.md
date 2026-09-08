# W2: `standards-check.yml` Fleet Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the `standards-check.yml` caller stub as a NON-required check on every fleet repo, prove cross-repo tag resolution on one clean pilot, and clear the lint debt in waves so each repo can be flipped to required in W3.

**Architecture:** A new, small bulk-install script in `github-workflows` reads a canonical stub from that same repo, classifies each fleet repo (`MISSING` / `CURRENT` / `DIFFERS` / `IGNORED` / `ARCHIVED`), and writes the stub either via a branch+PR (pilots) or a direct Contents-API put to the default branch (fleet). Remediation is separate: one PR per repo per wave, verified locally with `standards/run-standards.sh` before push and by the now-installed non-required check after push. Nothing in this plan changes branch protection; that is W3.

**Tech Stack:** bash 5, `gh` (REST via `gh api`), a hermetic stub-`gh` test harness (pattern from `dev-env/scripts/org-migration/tests/`), the five pinned linters (`shellcheck 0.11.0`, `actionlint 1.7.12`, `zizmor 1.30.0`, `yamllint 1.38.0`, `markdownlint-cli2 0.23.2`).

**Spec:** `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md` (item W2) and `smartwatermelon/github-workflows#154` (Phases 3/4). Research inputs: `.superpowers/sdd/2026-09-08-w1-standards-check/w2-research.md`.

## Global Constraints

- Never commit on `main` in any clone, except via the direct-push mechanism authorized below (Task 5 only).
- `shellcheck -S info` clean on every shell file touched; no `# shellcheck disable`.
- Every behavior change has a test observed failing before the fix.
- Re-measure before acting on any number in this document; the lint-debt table was measured 2026-09-08 and repos change.
- Text files end with a newline.
- Use `git -C <abs path>`; never shell `cd`. Use `gh --repo owner/repo` explicitly; the pre-merge hook reads cwd.
- Every PR body ends with `https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf`; every commit ends with `Claude-Session: https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf`.
- Do NOT merge. Each PR needs a merge-lock from Andrew. Surface repo, number, URL, one line.

## Decisions recorded 2026-09-08 (Andrew)

| Question | Decision |
| --- | --- |
| Stub install mechanism | **Direct-push to main** for the fleet, after the pilots go through PRs. Andrew selected the option worded: "Contents API PUT with branch=main, the documented Phase 2 playbook pattern. Pilots go through PRs first. Needs your explicit written authorization for the Protocol 1 exception, recorded in the W2 plan." This selection is that authorization. **Scope of the exception:** one identical, non-required caller stub file (`.github/workflows/standards-check.yml`, content = `standards/caller-stub.yml` verbatim), created only where absent, on non-archived repos in `smartwatermelon`, `nightowlstudiollc`, and the five `twistedmelonman` repos. No other file, no edits to existing files, no remediation content, no protection changes. Anything outside this scope goes through a PR. |
| shellcheck severity in CI | **Keep `-S info`.** Same gate as local hooks. |
| Remediation waves, in order | **1. node-floor (3 repos). 2. zizmor pins (16 repos).** Andrew asked whether shellcheck and markdownlint can be combined; answer: yes. **3. Combined lint wave** (shellcheck + markdownlint + yamllint, one PR per repo, ~28 repos) is planned but gated behind waves 1–2 landing, so Andrew has a window to object before it starts. |

## Live state measured 2026-09-08

| Claim | Evidence |
| --- | --- |
| `standards-check-v1` tag not on remote | `git ls-remote --tags origin 'standards-check*'` empty at 14:20 PDT; Andrew pushes it by hand (human-only floating-tag policy). **Tasks 3+ block on this.** |
| `enforce_admins` off on protected branches | `false` on repo-template, pr-review, lock-sync, nightowlstudiollc/.github, kebab-tax, personify, homebrew-tap. Direct Contents-API put to `main` is therefore not blocked by the required-check rule. |
| Required context today | `claude-review / run-review` on every sampled repo (personify also `validate`). Standards check will be `standards-check / run-standards-check`. Not changed in W2. |
| `smartwatermelon/headroom` | 404. Dead entry in `.claude-review-ignore`; do not carry it forward. |
| `Gmail-MCP-Server` | 404 under both orgs. N1b's list is stale; the live node-floor set is `kebab-tax`, `reliquarist`, `gmail-newsletter-filter`. |
| Fleet lint debt | 31 of 37 non-pilot repos and 3 of 4 pilots fail today (table in the research file, §3). `::error::` bodies were not retained; Task 6 re-measures. |
| No canonical caller stub exists | `smartwatermelon/.github/workflow-templates/` has only the blocking-review and dependabot templates. |

## Interruption budget

Merge locks are the only recurring ask. Estimated count: tooling 1, pilots 4, node-floor 3, zizmor ~16, combined lint ~28, docs 1. **About 53 locks.** Remediation PRs are staged in rounds of no more than 10 open at once so locks come in sittings. The fleet stub install is 0 locks by decision.

## File Structure

In `smartwatermelon/github-workflows` (new files):

- `standards/caller-stub.yml` — the canonical caller, verbatim content that lands in every repo. Single source; the README's Setup block and the workflow's header comment must match it.
- `bulk-install-standards-check.sh` — classify + install. No dependency on `bulk-install-claude-review.sh` (that script is retired in W3).
- `.standards-check-ignore` — `owner/repo` per line; seeded with `nightowlstudiollc/networth-agent` only (mirrors the judgment-review exclusion; headroom is gone). Andrew can empty it later.
- `tests/test-bulk-install-standards-check.sh` — hermetic stub-`gh` tests.
- `tests/stub-gh/gh` — the stub.

In `smartwatermelon/dev-env` (this repo): this plan; `docs/STATUS.md` update in Task 10; scan output under `.superpowers/sdd/2026-09-08-w2-fleet-rollout/`.

---

### Task 1: Canonical stub, ignore file, and the classifier (dry-run only)

**Files:**

- Create: `github-workflows/standards/caller-stub.yml`
- Create: `github-workflows/.standards-check-ignore`
- Create: `github-workflows/bulk-install-standards-check.sh`
- Create: `github-workflows/tests/stub-gh/gh`
- Create: `github-workflows/tests/test-bulk-install-standards-check.sh`
- Test runner: `github-workflows/tests/run-tests.sh` (already globs `test-*.sh`)

**Interfaces:**

- Produces: `bulk-install-standards-check.sh [--apply] [--mode=pr|push] [--only owner/repo] [--owners a,b] [--extra-repos owner/repo,...]`. Exit 0 when every repo classified without `ERROR`; exit 1 otherwise. One line per repo: `<CLASS>  owner/repo  <note>`. Classes: `MISSING`, `CURRENT`, `DIFFERS`, `IGNORED`, `ARCHIVED`, `ERROR`.
- Env for tests: `BULK_GH=<path>` overrides the `gh` binary; `BULK_STUB_FILE=<path>` overrides the canonical stub path.

- [ ] **Step 1: Branch**

```bash
git -C /Users/andrewrich/Developer/github-workflows switch main
git -C /Users/andrewrich/Developer/github-workflows pull --ff-only
git -C /Users/andrewrich/Developer/github-workflows switch -c claude/feat-bulk-install-standards-check-019HDRKL
```

- [ ] **Step 2: Write the canonical stub**

`standards/caller-stub.yml`, exactly (this must byte-match the README Setup block at `README.md:412-424` and the header comment in `.github/workflows/standards-check.yml`; if they differ, the stub file wins and the other two are corrected in Step 9):

```yaml
name: Standards Check
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
permissions:
  contents: read
jobs:
  standards-check:
    uses: smartwatermelon/github-workflows/.github/workflows/standards-check.yml@standards-check-v1
```

- [ ] **Step 3: Write the ignore file**

`.standards-check-ignore`:

```text
# Repos that never get standards-check.yml installed by
# bulk-install-standards-check.sh. One owner/repo per line; # is a comment.
nightowlstudiollc/networth-agent
```

- [ ] **Step 4: Write the stub `gh`**

`tests/stub-gh/gh`. It answers the exact `gh api` / `gh repo list` / `gh pr create` shapes the script uses, driven by a fixture directory `STUB_DIR`, and appends every invocation to `${STUB_DIR}/calls.log`.

```bash
#!/usr/bin/env bash
# Stub gh for bulk-install-standards-check.sh tests. Fixture layout:
#   ${STUB_DIR}/repos/<owner>.json      -> output of `gh repo list <owner> --json ...`
#   ${STUB_DIR}/files/<owner>__<repo>   -> existing stub content, if the repo has one
#   ${STUB_DIR}/archived                -> owner/repo per line (isArchived=true)
#   ${STUB_DIR}/calls.log               -> every argv, one line each
set -euo pipefail
: "${STUB_DIR:?}"
printf '%s\n' "$*" >>"${STUB_DIR}/calls.log"
case "$1" in
  repo)
    # gh repo list <owner> --json name,isArchived,defaultBranchRef --limit 200
    owner="$3"
    cat "${STUB_DIR}/repos/${owner}.json"
    ;;
  api)
    shift
    method="GET"
    path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --jq|-f|-F) shift 2 ;;
        -*) shift ;;
        *) path="$1"; shift ;;
      esac
    done
    case "${method} ${path}" in
      "GET repos/"*"/contents/.github/workflows/standards-check.yml")
        # repos/<owner>/<repo>/contents/...
        rest="${path#repos/}"; owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"
        f="${STUB_DIR}/files/${owner}__${repo}"
        if [[ -f "${f}" ]]; then
          printf '{"sha":"deadbeef","content":"%s"}\n' "$(base64 <"${f}" | tr -d '\n')"
        else
          echo '{"message":"Not Found","status":"404"}' >&2; exit 1
        fi ;;
      "GET repos/"*)
        # default-branch lookup: repos/<owner>/<repo>
        echo '{"default_branch":"main"}' ;;
      "PUT repos/"*"/contents/"*)
        echo '{"content":{"path":".github/workflows/standards-check.yml"},"commit":{"sha":"c0ffee"}}' ;;
      "POST repos/"*"/git/refs")
        echo '{"ref":"refs/heads/x"}' ;;
      "GET repos/"*"/git/ref/heads/main")
        echo '{"object":{"sha":"abc123"}}' ;;
      *) echo "stub gh: unhandled ${method} ${path}" >&2; exit 99 ;;
    esac
    ;;
  pr)
    echo "https://github.com/stub/pr/1"
    ;;
  *) echo "stub gh: unhandled $*" >&2; exit 99 ;;
esac
```

`chmod +x tests/stub-gh/gh`.

- [ ] **Step 5: Write the failing tests**

`tests/test-bulk-install-standards-check.sh`:

```bash
#!/usr/bin/env bash
# Hermetic tests for bulk-install-standards-check.sh against tests/stub-gh/gh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../bulk-install-standards-check.sh"
stub="${here}/../standards/caller-stub.yml"
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

_fixture() { # creates a fresh STUB_DIR with two owners, four repos
  STUB_DIR="$(mktemp -d)"; export STUB_DIR
  mkdir -p "${STUB_DIR}/repos" "${STUB_DIR}/files"
  cat >"${STUB_DIR}/repos/acme.json" <<'EOF'
[{"name":"alpha","isArchived":false,"defaultBranchRef":{"name":"main"}},
 {"name":"beta","isArchived":false,"defaultBranchRef":{"name":"main"}},
 {"name":"old","isArchived":true,"defaultBranchRef":{"name":"main"}}]
EOF
  cat >"${STUB_DIR}/repos/nite.json" <<'EOF'
[{"name":"gamma","isArchived":false,"defaultBranchRef":{"name":"main"}}]
EOF
  cp "${stub}" "${STUB_DIR}/files/acme__beta"          # beta already CURRENT
  printf 'name: Different\n' >"${STUB_DIR}/files/nite__gamma"  # gamma DIFFERS
  printf 'acme/alpha-ignored\n' >"${STUB_DIR}/ignore"
  : >"${STUB_DIR}/calls.log"
}

run() { BULK_GH="${here}/stub-gh/gh" BULK_STUB_FILE="${stub}" BULK_IGNORE_FILE="${STUB_DIR}/ignore" bash "${script}" --owners acme,nite "$@"; }

# 1. dry run classifies every repo and writes nothing
_fixture
out="$(run 2>&1)" || true
grep -q '^MISSING   *acme/alpha' <<<"${out}" && _ok "alpha is MISSING" || _bad "alpha classification: ${out}"
grep -q '^CURRENT   *acme/beta'  <<<"${out}" && _ok "beta is CURRENT"  || _bad "beta classification"
grep -q '^ARCHIVED  *acme/old'   <<<"${out}" && _ok "old is ARCHIVED"  || _bad "old classification"
grep -q '^DIFFERS   *nite/gamma' <<<"${out}" && _ok "gamma is DIFFERS" || _bad "gamma classification"
grep -q 'PUT' "${STUB_DIR}/calls.log" && _bad "dry run wrote a file" || _ok "dry run wrote nothing"

# 2. --apply --mode=push PUTs only the MISSING repo, onto its default branch
_fixture
run --apply --mode=push >/dev/null 2>&1 || true
puts="$(grep -c 'PUT repos/' "${STUB_DIR}/calls.log" || true)"
[[ "${puts}" == "1" ]] && _ok "push mode: exactly one PUT" || _bad "push mode: ${puts} PUTs"
grep -q 'PUT repos/acme/alpha/contents/.github/workflows/standards-check.yml' "${STUB_DIR}/calls.log" && _ok "PUT targets alpha" || _bad "PUT target"
grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'branch=main' && _ok "PUT goes to main" || _bad "PUT branch"
grep -q 'git/refs' "${STUB_DIR}/calls.log" && _bad "push mode created a branch" || _ok "push mode: no branch"

# 3. --apply --mode=pr creates a branch, PUTs onto it, opens a PR
_fixture
run --apply --mode=pr >/dev/null 2>&1 || true
grep -q 'POST repos/acme/alpha/git/refs' "${STUB_DIR}/calls.log" && _ok "pr mode: branch created" || _bad "pr mode: no branch"
grep 'PUT repos/acme/alpha' "${STUB_DIR}/calls.log" | grep -q 'branch=chore/standards-check-stub' && _ok "PUT goes to the feature branch" || _bad "PUT branch in pr mode"
grep -q '^pr create' "${STUB_DIR}/calls.log" && _ok "pr mode: PR opened" || _bad "pr mode: no PR"

# 4. DIFFERS is never written, in either mode
_fixture
run --apply --mode=push >/dev/null 2>&1 || true
grep -q 'PUT repos/nite/gamma' "${STUB_DIR}/calls.log" && _bad "DIFFERS was overwritten" || _ok "DIFFERS left alone"

# 5. ignore file honored; --only restricts
_fixture
printf 'acme/alpha\n' >"${STUB_DIR}/ignore"
out="$(run 2>&1)" || true
grep -q '^IGNORED   *acme/alpha' <<<"${out}" && _ok "ignore file honored" || _bad "ignore file"
_fixture
out="$(run --only nite/gamma 2>&1)" || true
grep -q 'acme/' <<<"${out}" && _bad "--only leaked other repos" || _ok "--only restricts"

# 6. --extra-repos adds explicit owner/repo entries outside --owners
_fixture
mkdir -p "${STUB_DIR}/repos"; printf '[]\n' >"${STUB_DIR}/repos/solo.json"
out="$(run --extra-repos solo/thing 2>&1)" || true
grep -q '^MISSING   *solo/thing' <<<"${out}" && _ok "--extra-repos included" || _bad "--extra-repos: ${out}"

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
```

- [ ] **Step 6: Run the tests; observe failure**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-bulk-install-standards-check.sh`
Expected: FAIL on every case (script does not exist).

- [ ] **Step 7: Write the script**

`bulk-install-standards-check.sh`:

```bash
#!/usr/bin/env bash
# Install the standards-check.yml caller stub across the fleet.
#
# Classifies every non-archived repo of --owners (plus --extra-repos) as
# MISSING / CURRENT / DIFFERS / IGNORED / ARCHIVED / ERROR and, with --apply,
# writes the canonical stub (standards/caller-stub.yml) into MISSING repos.
#
#   --mode=pr    branch chore/standards-check-stub + Contents-API put + PR
#   --mode=push  Contents-API put straight onto the default branch. This is
#                the W2 Phase-2 mechanism Andrew authorized on 2026-09-08 for
#                this one file only (dev-env docs/superpowers/plans/
#                2026-09-08-w2-fleet-rollout.md, "Decisions"). Never extend
#                it to other content.
#
# Dry run is the default. DIFFERS repos are reported and never touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${BULK_GH:-gh}"
STUB_FILE="${BULK_STUB_FILE:-${here}/standards/caller-stub.yml}"
IGNORE_FILE="${BULK_IGNORE_FILE:-${here}/.standards-check-ignore}"
INSTALL_PATH=".github/workflows/standards-check.yml"
BRANCH="chore/standards-check-stub"
SESSION="https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf"

APPLY=false
MODE="pr"
ONLY=""
OWNERS="smartwatermelon,nightowlstudiollc"
EXTRA="twistedmelonman/dotfiles,twistedmelonman/claude-config,twistedmelonman/personify,twistedmelonman/huddle-transcribe,twistedmelonman/projectinsomnia"

usage() {
  cat <<EOF
Usage: ${0##*/} [--apply] [--mode=pr|push] [--only owner/repo] [--owners a,b] [--extra-repos o/r,...]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --mode=pr|--mode=push) MODE="${1#--mode=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --owners) OWNERS="$2"; shift 2 ;;
    --extra-repos) EXTRA="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "${STUB_FILE}" ]] || { echo "stub file not found: ${STUB_FILE}" >&2; exit 2; }
STUB_CONTENT="$(cat "${STUB_FILE}"; printf x)"; STUB_CONTENT="${STUB_CONTENT%x}"
STUB_B64="$(printf '%s' "${STUB_CONTENT}" | base64 | tr -d '\n')"

is_ignored() {
  [[ -f "${IGNORE_FILE}" ]] || return 1
  grep -v '^[[:space:]]*#' "${IGNORE_FILE}" | grep -qx "$1"
}

# Emits "owner/repo<TAB>archived(true|false)" lines.
list_repos() {
  local owner
  IFS=',' read -r -a owners <<<"${OWNERS}"
  for owner in "${owners[@]}"; do
    [[ -n "${owner}" ]] || continue
    "${GH}" repo list "${owner}" --json name,isArchived --limit 200 \
      | jq -r --arg o "${owner}" '.[] | "\($o)/\(.name)\t\(.isArchived)"'
  done
  if [[ -n "${EXTRA}" ]]; then
    local r
    IFS=',' read -r -a extras <<<"${EXTRA}"
    for r in "${extras[@]}"; do
      [[ -n "${r}" ]] && printf '%s\tfalse\n' "${r}"
    done
  fi
}

existing_content() { # owner/repo -> prints decoded content, or returns 1
  local body
  body="$("${GH}" api "repos/$1/contents/${INSTALL_PATH}" 2>/dev/null)" || return 1
  jq -r '.content' <<<"${body}" | tr -d '\n' | base64 -d
}

default_branch() { "${GH}" api "repos/$1" --jq .default_branch; }

put_file() { # owner/repo branch
  "${GH}" api -X PUT "repos/$1/contents/${INSTALL_PATH}" \
    -f message="ci: add standards-check.yml caller stub (non-required)

Installs the deterministic standards check as a non-required status.
It becomes required per repo in W3 once the repo is green.

Claude-Session: ${SESSION}" \
    -f content="${STUB_B64}" \
    -f branch="$2" >/dev/null
}

install_push() { # owner/repo
  local db; db="$(default_branch "$1")"
  put_file "$1" "${db}"
  echo "pushed to ${db}"
}

install_pr() { # owner/repo
  local db sha
  db="$(default_branch "$1")"
  sha="$("${GH}" api "repos/$1/git/ref/heads/${db}" --jq .object.sha)"
  "${GH}" api -X POST "repos/$1/git/refs" -f ref="refs/heads/${BRANCH}" -f sha="${sha}" >/dev/null
  put_file "$1" "${BRANCH}"
  "${GH}" pr create --repo "$1" --head "${BRANCH}" --base "${db}" \
    --title "ci: add standards-check.yml caller stub (non-required)" \
    --body "Installs \`standards-check.yml\` as a NON-required check. Branch protection is unchanged; W3 flips it to required once this repo is green.

Reusable workflow: smartwatermelon/github-workflows \`standards-check.yml@standards-check-v1\`.

${SESSION}"
}

rc=0
while IFS=$'\t' read -r repo archived; do
  [[ -n "${repo}" ]] || continue
  if [[ -n "${ONLY}" && "${repo}" != "${ONLY}" ]]; then continue; fi
  if [[ "${archived}" == "true" ]]; then printf 'ARCHIVED  %s\n' "${repo}"; continue; fi
  if is_ignored "${repo}"; then printf 'IGNORED   %s\n' "${repo}"; continue; fi
  if current="$(existing_content "${repo}")"; then
    if [[ "${current}" == "${STUB_CONTENT}" ]]; then
      printf 'CURRENT   %s\n' "${repo}"
    else
      printf 'DIFFERS   %s  (has a non-canonical stub; not touched)\n' "${repo}"
    fi
    continue
  fi
  if ! ${APPLY}; then
    printf 'MISSING   %s  (dry run; would %s)\n' "${repo}" "${MODE}"
    continue
  fi
  if out="$(install_"${MODE}" "${repo}" 2>&1)"; then
    printf 'MISSING   %s  -> %s\n' "${repo}" "${out}"
  else
    printf 'ERROR     %s  %s\n' "${repo}" "${out}"
    rc=1
  fi
done < <(list_repos)
exit "${rc}"
```

`chmod +x bulk-install-standards-check.sh`.

- [ ] **Step 8: Run the tests; observe pass. Shellcheck.**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-bulk-install-standards-check.sh`
Expected: `N passed, 0 failed`.

Run: `shellcheck -S info /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh /Users/andrewrich/Developer/github-workflows/tests/stub-gh/gh /Users/andrewrich/Developer/github-workflows/tests/test-bulk-install-standards-check.sh`
Expected: no output.

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/run-tests.sh`
Expected: `0 test file(s) failed`.

- [ ] **Step 9: Byte-match the three stub copies**

```bash
diff <(sed -n '/^```yaml$/,/^```$/p' /Users/andrewrich/Developer/github-workflows/README.md | sed -n '/^name: Standards Check$/,/@standards-check-v1$/p' | head -9) /Users/andrewrich/Developer/github-workflows/standards/caller-stub.yml
```

Expected: no diff. If there is one, edit the README block (and the header comment in `.github/workflows/standards-check.yml`, stripping its `#` prefixes when comparing) to match the stub file. Add a sentence to README's `standards-check.yml` Setup section: "The canonical copy is `standards/caller-stub.yml`; `bulk-install-standards-check.sh` installs it fleet-wide."

- [ ] **Step 10: Live dry run against the real fleet**

Run: `bash /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh > /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/fdd1b816-abbd-4693-807f-764faa0394c7/scratchpad/w2-dryrun.txt; grep -c MISSING $_`
Expected: no `ERROR` lines; `github-workflows` itself reports `CURRENT` (it already carries the self-applying caller; if it reports `DIFFERS`, that is a real drift between the self-caller and the canonical stub, fix the self-caller in this PR); every other fleet repo `MISSING`; `networth-agent` `IGNORED`. Save the file; Task 5 diffs against it.

- [ ] **Step 11: Commit, push, PR**

```bash
git -C /Users/andrewrich/Developer/github-workflows add standards/caller-stub.yml .standards-check-ignore bulk-install-standards-check.sh tests/stub-gh/gh tests/test-bulk-install-standards-check.sh README.md
git -C /Users/andrewrich/Developer/github-workflows commit -m "feat: bulk-install-standards-check.sh and the canonical caller stub (W2)

Classifies every fleet repo and installs standards/caller-stub.yml where
absent, via PR (pilots) or direct put to the default branch (fleet, per
the 2026-09-08 authorization). Hermetic stub-gh tests.

Claude-Session: https://claude.ai/code/session_019HDRKLQNv82SEBd4zGpcXf"
```

Then Protocol 4 checks, push, `gh pr create --repo smartwatermelon/github-workflows --head claude/feat-bulk-install-standards-check-019HDRKL`. Surface the PR. The repo's own `standards-check` runs on this PR; it must be green.

---

### Task 2: Pilot 1, `repo-template`, via PR mode (proves cross-repo tag resolution)

**Gate:** `git -C /Users/andrewrich/Developer/github-workflows ls-remote --tags origin standards-check-v1` prints one line. If empty, stop; Andrew has not pushed the tag.

**Files:** none locally; one PR on `smartwatermelon/repo-template` created by the script, then two hand edits pushed to the same branch.

- [ ] **Step 1: Install via PR mode**

Run: `bash /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh --apply --mode=pr --only smartwatermelon/repo-template`
Expected: one `MISSING smartwatermelon/repo-template -> https://github.com/smartwatermelon/repo-template/pull/N` line.

- [ ] **Step 2: Verify the check ran at the tag's commit**

```bash
tag_sha="$(git -C /Users/andrewrich/Developer/github-workflows rev-parse standards-check-v1^{commit})"
run_id="$(gh run list --repo smartwatermelon/repo-template --workflow 'Standards Check' --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "${run_id}" --repo smartwatermelon/repo-template --log | grep -E 'workflow_sha|Checkout standards|standards-check:' | head
```

Expected: the log's resolved SHA equals `${tag_sha}`, the sparse checkout step succeeded, and the final line is `standards-check: all linters passed` (or the runner's equivalent success line). Conclusion `success`. This is the one property the W1 self-check could not exercise; record the SHA match in the task report.

- [ ] **Step 3: Add the README fix and the pin float to the same PR**

```bash
gh repo clone smartwatermelon/repo-template /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/fdd1b816-abbd-4693-807f-764faa0394c7/scratchpad/repo-template -- -q
git -C .../repo-template switch chore/standards-check-stub
```

Edit `README.md` step 3 to:

```markdown
3. **Branch protection** (optional but recommended) — add
   `standards-check / run-standards-check` as a required status check under
   Settings → Branches. (`claude-review / run-review` is retired in W3.)
```

Edit `.github/workflows/claude-blocking-review.yml`: `@v3.2.1` → `@v3`. Edit `.github/workflows/claude.yml`: `@v3.1.1` → `@v3`.

Run: `bash /Users/andrewrich/Developer/github-workflows/standards/run-standards.sh --repo .../repo-template`
Expected: exit 0.

Commit (message: `docs: name standards-check as the required check; float review pins to @v3`), push, surface the PR.

---

### Task 3: Pilots 2–4 via PR mode (expected red, non-required)

**Gate:** Task 2 Step 2 recorded a SHA match.

- [ ] **Step 1: Install**

```bash
for r in smartwatermelon/pr-review smartwatermelon/claude-code-workflows-agents nightowlstudiollc/.github; do
  bash /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh --apply --mode=pr --only "$r"
done
```

- [ ] **Step 2: Capture the failure bodies**

For each PR, once the run finishes:

```bash
gh run view "${run_id}" --repo "$r" --log-failed > /Users/andrewrich/Developer/dev-env/.superpowers/sdd/2026-09-08-w2-fleet-rollout/pilot-${r//\//__}.log
```

Expected: `pr-review` red on shellcheck + zizmor; `claude-code-workflows-agents` red on shellcheck + zizmor + markdownlint; `.github` red on zizmor. A red run here is the expected result, not a rollout failure; the check is non-required and the PRs are mergeable. Surface all three PRs for locks with that sentence in the message.

---

### Task 4: Direct-push rehearsal on one clean, low-stakes repo

**Gate:** All four pilot PRs merged (Andrew's locks).

- [ ] **Step 1: Apply to exactly one repo**

Run: `bash /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh --apply --mode=push --only smartwatermelon/homebrew-tap`

- [ ] **Step 2: Read the commit back from the default branch (not the script's own line)**

```bash
gh api repos/smartwatermelon/homebrew-tap/commits --jq '.[0] | .sha + " " + .commit.message' -F path=.github/workflows/standards-check.yml
gh api repos/smartwatermelon/homebrew-tap/contents/.github/workflows/standards-check.yml --jq .content | base64 -d | diff - /Users/andrewrich/Developer/github-workflows/standards/caller-stub.yml
```

Expected: the newest commit on that path is the stub commit; the diff is empty. Re-run the script with `--only smartwatermelon/homebrew-tap` (dry run): expected `CURRENT`. If any of the three fail, stop and report; do not proceed to Task 5.

---

### Task 5: Fleet direct-push

**Gate:** Task 4 all three checks passed.

- [ ] **Step 1: Fresh dry run, diff against Task 1's**

Run the script with no flags into `w2-dryrun-2.txt`; `diff` against `w2-dryrun.txt`. Expected differences: the five repos done in Tasks 2–4 now `CURRENT`. Any new `DIFFERS`/`ERROR` is investigated before apply.

- [ ] **Step 2: Apply**

Run: `bash /Users/andrewrich/Developer/github-workflows/bulk-install-standards-check.sh --apply --mode=push | tee /Users/andrewrich/Developer/dev-env/.superpowers/sdd/2026-09-08-w2-fleet-rollout/fleet-push.txt`
Expected: exit 0; every previously `MISSING` line now ends `-> pushed to main` (or the repo's default branch).

- [ ] **Step 3: Verify idempotency and count**

Run the dry run again. Expected: zero `MISSING`, zero `ERROR`; `CURRENT` count equals the fleet size minus ignored/archived. Record counts in the task report.

---

### Task 6: Re-measure lint debt with retained output

**Files:** Create `dev-env/.superpowers/sdd/2026-09-08-w2-fleet-rollout/scan/<owner>__<repo>.log` per repo, and `scan/summary.tsv` (`owner/repo<TAB>exit<TAB>failing-linters`).

- [ ] **Step 1: Scan**

For every non-archived repo in the fleet (same enumeration as the script; use `gh repo list <owner> --json name,isArchived,diskUsage --limit 200` and skip `diskUsage > 200000`):

```bash
d="$(mktemp -d)"; gh repo clone "$r" "$d" -- -q --depth 1
bash /Users/andrewrich/Developer/github-workflows/standards/run-standards.sh --repo "$d" > "scan/${r//\//__}.log" 2>&1; echo "$r $? $(grep -oE '::error::[a-z-]+ found problems' "scan/${r//\//__}.log" | sed 's/::error::\(.*\) found problems/\1/' | paste -sd, -)" >> scan/summary.tsv
rm -rf "$d"
```

- [ ] **Step 2: zizmor root cause, once**

`grep -h -A2 'zizmor' scan/*.log | grep -oE '[a-z-]+\[[^]]*\]|unpinned-uses|dangerous-triggers|template-injection|[a-z-]+: ' | sort | uniq -c | sort -rn` → write `scan/zizmor-findings.md`: rule → repo list → the fix per rule. Expected dominant rule: `unpinned-uses` (third-party actions at a floating tag; fix = pin to a full SHA with a `# vX.Y.Z` comment, Dependabot keeps the comment current). If a rule needs a policy change (e.g. `dangerous-triggers` on `pull_request_target` callers that already carry the `# zizmor: ignore[...]` comment), note it; do not silence rules in `zizmor.yml` without Andrew.

- [ ] **Step 3: Report**

The task report lists: pass count, per-linter counts, the zizmor rule table, and the three node-floor repos with their exact offending lines (from the logs). Commit the `scan/` directory to a dev-env docs branch together with Task 10's STATUS update.

---

### Task 7: Wave 1, node-floor (3 repos)

Also closes N1b: the live N1b set is these three (`tensegrity` has no sub-floor pin; `Gmail-MCP-Server` no longer exists; record both facts in Task 10).

One PR per repo. For each:

- [ ] **Step 1: Clone, branch**

```bash
gh repo clone "$r" "$d" -- -q
git -C "$d" switch -c claude/chore-node-floor-019HDRKL
```

- [ ] **Step 2: Edit every offending pin from the scan log**

- `.nvmrc`: `24` (matches the local default `lts/krypton`, v24.19.0).
- `node-version: 20` / `'20'` / `20.x` in workflows: `24`.
- `package.json` `engines.node`: `>=22.0.0` (the floor; do not raise engines above what the runtime supports).
- Known targets from the 2026-09-08 scan: `nightowlstudiollc/kebab-tax` (`.nvmrc`, `ci.yml` ×2, `deploy-workers.yml` ×3, `publish-changelog.yml` via `.nvmrc`, `release-gate.yml`), `nightowlstudiollc/reliquarist` (`package.json` engines, `ci.yml`), `smartwatermelon/gmail-newsletter-filter` (`package.json` engines). Re-read the scan log; the list may have changed.

- [ ] **Step 3: Verify locally, then in CI**

Run: `bash /Users/andrewrich/Developer/github-workflows/standards/run-standards.sh --repo "$d" 2>&1 | grep -E 'node-floor|Node'`
Expected: no `::error::` lines mentioning Node.

Commit (`chore(node): raise Node pins to the fleet floor (22+)`), push, PR. After CI: every job that previously reached its Node step still reaches it and passes (N1b's own acceptance test); read the job list, do not trust the green badge. `standards-check` may still be red on other linters; say which in the PR surface line. For `kebab-tax`, also confirm the `deploy-workers` job does not run on PRs (it is a deploy); if it does, check its Node step too.

---

### Task 8: Wave 2, zizmor pins

**Gate:** `scan/zizmor-findings.md` exists (Task 6).

Repos (2026-09-08 measurement; re-derive from `scan/summary.tsv`): `pr-review`, `claude-code-workflows-agents`, `nightowlstudiollc/.github`, `swift-progress-indicator`, `kebab-tax-netlify`, `huddle-transcribe`, `dumbify`, `scripts`, `spokane-snow`, `tensegrity`, `personify`, `archive-resolver`, `lock-sync`, `slack-mcp`, `claude-config`, `kebab-tax`.

Dispatch in batches of 4 repos per implementer; at most 10 PRs open at once.

For each repo:

- [ ] **Step 1: Clone, branch `claude/ci-pin-actions-019HDRKL`**
- [ ] **Step 2: Fix per rule** (from `zizmor-findings.md`). For `unpinned-uses`: replace `uses: owner/action@vN` with `uses: owner/action@<40-char sha> # vN.N.N`, resolving the SHA with `gh api repos/owner/action/git/ref/tags/vN.N.N --jq .object.sha` (dereference annotated tags via `git/tags/<sha>` if `.object.type == "tag"`). Do not pin `smartwatermelon/github-workflows/...@vN` reusable-workflow refs; those are first-party and Dependabot-managed by tag (see `docs/plans/2026-04-18-v2-rollout-playbook.md`).
- [ ] **Step 3: Verify:** `run-standards.sh --repo "$d" 2>&1 | grep -A20 '== zizmor'` shows no findings; `actionlint` still clean.
- [ ] **Step 4: Commit (`ci: pin third-party actions to SHAs (zizmor unpinned-uses)`), push, PR.** The non-required `standards-check` on the PR must show zizmor green.

---

### Task 9: Wave 3, combined lint (shellcheck + markdownlint + yamllint)

**Gate:** Waves 1 and 2 merged, AND Andrew has not objected since this plan was surfaced. Before dispatching, post one line: "Starting wave 3 (~28 lint PRs in rounds of 10) unless you say otherwise."

Repos: every `scan/summary.tsv` row whose failing set includes `shellcheck`, `markdownlint`, or `yamllint`. One PR per repo carrying all three. Branch `claude/chore-lint-debt-019HDRKL`. Same batch/round limits as Task 8.

Per repo:

- [ ] **Step 1:** `shellcheck -S info` every finding fixed in place; no `# shellcheck disable`; no behavior changes beyond quoting/`[[ ]]`/`$(...)`; if a fix would change behavior (e.g. word-splitting that a caller relies on), leave it, note it in the PR body, and file an issue on that repo.
- [ ] **Step 2:** markdownlint per the config in effect (repo root `.markdownlint*` if present, else `standards/markdownlint.json`). Reflow, fence languages, heading levels; no content rewrites.
- [ ] **Step 3:** yamllint per `standards/yamllint.yml` (only `kebab-tax`, `night-owl-studio` as of the scan).
- [ ] **Step 4:** `run-standards.sh --repo "$d"` exit 0 for those three linters (zizmor/node-floor already green from earlier waves, or still red if that repo's wave PR has not merged; say so).
- [ ] **Step 5:** Commit (`chore: clear shellcheck, markdownlint, yamllint debt`), push, PR.

---

### Task 10: Status and handoff to W3

**Files:**

- Modify: `dev-env/docs/STATUS.md` (Fleet row; N1b bullet; "Critical path" section)
- Create: `dev-env/.superpowers/sdd/2026-09-08-w2-fleet-rollout/w3-readiness.tsv` — `owner/repo<TAB>standards-check green? (y/n)<TAB>blocking linters`

- [ ] **Step 1:** Regenerate the readiness table from the latest `standards-check` run on each repo's default branch: `gh run list --repo $r --workflow 'Standards Check' --branch main --limit 1 --json conclusion`. (If a repo has had no PR since install, the check has never run; mark `never-ran`, and W3 opens a no-op PR to trigger it.)
- [ ] **Step 2:** STATUS.md: Fleet row → `W0, W1, W2 done. W3 open — critical path.`; N1b → done, with the Gmail-MCP-Server/tensegrity note; add the lock count actually spent and the readiness summary (green N of M).
- [ ] **Step 3:** Commit, push, PR (docs only). Surface it.

---

## Self-review

- Spec coverage: install fleet-wide non-required (Tasks 1–5), pilots first (2–3), measured pilot verdict (2.2), remediation waves per decision (7–9), W3 handoff (10), repo-template README/pins (2.3), `.claude-review-ignore` disposition (Task 1 Step 3), zizmor root cause once (6.2), lock-count disclosure (Interruption budget), N1b reconciliation (7, 10). Not covered by design: flipping required checks, retiring the reviewer, `workflow-templates/` entry in `smartwatermelon/.github` (W3).
- Placeholders: none; every code step has content.
- Names: `bulk-install-standards-check.sh`, `standards/caller-stub.yml`, `.standards-check-ignore`, class words `MISSING/CURRENT/DIFFERS/IGNORED/ARCHIVED/ERROR`, branch `chore/standards-check-stub`, env `BULK_GH/BULK_STUB_FILE/BULK_IGNORE_FILE` are consistent across Tasks 1–5.
