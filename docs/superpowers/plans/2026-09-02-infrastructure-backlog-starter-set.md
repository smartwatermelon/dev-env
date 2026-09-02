# Infrastructure Backlog — Starter Set Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four unblocked, independent items the backlog design names
as "start with" — remove an unpatched Node runtime from daily use, stop the
cross-org git identity leak, make wrong-identity `gh` operations visible
instead of silent, and retire the manual `uchg` tripwire guarding local review.

**Architecture:** Four independent tracks, no shared state, executable in any
order or in parallel. Each lands in a different repo (`dotfiles`,
`claude-wrapper`, `claude-code-workflows-agents`), so tasks do not contend.
Every behavioral change is validated against a known-bad case before its fix
is accepted — the backlog's defining defect is checks that report success
while doing nothing.

**Tech Stack:** Bash 5.x, shellcheck, the `dotfiles/bash/tests` suite (23
tests, plain-bash, `run-tests.sh` runner), `claude-wrapper/tests`, GitHub
Actions, nvm.

**Spec:** `docs/superpowers/specs/2026-09-01-infrastructure-backlog-design.md`

## Scope

This plan covers **only** the starter set: N1a, F2, F3, and the remainder of
L1. Chosen 2026-09-02 because these four are the only items with no unresolved
upstream decision, so every task below can be written with real code rather
than placeholders.

Explicitly **not** in this plan, and why:

| Item | Blocked on |
| --- | --- |
| F1 | **Already implemented** — see "What verification changed", below. |
| F4, I3 | F4 direction chosen (route org ops to keyring identity); needs its own plan. |
| I0, I1, I2 | I0's script must run on the company machine before I1 is designed. |
| W1/W2/W3 | Three decisions in `github-workflows#154` are unanswered. |
| N1b | Product-repo Node pins; larger fan-out, own plan. |
| L2, L3, L4, L5 | Sequenced behind L2 (deploy/edit separation), not yet planned. |

## What verification changed

State was re-verified against live code on 2026-09-02, before this plan was
written. Two spec items had already been implemented in the day since it was
authored. Both are recorded here rather than silently dropped, because the
spec still lists them as pending work.

**F1 is done.** `_gh_wrapper_resolve_owner()` exists at
`dotfiles/bash/gh-wrapper.sh:61-96`, handles both `git@host:` and
`scheme://host/` remote forms plus `-R`/`--repo`/`--repo=`/`-R<value>`
argument parsing, and is already shared by `_gh_wrapper_sync_identity` and
`_gh_wrapper_force_draft_for_off_org`. The spec's F1 ("extract it once") has
no work left. F2 and F3 below consume it as-is.

**L1's remediation is done; only the tripwire removal remains.**
`bash/tests/lib/git-env-isolation.sh` exists and is used by 9 fixture tests.
`test-git-env-isolation.sh` is the known-bad-validated regression test the
spec asked for: it builds a throwaway repo with a linked worktree, exports a
`GIT_DIR` pointing at it, and runs the real fixture tests under that
condition — with a control case that requires the *unguarded* operation to
contaminate, so the guard cannot rot into decoration. Suite: 23 passed, 0
failed. What is left is Task 4: confirm the guard holds with the `uchg` flag
off, then remove the flag.

**Everything else matched the spec exactly:** `~/.nvm/alias/default` is `20`;
`which node` is v20.20.2 with v22.23.2 and v24.19.0 installed and idle;
`code-quality.yml:80` and `validate.yml:233` both read `node-version: '20'`;
`git-identity.sh:12-15` exports all four git identity variables
unconditionally; `CLAUDE_GH_TOKEN_ROUTER` appears only at
`gh-wrapper.sh:488-490`, in the standalone-executable branch, defined nowhere.

## Global Constraints

- **GNU Bash 5.x compatible.** All shellcheck issues resolved at
  `-S info`. **Never** use `# shellcheck disable` directives.
- **Never** use `((var++))` under `set -e` — when `var=0` it exits. Use
  `((var += 1))`.
- Run `shellcheck -S info <script>` after every script edit, before commit.
- **Validate every fix against a known-bad case.** A test that passes without
  first being shown to fail against the broken behavior proves nothing. Each
  task below specifies its known-bad case explicitly.
- `dotfiles` test convention: `unset CDPATH` at the top of every test (a `cd`
  echoes its resolved path to stdout and corrupts command substitution). See
  `dotfiles/bash/README.md`, "Adding a test".
- `dotfiles` tests use `GIT=/usr/bin/git` for fixture setup, bypassing the
  repo's PATH wrapper, which enforces branch rules that are correct for real
  work and wrong for scratch fixtures.
- Never `git add .` — add files individually.
- Never `--no-verify`.
- Branch naming: `claude/<type>-<description>-<session-id>`. Never commit to
  `main`.
- Text files end with a newline.

---

## Task 1: Move the local Node default off EOL v20 (N1a, local)

Node 20 reached EOL 2026-04-30 and takes no security patches. nvm prepends
its active version at `PATH` position 1, ahead of Homebrew at position 6, so
v20.20.2 shadows every other install. Nothing is missing — the pin is the
cause.

**Files:**

- Modify: `~/.nvm/alias/default` (via `nvm alias`, not by hand)

**Interfaces:**

- Consumes: nothing.
- Produces: a supported local Node line. No later task depends on it.

**Not a repo change.** This is local machine state, so there is no commit.
It is Task 1 because it removes an unpatched runtime from daily use in about
a minute.

- [ ] **Step 1: Record the known-bad starting state**

```bash
cat ~/.nvm/alias/default     # expect: 20
which node                   # expect: .../v20.20.2/bin/node
node --version               # expect: v20.20.2
ls ~/.nvm/versions/node/     # expect: v20.20.2 v22.23.2 v24.19.0
```

Expected: default is `20`, active node is v20.20.2, and v24.19.0 is present
and idle. If v24.19.0 is absent, run `nvm install lts/krypton` first.

- [ ] **Step 2: Confirm nothing needs reinstalling**

```bash
for v in v20.20.2 v22.23.2 v24.19.0; do
  echo "=== ${v} ==="
  ls ~/.nvm/versions/node/"${v}"/lib/node_modules/
done
```

Expected: only `corepack` and `npm` under each. If any other global package
appears, note it — it must be reinstalled under v24 before switching.

- [ ] **Step 3: Switch the default**

```bash
nvm alias default lts/krypton
hash -r
```

- [ ] **Step 4: Verify with `which`, not `command -v`**

```bash
which node        # expect: .../v24.19.0/bin/node
node --version    # expect: v24.19.0
```

**This step is the whole point of the task.** `command -v node` and
`type node` read bash's per-session hash table and will report the **stale**
v20 path even after a successful switch. Only `which` does a fresh PATH scan.
If `which` still shows v20.20.2, open a new shell and re-check before
concluding anything.

- [ ] **Step 5: Confirm in a clean shell**

```bash
bash -lc 'which node && node --version'
```

Expected: v24.19.0. This proves the change survives a fresh login shell
rather than living only in the current one.

---

## Task 2: Move infrastructure-repo CI off EOL Node 20 (N1a, CI)

**Files:**

- Modify: `claude-code-workflows-agents/.github/workflows/code-quality.yml:80`
- Modify: `claude-code-workflows-agents/.github/workflows/validate.yml:233`

**Interfaces:**

- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Re-resolve the line numbers**

```bash
cd ~/Developer/claude-code-workflows-agents
git switch main && git pull
grep -n "node-version" .github/workflows/code-quality.yml .github/workflows/validate.yml
```

Expected: `code-quality.yml:80:          node-version: '20'` and
`validate.yml:233:          node-version: '20'`. Line numbers are from
2026-09-01; if they moved, use what `grep` reports, not what is written above.

- [ ] **Step 2: Create the branch**

```bash
git switch -c claude/chore-node-24-ci-$(date +%s)
git branch --show-current   # must NOT be main
```

- [ ] **Step 3: Establish the known-bad case — prove the Node step runs**

Before changing a version, confirm the job actually reaches its Node step.
A workflow can pass because the step was skipped, in which case bumping it
proves nothing.

```bash
gh run list --workflow=code-quality.yml --limit 5 \
  --json databaseId,conclusion,headBranch
gh run view <most-recent-id> --log | grep -iA3 "setup-node\|node-version"
```

Expected: log shows setup-node executing and reporting v20.x. If the step is
skipped or absent from the log, stop — the pin is not what it appears to be,
and that is a finding to report rather than a version to bump.

- [ ] **Step 4: Change both pins to Node 24**

In `code-quality.yml`, line 80:

```yaml
          node-version: '24'
```

In `validate.yml`, line 233:

```yaml
          node-version: '24'
```

- [ ] **Step 5: Verify the workflows still parse**

```bash
actionlint .github/workflows/code-quality.yml .github/workflows/validate.yml
```

Expected: no output (clean). If `actionlint` is not installed, skip it — CI
runs it — and note the skip.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/code-quality.yml .github/workflows/validate.yml
git commit -m "$(cat <<'EOF'
chore(ci): move off end-of-life Node 20

Node 20 reached EOL 2026-04-30 and no longer receives security patches.
Both workflows pinned it explicitly. Move to Node 24 (lts/krypton,
supported through 2028-04-30).

Advances smartwatermelon/dev-env#78

Claude-Session: https://claude.ai/code/session_012yVgeNiQARufjPhKnFZUVZ
EOF
)"
```

- [ ] **Step 7: Push and confirm CI is green on Node 24**

```bash
git push -u origin HEAD
gh pr create --fill
```

Then watch the run and confirm the setup-node step now reports v24.x — the
same log check as Step 3, against the new run. A green check alone is not
sufficient evidence; read the version out of the log.

---

## Task 3: Make `git-identity.sh` owner-aware (F2)

Stops a cross-org identity leak. `claude-wrapper/lib/git-identity.sh:12-15`
exports `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and
`GIT_COMMITTER_EMAIL` unconditionally, with no repo or owner awareness. Git
environment variables outrank all gitconfig, **including `includeIf`** — so
the `includeIf gitdir:.../beacon-biosignals/` block at
`dotfiles/git/config:55-56` is dead, and every commit made in a
`beacon-biosignals` repo through Claude Code is authored at a
`smartwatermelon` address.

**Approach (from the spec, second of two shapes):** read `git config
user.email` *after* `includeIf` resolution and override only when it is
unset. This is smaller than owner-resolution and defers to gitconfig, which
is where per-repo identity is already correctly expressed.

**Files:**

- Modify: `claude-wrapper/lib/git-identity.sh:11-17`
- Create: `claude-wrapper/tests/test-git-identity-owner-aware.sh`
- Modify: `claude-wrapper/README.md:299`

**Interfaces:**

- Consumes: `debug_log` from `lib/logging.sh` (already required by this file).
- Produces: nothing consumed by later tasks. Task 4 is independent.

- [ ] **Step 1: Write the failing test**

Create `claude-wrapper/tests/test-git-identity-owner-aware.sh`:

```bash
#!/usr/bin/env bash
# Regression test: git-identity.sh must not override a repo's configured
# identity. smartwatermelon/claude-wrapper — cross-org identity leak.
#
# KNOWN-BAD CASE: the second assertion below fails against the current
# unconditional export. It is the reason this test exists; if it ever passes
# without the fix, the test is not measuring what it claims to.
set -uo pipefail
unset CDPATH

WORKDIR="/tmp/git-identity-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

GIT=/usr/bin/git
LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

debug_log() { :; }
export -f debug_log

# Case 1: repo with NO configured identity -> bot identity applies.
"${GIT}" init -q "${WORKDIR}/no-identity"
(
  cd "${WORKDIR}/no-identity" || exit 1
  # shellcheck source=/dev/null
  source "${LIB_DIR}/git-identity.sh"
  if [[ "${GIT_AUTHOR_EMAIL:-}" == "claude-code@smartwatermelon.github" ]]; then
    exit 0
  fi
  exit 1
)
if [[ $? -eq 0 ]]; then
  _pass "unconfigured repo gets the bot identity"
else
  _fail "unconfigured repo should get the bot identity"
fi

# Case 2: repo WITH a configured identity -> that identity is preserved.
"${GIT}" init -q "${WORKDIR}/has-identity"
"${GIT}" -C "${WORKDIR}/has-identity" config user.name "Andrew Rich"
"${GIT}" -C "${WORKDIR}/has-identity" config user.email "arich@beacon.bio"
(
  cd "${WORKDIR}/has-identity" || exit 1
  # shellcheck source=/dev/null
  source "${LIB_DIR}/git-identity.sh"
  if [[ -z "${GIT_AUTHOR_EMAIL:-}" ]]; then
    exit 0
  fi
  if [[ "${GIT_AUTHOR_EMAIL}" == "arich@beacon.bio" ]]; then
    exit 0
  fi
  exit 1
)
if [[ $? -eq 0 ]]; then
  _pass "configured repo keeps its own identity"
else
  _fail "configured identity was overridden by the bot identity"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-git-identity-owner-aware.sh: all assertions passed"
  exit 0
fi
exit 1
```

- [ ] **Step 2: Run the test and confirm case 2 fails**

```bash
chmod +x ~/Developer/claude-wrapper/tests/test-git-identity-owner-aware.sh
bash ~/Developer/claude-wrapper/tests/test-git-identity-owner-aware.sh
```

Expected: case 1 PASSes, case 2 **FAILs** with "configured identity was
overridden by the bot identity". If case 2 passes here, stop — either the
leak is already fixed or the test is not exercising the export path, and
either way the rest of this task is built on a false premise.

- [ ] **Step 3: Make the export conditional**

Replace `claude-wrapper/lib/git-identity.sh:11-17` with:

```bash
# Set Git author/committer identity — only when the repository does not
# already express one.
#
# Git's GIT_AUTHOR_*/GIT_COMMITTER_* environment variables outrank ALL
# gitconfig, including `includeIf`. Exporting them unconditionally made
# every commit in a beacon-biosignals repo author as a smartwatermelon
# address and rendered the includeIf block in dotfiles/git/config dead.
# Defer to gitconfig where it has an answer; supply the bot identity only
# where it does not.
_claude_git_configured_email="$(git config --get user.email 2>/dev/null)"

if [[ -z "${_claude_git_configured_email}" ]]; then
  export GIT_AUTHOR_NAME="${CLAUDE_GIT_NAME}"
  export GIT_AUTHOR_EMAIL="${CLAUDE_GIT_EMAIL}"
  export GIT_COMMITTER_NAME="${CLAUDE_GIT_NAME}"
  export GIT_COMMITTER_EMAIL="${CLAUDE_GIT_EMAIL}"
  debug_log "Git identity: ${CLAUDE_GIT_NAME} <${CLAUDE_GIT_EMAIL}> (repo had none)"
else
  debug_log "Git identity: deferring to repo config <${_claude_git_configured_email}>"
fi

unset _claude_git_configured_email
```

- [ ] **Step 4: Run the test and confirm both cases pass**

```bash
bash ~/Developer/claude-wrapper/tests/test-git-identity-owner-aware.sh
```

Expected: both PASS, exit 0.

- [ ] **Step 5: Run the full claude-wrapper suite**

```bash
cd ~/Developer/claude-wrapper
for t in tests/test-*.sh; do echo "=== ${t} ==="; bash "${t}" || echo "FAILED: ${t}"; done
```

Expected: no `FAILED:` lines. `test-credentials.sh` and
`test-gh-token-permissions.sh` are the ones most likely to touch identity —
read their output rather than only their exit codes.

- [ ] **Step 6: shellcheck**

```bash
shellcheck -S info ~/Developer/claude-wrapper/lib/git-identity.sh \
                   ~/Developer/claude-wrapper/tests/test-git-identity-owner-aware.sh
```

Expected: clean. Fix anything reported; do not add a disable directive.

- [ ] **Step 7: Verify the real-world behavior changed**

```bash
cd ~/Developer/dev-env && git config --get user.email
cd ~/Developer/claude-wrapper && git log -1 --format='%an <%ae>'
```

Then confirm a commit made in a `beacon-biosignals` checkout would now use
the beacon identity. If no such checkout is available on this machine, say
so in the task report rather than asserting the fix works there.

- [ ] **Step 8: Correct the README**

`claude-wrapper/README.md:299` documents the current wrong behavior as
correct ("`git config user.name` should show `Claude Code Bot`"). Replace
that expectation with: the bot identity appears only in repositories that do
not configure their own `user.email`; repositories with a configured
identity — including those set via `includeIf` — keep it.

- [ ] **Step 9: Commit**

```bash
cd ~/Developer/claude-wrapper
git switch -c claude/fix-git-identity-org-blind-$(date +%s)
git add lib/git-identity.sh tests/test-git-identity-owner-aware.sh README.md
git commit -m "$(cat <<'EOF'
fix(identity): defer to repo gitconfig instead of forcing the bot identity

GIT_AUTHOR_*/GIT_COMMITTER_* outrank all gitconfig including includeIf, so
exporting them unconditionally authored every beacon-biosignals commit at a
smartwatermelon address and made the includeIf block in dotfiles/git/config
dead. Export the bot identity only where the repo configures none.

Adds a regression test whose second case fails against the previous
unconditional export.

Claude-Session: https://claude.ai/code/session_012yVgeNiQARufjPhKnFZUVZ
EOF
)"
```

**Open question deferred to implementation, per the spec:** whether a distinct
bot identity is wanted at all now that sessions are attributed via
`Claude-Session:` trailers. This task keeps it for unconfigured repos and does
not settle that question. Raise it in the task report; do not decide it here.

---

## Task 4: Retire the `uchg` tripwire on dotfiles `.git/config` (L1 remainder)

The isolation fix has landed: `bash/tests/lib/git-env-isolation.sh` exists,
9 fixture tests use it, and `test-git-env-isolation.sh` validates it against
an injected `GIT_DIR` with a control case that requires the unguarded
operation to contaminate. What remains is the manual stopgap.

`chflags uchg` on `dotfiles/.git/config` is a load-bearing manual workaround
on the file that controls whether review infrastructure runs at all. It is
acceptable as a stopgap and not as a steady state: it will be forgotten, and
the failure it prevents is invisible.

**Files:**

- Modify: `/Users/andrewrich/Developer/dotfiles/.git/config` (flag only, not
  content)

**Interfaces:**

- Consumes: the isolation helper from the landed L1 work.
- Produces: nothing.

**No commit.** `.git/config` is not tracked. This task changes a filesystem
flag and verifies a guard.

- [ ] **Step 1: Record the starting state**

```bash
ls -lO ~/Developer/dotfiles/.git/config
git -C ~/Developer/dotfiles config core.hooksPath
```

Expected: `uchg` present in the flags column; `core.hooksPath` is
`~/.config/git/hooks`. Both were true on 2026-09-02.

- [ ] **Step 2: Back up the config before touching the flag**

```bash
cp ~/Developer/dotfiles/.git/config /tmp/dotfiles-git-config-backup-$(date +%s)
ls -l /tmp/dotfiles-git-config-backup-*
```

This is the file whose corruption silently disables local review. Have a copy
before removing its protection.

- [ ] **Step 3: Confirm the suite is green with the flag still on**

```bash
bash ~/Developer/dotfiles/bash/tests/run-tests.sh 2>&1 | tail -5
```

Expected: `SUMMARY: 23 passed, 0 failed, 23 total`. This is the baseline.

- [ ] **Step 4: Remove the flag**

```bash
chflags nouchg ~/Developer/dotfiles/.git/config
ls -lO ~/Developer/dotfiles/.git/config
```

Expected: the flags column no longer shows `uchg`.

- [ ] **Step 5: Run the full suite unprotected — the real test**

```bash
bash ~/Developer/dotfiles/bash/tests/run-tests.sh 2>&1 | tail -5
git -C ~/Developer/dotfiles config core.hooksPath
git -C ~/Developer/dotfiles config user.email
git -C ~/Developer/dotfiles config user.name
```

Expected: 23 passed, 0 failed; `core.hooksPath` still
`~/.config/git/hooks`; `user.email` and `user.name` **not** set to
`test@example.com` / `Test`.

An empty `core.hooksPath` is the failure that matters, and it does not mean
"unset" — git resolves it to `./`, the repo root, where a `pre-commit/`
*directory* exists. So `[[ -x ./pre-commit ]]` succeeds while git finds no
executable, and review silently does not fire. Check for an **empty** value,
not just a missing one.

- [ ] **Step 6: Run the suite from a linked worktree**

The bug needs an inherited `GIT_DIR`, which git exports only when a hook runs
from a linked worktree. A suite run from the main checkout reproduces the
false negative that three separate investigations already hit.

```bash
cd ~/Developer/dotfiles
/usr/bin/git worktree add /tmp/dotfiles-l1-check HEAD
bash /tmp/dotfiles-l1-check/bash/tests/run-tests.sh 2>&1 | tail -5
git -C ~/Developer/dotfiles config core.hooksPath
```

Expected: suite green, and `core.hooksPath` in the **main** checkout still
`~/.config/git/hooks` — that is the contamination target.

- [ ] **Step 7: Clean up the worktree**

```bash
/usr/bin/git -C ~/Developer/dotfiles worktree remove /tmp/dotfiles-l1-check
/usr/bin/git -C ~/Developer/dotfiles worktree list
```

- [ ] **Step 8: Decide, and report honestly**

If Steps 5 and 6 both left `core.hooksPath` intact: the flag stays off. Record
in the task report that the tripwire was removed, on what evidence, and on
what date.

If either step contaminated the config: **restore the flag immediately**
(`chflags uchg ~/Developer/dotfiles/.git/config`), restore the backup from
Step 2 if needed, and report the contamination as a finding. Do not
re-attempt removal. A reproduction is more valuable than a removed flag — the
mechanism was never identified, and this would be the first live capture.

---

## Task 5: Fail closed when `GH_TOKEN` overrides the resolved identity (F3, cheap tier)

**Decision (2026-09-01): cheap tier now; full router deferred.**

The defect is inverted from how it was long described. The wrapper never
assigns `GH_TOKEN` — the precedence runs the other way: **`GH_TOKEN`
overrides the wrapper.** `claude-wrapper/lib/credentials.sh:112` exports a
single restricted-scope CCCLI PAT at session start, and `gh` gives that
variable absolute precedence over the keyring identity `gh auth switch`
selects. So:

1. `_gh_wrapper_sync_identity()` resolves the owner and picks an identity.
2. `gh auth switch` succeeds and updates `~/.config/gh/hosts.yml`.
3. The fail-closed check at `gh-wrapper.sh:229` reads the `user:` field from
   `hosts.yml`, sees the correct name, and passes.
4. `command gh` runs as the CCCLI PAT, ignoring all of it.

Step 3 is what makes this a defect rather than a missing feature. That check
exists to refuse running as the wrong identity. It reads `hosts.yml` — which
the wrapper just wrote — so **it verifies its own output**, not the auth `gh`
will actually use.

This task does not fix routing. It converts a silent wrong-identity into a
visible error.

**Expected consequence, stated up front:** operations that currently succeed
as the wrong identity will begin failing visibly. That is the intent. It will
surface on first use rather than at deploy time.

**Files:**

- Modify: `dotfiles/bash/gh-wrapper.sh` — inside `_gh_wrapper_sync_identity`,
  after the `desired` case block (currently ends line 225), before the
  `current=` assignment (currently line 227)
- Create: `dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh`

**Interfaces:**

- Consumes: `_gh_wrapper_resolve_owner "$@"` (already called at the top of
  `_gh_wrapper_sync_identity`) and the `desired` variable the case block sets.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Re-read the function and re-resolve line numbers**

```bash
grep -n "_gh_wrapper_sync_identity()" ~/Developer/dotfiles/bash/gh-wrapper.sh
sed -n '203,235p' ~/Developer/dotfiles/bash/gh-wrapper.sh
```

Line numbers above are from 2026-09-02. Use what you see, not what is
written here.

- [ ] **Step 2: Determine which identity the token actually represents**

```bash
GH_TOKEN="${GH_TOKEN:-}" gh api user --jq .login
```

Expected: the login the CCCLI PAT authenticates as. Record it — the guard
compares against this. If `GH_TOKEN` is unset in your shell, the wrapper's
concern does not arise there; test via the fixture in Step 3 instead.

- [ ] **Step 3: Write the failing test**

Create `dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh`:

```bash
#!/usr/bin/env bash
# Regression test: _gh_wrapper_sync_identity must not report success when
# GH_TOKEN will override the identity it just switched to.
#
# KNOWN-BAD CASE: case 2 below passes against the CURRENT code, because the
# fail-closed check reads hosts.yml (its own output) rather than the auth gh
# will actually use. That inverted assertion is the bug this test pins.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="/tmp/gh-token-precedence-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Sandbox HOME so the fixture never reads or writes the real hosts.yml.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: smartwatermelon
    oauth_token: fake
YAML

"${GIT}" init -q "${WORKDIR}/repo"
"${GIT}" -C "${WORKDIR}/repo" remote add origin \
  git@github.com:smartwatermelon/example.git

# Case 1: no GH_TOKEN -> sync succeeds, as it does today.
(
  cd "${WORKDIR}/repo" || exit 1
  unset GH_TOKEN
  # shellcheck source=/dev/null
  source "${WRAPPER}"
  _gh_wrapper_sync_identity
)
if [[ $? -eq 0 ]]; then
  _pass "no GH_TOKEN: sync succeeds"
else
  _fail "no GH_TOKEN: sync should succeed"
fi

# Case 2: GH_TOKEN belonging to a DIFFERENT identity than the resolved owner
# maps to. Must fail closed. Fails against the current code, which passes.
(
  cd "${WORKDIR}/repo" || exit 1
  export GH_TOKEN="fake-token-for-andrewmrich"
  export CLAUDE_GH_TOKEN_LOGIN="andrewmrich"
  # shellcheck source=/dev/null
  source "${WRAPPER}"
  _gh_wrapper_sync_identity
)
if [[ $? -ne 0 ]]; then
  _pass "mismatched GH_TOKEN: fails closed"
else
  _fail "mismatched GH_TOKEN: silently ran as the wrong identity"
fi

# Case 3: GH_TOKEN matching the resolved identity -> proceeds.
(
  cd "${WORKDIR}/repo" || exit 1
  export GH_TOKEN="fake-token-for-smartwatermelon"
  export CLAUDE_GH_TOKEN_LOGIN="smartwatermelon"
  # shellcheck source=/dev/null
  source "${WRAPPER}"
  _gh_wrapper_sync_identity
)
if [[ $? -eq 0 ]]; then
  _pass "matching GH_TOKEN: proceeds"
else
  _fail "matching GH_TOKEN: should proceed"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-gh-token-precedence.sh: all assertions passed"
  exit 0
fi
exit 1
```

- [ ] **Step 4: Run the test and confirm case 2 fails**

```bash
bash ~/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh
```

Expected: cases 1 and 3 PASS, case 2 **FAILs** with "silently ran as the
wrong identity". That failure is the defect, reproduced. If case 2 passes
before the fix, the test is not exercising the guard — stop and investigate
rather than proceeding.

- [ ] **Step 5: Add the guard**

Insert into `_gh_wrapper_sync_identity`, after the `case "${owner,,}"` block
that sets `desired` and before the `current=` assignment:

```bash
  # GH_TOKEN outranks the keyring identity that `gh auth switch` selects, so
  # the hosts.yml check below verifies this function's own output rather than
  # the auth `gh` will actually use. When a token is present and represents a
  # different identity than the resolved owner needs, fail closed instead of
  # silently acting as the wrong account.
  #
  # CLAUDE_GH_TOKEN_LOGIN names the identity GH_TOKEN authenticates as. The
  # test fixture sets it directly. In production it is unset, so the `gh api
  # user` fallback below resolves it — one network call per invocation. See
  # Step 11: session-level caching is a known follow-up, deliberately not
  # built here.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    local token_login="${CLAUDE_GH_TOKEN_LOGIN:-}"

    if [[ -z "${token_login}" ]]; then
      token_login="$(GH_TOKEN="${GH_TOKEN}" command gh api user --jq .login 2>/dev/null)"
    fi

    if [[ -z "${token_login}" ]]; then
      echo "[gh] ERROR: GH_TOKEN is set but its identity could not be resolved" >&2
      echo "[gh] Refusing to run: GH_TOKEN overrides 'gh auth switch', so the" >&2
      echo "[gh] identity check cannot be trusted. Unset GH_TOKEN to use the" >&2
      echo "[gh] keyring identity." >&2
      return 1
    fi

    if [[ "${token_login,,}" != "${desired,,}" ]]; then
      echo "[gh] ERROR: GH_TOKEN authenticates as '${token_login}' but repo owner '${owner}' requires '${desired}'" >&2
      echo "[gh] GH_TOKEN takes precedence over 'gh auth switch', so this would" >&2
      echo "[gh] run as the wrong identity. Failing closed." >&2
      echo "[gh] Fix: unset GH_TOKEN to use the keyring identity for this repo." >&2
      return 1
    fi
  fi
```

- [ ] **Step 6: Run the test and confirm all three cases pass**

```bash
bash ~/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh
```

Expected: three PASS lines, exit 0.

- [ ] **Step 7: Run the full dotfiles suite**

```bash
bash ~/Developer/dotfiles/bash/tests/run-tests.sh 2>&1 | tail -30
```

Expected: `SUMMARY: 24 passed, 0 failed, 24 total` — the 23 existing plus this
one. Pay particular attention to `test-gh-wrapper-identity.sh` and
`test-gh-wrapper-draft-off-org.sh`, which exercise the same function.

- [ ] **Step 8: shellcheck**

```bash
shellcheck -S info ~/Developer/dotfiles/bash/gh-wrapper.sh \
                   ~/Developer/dotfiles/bash/tests/test-gh-wrapper-gh-token-precedence.sh
```

Expected: clean.

- [ ] **Step 9: Exercise the guard against real state**

```bash
hash -r
cd ~/Developer/dev-env && gh repo view --json nameWithOwner --jq .nameWithOwner
```

Expected: succeeds if `GH_TOKEN` matches `smartwatermelon`, or fails with the
new explicit error if it does not. **Either outcome is a valid result** — the
error is the intended behavior, not a regression. Report which one occurred.

If it now fails on repos that previously worked, that is the expected
consequence recorded above: those operations were running as the wrong
identity. Report the blast radius (which repos, which commands) rather than
weakening the guard.

- [ ] **Step 10: Commit**

```bash
cd ~/Developer/dotfiles
git switch -c claude/fix-gh-token-precedence-guard-$(date +%s)
git add bash/gh-wrapper.sh bash/tests/test-gh-wrapper-gh-token-precedence.sh
git commit -m "$(cat <<'EOF'
fix(gh): fail closed when GH_TOKEN overrides the resolved identity

GH_TOKEN takes precedence over the keyring identity that `gh auth switch`
selects, so the existing fail-closed check — which reads the `user:` field
from the hosts.yml the wrapper itself just wrote — verified its own output
rather than the auth gh actually uses. It reported success while the
guarantee it enforces was void.

Cheap tier only: this does not route tokens per-org. It converts a silent
wrong-identity into a visible error. Operations that previously succeeded as
the wrong identity will now fail explicitly, which is the intent.

Adds a regression test whose mismatched-token case passes against the
previous code.

Claude-Session: https://claude.ai/code/session_012yVgeNiQARufjPhKnFZUVZ
EOF
)"
```

- [ ] **Step 11: Note the follow-up, do not implement it**

The production path resolves `token_login` with a `gh api user` call when
`CLAUDE_GH_TOKEN_LOGIN` is unset — one network call per `gh` invocation in
the hot path. Session-level caching is the obvious follow-up. Report it; do
not build it here.

The full router (`CLAUDE_GH_TOKEN_ROUTER`, stubbed at `gh-wrapper.sh:488-490`
in the standalone branch only, defined nowhere) stays **deferred** per the
2026-09-01 decision. It needs a second PAT for `andrewmrich` and reverses a
documented product decision in `claude-wrapper/README.md:75` and
`docs/SECRETS.md:169-171`. Do not implement it in this plan.

---

## Verification

After all five tasks, confirm the starter set as a whole:

- [ ] `which node` reports v24.19.0 in a fresh login shell
- [ ] `claude-code-workflows-agents` CI green, with v24.x read out of the
      setup-node log — not merely a green check
- [ ] `claude-wrapper` suite green; a repo with a configured `user.email`
      keeps it
- [ ] `dotfiles` suite green at 24 tests, from both the main checkout and a
      linked worktree; `core.hooksPath` non-empty afterward
- [ ] `uchg` removed from `dotfiles/.git/config`, or restored with a
      contamination report explaining why
- [ ] Every new test was observed failing before its fix

Then update the spec's status line to record which starter-set items landed,
and open issues for the three spec items still unfiled that this plan
touches: `GH_TOKEN` precedence (Task 5), `git-identity.sh` org-blindness
(Task 3). The spec lists both under "Items needing GitHub issues".
