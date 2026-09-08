# W1: `standards-check.yml` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deterministic, secret-free reusable workflow in
`smartwatermelon/github-workflows` that runs shellcheck, yamllint, actionlint,
zizmor, markdownlint, and a Node-EOL floor check, so it can replace
`claude-blocking-review.yml` as the fleet's required check (W2, W3).

**Architecture:** One bash script, `standards/run-standards.sh`, does all the
work and is testable locally against known-bad fixtures. The reusable
workflow `.github/workflows/standards-check.yml` only installs pinned tools,
fetches canonical configs for repos that carry none, and runs the script. A
self-applying caller dogfoods it on `github-workflows`' own PRs. The workflow
gets its own tag namespace (`standards-check-v1`), like
`dependabot-auto-merge-v2`, because git tags are repo-scoped.

**Tech Stack:** GitHub Actions on `ubuntu-latest`, bash 5, shellcheck 0.11.0,
actionlint 1.7.12, zizmor 1.30.0, yamllint 1.38.0, markdownlint-cli2 0.23.2.

**Spec:** `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md`
("W1 — Build `standards-check.yml`", "Folded into the same pass", "Runtime EOL
layer → Feeds W1"), `smartwatermelon/github-workflows#154` (Phase 1), and the
decisions recorded in `2026-09-08-backlog-remainder-roadmap.md`. Research
inputs: `.superpowers/sdd/2026-09-08-backlog-remainder-roadmap/w1-research.md`
(git-ignored scratch; the facts it established are restated here).

## Global Constraints

- Work happens in `/Users/andrewrich/Developer/github-workflows`. Never commit
  on `main`; branch `claude/feat-standards-check-<session>`.
- Every third-party `uses:` is SHA-pinned with a `# vX.Y.Z` comment
  (`zizmor.yml` policy: `"*": hash-pin`). First-party refs may float.
- Every tool binary is version-pinned and, where a checksum is published,
  checksum-verified before use. No marketplace actions for the linters.
- No secrets. The only token is the default `GITHUB_TOKEN`, `contents: read`.
- `shellcheck -S info` clean on every shell file added; no
  `# shellcheck disable`; never `((var++))`.
- Every check in the script is validated against a known-bad fixture that is
  observed FAILING before the check is trusted.
- Text files end with a newline. Markdown passes markdownlint with the
  canonical config below.

## Design rulings (2026-09-08)

| Ruling | Why | Cost if wrong |
| --- | --- | --- |
| **Lint-only. The workflow does not run a repo's tests.** | Runners are heterogeneous (pytest, vitest, jest, `node --test`, bats, Makefile, none). Repos that have a test workflow keep it and W3 adds it to required checks alongside `standards-check`, the way `personify` already requires `validate`. | Repos with no test workflow stay without a test gate — same as today. |
| **Own tag namespace `standards-check-v1`.** | Tags are repo-scoped; `v3` belongs to `claude-blocking-review.yml`. Same pattern as `dependabot-auto-merge-v2`. | None expected. |
| **Script-first: `standards/run-standards.sh` does the work; the workflow is a thin installer.** | Local testability with known-bad fixtures; a human can run the same check before pushing. | Slightly more files. |
| **Tools by checksummed release tarball (shellcheck, actionlint, zizmor), `pipx` pin (yamllint), `npx` pin (markdownlint-cli2).** | No first-party actions exist for these; the fleet already uses the checksummed-tarball pattern for shellcheck in two repos. | Version bumps are manual PRs to `github-workflows` (Dependabot does not track them). |
| **Config precedence: repo-root config if present, else the canonical file from `github-workflows/standards/` at the *called workflow's* SHA (`github.job_workflow_sha`).** | Lets repos opt into stricter/looser rules while giving every repo a working default without W2 having to copy three files. `zizmor.yml` is still propagated in W2 because local pre-commit needs it. | A repo's local pre-commit and CI could disagree until the repo carries its own config. |
| **Per-linter boolean inputs, all default `true`; `node_floor` default `"22"`.** | W2 pilots will find repos with lint debt; a toggle keeps rollout unblocked while debt is paid. Node 20 is EOL; 22 is the lowest supported line. | A repo could silently disable a linter — visible in its caller stub, which is reviewed. |
| **shellcheck severity `info`, matching the local standard.** | The local hook uses `-S info`; CI should not be looser. | More findings on first rollout; pilots measure. |
| **No doc-only or Dependabot skip.** | Linting is seconds and deterministic; the skips existed to save LLM cost. | None. |
| **Check name `standards-check / run-standards-check`.** | Same `{caller job} / {inner job}` mechanism as `claude-review / run-review`. | Branch protection must use this exact string (W3). |

---

### Task 1: Canonical configs and the Node-floor checker

**Files:**

- Create: `standards/markdownlint.json`
- Create: `standards/yamllint.yml`
- Create: `standards/check-node-floor.sh`
- Create: `tests/test-check-node-floor.sh`
- Create: `tests/run-tests.sh`

**Interfaces:**

- Produces: `standards/check-node-floor.sh <repo-dir> <floor-major>` → exit 0 when no Node pin below the floor is found, exit 1 and one `::error::` line per offending pin otherwise. Task 2's script calls it.
- Produces: `tests/run-tests.sh` runs every `tests/test-*.sh` and exits nonzero if any fails. Task 2 adds to it.

- [ ] **Step 1: Write the canonical configs**

`standards/markdownlint.json` — identical to `~/.config/markdownlint-cli/.markdownlint.json`:

```json
{
  "default": true,
  "MD013": false,
  "MD024": {
    "siblings_only": true
  },
  "MD029": false,
  "MD033": false,
  "MD036": false,
  "MD040": false,
  "MD046": false,
  "MD060": false
}
```

`standards/yamllint.yml` — identical to `~/.config/yamllint/config`:

```yaml
---
# Canonical yamllint config for standards-check.yml. Mirrors
# ~/.config/yamllint/config in dotfiles; keep them in sync.
extends: relaxed

rules:
  line-length:
    max: 120
```

- [ ] **Step 2: Write the failing test for the Node-floor checker**

`tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Runs every tests/test-*.sh; exits nonzero if any fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "${here}"/test-*.sh; do
  echo "== ${t##*/}"
  if bash "${t}"; then
    echo "PASS ${t##*/}"
  else
    echo "FAIL ${t##*/}"
    failed=$((failed + 1))
  fi
done
echo "${failed} test file(s) failed"
[[ "${failed}" -eq 0 ]]
```

`tests/test-check-node-floor.sh`:

```bash
#!/usr/bin/env bash
# Known-bad validation for standards/check-node-floor.sh. Each fixture is a
# throwaway directory; the control case proves the checker can fail.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${here}/../standards/check-node-floor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# Fixture 1: workflow pins node 20 -> must fail
mkdir -p "${tmp}/f1/.github/workflows"
cat >"${tmp}/f1/.github/workflows/ci.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: actions/setup-node@abc
        with:
          node-version: 20
EOF
if bash "${checker}" "${tmp}/f1" 22 >/dev/null 2>&1; then _bad "workflow node-version 20 accepted"; else _ok "workflow node-version 20 rejected"; fi

# Fixture 2: .nvmrc 18.20.4 -> must fail
mkdir -p "${tmp}/f2"; echo "18.20.4" >"${tmp}/f2/.nvmrc"
if bash "${checker}" "${tmp}/f2" 22 >/dev/null 2>&1; then _bad ".nvmrc 18 accepted"; else _ok ".nvmrc 18 rejected"; fi

# Fixture 3: package.json engines floor admits 14 -> must fail
mkdir -p "${tmp}/f3"; echo '{"engines":{"node":">=14.0.0"}}' >"${tmp}/f3/package.json"
if bash "${checker}" "${tmp}/f3" 22 >/dev/null 2>&1; then _bad "engines >=14 accepted"; else _ok "engines >=14 rejected"; fi

# Fixture 4: everything at or above the floor -> must pass
mkdir -p "${tmp}/f4/.github/workflows"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version: "24"\n' >"${tmp}/f4/.github/workflows/ci.yml"
echo "lts/krypton" >"${tmp}/f4/.nvmrc"
echo '{"engines":{"node":">=22"}}' >"${tmp}/f4/package.json"
if bash "${checker}" "${tmp}/f4" 22 >/dev/null 2>&1; then _ok "conformant repo passes"; else _bad "conformant repo rejected"; fi

# Fixture 5: no Node anywhere -> must pass
mkdir -p "${tmp}/f5"; echo "hi" >"${tmp}/f5/README.md"
if bash "${checker}" "${tmp}/f5" 22 >/dev/null 2>&1; then _ok "repo without Node passes"; else _bad "repo without Node rejected"; fi

# Fixture 6: node-version-file indirection to a bad .nvmrc -> must fail
mkdir -p "${tmp}/f6/.github/workflows"; echo "20.19.4" >"${tmp}/f6/.nvmrc"
printf 'jobs:\n  b:\n    steps:\n      - with:\n          node-version-file: .nvmrc\n' >"${tmp}/f6/.github/workflows/ci.yml"
if bash "${checker}" "${tmp}/f6" 22 >/dev/null 2>&1; then _bad "node-version-file -> 20 accepted"; else _ok "node-version-file -> 20 rejected"; fi

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-check-node-floor.sh`
Expected: script errors because `standards/check-node-floor.sh` does not exist (every "rejected" case reports FAIL-by-absence is not acceptable — the checker must exist and fail *for the right reason*, so proceed to Step 4 and re-run).

- [ ] **Step 4: Write the checker**

`standards/check-node-floor.sh`:

```bash
#!/usr/bin/env bash
# check-node-floor.sh <repo-dir> <floor-major>
#
# Fails (exit 1) if any Node.js version pin in the repo names a major below
# <floor-major>. Sources scanned:
#   - .github/workflows/*.yml|*.yaml : `node-version:` literals and
#     `node-version-file:` indirections
#   - .nvmrc, .node-version           : bare versions ("20", "20.19.4", "v18")
#   - package.json                    : engines.node lower bound (">=14.0.0")
# Named aliases (lts/*, node, latest, current) are accepted: they float and
# are never below the floor. Expressions (${{ ... }}) are skipped with a
# notice because they cannot be resolved statically.
set -euo pipefail

repo="${1:?usage: check-node-floor.sh <repo-dir> <floor-major>}"
floor="${2:?usage: check-node-floor.sh <repo-dir> <floor-major>}"
[[ "${floor}" =~ ^[0-9]+$ ]] || { echo "::error::floor must be an integer major, got '${floor}'"; exit 2; }

errors=0

# _major <version-string> -> prints the major, or nothing for aliases/unparseable.
_major() {
  local v="${1}"
  v="${v#v}"; v="${v%%.*}"
  [[ "${v}" =~ ^[0-9]+$ ]] && printf '%s' "${v}"
}

# _check <major-or-empty> <where>
_check() {
  local major="${1}" where="${2}"
  [[ -z "${major}" ]] && return 0
  if (( major < floor )); then
    echo "::error::${where}: Node ${major} is below the supported floor (${floor})"
    errors=$((errors + 1))
  fi
}

# _version_from_file <path> -> first non-empty, non-comment line, trimmed
_version_from_file() {
  grep -vE '^\s*(#|$)' "${1}" | head -1 | tr -d '[:space:]'
}

for f in "${repo}/.nvmrc" "${repo}/.node-version"; do
  [[ -f "${f}" ]] || continue
  raw="$(_version_from_file "${f}")"
  _check "$(_major "${raw}")" "${f#"${repo}"/}: ${raw}"
done

if [[ -f "${repo}/package.json" ]] && command -v jq >/dev/null; then
  eng="$(jq -r '.engines.node // empty' "${repo}/package.json" 2>/dev/null || true)"
  if [[ -n "${eng}" ]]; then
    # Lower bound: first numeric token after an optional >= / ^ / ~ prefix.
    low="$(printf '%s' "${eng}" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1 || true)"
    _check "$(_major "${low}")" "package.json engines.node: ${eng}"
  fi
fi

shopt -s nullglob
for wf in "${repo}"/.github/workflows/*.yml "${repo}"/.github/workflows/*.yaml; do
  rel="${wf#"${repo}"/}"
  while IFS= read -r line; do
    val="$(printf '%s' "${line}" | sed -E 's/.*node-version:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ "${val}" == *'${{'* ]]; then
      echo "::notice::${rel}: node-version is an expression (${val}); not checked"
      continue
    fi
    _check "$(_major "${val}")" "${rel}: node-version: ${val}"
  done < <(grep -E '^\s*node-version:' "${wf}" || true)
  while IFS= read -r line; do
    vf="$(printf '%s' "${line}" | sed -E 's/.*node-version-file:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ -f "${repo}/${vf}" ]]; then
      raw="$(_version_from_file "${repo}/${vf}")"
      _check "$(_major "${raw}")" "${rel}: node-version-file ${vf} -> ${raw}"
    fi
  done < <(grep -E '^\s*node-version-file:' "${wf}" || true)
done

if (( errors > 0 )); then
  echo "::error::${errors} Node pin(s) below floor ${floor}. Node 20 reached EOL 2026-04-30."
  exit 1
fi
echo "Node floor ${floor}: OK"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-check-node-floor.sh`
Expected: `6 passed, 0 failed`.

Run: `shellcheck -S info /Users/andrewrich/Developer/github-workflows/standards/check-node-floor.sh /Users/andrewrich/Developer/github-workflows/tests/test-check-node-floor.sh /Users/andrewrich/Developer/github-workflows/tests/run-tests.sh`
Expected: silent.

- [ ] **Step 6: Commit**

```bash
git -C /Users/andrewrich/Developer/github-workflows add standards/markdownlint.json standards/yamllint.yml standards/check-node-floor.sh tests/test-check-node-floor.sh tests/run-tests.sh
git -C /Users/andrewrich/Developer/github-workflows commit -m "feat(standards): canonical lint configs and a Node-floor checker"
```

---

### Task 2: `standards/run-standards.sh`

**Files:**

- Create: `standards/run-standards.sh`
- Create: `tests/test-run-standards.sh`

**Interfaces:**

- Consumes: `standards/check-node-floor.sh` (Task 1).
- Produces: `standards/run-standards.sh [--repo DIR] [--config-dir DIR] [--skip a,b,c] [--node-floor N]` → exit 0 when every enabled linter is clean, exit 1 otherwise; prints one `== <linter>` header per linter and `::error::` lines for findings. Linter names: `shellcheck`, `yamllint`, `actionlint`, `zizmor`, `markdownlint`, `node-floor`. Task 3's workflow calls it exactly this way.
- Requires on `PATH`: `shellcheck`, `yamllint`, `actionlint`, `zizmor`, `markdownlint-cli2`, `jq`, `git`.

- [ ] **Step 1: Write the failing test**

`tests/test-run-standards.sh`:

```bash
#!/usr/bin/env bash
# Known-bad validation for standards/run-standards.sh: one fixture per
# linter that MUST fail, one clean fixture that MUST pass, and a --skip case
# proving the toggle really disables a linter. Requires the five tools on
# PATH (brew install shellcheck yamllint actionlint zizmor markdownlint-cli2).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="${here}/../standards/run-standards.sh"
cfg="${here}/../standards"
for tool in shellcheck yamllint actionlint zizmor markdownlint-cli2 jq; do
  command -v "${tool}" >/dev/null || { echo "SKIP: ${tool} not on PATH"; exit 0; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
pass=0; fail=0
_ok() { echo "  ok   $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
_mk() { mkdir -p "${tmp}/$1"; git -C "${tmp}/$1" init -q; }
_expect_fail() { # name dir
  if bash "${runner}" --repo "${tmp}/$2" --config-dir "${cfg}" >"${tmp}/$2.log" 2>&1; then _bad "$1 (accepted; see ${tmp}/$2.log)"; else _ok "$1"; fi
}
_expect_pass() {
  if bash "${runner}" --repo "${tmp}/$2" --config-dir "${cfg}" >"${tmp}/$2.log" 2>&1; then _ok "$1"; else _bad "$1 (rejected; see ${tmp}/$2.log)"; cat "${tmp}/$2.log"; fi
}

_mk bad-sh; printf '#!/usr/bin/env bash\necho $1\n' >"${tmp}/bad-sh/x.sh"; git -C "${tmp}/bad-sh" add -A
_expect_fail "shellcheck: unquoted \$1 (SC2086) rejected" bad-sh

_mk bad-yaml; printf 'a: 1\n  b: 2\n' >"${tmp}/bad-yaml/x.yml"; git -C "${tmp}/bad-yaml" add -A
_expect_fail "yamllint: bad indentation rejected" bad-yaml

_mk bad-action; mkdir -p "${tmp}/bad-action/.github/workflows"
printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n        uses: actions/checkout@v7\n' >"${tmp}/bad-action/.github/workflows/ci.yml"
git -C "${tmp}/bad-action" add -A
_expect_fail "actionlint: run+uses in one step rejected" bad-action

_mk bad-zizmor; mkdir -p "${tmp}/bad-zizmor/.github/workflows"
printf 'on: pull_request_target\npermissions: write-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          ref: ${{ github.event.pull_request.head.ref }}\n' >"${tmp}/bad-zizmor/.github/workflows/ci.yml"
git -C "${tmp}/bad-zizmor" add -A
_expect_fail "zizmor: pwn-request / unpinned third-party rejected" bad-zizmor

_mk bad-md; printf '#Bad heading\n\n\n\nx\n' >"${tmp}/bad-md/README.md"; git -C "${tmp}/bad-md" add -A
_expect_fail "markdownlint: MD018/MD012 rejected" bad-md

_mk bad-node; echo "20" >"${tmp}/bad-node/.nvmrc"; git -C "${tmp}/bad-node" add -A
_expect_fail "node-floor: .nvmrc 20 rejected" bad-node

_mk clean; mkdir -p "${tmp}/clean/.github/workflows"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "${1:-}"\n' >"${tmp}/clean/ok.sh"
printf '# Title\n\nBody.\n' >"${tmp}/clean/README.md"
printf 'key: value\n' >"${tmp}/clean/x.yml"
printf 'on: push\npermissions:\n  contents: read\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"${tmp}/clean/.github/workflows/ci.yml"
echo "lts/krypton" >"${tmp}/clean/.nvmrc"
git -C "${tmp}/clean" add -A
_expect_pass "clean repo passes every linter" clean

if bash "${runner}" --repo "${tmp}/bad-sh" --config-dir "${cfg}" --skip shellcheck >/dev/null 2>&1; then _ok "--skip shellcheck disables the linter"; else _bad "--skip shellcheck did not disable it"; fi

_mk empty; git -C "${tmp}/empty" add -A
_expect_pass "empty repo passes (nothing to lint is not a failure)" empty

echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-run-standards.sh`
Expected: every case FAILs or errors because the runner does not exist. If it prints `SKIP: <tool> not on PATH`, install the tool with Homebrew first; the tools are required for this task.

- [ ] **Step 3: Write the runner**

`standards/run-standards.sh`:

```bash
#!/usr/bin/env bash
# run-standards.sh — the deterministic standards check.
#
#   run-standards.sh [--repo DIR] [--config-dir DIR] [--skip a,b,c] [--node-floor N]
#
# Runs shellcheck, yamllint, actionlint, zizmor, markdownlint, and the
# Node-floor check over the tracked files of DIR (default: cwd). Exit 0 only
# when every enabled linter is clean. A linter with nothing to lint passes
# with a notice — absence of files is not a failure.
#
# Config precedence, per linter: a config at the repo root wins; otherwise
# the canonical file under --config-dir (github-workflows/standards/) is
# used. zizmor's canonical config is ../zizmor.yml relative to --config-dir.
#
# Same script runs in CI (standards-check.yml) and locally.
set -euo pipefail

repo="$(pwd)"
config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skip=""
node_floor="22"
while (($# > 0)); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --skip) skip="$2"; shift 2 ;;
    --node-floor) node_floor="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1"; exit 2 ;;
  esac
done
repo="$(cd "${repo}" && pwd)"
config_dir="$(cd "${config_dir}" && pwd)"

failures=0
_skipped() { [[ ",${skip}," == *",$1,"* ]]; }
_header() { echo; echo "== $1"; }
_fail() { echo "::error::$1 found problems"; failures=$((failures + 1)); }
_tracked() { git -C "${repo}" ls-files -z --cached --others --exclude-standard; }

# shellcheck: *.sh, *.bash, and files whose shebang is a bourne-family shell.
if _skipped shellcheck; then echo "== shellcheck: skipped by input"; else
  _header shellcheck
  files=()
  while IFS= read -r -d '' f; do
    case "${f}" in
      *.sh|*.bash) files+=("${f}") ;;
      *) [[ -f "${repo}/${f}" ]] && head -c 64 "${repo}/${f}" 2>/dev/null | head -1 | grep -qE '^#!.*\b(ba)?sh\b' && files+=("${f}") ;;
    esac
  done < <(_tracked)
  if ((${#files[@]} == 0)); then echo "::notice::no shell files"; else
    (cd "${repo}" && shellcheck -S info "${files[@]}") || _fail shellcheck
  fi
fi

# yamllint: *.yml, *.yaml
if _skipped yamllint; then echo "== yamllint: skipped by input"; else
  _header yamllint
  files=()
  while IFS= read -r -d '' f; do case "${f}" in *.yml|*.yaml) files+=("${f}") ;; esac; done < <(_tracked)
  if ((${#files[@]} == 0)); then echo "::notice::no YAML files"; else
    cfg=""
    for c in .yamllint .yamllint.yml .yamllint.yaml; do [[ -f "${repo}/${c}" ]] && { cfg="${repo}/${c}"; break; }; done
    [[ -n "${cfg}" ]] || cfg="${config_dir}/yamllint.yml"
    (cd "${repo}" && yamllint -c "${cfg}" -f parsable "${files[@]}") || _fail yamllint
  fi
fi

# actionlint: .github/workflows only; it finds them itself.
if _skipped actionlint; then echo "== actionlint: skipped by input"; else
  _header actionlint
  if compgen -G "${repo}/.github/workflows/*.y*ml" >/dev/null; then
    (cd "${repo}" && actionlint -shellcheck= -pyflakes=) || _fail actionlint
  else echo "::notice::no workflows"; fi
fi

# zizmor: repo-root zizmor.yml, else the canonical policy one level above config-dir.
if _skipped zizmor; then echo "== zizmor: skipped by input"; else
  _header zizmor
  if compgen -G "${repo}/.github/workflows/*.y*ml" >/dev/null; then
    cfg="${repo}/zizmor.yml"; [[ -f "${cfg}" ]] || cfg="${config_dir}/../zizmor.yml"
    (cd "${repo}" && zizmor --config "${cfg}" --min-severity low --no-online-audits .) || _fail zizmor
  else echo "::notice::no workflows"; fi
fi

# markdownlint: *.md via markdownlint-cli2; repo config wins, else canonical.
if _skipped markdownlint; then echo "== markdownlint: skipped by input"; else
  _header markdownlint
  files=()
  while IFS= read -r -d '' f; do case "${f}" in *.md) files+=("${f}") ;; esac; done < <(_tracked)
  if ((${#files[@]} == 0)); then echo "::notice::no Markdown files"; else
    cfg=""
    for c in .markdownlint-cli2.jsonc .markdownlint-cli2.yaml .markdownlint-cli2.cjs .markdownlint.jsonc .markdownlint.json .markdownlint.yaml .markdownlint.yml .markdownlintrc; do
      [[ -f "${repo}/${c}" ]] && { cfg="${repo}/${c}"; break; }
    done
    [[ -n "${cfg}" ]] || cfg="${config_dir}/markdownlint.json"
    (cd "${repo}" && markdownlint-cli2 --config "${cfg}" "${files[@]}") || _fail markdownlint
  fi
fi

# node-floor
if _skipped node-floor; then echo "== node-floor: skipped by input"; else
  _header node-floor
  bash "${config_dir}/check-node-floor.sh" "${repo}" "${node_floor}" || _fail node-floor
fi

echo
if ((failures > 0)); then
  echo "::error::standards-check: ${failures} linter(s) failed"
  exit 1
fi
echo "standards-check: all enabled linters clean"
```

- [ ] **Step 4: Run the test until it passes**

Run: `bash /Users/andrewrich/Developer/github-workflows/tests/test-run-standards.sh`
Expected: `9 passed, 0 failed`. If a "rejected" case is accepted, read `${tmp}/<fixture>.log` and fix the *fixture* only if the linter genuinely does not flag it at that severity; never loosen the runner to make a fixture pass. If `bad-zizmor` is accepted, confirm zizmor's `unpinned-uses` fires with the canonical policy (`"*": hash-pin` on `actions/checkout@v7`).

Run: `shellcheck -S info /Users/andrewrich/Developer/github-workflows/standards/run-standards.sh /Users/andrewrich/Developer/github-workflows/tests/test-run-standards.sh`
Expected: silent.

- [ ] **Step 5: Dogfood on the repo itself**

Run: `bash /Users/andrewrich/Developer/github-workflows/standards/run-standards.sh --repo /Users/andrewrich/Developer/github-workflows`
Expected: exit 0. If it fails, fix the findings in `github-workflows` in this same commit (they are real) and record which in the report.

- [ ] **Step 6: Commit**

```bash
git -C /Users/andrewrich/Developer/github-workflows add standards/run-standards.sh tests/test-run-standards.sh
git -C /Users/andrewrich/Developer/github-workflows commit -m "feat(standards): run-standards.sh with known-bad fixture tests"
```

---

### Task 3: The reusable workflow and its self-applying caller

**Files:**

- Create: `.github/workflows/standards-check.yml`
- Create: `.github/workflows/self-standards-check.yml`
- Modify: `zizmor.yml` (add `standards-check.yml` to the `excessive-permissions` ignore list)

**Interfaces:**

- Consumes: `standards/run-standards.sh` CLI (Task 2); `standards/` configs (Task 1).
- Produces: reusable workflow `smartwatermelon/github-workflows/.github/workflows/standards-check.yml` with inputs `shellcheck`, `yamllint`, `actionlint`, `zizmor`, `markdownlint`, `node_floor_check` (booleans, default `true`), `node_floor` (string, default `"22"`); inner job id `run-standards-check`. W2's caller stub uses these names.

- [ ] **Step 1: Write the reusable workflow**

`.github/workflows/standards-check.yml`:

```yaml
name: Standards Check

# Reusable, deterministic, secret-free standards check. Replaces the CI
# judgment reviewer as the fleet's required check (dev-env#60,
# github-workflows#154). Installs pinned linters and runs
# standards/run-standards.sh from THIS repo at the SHA the caller resolved
# (github.job_workflow_sha), so the script, the configs, and the workflow
# always agree.
#
# Caller stub (name the job `standards-check`; the required check is then
# `standards-check / run-standards-check`):
#
#   name: Standards Check
#   on:
#     pull_request:
#       types: [opened, synchronize, ready_for_review, reopened]
#   permissions:
#     contents: read
#   jobs:
#     standards-check:
#       uses: smartwatermelon/github-workflows/.github/workflows/standards-check.yml@standards-check-v1
#
# Tool versions are pinned here and verified by checksum. Bump them by PR.

on:
  workflow_call:
    inputs:
      shellcheck:
        description: Run shellcheck -S info over shell files
        type: boolean
        default: true
      yamllint:
        description: Run yamllint over YAML files
        type: boolean
        default: true
      actionlint:
        description: Run actionlint over .github/workflows
        type: boolean
        default: true
      zizmor:
        description: Run zizmor over .github/workflows
        type: boolean
        default: true
      markdownlint:
        description: Run markdownlint-cli2 over Markdown files
        type: boolean
        default: true
      node_floor_check:
        description: Fail on Node.js pins below node_floor
        type: boolean
        default: true
      node_floor:
        description: Lowest supported Node.js major
        type: string
        default: "22"

permissions: {}

env:
  SHELLCHECK_VERSION: "0.11.0"
  SHELLCHECK_SHA256: "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
  ACTIONLINT_VERSION: "1.7.12"
  ACTIONLINT_SHA256: "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
  ZIZMOR_VERSION: "1.30.0"
  ZIZMOR_SHA256: "ec8c95cd800845abb9bbc5f377ec7c57d2eb8e2386a00a201d3a74ee4092e5ed"
  YAMLLINT_VERSION: "1.38.0"
  MARKDOWNLINT_CLI2_VERSION: "0.23.2"

jobs:
  run-standards-check:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Checkout caller repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
          fetch-depth: 1
          path: repo

      - name: Checkout standards at the called-workflow SHA
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: smartwatermelon/github-workflows
          ref: ${{ github.job_workflow_sha }}
          persist-credentials: false
          fetch-depth: 1
          path: standards-src
          sparse-checkout: |
            standards
            zizmor.yml

      - name: Install pinned linters
        env:
          SKIP_SHELLCHECK: ${{ inputs.shellcheck == false }}
          SKIP_ACTIONLINT: ${{ inputs.actionlint == false }}
          SKIP_ZIZMOR: ${{ inputs.zizmor == false }}
          SKIP_YAMLLINT: ${{ inputs.yamllint == false }}
          SKIP_MARKDOWNLINT: ${{ inputs.markdownlint == false }}
        run: |
          set -euo pipefail
          mkdir -p "${HOME}/.local/bin"; echo "${HOME}/.local/bin" >> "${GITHUB_PATH}"
          if [ "${SKIP_SHELLCHECK}" != "true" ]; then
            curl -Lfso /tmp/shellcheck.tar.xz \
              "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
            echo "${SHELLCHECK_SHA256}  /tmp/shellcheck.tar.xz" | sha256sum -c -
            tar -xJf /tmp/shellcheck.tar.xz -C /tmp
            install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "${HOME}/.local/bin/shellcheck"
          fi
          if [ "${SKIP_ACTIONLINT}" != "true" ]; then
            curl -Lfso /tmp/actionlint.tar.gz \
              "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
            echo "${ACTIONLINT_SHA256}  /tmp/actionlint.tar.gz" | sha256sum -c -
            tar -xzf /tmp/actionlint.tar.gz -C /tmp actionlint
            install -m 0755 /tmp/actionlint "${HOME}/.local/bin/actionlint"
          fi
          if [ "${SKIP_ZIZMOR}" != "true" ]; then
            curl -Lfso /tmp/zizmor.tar.gz \
              "https://github.com/zizmorcore/zizmor/releases/download/v${ZIZMOR_VERSION}/zizmor-x86_64-unknown-linux-gnu.tar.gz"
            echo "${ZIZMOR_SHA256}  /tmp/zizmor.tar.gz" | sha256sum -c -
            mkdir -p /tmp/zizmor && tar -xzf /tmp/zizmor.tar.gz -C /tmp/zizmor
            install -m 0755 "$(find /tmp/zizmor -type f -name zizmor | head -1)" "${HOME}/.local/bin/zizmor"
          fi
          if [ "${SKIP_YAMLLINT}" != "true" ]; then
            pipx install "yamllint==${YAMLLINT_VERSION}"
          fi
          if [ "${SKIP_MARKDOWNLINT}" != "true" ]; then
            npm install -g "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}"
          fi

      - name: Run standards
        env:
          SKIP_LIST: >-
            ${{ inputs.shellcheck == false && 'shellcheck,' || '' }}${{ inputs.yamllint == false && 'yamllint,' || '' }}${{ inputs.actionlint == false && 'actionlint,' || '' }}${{ inputs.zizmor == false && 'zizmor,' || '' }}${{ inputs.markdownlint == false && 'markdownlint,' || '' }}${{ inputs.node_floor_check == false && 'node-floor,' || '' }}
          NODE_FLOOR: ${{ inputs.node_floor }}
        run: |
          set -euo pipefail
          [[ "${NODE_FLOOR}" =~ ^[0-9]+$ ]] || { echo "::error::node_floor must be an integer major"; exit 2; }
          bash standards-src/standards/run-standards.sh \
            --repo repo \
            --config-dir standards-src/standards \
            --skip "${SKIP_LIST%,}" \
            --node-floor "${NODE_FLOOR}"
```

- [ ] **Step 2: Write the self-applying caller**

`.github/workflows/self-standards-check.yml`:

```yaml
name: Self Standards Check

# Self-applying caller: runs this repo's reusable standards-check.yml on its
# own PRs via a local path, so a PR that changes the check dogfoods itself.
# Produces the `standards-check / run-standards-check` status check.

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

permissions:
  contents: read

jobs:
  standards-check:
    uses: ./.github/workflows/standards-check.yml
```

Note: with a local `uses: ./...`, `github.job_workflow_sha` is the PR head SHA, so the sparse checkout in Step 1 fetches the same commit. Verify this in Step 5's run log.

- [ ] **Step 3: Extend `zizmor.yml`**

Add under `excessive-permissions.ignore`, keeping the comment style of the existing entries:

```yaml
      - standards-check.yml # caller for standards-check.yml
```

- [ ] **Step 4: Lint locally and run the suite**

Run:

```bash
cd /Users/andrewrich/Developer/github-workflows && actionlint && zizmor --config zizmor.yml --min-severity low --no-online-audits . && yamllint -c standards/yamllint.yml .github/workflows/standards-check.yml .github/workflows/self-standards-check.yml && bash tests/run-tests.sh && bash standards/run-standards.sh
```

(`cd` inside a single subshell command is acceptable here because the linters resolve paths relative to the repo root; do not rely on it persisting.)
Expected: all silent/passing. Fix any finding in the new files.

- [ ] **Step 5: Commit, push, open the PR, and read the run log**

```bash
git -C /Users/andrewrich/Developer/github-workflows add .github/workflows/standards-check.yml .github/workflows/self-standards-check.yml zizmor.yml
git -C /Users/andrewrich/Developer/github-workflows commit -m "feat: standards-check.yml reusable workflow with self-applying caller"
git -C /Users/andrewrich/Developer/github-workflows push -u origin <branch>
gh pr create --repo smartwatermelon/github-workflows --head <branch> --title "feat: standards-check.yml, the deterministic required check (W1)" --body "<body>"
```

Then wait for the `standards-check / run-standards-check` check and read its log:

```bash
gh run list --repo smartwatermelon/github-workflows --workflow self-standards-check.yml --limit 1 --json databaseId,conclusion
gh run view <id> --repo smartwatermelon/github-workflows --log | grep -E "sha256sum|OK$|== |standards-check:|job_workflow_sha|Checkout standards" | head -40
```

Expected: every checksum line reads `OK`; six `== <linter>` headers; final line `standards-check: all enabled linters clean`; the standards checkout resolved the PR head SHA. A green check without those log lines is not evidence.

---

### Task 4: Known-bad validation on a throwaway PR

**Files:** none kept. A scratch branch off the Task 3 branch.

- [ ] **Step 1: Push a deliberately failing commit**

```bash
git -C /Users/andrewrich/Developer/github-workflows checkout -b claude/scratch-standards-known-bad-<session>
printf '#!/usr/bin/env bash\necho $1\n' > /Users/andrewrich/Developer/github-workflows/standards/_known_bad.sh
git -C /Users/andrewrich/Developer/github-workflows add standards/_known_bad.sh
git -C /Users/andrewrich/Developer/github-workflows commit -m "test: known-bad fixture for standards-check (DO NOT MERGE)"
git -C /Users/andrewrich/Developer/github-workflows push -u origin claude/scratch-standards-known-bad-<session>
gh pr create --repo smartwatermelon/github-workflows --head claude/scratch-standards-known-bad-<session> --base <task-3-branch> --draft --title "DO NOT MERGE: standards-check known-bad validation" --body "Throwaway. Proves standards-check fails on a real SC2086. Closed after the run."
```

If the local pre-commit hook blocks the commit on the shellcheck finding, that is the hook doing its job: bypassing is forbidden, so instead create the file via the GitHub Contents API on the scratch branch:

```bash
gh api -X PUT repos/smartwatermelon/github-workflows/contents/standards/_known_bad.sh -f branch=claude/scratch-standards-known-bad-<session> -f message="test: known-bad fixture (DO NOT MERGE)" -f content="$(printf '#!/usr/bin/env bash\necho $1\n' | base64)"
```

- [ ] **Step 2: Confirm the check FAILS for the right reason**

```bash
gh pr checks <scratch-pr> --repo smartwatermelon/github-workflows --watch
gh run view <id> --repo smartwatermelon/github-workflows --log | grep -E "SC2086|::error::shellcheck|standards-check: [0-9]+ linter"
```

Expected: `standards-check / run-standards-check` is **failing**, the log names `SC2086` in `standards/_known_bad.sh`, and the summary line reports 1 linter failed.

- [ ] **Step 3: Close the scratch PR and delete the branch**

```bash
gh pr close <scratch-pr> --repo smartwatermelon/github-workflows --delete-branch
git -C /Users/andrewrich/Developer/github-workflows checkout <task-3-branch>
git -C /Users/andrewrich/Developer/github-workflows branch -D claude/scratch-standards-known-bad-<session>
```

Record the scratch PR number, the failing run id, and the grep output in the report.

---

### Task 5: Documentation

**Files:**

- Modify: `README.md` (new section after the `dependabot-auto-merge.yml` section; versioning table gains the `standards-check-v1` namespace)
- Modify: `CLAUDE.md` (mention `tests/run-tests.sh` and `standards/run-standards.sh`)

- [ ] **Step 1: README section**

Add a `## standards-check.yml` section containing: purpose (deterministic required check replacing the judgment reviewer, per dev-env#60 and #154), the caller stub from the workflow header verbatim, the inputs table (seven inputs, types, defaults), the check name `standards-check / run-standards-check`, config precedence (repo root wins, else `standards/`), the pinned tool versions table with a sentence that bumps are manual PRs, the local command `bash standards/run-standards.sh --repo <dir>`, and a "Versioning" note: tags `standards-check-vX.Y.Z` (exact) and `standards-check-v1` (floating, recommended for callers), moved manually and human-authorized like `v3`.

- [ ] **Step 2: CLAUDE.md**

Add under the repo's testing/lint guidance: `bash tests/run-tests.sh` runs the standards suites (requires the five linters via Homebrew); `bash standards/run-standards.sh` is the same check CI runs.

- [ ] **Step 3: Lint, commit, push**

Run: `markdownlint-cli2 --config /Users/andrewrich/Developer/github-workflows/standards/markdownlint.json /Users/andrewrich/Developer/github-workflows/README.md /Users/andrewrich/Developer/github-workflows/CLAUDE.md`
Expected: silent.

```bash
git -C /Users/andrewrich/Developer/github-workflows add README.md CLAUDE.md
git -C /Users/andrewrich/Developer/github-workflows commit -m "docs: document standards-check.yml, its inputs, and its tag namespace"
git -C /Users/andrewrich/Developer/github-workflows push
```

---

## After merge (human steps, one sitting)

1. **Tag the release** (floating-tag moves are human-authorized by this repo's own policy):

   ```bash
   git -C /Users/andrewrich/Developer/github-workflows switch main && git -C /Users/andrewrich/Developer/github-workflows pull
   git -C /Users/andrewrich/Developer/github-workflows tag -a standards-check-v1.0.0 -m "standards-check v1.0.0"
   git -C /Users/andrewrich/Developer/github-workflows tag -f standards-check-v1 standards-check-v1.0.0
   git -C /Users/andrewrich/Developer/github-workflows push origin standards-check-v1.0.0 standards-check-v1
   ```

2. W2 begins with the four pilots (`repo-template`, `pr-review`,
   `claude-code-workflows-agents`, `nightowlstudiollc/.github`) calling
   `@standards-check-v1`. W2 gets its own plan.
