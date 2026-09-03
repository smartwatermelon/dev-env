# Org Migration (I3) and Token Scope Escape Hatch (F4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the 31 active `smartwatermelon/*` repos into a GitHub org named `smartwatermelon` (by renaming the user to `twistedmelonman` first) so `CLAUDE_CODE_OAUTH_TOKEN` lives at org level, without changing a single repo URL.

**Architecture:** Two code deliverables land before any GitHub state changes: a dotfiles PR that teaches `gh-wrapper.sh` the new login and prints a loud fix on scope errors, and a dev-env PR with the transfer scripts, runbook, and rotation doc. Then seven ordered migration steps run, each gated on a verification. The rename is a human UI action; everything else is scripted.

**Tech Stack:** Bash 5, `gh` CLI (wrapped), `jq`, GitHub REST API (`/repos/{o}/{r}/transfer`), dotfiles test runner `bash/tests/run-tests.sh`, Google Calendar connector.

**Spec:** `docs/superpowers/specs/2026-09-03-org-migration-design.md`

## Global Constraints

- Org name is `smartwatermelon`; the personal account becomes `twistedmelonman`. No repo URL, `uses:` ref, tap, marketplace, or remote changes.
- Org plan: Free. `scripts` keeps its repo-level `CLAUDE_CODE_OAUTH_TOKEN` (Free-plan org secrets do not reach private repos).
- `cleanroom` targets `nightowlstudiollc`. Archived repos (27) and the two active forks stay under `twistedmelonman`.
- F4 = escape hatch `env -u GH_TOKEN gh …`. Never add `admin:org` to the CCCLI PAT. No router, no second PAT.
- The wrapper carries exactly one temporary alias `twistedmelonman=smartwatermelon`, removed in Task 12.
- All shell: GNU Bash 5, `shellcheck -S info` clean, no `# shellcheck disable`, `((var += 1))` not `((var++))`, files end with newline.
- Every new or changed test is observed failing before the fix (known-bad), and the failing output is pasted into the task's PR description.
- dotfiles tests: `unset CDPATH`, `isolate_git_env`, sandboxed `HOME`, `unset GH_TOKEN CLAUDE_GH_TOKEN_LOGIN`, stub `gh` on `PATH`.
- Commits: `git -C <abs path>`, never `git add .`, branch `claude/<type>-<desc>-<session>`, trailer `Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6`.
- `docs/token-rotation.md` contains no token material. Ever.
- Human-only actions (rename, org creation, `claude setup-token`, merge-locks, repo deletions) are marked **HUMAN** and the agent stops there.

---

## Order and gates

| Task | Repo | Gate to start |
| --- | --- | --- |
| 1 Owner table + alias | dotfiles | none |
| 2 Scope hint | dotfiles | Task 1 (same branch) |
| 3 move-list + snapshot.sh | dev-env | none (parallel with 1–2) |
| 4 transfer.sh + verify.sh | dev-env | Task 3 |
| 5 Runbook + token-rotation.md | dev-env | none |
| 6 Step 1 pre-flight | both | dotfiles PR **merged**, dev-env PR merged |
| 7 Step 2 rename + org (**HUMAN**) | GitHub | Task 6 |
| 8 Step 3 github-workflows first | GitHub | Task 7 verified |
| 9 Step 4 batch transfer | GitHub | Task 8 verified |
| 10 Step 5 org secret | GitHub | Task 9 verified |
| 11 Step 6 cleanup | GitHub, dev-env | Task 10 verified |
| 12 Alias removal | dotfiles | all three machines re-logged in (Task 7) |
| 13 Step 7 docs | dev-env | Task 11 |

Tasks 1–5 are the code PRs. Tasks 6–13 are migration execution.

---

### Task 1: Owner table, login alias, force-draft list (dotfiles)

**Files:**

- Modify: `bash/gh-wrapper.sh:203-297` (`_gh_wrapper_sync_identity`), `:455` (force-draft list), `:623-624` (exports)
- Modify: `bash/tests/test-gh-wrapper-identity.sh`
- Modify: `bash/tests/test-gh-wrapper-gh-token-precedence.sh:74-80`
- Modify: `bash/tests/test-gh-wrapper-draft-off-org.sh`

**Interfaces:**

- Produces: `_gh_wrapper_logins_equal <desired> <actual>` → exit 0 when equal case-insensitively or when `<actual>` is the alias of `<desired>` per `_GH_WRAPPER_LOGIN_ALIASES` (format `desired=alias[,desired=alias]`); exit 1 otherwise. One-directional: `logins_equal smartwatermelon twistedmelonman` is 1.
- Produces: `_gh_wrapper_keyring_login` → prints the `github.com:` `user:` from `${HOME}/.config/gh/hosts.yml`, empty if absent. Task 2 uses it.

- [ ] **Step 1: Create the branch**

```bash
git -C /Users/andrewrich/Developer/dotfiles switch -c claude/feat-gh-wrapper-org-migration-01RUgidK
git -C /Users/andrewrich/Developer/dotfiles branch --show-current
```

- [ ] **Step 2: Update the identity test for the new table**

In `bash/tests/test-gh-wrapper-identity.sh`, replace the header comment line 11 `#   3. The smartwatermelon default for everything else.` with `#   3. The twistedmelonman default for everything else (smartwatermelon is a temporary alias).`

Replace lines 133-153 (Tier 1 and Tier 3 blocks) with:

```bash
# --- Tier 1: explicitly-claimed owners -------------------------------------
# These win in both directions and must never depend on cwd. "Wrong current"
# fixtures use andrewmrich, not smartwatermelon: smartwatermelon is an alias
# of twistedmelonman until the 2026-09 rename lands, so it never triggers a
# switch (see the alias block below).
assert_desired "lowercase smartwatermelon" "andrewmrich" "smartwatermelon/dotfiles" "twistedmelonman"
assert_desired "lowercase nightowlstudiollc" "andrewmrich" "nightowlstudiollc/kebab-tax" "twistedmelonman"
assert_desired "lowercase twistedmelonman" "andrewmrich" "twistedmelonman/old-archived" "twistedmelonman"
assert_desired "already twistedmelonman stays" "twistedmelonman" "smartwatermelon/dotfiles" "twistedmelonman"
assert_desired "beacon-biosignals org" "twistedmelonman" "beacon-biosignals/somerepo" "andrewmrich"
# The git-pkgs-proxy case: a fork created during Beacon work, owned by
# andrewmrich rather than the beacon-biosignals org.
assert_desired "andrewmrich personal fork" "twistedmelonman" "andrewmrich/git-pkgs-proxy" "andrewmrich"

# Case-insensitivity across all claimed owners
# (regression: smartwatermelon/dotfiles#159).
assert_desired "mixed-case SmartWatermelon" "andrewmrich" "SmartWatermelon/dotfiles" "twistedmelonman"
assert_desired "upper-case NIGHTOWLSTUDIOLLC" "andrewmrich" "NIGHTOWLSTUDIOLLC/kebab-tax" "twistedmelonman"
assert_desired "mixed-case TwistedMelonMan" "andrewmrich" "TwistedMelonMan/old-archived" "twistedmelonman"
assert_desired "mixed-case Beacon-BioSignals" "twistedmelonman" "Beacon-BioSignals/somerepo" "andrewmrich"
assert_desired "mixed-case AndrewMRich" "twistedmelonman" "AndrewMRich/git-pkgs-proxy" "andrewmrich"

# --- Temporary alias (remove with the alias, dev-env org-migration Step 6) ---
# Before the rename, both tokens still report smartwatermelon. That must be
# accepted as twistedmelonman, in both directions the wrapper compares
# (hosts.yml here; GH_TOKEN in test-gh-wrapper-gh-token-precedence.sh).
assert_no_switch() {
  local label="$1" current_user="$2" repo_arg="$3"
  rm -f "${switch_log}"
  cat >"${HOME}/.config/gh/hosts.yml" <<EOF
github.com:
    user: ${current_user}
EOF
  if ! _gh_wrapper_sync_identity --repo "${repo_arg}" pr list; then
    echo "FAIL: ${label} — _gh_wrapper_sync_identity returned non-zero"
    fail=1
    return
  fi
  local got
  got="$(cat "${switch_log}" 2>/dev/null || true)"
  if [[ -z "${got}" ]]; then
    echo "PASS: ${label} (no switch, ${current_user} accepted)"
  else
    echo "FAIL: ${label} — unexpected switch attempted to '${got}'"
    fail=1
  fi
}
assert_no_switch "alias: smartwatermelon accepted for twistedmelonman" "smartwatermelon" "smartwatermelon/dotfiles"
assert_no_switch "alias: SmartWatermelon accepted case-insensitively" "SmartWatermelon" "nightowlstudiollc/kebab-tax"

if _gh_wrapper_logins_equal twistedmelonman smartwatermelon; then
  echo "PASS: logins_equal accepts the alias"
else
  echo "FAIL: logins_equal rejects the alias"
  fail=1
fi
if _gh_wrapper_logins_equal smartwatermelon twistedmelonman; then
  echo "FAIL: logins_equal is not one-directional"
  fail=1
else
  echo "PASS: logins_equal is one-directional"
fi
if _gh_wrapper_logins_equal twistedmelonman andrewmrich; then
  echo "FAIL: logins_equal accepted an unrelated login"
  fail=1
else
  echo "PASS: logins_equal rejects an unrelated login"
fi

# --- Tier 3: default ---------------------------------------------------------
# An owner claimed by neither identity, with no Beacon context, defaults to
# twistedmelonman.
assert_desired "unclaimed owner defaults to twistedmelonman" "andrewmrich" "someotherorg/somerepo" "twistedmelonman"
```

Then update the remaining fixtures in the Tier 2 block and the Tier-1-beats-Tier-2 block: every `"smartwatermelon"` in the `current_user` or `expected` positions of `assert_desired_in` becomes `"twistedmelonman"` (lines 162-163, 169-170, 177-178, 185-186, 193-194). The `assert_warns` hosts.yml fixture (line 207) becomes `user: twistedmelonman`.

- [ ] **Step 3: Update the precedence test**

Replace lines 74-80 of `bash/tests/test-gh-wrapper-gh-token-precedence.sh` with:

```bash
# Case 3: GH_TOKEN matching the resolved identity -> proceeds.
if _sync_under_env GH_TOKEN="fake-token-for-twistedmelonman" \
  CLAUDE_GH_TOKEN_LOGIN="twistedmelonman"; then
  _pass "matching GH_TOKEN: proceeds"
else
  _fail "matching GH_TOKEN: should proceed"
fi

# Case 3b: GH_TOKEN still reporting the pre-rename login. Accepted through the
# temporary alias (dev-env org-migration design, "Temporary login alias").
# Delete this case together with the alias.
if _sync_under_env GH_TOKEN="fake-token-for-smartwatermelon" \
  CLAUDE_GH_TOKEN_LOGIN="smartwatermelon"; then
  _pass "aliased GH_TOKEN (smartwatermelon): proceeds"
else
  _fail "aliased GH_TOKEN (smartwatermelon): should proceed via alias"
fi
```

Change the hosts.yml fixture at line 31 to `user: twistedmelonman`.

- [ ] **Step 4: Update the draft test**

After the line `assert_args "nightowlstudiollc explicit -R" 0 pr create -R nightowlstudiollc/somerepo --title x` in `bash/tests/test-gh-wrapper-draft-off-org.sh`, add:

```bash
# twistedmelonman is the personal account that keeps the archived repos and
# forks after the 2026-09 org migration: in-org, no draft forced.
assert_args "twistedmelonman explicit --repo" 0 pr create --repo twistedmelonman/old-archived --title x
```

- [ ] **Step 5: Run the three tests and record the known-bad output**

```bash
bash /Users/andrewrich/Developer/dotfiles/bash/tests/run-tests.sh gh-wrapper 2>&1 | tee /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/task1-known-bad.txt
```

Expected: FAIL lines including `lowercase smartwatermelon — expected switch to 'twistedmelonman', got 'smartwatermelon'`, `matching GH_TOKEN: should proceed`, `logins_equal` "command not found", and `twistedmelonman explicit --repo — expected --draft present=0, got=1`. Runner exits non-zero. Keep the file; it goes in the PR body.

- [ ] **Step 6: Add the alias, the helpers, and the new table**

In `bash/gh-wrapper.sh`, insert directly before the `_gh_wrapper_sync_identity()` comment block (before line 196, the comment that begins `# Auto-switch gh identity`; if that comment starts on a different line, anchor on the line `_gh_wrapper_sync_identity() {` and insert before its leading comment):

```bash
# TEMPORARY until the 2026-09 rename lands (dev-env
# docs/superpowers/specs/2026-09-03-org-migration-design.md, Step 2). Remove
# in the Step 6 follow-up together with every test case that names it. Both
# logins are the same person: the personal account is renamed from
# smartwatermelon to twistedmelonman, and until that happens every token
# still reports the old name. Format: desired=alias[,desired=alias...].
_GH_WRAPPER_LOGIN_ALIASES="${_GH_WRAPPER_LOGIN_ALIASES:-twistedmelonman=smartwatermelon}"

# True when `actual` is `desired` or one of desired's aliases, case-
# insensitively. One-directional: an alias never stands in for its own
# desired value as a `desired` argument.
_gh_wrapper_logins_equal() {
  local desired="${1,,}" actual="${2,,}"
  [[ "${desired}" == "${actual}" ]] && return 0
  local IFS=','
  local pair
  for pair in ${_GH_WRAPPER_LOGIN_ALIASES}; do
    pair="${pair,,}"
    if [[ "${pair%%=*}" == "${desired}" && "${pair#*=}" == "${actual}" ]]; then
      return 0
    fi
  done
  return 1
}

# The keyring login gh will use: the `user:` under `github.com:` in hosts.yml.
# Empty when no host entry exists.
_gh_wrapper_keyring_login() {
  awk '/^github\.com:/{f=1} f && /^ *user:/{print $2; exit}' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'"
}
```

Replace the owner table (lines 209-225, including the stale NOTE comment) with:

```bash
  # smartwatermelon is the ORG (2026-09 migration); nightowlstudiollc is the
  # other org; twistedmelonman is the personal account that owns both and
  # keeps the archived repos and forks. All three resolve to the person.
  case "${owner,,}" in
    smartwatermelon | nightowlstudiollc | twistedmelonman) desired="twistedmelonman" ;;
    beacon-biosignals | andrewmrich) desired="andrewmrich" ;;
    *)
      if _gh_wrapper_is_beacon_context; then
        desired="andrewmrich"
      else
        desired="twistedmelonman"
      fi
      ;;
  esac
```

Replace line 278 `if [[ "${token_login,,}" != "${desired,,}" ]]; then` with:

```bash
    if ! _gh_wrapper_logins_equal "${desired}" "${token_login}"; then
```

Replace lines 287-289:

```bash
  current="$(_gh_wrapper_keyring_login)"

  if [[ -n "${current}" ]] && ! _gh_wrapper_logins_equal "${desired}" "${current}"; then
```

Replace line 455 `smartwatermelon | nightowlstudiollc) ;; # in-org: no change` with:

```bash
        smartwatermelon | nightowlstudiollc | twistedmelonman) ;; # in-org: no change
```

Update the export lines 623-624: append `_gh_wrapper_logins_equal _gh_wrapper_keyring_login` to the `export -f` list, and append `_GH_WRAPPER_LOGIN_ALIASES` to the `export` list.

- [ ] **Step 7: Lint and run the tests**

```bash
shellcheck -S info /Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-identity.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-draft-off-org.sh
bash /Users/andrewrich/Developer/dotfiles/bash/tests/run-tests.sh gh-wrapper
```

Expected: shellcheck silent; every gh-wrapper test PASS, runner exit 0.

- [ ] **Step 8: Commit**

```bash
git -C /Users/andrewrich/Developer/dotfiles add bash/gh-wrapper.sh bash/tests/test-gh-wrapper-identity.sh bash/tests/test-gh-wrapper-gh-token-precedence.sh bash/tests/test-gh-wrapper-draft-off-org.sh
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
feat(gh-wrapper): resolve personal-account owners to twistedmelonman

Prepares for the 2026-09 org migration: the smartwatermelon user is
renamed to twistedmelonman and the name is re-claimed as an org. The
owner table now maps smartwatermelon, nightowlstudiollc, and
twistedmelonman to the person, and the force-draft in-org list gains
twistedmelonman.

A single dated alias (twistedmelonman=smartwatermelon) keeps every
wrapped call working between this change landing and the rename. It is
removed in a follow-up once all machines have re-logged in.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
head -6 "$(git -C /Users/andrewrich/Developer/dotfiles rev-parse --git-dir)/last-review-result.log"
```

---

### Task 2: F4 scope-error hint (dotfiles)

**Files:**

- Modify: `bash/gh-wrapper.sh` (new helpers before the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` split at line 476; standalone exec at line 553)
- Create: `bash/tests/test-gh-wrapper-scope-hint.sh`

**Interfaces:**

- Consumes: `_gh_wrapper_keyring_login` (Task 1).
- Produces: `_gh_wrapper_run_with_scope_hint <real_gh> <args…>` runs `<real_gh>`, mirrors its stderr live, and on non-zero exit with a scope error prints the hint; returns the real exit code. `_gh_wrapper_scope_from_file <file>` prints the scope name or nothing. `_gh_wrapper_print_scope_hint <scope> <args…>` prints the hint to stderr.
- Only the standalone wrapper (`~/.local/bin/gh`) runs the hint. Function mode reaches it through `command gh`, so no dedupe variable is needed. If `~/.local/bin/gh` is not on `PATH`, no hint is printed; that is the documented limit.

- [ ] **Step 1: Measure gh's real scope-error text (read-only, no state change)**

```bash
gh api orgs/nightowlstudiollc/actions/secrets 2>&1 >/dev/null | cat -A | head -5
```

`GH_TOKEN` (the CCCLI PAT, no `admin:org`) is set in the session, so this must fail. Expected shape, from gh's `ScopesSuggestion`: a line containing `This API operation needs the "admin:org" scope.` Paste the observed line verbatim into the stub in Step 2. If the observed text differs from the pattern below, change the pattern, not the measurement.

- [ ] **Step 2: Write the failing test**

Create `bash/tests/test-gh-wrapper-scope-hint.sh`:

```bash
#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's F4 scope-error hint.
# Run directly: bash bash/tests/test-gh-wrapper-scope-hint.sh
#
# When the real gh fails with GitHub's "needs the ... scope" error, the
# wrapper must print the exact fix (env -u GH_TOKEN ... when GH_TOKEN is set;
# gh auth refresh otherwise), keep the original stderr, and pass the exit
# code through. A non-scope failure prints no hint. A success prints nothing.
# Design: dev-env docs/superpowers/specs/2026-09-03-org-migration-design.md.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"
WORKDIR="/tmp/gh-wrapper-scope-hint-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML
unset GH_TOKEN
# The wrapper's F3 guard resolves GH_TOKEN's login through `gh api user` when
# this is unset; that would hit the stub and fail. Pin it so no case here
# depends on identity resolution — the scope hint is the thing under test.
export CLAUDE_GH_TOKEN_LOGIN="twistedmelonman"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Three stub gh binaries. Each is the only `gh` on PATH after the wrapper
# itself, which _gh_wrapper_find_real_gh skips.
STUBS="${WORKDIR}/stubs"
mkdir -p "${STUBS}/scope" "${STUBS}/plain403" "${STUBS}/ok"

# Text measured against the real gh binary (Task 2 Step 1 of the plan).
cat >"${STUBS}/scope/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"message":"Resource not accessible by personal access token"}'
echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
echo 'gh: This API operation needs the "admin:org" scope. To create a new token with this scope, run:  gh auth refresh -h github.com -s admin:org' >&2
exit 4
STUB
cat >"${STUBS}/plain403/gh" <<'STUB'
#!/usr/bin/env bash
echo 'gh: Must have admin rights to Repository. (HTTP 403)' >&2
exit 1
STUB
cat >"${STUBS}/ok/gh" <<'STUB'
#!/usr/bin/env bash
echo 'stdout-from-gh'
echo 'stderr-from-gh' >&2
exit 0
STUB
chmod +x "${STUBS}"/*/gh

# Run the wrapper in standalone mode from a non-repo cwd (owner resolution
# yields nothing, so no identity switch is attempted) with the given stub
# first on PATH after the wrapper. Captures stdout and stderr separately.
_run() {
  local stub="$1"
  shift
  (
    cd "${HOME}/neutral-cwd" || exit 99
    PATH="${STUBS}/${stub}:${PATH}" bash "${WRAPPER}" "$@" \
      >"${WORKDIR}/out" 2>"${WORKDIR}/err"
  )
}

# --- Case 1: scope error with GH_TOKEN set -> env -u hint ---------------------
GH_TOKEN="fixture-token" _run scope secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all
rc=$?
err="$(cat "${WORKDIR}/err")"
out="$(cat "${WORKDIR}/out")"

if [[ "${rc}" -eq 4 ]]; then
  _pass "scope error: exit code passes through (4)"
else
  _fail "scope error: expected exit 4, got ${rc}"
fi
if [[ "${err}" == *'needs the "admin:org" scope'* ]]; then
  _pass "scope error: original stderr preserved"
else
  _fail "scope error: original stderr missing, got: ${err}"
fi
if [[ "${err}" == *"[gh] GH_TOKEN is set and lacks the 'admin:org' scope"* ]]; then
  _pass "scope error: hint names the scope"
else
  _fail "scope error: hint missing, got: ${err}"
fi
if [[ "${err}" == *"env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all"* ]]; then
  _pass "scope error: hint carries the exact re-run command"
else
  _fail "scope error: re-run command missing, got: ${err}"
fi
if [[ "${err}" == *"keyring identity for twistedmelonman"* ]]; then
  _pass "scope error: hint names the keyring login from hosts.yml"
else
  _fail "scope error: keyring login missing, got: ${err}"
fi
if [[ "${out}" == *'Resource not accessible'* ]]; then
  _pass "scope error: stdout passes through untouched"
else
  _fail "scope error: stdout lost, got: ${out}"
fi

# --- Case 2: scope error WITHOUT GH_TOKEN -> gh auth refresh hint -------------
_run scope secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" == *"gh auth refresh -h github.com -s admin:org"* && "${err}" == *"[gh]"* ]]; then
  _pass "scope error, no GH_TOKEN: refresh hint"
else
  _fail "scope error, no GH_TOKEN: expected refresh hint, got: ${err}"
fi
if [[ "${err}" == *"env -u GH_TOKEN"* ]]; then
  _fail "scope error, no GH_TOKEN: must not suggest env -u"
else
  _pass "scope error, no GH_TOKEN: does not suggest env -u"
fi

# --- Case 3: negative control, non-scope 403 -> no hint -----------------------
GH_TOKEN="fixture-token" _run plain403 pr list --repo smartwatermelon/dotfiles
rc=$?
err="$(cat "${WORKDIR}/err")"
if [[ "${rc}" -eq 1 && "${err}" == *"Must have admin rights"* && "${err}" != *"[gh]"* ]]; then
  _pass "non-scope 403: stderr preserved, no hint, exit 1"
else
  _fail "non-scope 403: expected no hint, got rc=${rc} err=${err}"
fi

# --- Case 4: negative control, success -> nothing added -----------------------
GH_TOKEN="fixture-token" _run ok repo view smartwatermelon/dotfiles
rc=$?
if [[ "${rc}" -eq 0 && "$(cat "${WORKDIR}/out")" == "stdout-from-gh" && "$(cat "${WORKDIR}/err")" == "stderr-from-gh" ]]; then
  _pass "success: stdout and stderr untouched, exit 0"
else
  _fail "success: output altered, rc=${rc} out=$(cat "${WORKDIR}/out") err=$(cat "${WORKDIR}/err")"
fi

# --- Case 5: no stray temp files --------------------------------------------
if compgen -G "${TMPDIR:-/tmp}/gh-wrapper-stderr.*" >/dev/null; then
  _fail "temp stderr files left behind"
else
  _pass "temp stderr files cleaned up"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-scope-hint.sh: all assertions passed"
  exit 0
fi
exit 1
```

- [ ] **Step 3: Run it, record the known-bad**

```bash
bash /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-scope-hint.sh 2>&1 | tee -a /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/task2-known-bad.txt
```

Expected: cases 1 (hint lines), 2 fail with "hint missing"; exit code, stderr-preserved, case 3, case 4, case 5 pass. Exit 1.

- [ ] **Step 4: Implement the helpers**

In `bash/gh-wrapper.sh`, insert before the line `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then` (line 476):

```bash
# --- F4: scope-error hint ------------------------------------------------------
# GH_TOKEN (the CCCLI PAT) and the keyring token are the same login; only the
# scopes differ. When gh fails because the active token lacks a scope, say
# exactly how to re-run the one command with the other token. Detection is
# gh's own ScopesSuggestion text, so there is no command classifier to get
# wrong. Design: dev-env docs/superpowers/specs/2026-09-03-org-migration-design.md.

# Print the scope named in a captured stderr file, or nothing.
_gh_wrapper_scope_from_file() {
  grep -oE "needs the [\"'][A-Za-z0-9:_]+[\"'] scope" "$1" 2>/dev/null \
    | head -1 | sed -E "s/needs the [\"']([^\"']+)[\"'] scope/\1/"
}

_gh_wrapper_print_scope_hint() {
  local scope="$1"
  shift
  local cmd
  cmd="$(printf '%q ' "$@")"
  cmd="${cmd% }"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    local keyring
    keyring="$(_gh_wrapper_keyring_login)"
    echo "[gh] GH_TOKEN is set and lacks the '${scope}' scope. The keyring identity" >&2
    echo "[gh] for ${keyring:-<none in hosts.yml>} has it. Re-run this one command without GH_TOKEN:" >&2
    echo "[gh]   env -u GH_TOKEN gh ${cmd}" >&2
    echo "[gh] (Do not add the scope to the CCCLI PAT — it is exported into every session.)" >&2
  else
    echo "[gh] The active gh token lacks the '${scope}' scope. Add it to the keyring token:" >&2
    echo "[gh]   gh auth refresh -h github.com -s ${scope}" >&2
    echo "[gh] then re-run: gh ${cmd}" >&2
  fi
}

# Run the real gh. stderr goes to the terminal live AND to a temp file; stdout
# is untouched (fd 3 carries it around the pipe). On non-zero exit, a scope
# error in the file triggers the hint. The real exit code is returned.
_gh_wrapper_run_with_scope_hint() {
  local real_gh="$1"
  shift
  local errfile rc=0
  if ! errfile="$(mktemp "${TMPDIR:-/tmp}/gh-wrapper-stderr.XXXXXX")"; then
    "${real_gh}" "$@"
    return $?
  fi
  # `|| true` keeps `set -e` (standalone mode) from aborting on the failing
  # pipeline before rc is read.
  {
    "${real_gh}" "$@" 2>&1 1>&3 3>&- | tee "${errfile}" >&2
    rc="${PIPESTATUS[0]}"
  } 3>&1 || true
  if [[ "${rc}" -ne 0 ]]; then
    local scope
    scope="$(_gh_wrapper_scope_from_file "${errfile}")"
    if [[ -n "${scope}" ]]; then
      _gh_wrapper_print_scope_hint "${scope}" "$@"
    fi
  fi
  rm -f "${errfile}"
  return "${rc}"
}
```

Replace line 553 `exec "${REAL_GH}" "$@"` with:

```bash
  # Not exec: the hint needs gh's exit status and stderr after it returns.
  _gh_wrapper_rc=0
  _gh_wrapper_run_with_scope_hint "${REAL_GH}" "$@" || _gh_wrapper_rc=$?
  exit "${_gh_wrapper_rc}"
```

Append `_gh_wrapper_run_with_scope_hint _gh_wrapper_scope_from_file _gh_wrapper_print_scope_hint` to the `export -f` list.

- [ ] **Step 5: Lint, run the new test and the whole suite**

```bash
shellcheck -S info /Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-scope-hint.sh
bash /Users/andrewrich/Developer/dotfiles/bash/tests/run-tests.sh
```

Expected: shellcheck silent; 25 tests, all pass.

- [ ] **Step 6: Manual check against the real gh (read-only)**

```bash
gh api orgs/nightowlstudiollc/actions/secrets
```

Expected: gh's 403 text, followed by the four `[gh]` hint lines with `env -u GH_TOKEN gh api orgs/nightowlstudiollc/actions/secrets`. Then run that suggested command; it must list the org secrets (proves the keyring token has `admin:org`). Paste both outputs into the PR body.

- [ ] **Step 7: Commit, push, open the PR**

```bash
git -C /Users/andrewrich/Developer/dotfiles add bash/gh-wrapper.sh bash/tests/test-gh-wrapper-scope-hint.sh
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
feat(gh-wrapper): print the escape hatch on a token-scope error (F4)

GH_TOKEN and the keyring token are the same login; only the scopes
differ. When gh fails with its own "needs the ... scope" text, the
standalone wrapper now prints the exact re-run command with GH_TOKEN
unset (or `gh auth refresh -s <scope>` when no GH_TOKEN is set). stderr
is mirrored live through tee; stdout and the exit code pass through.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
git -C /Users/andrewrich/Developer/dotfiles diff origin/main...HEAD | ~/.claude/hooks/run-review.sh --mode=codebase --no-file
git -C /Users/andrewrich/Developer/dotfiles push -u origin claude/feat-gh-wrapper-org-migration-01RUgidK
gh pr create -R smartwatermelon/dotfiles --title "feat(gh-wrapper): twistedmelonman owner table, login alias, F4 scope hint" --body-file /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/dotfiles-pr-body.md
```

The PR body: link to the spec, the two known-bad outputs, the Step 6 manual outputs, and the line "Alias removal follow-up: Task 12 of the plan." Surface the PR (repo, number, URL) to Andrew. Merge needs a merge-lock from Andrew (**HUMAN**).

---

### Task 3: Move list and snapshot.sh (dev-env)

**Files:**

- Create: `scripts/org-migration/move-list.txt`
- Create: `scripts/org-migration/lib.sh`
- Create: `scripts/org-migration/snapshot.sh`
- Create: `scripts/org-migration/tests/test-snapshot.sh`
- Create: `scripts/org-migration/tests/run-tests.sh`

**Interfaces:**

- `move-list.txt`: one `repo<TAB>target-org` per line, `#` comments allowed.
- `lib.sh`: `om_read_move_list <file>` prints `repo target` pairs (space separated, comments stripped), fails on a malformed line. `om_lookup_owner <repo>` prints `login type` for `repos/smartwatermelon/<repo>` (redirects cover every migration state), fails non-zero on 404.
- `snapshot.sh <move-list> <outdir>`: writes `<outdir>/<repo>.json` per repo, exit 1 if any repo failed (after trying all).
- Snapshot JSON shape (Task 4's verify.sh diffs `del(.owner)`):

```json
{"repo":"dotfiles","owner":{"login":"smartwatermelon","type":"User"},
 "default_branch":"main","visibility":"public","archived":false,
 "topics":[],"pages":null,"secrets":["CLAUDE_CODE_OAUTH_TOKEN"],
 "protection":null,"rulesets":[]}
```

- [ ] **Step 1: Branch**

```bash
git -C /Users/andrewrich/Developer/dev-env switch -c claude/feat-org-migration-tooling-01RUgidK
```

(The spec+plan branch `claude/docs-org-migration-design-01RUgidK` is separate; base this on `main` after that PR merges, or on that branch if it has not.)

- [ ] **Step 2: Write the move list from the live inventory**

```bash
gh repo list smartwatermelon --limit 100 --json name,isArchived,isFork --jq '.[] | select(.isArchived==false and .isFork==false) | .name' | sort
```

Expected: 31 names. Write `scripts/org-migration/move-list.txt`:

```text
# repo<TAB>target-org — reviewed by hand in the PR that added it.
# Source of truth for transfer.sh; never derived at run time.
# github-workflows goes first, alone (design Step 3); transfer.sh --only.
# cleanroom is the one repo that targets nightowlstudiollc.
```

followed by the 31 lines, each `name<TAB>smartwatermelon`, except `cleanroom<TAB>nightowlstudiollc`. Confirm the count: `grep -vc '^#' scripts/org-migration/move-list.txt` → 31. Confirm `github-workflows` is present.

- [ ] **Step 3: Write the failing snapshot test**

Create `scripts/org-migration/tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Run every test-*.sh in this directory; exit non-zero if any fails.
set -uo pipefail
unset CDPATH
dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${dir}"/test-*.sh; do
  echo "== ${t##*/}"
  if ! bash "${t}"; then fail=1; fi
done
exit "${fail}"
```

Create `scripts/org-migration/tests/test-snapshot.sh`:

```bash
#!/usr/bin/env bash
# snapshot.sh must write one JSON per repo with the documented shape, and
# must exit non-zero, naming the repo, when a repo cannot be read.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="${HERE}/../snapshot.sh"
WORK="/tmp/om-snapshot-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/out"
trap 'rm -rf "${WORK}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh: answers `gh api <path> [--jq <expr>]` from canned responses and
# honors --jq by piping through the real jq, as gh does.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
path="$2"
jqexpr=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() { if [[ -n "${jqexpr}" ]]; then jq -c "${jqexpr}"; else cat; fi; }
case "${path}" in
  repos/smartwatermelon/dotfiles)
    echo '{"name":"dotfiles","owner":{"login":"smartwatermelon","type":"User"},"default_branch":"main","visibility":"public","archived":false,"has_pages":false}' | emit ;;
  repos/smartwatermelon/dotfiles/topics) echo '{"names":["bash","dotfiles"]}' | emit ;;
  repos/smartwatermelon/dotfiles/actions/secrets) echo '{"secrets":[{"name":"CLAUDE_CODE_OAUTH_TOKEN"},{"name":"ANOTHER"}]}' | emit ;;
  repos/smartwatermelon/dotfiles/branches/main/protection) echo '{"message":"Branch not protected"}' >&2; exit 1 ;;
  repos/smartwatermelon/dotfiles/rulesets) echo '[{"id":1,"name":"main"}]' | emit ;;
  repos/smartwatermelon/dotfiles/pages) echo '{"message":"Not Found"}' >&2; exit 1 ;;
  repos/smartwatermelon/ghost*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) echo "stub: unexpected path ${path}" >&2; exit 2 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"

printf 'dotfiles\tsmartwatermelon\n' >"${WORK}/list-good"
printf '# comment\ndotfiles\tsmartwatermelon\nghost\tsmartwatermelon\n' >"${WORK}/list-bad"

# Case 1: good list -> JSON with the documented shape.
if PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-good" "${WORK}/out"; then
  _pass "good list: exit 0"
else
  _fail "good list: expected exit 0"
fi
f="${WORK}/out/dotfiles.json"
if [[ -f "${f}" ]] && jq -e '.repo=="dotfiles" and .owner.login=="smartwatermelon" and .owner.type=="User" and .default_branch=="main" and .visibility=="public" and .archived==false and .topics==["bash","dotfiles"] and .secrets==["ANOTHER","CLAUDE_CODE_OAUTH_TOKEN"] and .protection==null and (.rulesets|length)==1 and .pages==null' "${f}" >/dev/null; then
  _pass "good list: JSON shape"
else
  _fail "good list: JSON shape wrong: $(cat "${f}" 2>/dev/null)"
fi

# Case 2 (known-bad): a repo that 404s must fail non-zero and name the repo,
# after still writing the good one.
rm -rf "${WORK}/out" && mkdir -p "${WORK}/out"
err="$(PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-bad" "${WORK}/out" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -ne 0 && "${err}" == *ghost* ]]; then
  _pass "missing repo: non-zero and names ghost"
else
  _fail "missing repo: expected non-zero naming ghost, got rc=${rc} err=${err}"
fi
if [[ -f "${WORK}/out/dotfiles.json" ]]; then
  _pass "missing repo: the good repo was still snapshotted"
else
  _fail "missing repo: good repo skipped"
fi

# Case 3: malformed line rejected before any API call.
printf 'dotfiles smartwatermelon\n' >"${WORK}/list-malformed"
if PATH="${WORK}/bin:${PATH}" bash "${SNAPSHOT}" "${WORK}/list-malformed" "${WORK}/out" 2>/dev/null; then
  _fail "malformed line: should fail"
else
  _pass "malformed line: rejected"
fi

exit "${fail}"
```

- [ ] **Step 4: Run it to see it fail**

```bash
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/test-snapshot.sh
```

Expected: FAIL lines ("No such file" for snapshot.sh), exit 1.

- [ ] **Step 5: Write lib.sh and snapshot.sh**

`scripts/org-migration/lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for the 2026-09 org migration scripts. Sourced, not run.
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md

# Every lookup goes through repos/smartwatermelon/<repo>. Before the rename
# that is the real path; after the rename GitHub redirects it to
# twistedmelonman/<repo>; after the transfer it is the real path again (or a
# redirect to nightowlstudiollc/cleanroom). One path, every state.
OM_LOOKUP_OWNER="smartwatermelon"

# Print "repo target" per non-comment line. Fail on a line that is not
# exactly two tab-separated fields.
om_read_move_list() {
  local file="$1" line repo target extra n=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    IFS=$'\t' read -r repo target extra <<<"${line}"
    if [[ -z "${repo}" || -z "${target}" || -n "${extra}" || "${repo}" == *" "* ]]; then
      echo "move-list: line ${n} is not 'repo<TAB>target': ${line}" >&2
      return 1
    fi
    printf '%s %s\n' "${repo}" "${target}"
  done <"${file}"
}

# Print "login type" for the repo's current owner. Non-zero on any failure.
om_lookup_owner() {
  local repo="$1"
  gh api "repos/${OM_LOOKUP_OWNER}/${repo}" --jq '.owner.login + " " + .owner.type'
}
```

`scripts/org-migration/snapshot.sh`:

```bash
#!/usr/bin/env bash
# Snapshot the settings of every repo on the move list, one JSON per repo.
# Read-only. Usage: snapshot.sh <move-list> <outdir>
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

if [[ $# -ne 2 ]]; then
  echo "usage: snapshot.sh <move-list> <outdir>" >&2
  exit 2
fi
list="$1"
outdir="$2"
mkdir -p "${outdir}"

# Fetch a sub-resource; print `null` when GitHub answers 404 (not configured).
_optional() {
  local out
  if out="$(gh api "$1" 2>/dev/null)"; then
    printf '%s\n' "${out}"
  else
    echo null
  fi
}

pairs="$(om_read_move_list "${list}")" || exit 1
failed=0
while read -r repo _target; do
  base="repos/${OM_LOOKUP_OWNER}/${repo}"
  if ! core="$(gh api "${base}")"; then
    echo "snapshot: FAILED to read ${repo}" >&2
    failed=$((failed + 1))
    continue
  fi
  default_branch="$(jq -r '.default_branch' <<<"${core}")"
  topics="$(gh api "${base}/topics" --jq '.names' 2>/dev/null || echo '[]')"
  secrets="$(gh api "${base}/actions/secrets" --jq '[.secrets[].name] | sort' 2>/dev/null || echo '[]')"
  protection="$(_optional "${base}/branches/${default_branch}/protection")"
  rulesets="$(_optional "${base}/rulesets")"
  pages="$(_optional "${base}/pages")"
  jq -n \
    --arg repo "${repo}" \
    --argjson core "${core}" \
    --argjson topics "${topics}" \
    --argjson secrets "${secrets}" \
    --argjson protection "${protection}" \
    --argjson rulesets "${rulesets}" \
    --argjson pages "${pages}" \
    '{repo: $repo,
      owner: {login: $core.owner.login, type: $core.owner.type},
      default_branch: $core.default_branch,
      visibility: $core.visibility,
      archived: $core.archived,
      topics: $topics, pages: $pages, secrets: $secrets,
      protection: $protection, rulesets: $rulesets}' >"${outdir}/${repo}.json"
  echo "snapshot: ${repo} -> ${outdir}/${repo}.json"
done <<<"${pairs}"

if [[ "${failed}" -gt 0 ]]; then
  echo "snapshot: ${failed} repo(s) failed" >&2
  exit 1
fi
```

- [ ] **Step 6: Lint and test**

```bash
chmod +x /Users/andrewrich/Developer/dev-env/scripts/org-migration/snapshot.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/run-tests.sh
shellcheck -S info /Users/andrewrich/Developer/dev-env/scripts/org-migration/lib.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/snapshot.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/*.sh
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/run-tests.sh
```

Expected: shellcheck silent; all PASS, exit 0.

- [ ] **Step 7: Live read-only smoke test on one repo**

```bash
printf 'dev-env\tsmartwatermelon\n' > /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/one.txt
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/snapshot.sh /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/one.txt /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/snap-one
jq . /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/snap-one/dev-env.json
```

Expected: `owner.login` `smartwatermelon`, `owner.type` `User`, `secrets` contains `CLAUDE_CODE_OAUTH_TOKEN`, `protection` non-null (dev-env is protected).

- [ ] **Step 8: Commit**

```bash
git -C /Users/andrewrich/Developer/dev-env add scripts/org-migration/move-list.txt scripts/org-migration/lib.sh scripts/org-migration/snapshot.sh scripts/org-migration/tests/run-tests.sh scripts/org-migration/tests/test-snapshot.sh
git -C /Users/andrewrich/Developer/dev-env commit -F - <<'EOF'
feat(org-migration): add the move list and the read-only snapshot script

move-list.txt is the checked-in source of truth (31 repos; cleanroom
targets nightowlstudiollc). snapshot.sh records owner, default branch,
visibility, archived, topics, pages, secret names, branch protection,
and rulesets per repo, looking every repo up through
repos/smartwatermelon/<repo> so the same path works before the rename,
after it (redirect), and after the transfer.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
```

---

### Task 4: transfer.sh and verify.sh (dev-env)

**Files:**

- Create: `scripts/org-migration/transfer.sh`
- Create: `scripts/org-migration/verify.sh`
- Create: `scripts/org-migration/tests/test-transfer.sh`
- Create: `scripts/org-migration/tests/test-verify.sh`

**Interfaces:**

- Consumes: `om_read_move_list`, `om_lookup_owner`, `OM_LOOKUP_OWNER` (Task 3), snapshot JSON shape (Task 3).
- `transfer.sh <move-list> [--only <repo>] [--dry-run]`: for each repo, skip if already `<target>`/`Organization`; else `POST repos/<current-login>/<repo>/transfer` with `new_owner=<target>`, then poll `repos/<target>/<repo>` up to 30 times, 2 s apart, until `owner.type` is `Organization`. Failures are reported and skipped; exit 1 at the end if any failed. `--dry-run` prints the POSTs it would make and exits 0.
- `verify.sh <move-list> <baseline-dir> <after-dir> [--clones <dir>]`: runs `snapshot.sh` into `<after-dir>`, then per repo: `del(.owner)` must be identical to baseline; `.owner.type` must be `Organization` and `.owner.login` must equal the target (case-insensitive). Then for every `<clones-dir>/*/.git` whose `origin` matches `github.com[:/]smartwatermelon/`, `git ls-remote --exit-code origin HEAD` must succeed. Exit 1 on any failure, after checking everything. `--clones` defaults to `${HOME}/Developer`.

- [ ] **Step 1: Write the failing transfer test**

Create `scripts/org-migration/tests/test-transfer.sh`:

```bash
#!/usr/bin/env bash
# transfer.sh: idempotent, one POST per repo that needs it, keeps going after
# a failure, exit 1 if anything failed, --dry-run makes no POST.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFER="${HERE}/../transfer.sh"
WORK="/tmp/om-transfer-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/state"
trap 'rm -rf "${WORK}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# Stub gh with per-repo state files: <state>/<repo> holds "login type".
# A POST .../transfer flips the state to "<new_owner> Organization" unless the
# repo is named "stuck", which never flips. Every POST is logged. GET answers
# are JSON piped through the real jq when --jq is given, as gh does.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
STATE="${OM_TEST_STATE:?}"
args=("$@")
path=""; method="GET"; new_owner=""; jqexpr=""
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    api) ;;
    -X) i=$((i + 1)); method="${args[$i]}" ;;
    -f) i=$((i + 1)); [[ "${args[$i]}" == new_owner=* ]] && new_owner="${args[$i]#new_owner=}" ;;
    --jq) i=$((i + 1)); jqexpr="${args[$i]}" ;;
    -*) ;;
    *) [[ -z "${path}" ]] && path="${args[$i]}" ;;
  esac
  i=$((i + 1))
done
if [[ "${method}" == "POST" && "${path}" == */transfer ]]; then
  repo="${path#repos/*/}"; repo="${repo%/transfer}"
  echo "POST ${path} new_owner=${new_owner}" >>"${STATE}/posts"
  if [[ "${repo}" != "stuck" ]]; then
    echo "${new_owner} Organization" >"${STATE}/${repo}"
  fi
  echo '{}'
  exit 0
fi
repo="${path#repos/*/}"
if [[ -f "${STATE}/${repo}" ]]; then
  read -r login type <"${STATE}/${repo}"
  # repos/smartwatermelon/<repo> always resolves (the redirect path). A lookup
  # under any other owner resolves only once that owner actually has it.
  if [[ "${path}" == "repos/smartwatermelon/${repo}" || "${path}" == "repos/${login}/${repo}" ]]; then
    json="$(printf '{"name":"%s","owner":{"login":"%s","type":"%s"}}' "${repo}" "${login}" "${type}")"
    if [[ -n "${jqexpr}" ]]; then jq -r "${jqexpr}" <<<"${json}"; else echo "${json}"; fi
    exit 0
  fi
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
STUB
chmod +x "${WORK}/bin/gh"

export OM_TEST_STATE="${WORK}/state"
echo "twistedmelonman User" >"${WORK}/state/alpha"
echo "twistedmelonman User" >"${WORK}/state/beta"
echo "nightowlstudiollc Organization" >"${WORK}/state/done"
echo "twistedmelonman User" >"${WORK}/state/stuck"
printf 'alpha\tsmartwatermelon\ndone\tnightowlstudiollc\nbeta\tsmartwatermelon\n' >"${WORK}/list"
printf 'stuck\tsmartwatermelon\nbeta\tsmartwatermelon\n' >"${WORK}/list-stuck"

run() { PATH="${WORK}/bin:${PATH}" OM_POLL_SECONDS=0 OM_POLL_MAX=2 bash "${TRANSFER}" "$@"; }

# Case 1: dry run makes no POST.
run "${WORK}/list" --dry-run >/dev/null 2>&1
if [[ ! -f "${WORK}/state/posts" ]]; then _pass "dry-run: no POST"; else _fail "dry-run: POSTed"; fi

# Case 2: real run POSTs alpha and beta, skips done, exits 0.
if run "${WORK}/list" >/dev/null 2>&1; then _pass "run: exit 0"; else _fail "run: expected exit 0"; fi
if [[ "$(grep -c '^POST' "${WORK}/state/posts")" == "2" ]] && grep -q 'repos/twistedmelonman/alpha/transfer new_owner=smartwatermelon' "${WORK}/state/posts" && grep -q 'repos/twistedmelonman/beta/transfer new_owner=smartwatermelon' "${WORK}/state/posts" && ! grep -q '/done/' "${WORK}/state/posts"; then
  _pass "run: exactly alpha and beta POSTed, done skipped"
else
  _fail "run: wrong POSTs: $(cat "${WORK}/state/posts")"
fi

# Case 3: idempotent second run makes no new POST.
run "${WORK}/list" >/dev/null 2>&1
if [[ "$(grep -c '^POST' "${WORK}/state/posts")" == "2" ]]; then _pass "rerun: no new POST"; else _fail "rerun: POSTed again"; fi

# Case 4 (known-bad): a repo that never resolves under the target is reported,
# the loop continues to beta, and the exit code is 1.
echo "twistedmelonman User" >"${WORK}/state/beta"
rm -f "${WORK}/state/posts"
err="$(run "${WORK}/list-stuck" 2>&1 >/dev/null)"
rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *stuck* ]]; then _pass "stuck: reported, exit 1"; else _fail "stuck: rc=${rc} err=${err}"; fi
if grep -q '/beta/transfer' "${WORK}/state/posts"; then _pass "stuck: loop continued to beta"; else _fail "stuck: beta not attempted"; fi

# Case 5: --only restricts to one repo.
echo "twistedmelonman User" >"${WORK}/state/alpha"
echo "twistedmelonman User" >"${WORK}/state/beta"
rm -f "${WORK}/state/posts"
run "${WORK}/list" --only beta >/dev/null 2>&1
if [[ "$(cat "${WORK}/state/posts")" == "POST repos/twistedmelonman/beta/transfer new_owner=smartwatermelon" ]]; then
  _pass "--only: exactly beta POSTed"
else
  _fail "--only: got $(cat "${WORK}/state/posts" 2>/dev/null)"
fi

exit "${fail}"
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/test-transfer.sh
```

Expected: FAILs (script missing), exit 1.

- [ ] **Step 3: Write transfer.sh**

```bash
#!/usr/bin/env bash
# Transfer every repo on the move list to its target org. Idempotent: a repo
# already owned by its target is skipped. A failed transfer is reported and
# the loop continues; exit 1 at the end if any failed.
# Usage: transfer.sh <move-list> [--only <repo>] [--dry-run]
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md, Steps 3-4.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# Poll cadence; the tests shrink both.
OM_POLL_SECONDS="${OM_POLL_SECONDS:-2}"
OM_POLL_MAX="${OM_POLL_MAX:-30}"

list=""
only=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      only="${2:?--only needs a repo}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -*)
      echo "transfer: unknown flag $1" >&2
      exit 2
      ;;
    *)
      list="$1"
      shift
      ;;
  esac
done
if [[ -z "${list}" ]]; then
  echo "usage: transfer.sh <move-list> [--only <repo>] [--dry-run]" >&2
  exit 2
fi

pairs="$(om_read_move_list "${list}")" || exit 1
failed=0
seen_only=0
while read -r repo target; do
  if [[ -n "${only}" && "${repo}" != "${only}" ]]; then
    continue
  fi
  seen_only=1
  if ! current="$(om_lookup_owner "${repo}")"; then
    echo "transfer: ${repo}: cannot resolve current owner; skipping" >&2
    failed=$((failed + 1))
    continue
  fi
  login="${current% *}"
  type="${current#* }"
  if [[ "${login,,}" == "${target,,}" && "${type}" == "Organization" ]]; then
    echo "transfer: ${repo}: already under ${target}; skip"
    continue
  fi
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "transfer: DRY RUN would POST repos/${login}/${repo}/transfer new_owner=${target}"
    continue
  fi
  echo "transfer: ${repo}: ${login} (${type}) -> ${target}"
  if ! gh api -X POST "repos/${login}/${repo}/transfer" -f "new_owner=${target}" >/dev/null; then
    echo "transfer: ${repo}: POST failed; skipping" >&2
    failed=$((failed + 1))
    continue
  fi
  ok=0
  n=0
  while [[ "${n}" -lt "${OM_POLL_MAX}" ]]; do
    if [[ "$(gh api "repos/${target}/${repo}" --jq '.owner.type' 2>/dev/null)" == "Organization" ]]; then
      ok=1
      break
    fi
    n=$((n + 1))
    sleep "${OM_POLL_SECONDS}"
  done
  if [[ "${ok}" -eq 1 ]]; then
    echo "transfer: ${repo}: now ${target}/${repo} (Organization)"
  else
    echo "transfer: ${repo}: did not resolve under ${target} after ${OM_POLL_MAX} polls" >&2
    failed=$((failed + 1))
  fi
done <<<"${pairs}"

if [[ -n "${only}" && "${seen_only}" -eq 0 ]]; then
  echo "transfer: --only ${only}: not on the move list" >&2
  exit 1
fi
if [[ "${failed}" -gt 0 ]]; then
  echo "transfer: ${failed} repo(s) failed; re-run to retry (completed repos are skipped)" >&2
  exit 1
fi
```

- [ ] **Step 4: Run the transfer test**

```bash
chmod +x /Users/andrewrich/Developer/dev-env/scripts/org-migration/transfer.sh
shellcheck -S info /Users/andrewrich/Developer/dev-env/scripts/org-migration/transfer.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/test-transfer.sh
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/test-transfer.sh
```

Expected: all 7 PASS, exit 0.

- [ ] **Step 5: Write the failing verify test**

Create `scripts/org-migration/tests/test-verify.sh`:

```bash
#!/usr/bin/env bash
# verify.sh: owner must be the only change between baseline and after; owner
# must be the target org; every smartwatermelon clone must still ls-remote.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${HERE}/../verify.sh"
WORK="/tmp/om-verify-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/base" "${WORK}/clones"
trap 'rm -rf "${WORK}"' EXIT
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }

# verify.sh calls snapshot.sh by path, so stub gh (not snapshot.sh): it serves
# whatever JSON the test puts in ${OM_TEST_CORE}/<repo>.json for
# repos/smartwatermelon/<repo>, and honors --jq through the real jq.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
path="$2"
jqexpr=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() { if [[ -n "${jqexpr}" ]]; then jq -c "${jqexpr}"; else cat; fi; }
repo="${path#repos/smartwatermelon/}"
case "${path}" in
  repos/smartwatermelon/*/topics) echo '{"names":[]}' | emit ;;
  repos/smartwatermelon/*/actions/secrets) echo '{"secrets":[]}' | emit ;;
  repos/smartwatermelon/*/branches/*/protection | repos/smartwatermelon/*/pages) exit 1 ;;
  repos/smartwatermelon/*/rulesets) echo '[]' | emit ;;
  repos/smartwatermelon/*) emit <"${OM_TEST_CORE:?}/${repo}.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
# git stub: ls-remote succeeds unless the remote names "broken".
cat >"${WORK}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"remote get-url origin"* ]]; then
  dir="$2"; cat "${dir}/.git/ORIGIN"; exit 0
fi
if [[ "$*" == *"ls-remote"* ]]; then
  dir="$2"; grep -q broken "${dir}/.git/ORIGIN" && exit 128; exit 0
fi
exit 0
STUB
chmod +x "${WORK}/bin/git"

mk_core() { # repo login type visibility
  printf '{"name":"%s","owner":{"login":"%s","type":"%s"},"default_branch":"main","visibility":"%s","archived":false}\n' "$1" "$2" "$3" "$4"
}
printf 'alpha\tsmartwatermelon\ncleanroom\tnightowlstudiollc\n' >"${WORK}/list"

# Baseline: both under the user.
mkdir -p "${WORK}/core-base"
mk_core alpha smartwatermelon User public >"${WORK}/core-base/alpha.json"
mk_core cleanroom smartwatermelon User private >"${WORK}/core-base/cleanroom.json"
OM_TEST_CORE="${WORK}/core-base" PATH="${WORK}/bin:${PATH}" bash "${HERE}/../snapshot.sh" "${WORK}/list" "${WORK}/base" >/dev/null

# Clones: one good smartwatermelon remote, one unrelated, one broken.
for c in good other broken; do mkdir -p "${WORK}/clones/${c}/.git"; done
echo "git@github.com:smartwatermelon/alpha.git" >"${WORK}/clones/good/.git/ORIGIN"
echo "git@github.com:someoneelse/thing.git" >"${WORK}/clones/other/.git/ORIGIN"
echo "git@github.com:smartwatermelon/broken.git" >"${WORK}/clones/broken/.git/ORIGIN"

run() { OM_TEST_CORE="$1" PATH="${WORK}/bin:${PATH}" bash "${VERIFY}" "${WORK}/list" "${WORK}/base" "${WORK}/after" --clones "$2"; }

# Case 1: owner-only change, all clones fine -> exit 0.
mkdir -p "${WORK}/core-good" "${WORK}/clones-good"
mk_core alpha smartwatermelon Organization public >"${WORK}/core-good/alpha.json"
mk_core cleanroom nightowlstudiollc Organization private >"${WORK}/core-good/cleanroom.json"
cp -R "${WORK}/clones/good" "${WORK}/clones/other" "${WORK}/clones-good/"
if run "${WORK}/core-good" "${WORK}/clones-good" >/dev/null 2>&1; then _pass "owner-only diff: exit 0"; else _fail "owner-only diff: expected exit 0"; fi

# Case 2 (known-bad): visibility changed too -> exit 1 naming the repo.
mkdir -p "${WORK}/core-drift"
cp "${WORK}/core-good/alpha.json" "${WORK}/core-drift/"
mk_core cleanroom nightowlstudiollc Organization public >"${WORK}/core-drift/cleanroom.json"
err="$(run "${WORK}/core-drift" "${WORK}/clones-good" 2>&1 >/dev/null)"; rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *cleanroom* && "${err}" == *visibility* ]]; then _pass "drift: exit 1 names cleanroom and the field"; else _fail "drift: rc=${rc} err=${err}"; fi

# Case 3: still a User -> exit 1.
mkdir -p "${WORK}/core-user"
cp "${WORK}/core-good/cleanroom.json" "${WORK}/core-user/"
mk_core alpha twistedmelonman User public >"${WORK}/core-user/alpha.json"
err="$(run "${WORK}/core-user" "${WORK}/clones-good" 2>&1 >/dev/null)"; rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *alpha* ]]; then _pass "not transferred: exit 1 names alpha"; else _fail "not transferred: rc=${rc} err=${err}"; fi

# Case 4: a broken smartwatermelon clone -> exit 1; unrelated clone ignored.
err="$(run "${WORK}/core-good" "${WORK}/clones" 2>&1 >/dev/null)"; rc=$?
if [[ "${rc}" -eq 1 && "${err}" == *broken* && "${err}" != *other* ]]; then _pass "clones: broken reported, other ignored"; else _fail "clones: rc=${rc} err=${err}"; fi

exit "${fail}"
```

- [ ] **Step 6: Run it to see it fail**

```bash
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/test-verify.sh
```

Expected: FAILs (verify.sh missing), exit 1.

- [ ] **Step 7: Write verify.sh**

```bash
#!/usr/bin/env bash
# Post-transfer verification: re-snapshot, diff against the baseline with
# owner as the only permitted change, confirm each owner is the target org,
# and ls-remote every local smartwatermelon clone. Exit 1 on any failure,
# after checking everything.
# Usage: verify.sh <move-list> <baseline-dir> <after-dir> [--clones <dir>]
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md, Step 4.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

clones="${HOME}/Developer"
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clones)
      clones="${2:?--clones needs a directory}"
      shift 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
if [[ "${#positional[@]}" -ne 3 ]]; then
  echo "usage: verify.sh <move-list> <baseline-dir> <after-dir> [--clones <dir>]" >&2
  exit 2
fi
list="${positional[0]}"
base="${positional[1]}"
after="${positional[2]}"
fail=0

bash "${HERE}/snapshot.sh" "${list}" "${after}" >/dev/null || fail=1

pairs="$(om_read_move_list "${list}")" || exit 1
while read -r repo target; do
  b="${base}/${repo}.json"
  a="${after}/${repo}.json"
  if [[ ! -f "${b}" || ! -f "${a}" ]]; then
    echo "verify: ${repo}: missing snapshot (baseline=${b} after=${a})" >&2
    fail=1
    continue
  fi
  # Every top-level field except owner must be byte-identical.
  changed="$(jq -n --slurpfile b "${b}" --slurpfile a "${a}" \
    '[($b[0] | del(.owner)) as $x | ($a[0] | del(.owner)) as $y | ($x + $y | keys[]) | select($x[.] != $y[.])] | join(",")')"
  changed="${changed//\"/}"
  if [[ -n "${changed}" ]]; then
    echo "verify: ${repo}: fields changed besides owner: ${changed}" >&2
    fail=1
  fi
  login="$(jq -r '.owner.login' "${a}")"
  type="$(jq -r '.owner.type' "${a}")"
  if [[ "${login,,}" != "${target,,}" || "${type}" != "Organization" ]]; then
    echo "verify: ${repo}: owner is ${login} (${type}), expected ${target} (Organization)" >&2
    fail=1
  else
    echo "verify: ${repo}: ok"
  fi
done <<<"${pairs}"

# Every local clone whose origin is smartwatermelon/* must still resolve.
for gitdir in "${clones}"/*/.git; do
  [[ -e "${gitdir}" ]] || continue
  dir="${gitdir%/.git}"
  url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
  [[ "${url}" =~ github\.com[:/]smartwatermelon/ ]] || continue
  if git -C "${dir}" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "verify: clone ${dir##*/}: ls-remote ok"
  else
    echo "verify: clone ${dir##*/}: ls-remote FAILED (${url})" >&2
    fail=1
  fi
done

exit "${fail}"
```

- [ ] **Step 8: Lint and run all tooling tests**

```bash
chmod +x /Users/andrewrich/Developer/dev-env/scripts/org-migration/verify.sh
shellcheck -S info /Users/andrewrich/Developer/dev-env/scripts/org-migration/*.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/*.sh
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/tests/run-tests.sh
```

Expected: shellcheck silent; all three test files pass, exit 0.

- [ ] **Step 9: Commit**

```bash
git -C /Users/andrewrich/Developer/dev-env add scripts/org-migration/transfer.sh scripts/org-migration/verify.sh scripts/org-migration/tests/test-transfer.sh scripts/org-migration/tests/test-verify.sh
git -C /Users/andrewrich/Developer/dev-env commit -F - <<'EOF'
feat(org-migration): add the idempotent transfer script and the verifier

transfer.sh POSTs /repos/{owner}/{repo}/transfer for each move-list repo
not already under its target org, polls until it resolves as an
Organization, reports and skips failures, and supports --only and
--dry-run. verify.sh re-snapshots, allows owner as the only diff, checks
each owner is the target org, and ls-remotes every local
smartwatermelon clone.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
```

---

### Task 5: Runbook and token-rotation doc (dev-env)

**Files:**

- Create: `docs/runbooks/org-migration-rename.md`
- Create: `docs/token-rotation.md`
- Modify: `CLAUDE.md` (Repository Structure: add `docs/runbooks/` and `scripts/org-migration/`)

**Interfaces:** Task 7 executes the runbook. Tasks 10 and 11 fill the rotation table.

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/org-migration-rename.md`:

````markdown
# Runbook: rename `smartwatermelon` → `twistedmelonman`, create org `smartwatermelon`

Design: `docs/superpowers/specs/2026-09-03-org-migration-design.md`, Step 2.
One sitting, one browser session. The window between A4 and B3 is the only
moment the name `smartwatermelon` is claimable by someone else. Do A and B
back to back.

## Before you start

- [ ] dotfiles PR "twistedmelonman owner table, login alias, F4 scope hint" is
      merged and `~/Developer/dotfiles` is on `main` at or after it.
      Check: `grep -c twistedmelonman ~/Developer/dotfiles/bash/gh-wrapper.sh`
      prints a number ≥ 4.
- [ ] Baseline snapshot committed under `docs/data/org-migration/`.
- [ ] You are signed in to github.com as `smartwatermelon` in the browser.
- [ ] Nothing is pushing or running CI right now (check
      `gh run list -R smartwatermelon/github-workflows --limit 3`).

## A. Rename the user

1. Open <https://github.com/settings/admin> ("Account" settings).
2. Under **Change username**, click **Change username**.
3. Read the warning dialog, click **I understand, let's change my username**.
4. Type `twistedmelonman`, click **Change my username**.
5. Confirm the page header shows `twistedmelonman`.

## B. Create the org (immediately)

1. Open <https://github.com/account/organizations/new?plan=free>.
2. Organization name: `smartwatermelon`. If the form says the name is taken,
   **stop**: go back to A and rename to `smartwatermelon` again. The design's
   failure table covers what happens next (a new spec).
3. Contact email: your gmail. "This organization belongs to": **My personal
   account**. Complete the verification, click **Next**.
4. Skip "Add organization members" (**Skip this step**). Skip the survey.
5. Confirm <https://github.com/smartwatermelon> shows the org page with you
   as owner.

## C. Org settings

1. <https://github.com/organizations/smartwatermelon/settings/actions>:
   **Actions permissions** must be "Allow all actions and reusable workflows"
   (the Free default). Under **Workflow permissions**, leave "Read
   repository contents and packages permissions" (repos carry their own
   setting across the transfer).
2. <https://github.com/organizations/smartwatermelon/settings/member_privileges>:
   leave defaults. You are the only member.

## D. Re-login the keyring on THIS machine

The keyring token still works after the rename, but `hosts.yml` records the
login name and the wrapper compares it. Re-login rewrites it.

```bash
env -u GH_TOKEN gh auth login -h github.com --web --scopes admin:org,repo,workflow,delete_repo
env -u GH_TOKEN gh auth logout -h github.com -u smartwatermelon   # stale entry, if listed
env -u GH_TOKEN gh auth status
```

Expected: the active github.com account is `twistedmelonman`, scopes include
`admin:org`. `delete_repo` is for Step 6's repo deletions; drop it from the
list if you would rather add it later with `gh auth refresh -s delete_repo`.

## E. Verify from a shell (paste the output back to the agent)

```bash
gh api user --jq .login                                  # GH_TOKEN: twistedmelonman
env -u GH_TOKEN gh api user --jq .login                  # keyring: twistedmelonman
gh api orgs/smartwatermelon --jq '.login + " " + .type'  # smartwatermelon Organization
gh api orgs/smartwatermelon/memberships/twistedmelonman --jq .role   # admin
gh api repos/smartwatermelon/dotfiles --jq '.owner.login + " " + .owner.type'  # twistedmelonman User (redirect)
cd ~/Developer/dotfiles && gh pr list --limit 1           # identity guard passes, no error
```

## F. The other two machines (TILSIT, MIMOLETTE)

Run section D on each, before the alias-removal PR (plan Task 12) merges.
Until then the alias keeps the old `hosts.yml` name working.

## Undo

Rename back at <https://github.com/settings/admin> → `smartwatermelon`. If
the org was created, delete it first at
<https://github.com/organizations/smartwatermelon/settings/profile> (bottom,
**Delete this organization**), because the name must be free.
````

- [ ] **Step 2: Write the rotation doc**

Create `docs/token-rotation.md`:

```markdown
# CLAUDE_CODE_OAUTH_TOKEN rotation

**This file never contains a token, a token prefix, or `claude setup-token`
output.** Dates and locations only. If a token appears here, treat it as
leaked: revoke and rotate.

Org-level secrets (design:
`docs/superpowers/specs/2026-09-03-org-migration-design.md`, Step 5). Free-plan
org secrets do not reach private repos, so `scripts` keeps a repo-level
token until it goes public.

| Scope | Minted | Expires | Minted on |
| --- | --- | --- | --- |
| org `smartwatermelon` | | | |
| org `nightowlstudiollc` | | | |
| repo `smartwatermelon/scripts` | | | |

Each row has a Google Calendar event "Rotate CLAUDE_CODE_OAUTH_TOKEN (<scope>)"
two weeks before the expiry date, pointing here.

## Rotation runbook

Rotate **before** expiry. Do not revoke-then-mint: revocation can take days
to propagate (`dev-env#54` findings) and every Claude workflow fails in
between.

1. Mint, on your own machine:

   ```bash
   claude setup-token
   ```

   Copy the token from the terminal. Do not paste it anywhere but step 2.

2. Set it (the wrapper prints this exact line if you forget `env -u`):

   ```bash
   env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all
   # or --org nightowlstudiollc
   # or, for scripts:  gh secret set CLAUDE_CODE_OAUTH_TOKEN -R smartwatermelon/scripts
   ```

   Paste when prompted.

3. Re-run one Claude workflow on a repo in that scope and read the log: the
   `claude-code-action` step must authenticate, not skip.

   ```bash
   gh run list -R smartwatermelon/dev-env --workflow claude-blocking-review.yml --limit 1 --json databaseId --jq '.[0].databaseId' | xargs -I{} gh run rerun {} -R smartwatermelon/dev-env
   ```

4. Update the table row (minted date, expiry = minted + the lifetime
   `setup-token` printed, machine).

5. Move the calendar event to two weeks before the new expiry.

```

- [ ] **Step 3: Update CLAUDE.md**

In `CLAUDE.md` under "Repository Structure", after the `docs/` bullets add:

```markdown
  - `docs/runbooks/` — Step-by-step manual procedures (UI actions the agent cannot perform)
  - `docs/token-rotation.md` — Where each `CLAUDE_CODE_OAUTH_TOKEN` lives and when it expires; never contains a token
- `scripts/org-migration/` — Snapshot/transfer/verify tooling for the 2026-09 org migration; tests in `scripts/org-migration/tests/run-tests.sh`
```

- [ ] **Step 4: Lint, commit, push, open the PR**

```bash
git -C /Users/andrewrich/Developer/dev-env add docs/runbooks/org-migration-rename.md docs/token-rotation.md CLAUDE.md
git -C /Users/andrewrich/Developer/dev-env commit -F - <<'EOF'
docs(org-migration): add the rename runbook and the token-rotation doc

The runbook is the exact click path for renaming the user and creating
the org in one sitting, plus the keyring re-login and shell checks. The
rotation doc holds dates only, never token material.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
git -C /Users/andrewrich/Developer/dev-env diff origin/main...HEAD | ~/.claude/hooks/run-review.sh --mode=codebase --no-file
git -C /Users/andrewrich/Developer/dev-env push -u origin claude/feat-org-migration-tooling-01RUgidK
gh pr create -R smartwatermelon/dev-env --title "feat(org-migration): transfer tooling, rename runbook, token-rotation doc" --body-file /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/devenv-pr-body.md
```

PR body: spec link, `tests/run-tests.sh` output, the Task 3 Step 7 live smoke JSON with the secret names, "Advances #54". Surface the PR. Merge needs a merge-lock (**HUMAN**).

---

### Task 6: Step 1 pre-flight

**Files:**

- Create: `docs/data/org-migration/<YYYY-MM-DD>-baseline/*.json` (31 files)

**Gate:** both PRs (Tasks 2 and 5) merged; `~/Developer/dotfiles` on `main` with the wrapper change; a new shell so the sourced `gh()` is the new one.

- [ ] **Step 1: Confirm the live wrapper is the new one**

```bash
grep -c twistedmelonman ~/Developer/dotfiles/bash/gh-wrapper.sh
bash -lc 'type gh | head -3; declare -f _gh_wrapper_logins_equal >/dev/null && echo alias-helper-loaded'
which gh; hash -t gh 2>/dev/null || true
```

Expected: count ≥ 4; `alias-helper-loaded`; `which gh` is `~/.local/bin/gh`. If `hash -t` shows a different path, run `hash -r` (see CLAUDE.md, PATH-shim wrappers).

- [ ] **Step 2: Baseline snapshot**

```bash
git -C /Users/andrewrich/Developer/dev-env switch main && git -C /Users/andrewrich/Developer/dev-env pull
git -C /Users/andrewrich/Developer/dev-env switch -c claude/data-org-migration-baseline-01RUgidK
d="$(date +%F)-baseline"
bash /Users/andrewrich/Developer/dev-env/scripts/org-migration/snapshot.sh /Users/andrewrich/Developer/dev-env/scripts/org-migration/move-list.txt "/Users/andrewrich/Developer/dev-env/docs/data/org-migration/${d}"
ls "/Users/andrewrich/Developer/dev-env/docs/data/org-migration/${d}" | wc -l
jq -r '[.repo, .owner.login, .visibility, (.secrets|join("+"))] | @tsv' "/Users/andrewrich/Developer/dev-env/docs/data/org-migration/${d}"/*.json | column -t
```

Expected: exit 0, 31 files, every owner `smartwatermelon`. Note which repos list `CLAUDE_CODE_OAUTH_TOKEN` (Task 10 deletes those, minus `scripts`).

- [ ] **Step 3: CODEOWNERS grep**

```bash
grep -rl --include=CODEOWNERS 'smartwatermelon' /Users/andrewrich/Developer/*/.github /Users/andrewrich/Developer/*/CODEOWNERS /Users/andrewrich/Developer/*/docs/CODEOWNERS 2>/dev/null || echo "no CODEOWNERS names smartwatermelon"
```

Expected: the echo line. If a file is listed, change `@smartwatermelon` to `@twistedmelonman` in that repo via its own PR before Task 7.

- [ ] **Step 4: Commit the baseline, PR, surface it**

```bash
git -C /Users/andrewrich/Developer/dev-env add "docs/data/org-migration/${d}"
git -C /Users/andrewrich/Developer/dev-env commit -F - <<EOF
data(org-migration): baseline snapshot of the 31 move-list repos (${d%-baseline})

Owner, default branch, visibility, archived, topics, pages, secret NAMES
(no values), branch protection, and rulesets, taken before the rename.
verify.sh diffs the post-transfer snapshot against this.

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
git -C /Users/andrewrich/Developer/dev-env push -u origin claude/data-org-migration-baseline-01RUgidK
gh pr create -R smartwatermelon/dev-env --title "data(org-migration): baseline snapshot" --body "Step 1 of docs/superpowers/specs/2026-09-03-org-migration-design.md. Advances #54.

https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6"
```

**Verified when:** PR merged; Task 7 may start.

---

### Task 7: Step 2 — rename and create the org (**HUMAN**)

**Files:** none. Andrew executes `docs/runbooks/org-migration-rename.md` sections A–E on this machine.

- [ ] **Step 1: Hand over**

Tell Andrew: "Runbook is at `docs/runbooks/org-migration-rename.md`. Do sections A through E now, then paste section E's output here." Stop.

- [ ] **Step 2: Verify from the agent's shell (after Andrew reports back)**

Run every command in runbook section E yourself and compare with Andrew's paste. All six must match the expected values. Also:

```bash
gh api users/smartwatermelon --jq .type      # Organization
gh api users/twistedmelonman --jq .type      # User
gh repo list twistedmelonman --limit 100 --json name --jq length   # 60
```

**Verified when:** all checks pass. Record the timestamp of the rename in the Task 13 issue comment.

---

### Task 8: Step 3 — transfer `github-workflows` alone

**Files:** none (GitHub state).

- [ ] **Step 1: Dry run, then transfer the one repo**

```bash
cd /Users/andrewrich/Developer/dev-env
bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt --only github-workflows --dry-run
bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt --only github-workflows
gh api repos/smartwatermelon/github-workflows --jq '.owner.login + " " + .owner.type'
```

Expected: dry run prints one POST line for `repos/twistedmelonman/github-workflows/transfer new_owner=smartwatermelon`; real run ends with `now smartwatermelon/github-workflows (Organization)`; the final line is `smartwatermelon Organization`.

- [ ] **Step 2: Re-run one consumer per org and read the evidence**

```bash
for r in smartwatermelon/dev-env nightowlstudiollc/networth-agent; do
  id="$(gh run list -R "$r" --workflow claude-blocking-review.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run rerun "$id" -R "$r"
  gh run watch "$id" -R "$r" --exit-status
  gh api "repos/$r/actions/runs/$id" --jq '.referenced_workflows[] | .path + " @ " + .ref'
done
```

Expected: both runs finish green, and each `referenced_workflows` line begins with `smartwatermelon/github-workflows/.github/workflows/`. The `referenced_workflows` field is the evidence that the reusable workflow resolved from the moved repo; the green check alone is not. If a run fails or the path is missing, **stop** (design failure table: "Consumer CI fails after Step 3").

**Verified when:** both lines show the path.

---

### Task 9: Step 4 — batch transfer and verify

**Files:**

- Create: `docs/data/org-migration/<YYYY-MM-DD>-after/*.json`

- [ ] **Step 1: Dry run, review, run**

```bash
cd /Users/andrewrich/Developer/dev-env
bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt --dry-run
```

Expected: 30 `DRY RUN would POST` lines (github-workflows shows `skip`), `cleanroom` targets `nightowlstudiollc`. Then:

```bash
bash scripts/org-migration/transfer.sh scripts/org-migration/move-list.txt 2>&1 | tee /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/transfer.log
```

Expected: exit 0. If exit 1, re-run once (completed repos skip); if a repo still fails, report it and continue to Step 2 for the rest.

- [ ] **Step 2: Verify**

```bash
base="$(ls -d /Users/andrewrich/Developer/dev-env/docs/data/org-migration/*-baseline | tail -1)"
after="/Users/andrewrich/Developer/dev-env/docs/data/org-migration/$(date +%F)-after"
bash scripts/org-migration/verify.sh scripts/org-migration/move-list.txt "${base}" "${after}" 2>&1 | tee /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/verify.log
```

Expected: 31 `ok` lines, every `smartwatermelon/*` clone under `~/Developer` `ls-remote ok`, exit 0. Any `fields changed besides owner` line is a finding: restore that setting by hand from the baseline JSON and record it in the Task 13 issue comment.

- [ ] **Step 3: Commit the after-snapshot**

```bash
git -C /Users/andrewrich/Developer/dev-env switch main && git -C /Users/andrewrich/Developer/dev-env pull
git -C /Users/andrewrich/Developer/dev-env switch -c claude/data-org-migration-after-01RUgidK
git -C /Users/andrewrich/Developer/dev-env add "${after}"
git -C /Users/andrewrich/Developer/dev-env commit -F - <<'EOF'
data(org-migration): post-transfer snapshot; verify.sh clean

Claude-Session: https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
git -C /Users/andrewrich/Developer/dev-env push -u origin claude/data-org-migration-after-01RUgidK
gh pr create -R smartwatermelon/dev-env --title "data(org-migration): post-transfer snapshot" --body-file /private/tmp/claude-501/-Users-andrewrich-Developer-dev-env/f048f9ec-b7ba-473a-91b9-3ab84adde1f8/scratchpad/verify.log
```

**Verified when:** verify.sh exit 0 and PR merged.

---

### Task 10: Step 5 — org-level secret

**Files:**

- Modify: `docs/token-rotation.md` (table rows)

- [ ] **Step 1: Mint and set (**HUMAN** for the paste)**

Tell Andrew to run, in his own terminal:

```bash
claude setup-token
env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R smartwatermelon/scripts
```

and to report the two lifetimes `setup-token` printed and the mint dates (not the tokens). The `nightowlstudiollc` org secret already exists; it is not re-minted now. Its expiry is unknown; Andrew reports the date from the 1Password item or the last mint if he has it, otherwise the row says "unknown, rotate at next opportunity".

- [ ] **Step 2: Confirm the org secret exists and delete the shadowing repo copies**

```bash
env -u GH_TOKEN gh secret list --org smartwatermelon
base="$(ls -d /Users/andrewrich/Developer/dev-env/docs/data/org-migration/*-baseline | tail -1)"
for f in "${base}"/*.json; do
  repo="$(jq -r .repo "$f")"
  [[ "${repo}" == "scripts" || "${repo}" == "cleanroom" ]] && continue
  if jq -e '.secrets | index("CLAUDE_CODE_OAUTH_TOKEN")' "$f" >/dev/null; then
    echo "deleting repo-level token on smartwatermelon/${repo}"
    gh secret delete CLAUDE_CODE_OAUTH_TOKEN -R "smartwatermelon/${repo}"
  fi
done
for r in networth-agent photo-game-poc cleanroom; do
  gh secret delete CLAUDE_CODE_OAUTH_TOKEN -R "nightowlstudiollc/${r}"
done
env -u GH_TOKEN gh secret list --org nightowlstudiollc
```

Expected: first list shows `CLAUDE_CODE_OAUTH_TOKEN` with visibility `ALL`; deletions succeed; the nightowlstudiollc org secret exists with visibility `ALL` or `SELECTED` including `cleanroom` (if `SELECTED`, add cleanroom: `env -u GH_TOKEN gh api -X PUT orgs/nightowlstudiollc/actions/secrets/CLAUDE_CODE_OAUTH_TOKEN/repositories/$(gh api repos/nightowlstudiollc/cleanroom --jq .id)`).

- [ ] **Step 3: Verify the token reaches workflows**

```bash
for r in smartwatermelon/dev-env smartwatermelon/scripts nightowlstudiollc/cleanroom nightowlstudiollc/networth-agent; do
  gh secret list -R "$r"
  id="$(gh run list -R "$r" --workflow claude-blocking-review.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run rerun "$id" -R "$r" && gh run watch "$id" -R "$r" --exit-status
  gh run view "$id" -R "$r" --log | grep -m2 -iE 'claude-code-action|authenticat' 
done
```

Expected: `gh secret list` on dev-env, cleanroom, networth-agent shows no repo-level `CLAUDE_CODE_OAUTH_TOKEN` (scripts still shows one); all four runs green; each log shows the `claude-code-action` step ran with authentication rather than skipping. If a run reports a missing token, restore the repo-level secret for that repo and record the finding.

- [ ] **Step 4: Fill the rotation table and commit**

Fill the three rows of `docs/token-rotation.md` with the dates from Step 1 (nightowlstudiollc row from Andrew's answer). Commit on a branch `claude/docs-token-rotation-dates-01RUgidK`, push, open the PR, surface it. Commit message subject: `docs(token-rotation): record the 2026-09 mint and expiry dates`.

**Verified when:** Step 3 passes and the PR is merged.

---

### Task 11: Step 6 — cleanup

**Files:** none in-repo beyond the issue and the calendar events.

- [ ] **Step 1: Delete the stale secret on the archived repo**

Archived repos are read-only, secrets included. Unarchive, delete, re-archive:

```bash
gh api -X PATCH repos/twistedmelonman/ralph-burndown -F archived=false --jq .archived
gh secret delete KEBAB_TAX_GITHUB_TOKEN -R twistedmelonman/ralph-burndown
gh secret list -R twistedmelonman/ralph-burndown
gh api -X PATCH repos/twistedmelonman/ralph-burndown -F archived=true --jq .archived
```

Expected: `false`, deletion ok, empty list, `true`.

- [ ] **Step 2: Repo deletions (**HUMAN** confirms first)**

Ask Andrew: "About to delete `twistedmelonman/claude-code-login` (fork) and `twistedmelonman/smartwatermelon.github.io` (archived, unused). Confirm." Only after an explicit yes:

```bash
gh api repos/twistedmelonman/smartwatermelon.github.io --jq '.archived, .has_pages, .fork'
env -u GH_TOKEN gh repo delete twistedmelonman/claude-code-login --yes
env -u GH_TOKEN gh repo delete twistedmelonman/smartwatermelon.github.io --yes
```

Expected: `true false false`; both deletions succeed. If `delete_repo` scope is missing, the wrapper hint says so; fix with `env -u GH_TOKEN gh auth refresh -h github.com -s delete_repo` and re-run.

- [ ] **Step 3: Calendar events**

Using the Google Calendar connector, for each row of `docs/token-rotation.md` with a known expiry, create an all-day event on `expiry − 14 days`: title `Rotate CLAUDE_CODE_OAUTH_TOKEN (<scope>)`, description `Runbook: dev-env docs/token-rotation.md`. Three events (nightowlstudiollc only if its expiry is known). Report the three event dates to Andrew.

- [ ] **Step 4: File the follow-up issues**

```bash
gh issue create -R smartwatermelon/dev-env --title "Make smartwatermelon/scripts public" --body "$(cat <<'EOF'
Follow-up from the 2026-09 org migration (docs/superpowers/specs/2026-09-03-org-migration-design.md).

`scripts` is the one private repo in the org that runs Claude workflows, so it keeps a repo-level CLAUDE_CODE_OAUTH_TOKEN until it goes public (Free-plan org secrets do not reach private repos).

Steps:
1. Secret audit of the working tree and full history (semgrep secrets + gitleaks over every commit).
2. History rewrite if anything is found (git filter-repo), force-push, re-clone everywhere.
3. Flip visibility to public.
4. Add the standard branch protection.
5. Delete the repo-level CLAUDE_CODE_OAUTH_TOKEN; the org secret takes over. Update docs/token-rotation.md and remove its calendar event.

https://claude.ai/code/session_01RUgidKkV54aNnH1rRNfUq6
EOF
)"
```

Surface the issue URL.

**Verified when:** Steps 1–4 done and reported.

---

### Task 12: Remove the temporary login alias (dotfiles follow-up)

**Files:**

- Modify: `bash/gh-wrapper.sh` (alias block from Task 1; header comment)
- Modify: `bash/tests/test-gh-wrapper-identity.sh`, `bash/tests/test-gh-wrapper-gh-token-precedence.sh`

**Gate:** Andrew confirms section D of the runbook ran on all three machines (`env -u GH_TOKEN gh api user --jq .login` prints `twistedmelonman` on each).

- [ ] **Step 1: Update the tests first (known-bad)**

In `test-gh-wrapper-identity.sh`, delete the whole "Temporary alias" block (the `assert_no_switch` function, its two calls, and the three `_gh_wrapper_logins_equal` checks), and add in the Tier 1 block:

```bash
# Post-rename: the old login is just another wrong identity.
assert_desired "stale smartwatermelon hosts.yml is switched" "smartwatermelon" "smartwatermelon/dotfiles" "twistedmelonman"
```

In `test-gh-wrapper-gh-token-precedence.sh`, replace case 3b with:

```bash
# Case 3b: GH_TOKEN reporting the pre-rename login is a mismatch now that the
# alias is gone.
if _sync_under_env GH_TOKEN="fake-token-for-smartwatermelon" \
  CLAUDE_GH_TOKEN_LOGIN="smartwatermelon"; then
  _fail "stale smartwatermelon GH_TOKEN: silently accepted"
else
  _pass "stale smartwatermelon GH_TOKEN: fails closed"
fi
```

Run `bash bash/tests/run-tests.sh gh-wrapper`. Expected: those two cases FAIL (alias still accepts them). Save the output for the PR body.

- [ ] **Step 2: Remove the alias**

In `bash/gh-wrapper.sh`: delete the `_GH_WRAPPER_LOGIN_ALIASES` assignment and its comment; delete `_gh_wrapper_logins_equal` and replace its two call sites with plain comparisons (`[[ "${token_login,,}" != "${desired,,}" ]]` and `[[ -n "${current}" && "${current,,}" != "${desired,,}" ]]`); remove `_gh_wrapper_logins_equal` from `export -f` and `_GH_WRAPPER_LOGIN_ALIASES` from `export`. Update the file's header comment so the owner-mapping description says `twistedmelonman`. In `test-gh-wrapper-identity.sh` line 11, drop the parenthetical about the alias.

- [ ] **Step 3: Lint, test, commit, PR**

```bash
shellcheck -S info /Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-identity.sh /Users/andrewrich/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh
bash /Users/andrewrich/Developer/dotfiles/bash/tests/run-tests.sh
```

Expected: silent; 25 tests pass. Branch `claude/chore-gh-wrapper-drop-alias-01RUgidK`; commit subject `chore(gh-wrapper): remove the twistedmelonman=smartwatermelon alias`; push; PR titled the same; surface it.

---

### Task 13: Step 7 — docs

**Files:**

- Modify: `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md` (I3, F4 sections)
- Modify: `docs/WORKFLOW-DEEP-DIVE.md` (owner-mapping mentions)
- Modify: `docs/superpowers/specs/2026-09-03-org-migration-design.md` (status line)

- [ ] **Step 1: Edit the backlog design**

In the I3 section, replace the body with a two-line pointer: "Done 2026-09 via `2026-09-03-org-migration-design.md`: user renamed to `twistedmelonman`, org `smartwatermelon` re-claimed, 31 repos transferred, no reference rewrite." Strike (`~~…~~`) the sentence claiming private repos gain protection by moving and add "(false on Free; see the migration spec)". In F4, replace the router paragraph with: "Resolved as a scope split, not an identity split: both tokens are the same login. Escape hatch `env -u GH_TOKEN gh …`; the wrapper prints it on a scope error. Router stays deferred."

- [ ] **Step 2: Edit WORKFLOW-DEEP-DIVE.md**

```bash
grep -n 'smartwatermelon' /Users/andrewrich/Developer/dev-env/docs/WORKFLOW-DEEP-DIVE.md
```

For each line describing the wrapper's owner→identity mapping, change the resolved identity from `smartwatermelon` to `twistedmelonman` and note that `smartwatermelon` is now the org. Leave repo URLs alone.

- [ ] **Step 3: Update the migration spec status line**

Change line 3 to `Status: EXECUTED <YYYY-MM-DD>. Findings and deviations recorded in dev-env#54's closing comment.`

- [ ] **Step 4: Commit, PR, close #54**

Branch `claude/docs-org-migration-done-01RUgidK`; commit subject `docs: record the org migration outcome (I3, F4)`; push; PR body says `Closes #54` and lists: rename timestamp, any verify.sh findings, secrets deleted, calendar event dates, the scripts issue number. Surface the PR. After merge, confirm:

```bash
gh issue view 54 -R smartwatermelon/dev-env --json state --jq .state
```

Expected: `CLOSED`.

---

## Self-review

**Spec coverage.** Decisions table → Tasks 1, 2 (F4), 3 (move list incl. cleanroom → nightowl), 10 (scripts keeps token), 11 (ralph-burndown secret, Pages repo deletion, calendar). Sequence Steps 1–7 → Tasks 6–13. gh-wrapper changes → Tasks 1, 2, 12. Transfer tooling → Tasks 3, 4. Token tracking → Tasks 5, 10. Failure handling → inline stops in Tasks 7, 8, 9. Effect on backlog → Task 13. I1's owner-mapping note is out of scope here (lands with I1).

**Placeholders.** The `<YYYY-MM-DD>` in Tasks 6, 9, 13 are run-time dates, computed by the commands shown. No TBDs.

**Type consistency.** `om_read_move_list` prints `repo target` (space separated) and is consumed identically in snapshot.sh, transfer.sh, verify.sh. Snapshot JSON keys (`repo owner default_branch visibility archived topics pages secrets protection rulesets`) match between snapshot.sh, test-snapshot.sh, and verify.sh's `del(.owner)`. `_gh_wrapper_keyring_login` is defined in Task 1 and used in Tasks 1 and 2. `_gh_wrapper_logins_equal` is defined in Task 1 and removed in Task 12 with both call sites.
