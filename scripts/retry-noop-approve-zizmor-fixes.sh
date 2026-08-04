#!/usr/bin/env bash
# Follow-up to drop-noop-approve-step.sh (smartwatermelon/dev-env#21):
# 20 of 26 repos failed that script's commit step because zizmor's
# pre-commit hook (which runs machine-globally via core.hooksPath, not
# per-repo, so it DOES fire in these scratch clones) flagged real,
# pre-existing findings in dependabot-auto-merge.yml:
#
#   - unpinned-uses: dependabot/fetch-metadata@v3 not SHA-pinned (real gap,
#     some repos got this fixed in earlier fleet work, these didn't)
#   - bot-conditions: github.actor == 'dependabot[bot]' is spoofable on
#     pull_request_target (confirmed against zizmor's own audit docs —
#     the workflow's OWN header comment claiming this is "not spoofable"
#     is incorrect; github.actor reflects the last actor to touch the
#     ref, not who opened the PR, so an attacker can make Dependabot the
#     last committer on their own malicious branch)
#   - dangerous-triggers: pull_request_target itself — a deliberate,
#     justified pattern per the workflow's header (dependabot-only via
#     the (corrected) actor check, narrow permissions, no PR code
#     execution) — suppressed here with a documented inline ignore
#     rather than "fixed", since the design is intentional
#
# One additional repo (smartwatermelon/dotfiles) failed for an unrelated
# reason: .github/ is gitignored there (see the repo's .gitignore `/*`
# allowlist pattern), so `git add` on an already-tracked-but-ignored file
# needs `-f`.
#
# This script applies all of the above in one commit per repo and opens
# one PR per repo, same pattern as drop-noop-approve-step.sh. Nothing is
# merged automatically.
#
# smartwatermelon/dev-env is excluded from REPOS below: its copy of
# dependabot-auto-merge.yml was fixed directly in this repo (dev-env#40,
# #41), including the actor-check and no-op-approve-step fixes this
# script applies elsewhere, so re-running it here would conflict.
#
# Usage: scripts/retry-noop-approve-zizmor-fixes.sh
#
# macOS-only: uses BSD sed (`sed -i ''`). Operator script for this user's
# own machines, not intended for Linux/CI.

set -euo pipefail

if ! auth_status_output=$(gh auth status 2>&1); then
  echo "gh is not authenticated — aborting before touching any repo:" >&2
  echo "${auth_status_output}" >&2
  exit 1
fi

# repo -> needs `git add -f` (gitignore quirk)
declare -A FORCE_ADD=(
  ["smartwatermelon/dotfiles"]=1
)

REPOS=(
  "smartwatermelon/ralph-burndown"
  "smartwatermelon/dotfiles"
  "smartwatermelon/smartwatermelon-marketplace"
  "smartwatermelon/archive-resolver"
  "smartwatermelon/mac-dev-server-setup"
  "smartwatermelon/scripts"
  "smartwatermelon/claude-wrapper"
  "smartwatermelon/qwen-sidebar"
  "smartwatermelon/slack-mcp"
  "smartwatermelon/swift-progress-indicator"
  "smartwatermelon/projectinsomnia"
  "smartwatermelon/lock-sync"
  "smartwatermelon/spokane-snow"
  "smartwatermelon/homebrew-tap"
  "smartwatermelon/crazy-larry"
  "nightowlstudiollc/tnjcleaning"
  "nightowlstudiollc/financial-agent"
  "nightowlstudiollc/networth-agent"
  "nightowlstudiollc/vpn-lan-bridge"
  "nightowlstudiollc/night-owl-studio"
)

WORKFLOW_FILE=".github/workflows/dependabot-auto-merge.yml"
FETCH_METADATA_SHA="25dd0e34f4fe68f24cc83900b1fe3fe149efef98"
BRANCH_NAME="chore/zizmor-fixes-dependabot-auto-merge-$(date +%Y%m%d-%H%M%S)-$$"
SCRATCH_ROOT=$(mktemp -d)
RESULTS_LOG="${SCRATCH_ROOT}/results.tsv"
FINAL_LOG="${SCRATCH_ROOT%/}-retry-zizmor-results.tsv"
printf 'repo\tstatus\tdetail\n' >"${RESULTS_LOG}"

trap 'cp "${RESULTS_LOG}" "${FINAL_LOG}" 2>/dev/null || true; rm -rf "${SCRATCH_ROOT}"' EXIT

commit_msg_file="${SCRATCH_ROOT}/commit-msg.txt"
cat >"${commit_msg_file}" <<'EOF'
fix(ci): SHA-pin fetch-metadata, fix spoofable actor check in dependabot-auto-merge.yml

zizmor flagged two real issues in dependabot-auto-merge.yml:

- unpinned-uses: dependabot/fetch-metadata@v3 was not SHA-pinned (other
  repos in the fleet already got this fixed; this repo hadn't).
- bot-conditions: `github.actor == 'dependabot[bot]'` is spoofable on
  pull_request_target -- github.actor reflects the last actor to touch
  the ref, not who opened the PR, so an attacker can make Dependabot
  the last committer on their own malicious branch. Switched to
  github.event.pull_request.user.login, which reflects who actually
  opened the PR. Verified against zizmor's own audit documentation
  (docs.zizmor.sh/audits/#bot-conditions); the prior header comment's
  claim that github.actor was "not spoofable" was incorrect.

The pull_request_target trigger itself is intentional and already
narrowly scoped (dependabot-only via the now-corrected actor check,
minimal permissions, no PR code execution) -- suppressed with a
documented inline zizmor ignore rather than changed.

Ref: smartwatermelon/dev-env#21
EOF

pr_body_file="${SCRATCH_ROOT}/pr-body.txt"
cat >"${pr_body_file}" <<'EOF'
Follow-up to the dev-env#21 no-op-approve-step remediation: zizmor's
pre-commit hook (which runs machine-globally, so it fires even in a
scratch clone) caught two pre-existing, real findings in this repo's
`dependabot-auto-merge.yml` while that PR was being prepared:

1. **`unpinned-uses`**: `dependabot/fetch-metadata@v3` was not SHA-pinned.
   Pinned to `25dd0e34f4fe68f24cc83900b1fe3fe149efef98 # v3`, matching
   the pattern already used elsewhere in the fleet.
2. **`bot-conditions`**: `github.actor == 'dependabot[bot]'` is spoofable
   on `pull_request_target` (confirmed against zizmor's audit docs —
   `github.actor` is the last actor to touch the ref, not who opened the
   PR). Switched to `github.event.pull_request.user.login`, and corrected
   the header comment, which had incorrectly claimed `github.actor` was
   safe here.

The `pull_request_target` trigger itself (`dangerous-triggers`) is an
intentional, already-justified design (dependabot-only via the corrected
actor check, minimal permissions, no PR code execution) — suppressed
with a documented inline `# zizmor: ignore[dangerous-triggers]` comment
rather than changed.

Part of the fleet-wide remediation tracked in smartwatermelon/dev-env#21.
This PR is not merged automatically — merge requires separate explicit
authorization, same as any other PR.
EOF

for repo in "${REPOS[@]}"; do
  echo "=== ${repo} ==="
  clone_dir="${SCRATCH_ROOT}/${repo//\//-}"
  clone_err_log="${SCRATCH_ROOT}/clone-err.log"
  : >"${clone_err_log}"

  if ! git clone --quiet "git@github.com:${repo}.git" "${clone_dir}" 2>"${clone_err_log}"; then
    clone_err_detail=$(tr '\n\t' '  ' <"${clone_err_log}")
    echo "  clone failed: ${clone_err_detail}"
    printf '%s\tskipped\tclone failed: %s\n' "${repo}" "${clone_err_detail}" >>"${RESULTS_LOG}"
    continue
  fi

  workflow_path="${clone_dir}/${WORKFLOW_FILE}"
  if [[ ! -f "${workflow_path}" ]]; then
    echo "  no ${WORKFLOW_FILE}, skipping"
    printf '%s\tskipped\tno workflow file\n' "${repo}" >>"${RESULTS_LOG}"
    continue
  fi

  # 1. SHA-pin fetch-metadata@v3 (preserve the version comment). Uses `|`
  #    as the sed delimiter since the replacement text contains `#`.
  sed -i '' -E "s|uses: dependabot/fetch-metadata@v3|uses: dependabot/fetch-metadata@${FETCH_METADATA_SHA} # v3|" "${workflow_path}"

  # 2. Fix the spoofable actor check
  sed -i '' "s|if: github.actor == 'dependabot\[bot\]'|if: github.event.pull_request.user.login == 'dependabot[bot]'|" "${workflow_path}"

  # 3. Correct the header comment's incorrect claim about github.actor.
  #    The original spans two lines ("...not spoofable;" / "GitHub sets
  #    this from the authenticated user)."); collapse to one corrected line.
  sed -i '' "s|Only runs when github.actor == 'dependabot\[bot\]' (not spoofable;|Only runs when github.event.pull_request.user.login == 'dependabot[bot]'|" "${workflow_path}"
  sed -i '' "/GitHub sets this from the authenticated user)\.\$/d" "${workflow_path}"

  # 4. Add a documented inline ignore for the intentional dangerous-triggers finding
  if ! grep -q 'zizmor: ignore\[dangerous-triggers\]' "${workflow_path}"; then
    sed -i '' 's|^on:$|on: # zizmor: ignore[dangerous-triggers] intentional: dependabot-only via corrected actor check, minimal permissions, no PR code execution|' "${workflow_path}"
  fi

  verify_fail=""
  grep -q "fetch-metadata@${FETCH_METADATA_SHA}" "${workflow_path}" || verify_fail="fetch-metadata not pinned"
  grep -q "github.event.pull_request.user.login == 'dependabot\[bot\]'" "${workflow_path}" || verify_fail="${verify_fail:+${verify_fail}; }actor check not fixed"
  grep -q 'zizmor: ignore\[dangerous-triggers\]' "${workflow_path}" || verify_fail="${verify_fail:+${verify_fail}; }zizmor ignore comment missing"
  if [[ -n "${verify_fail}" ]]; then
    echo "  sed verification failed: ${verify_fail}"
    printf '%s\tfailed\tsed verification failed: %s\n' "${repo}" "${verify_fail}" >>"${RESULTS_LOG}"
    continue
  fi

  zizmor_out="${SCRATCH_ROOT}/zizmor-check.log"
  if ! zizmor "${workflow_path}" >"${zizmor_out}" 2>&1; then
    zizmor_detail=$(tr '\n\t' '  ' <"${zizmor_out}")
    echo "  zizmor still reports findings after fixes: ${zizmor_detail}"
    printf '%s\tfailed\tzizmor still reports findings: %s\n' "${repo}" "${zizmor_detail}" >>"${RESULTS_LOG}"
    continue
  fi

  git_err_log="${SCRATCH_ROOT}/git-err.log"
  git_err_detail=""

  if ! git -C "${clone_dir}" checkout -b "${BRANCH_NAME}" >"${git_err_log}" 2>&1; then
    git_err_detail=$(tr '\n\t' '  ' <"${git_err_log}")
    echo "  git checkout failed: ${git_err_detail}"
    printf '%s\tfailed\tgit checkout failed: %s\n' "${repo}" "${git_err_detail}" >>"${RESULTS_LOG}"
    continue
  fi

  add_flags=(-C "${clone_dir}" add)
  [[ -n "${FORCE_ADD[${repo}]:-}" ]] && add_flags+=(-f)
  add_flags+=("${WORKFLOW_FILE}")
  if ! git "${add_flags[@]}" >"${git_err_log}" 2>&1; then
    git_err_detail=$(tr '\n\t' '  ' <"${git_err_log}")
    echo "  git add failed: ${git_err_detail}"
    printf '%s\tfailed\tgit add failed: %s\n' "${repo}" "${git_err_detail}" >>"${RESULTS_LOG}"
    continue
  fi

  # Note: git hooks are NOT cloned with a repo, but core.hooksPath is a
  # machine-global git config, so the local pre-commit hook DOES run
  # here -- that's exactly what caught the zizmor findings this script
  # exists to fix. A commit failure below means the fixes above didn't
  # fully satisfy the hook; check the captured output for specifics.
  if ! git -C "${clone_dir}" commit -F "${commit_msg_file}" >"${git_err_log}" 2>&1; then
    git_err_detail=$(tr '\n\t' '  ' <"${git_err_log}")
    echo "  git commit failed: ${git_err_detail}"
    printf '%s\tfailed\tgit commit failed: %s\n' "${repo}" "${git_err_detail}" >>"${RESULTS_LOG}"
    continue
  fi

  if ! git -C "${clone_dir}" push -u origin "${BRANCH_NAME}" >"${git_err_log}" 2>&1; then
    git_err_detail=$(tr '\n\t' '  ' <"${git_err_log}")
    if grep -qi 'already exists' "${git_err_log}"; then
      echo "  branch ${BRANCH_NAME} already exists on remote for this repo — likely a re-run; delete it remotely and re-run, or use a fresh timestamp"
      printf '%s\tskipped\tbranch already exists on remote\n' "${repo}" >>"${RESULTS_LOG}"
    else
      echo "  git push failed: ${git_err_detail}"
      printf '%s\tfailed\tgit push failed: %s\n' "${repo}" "${git_err_detail}" >>"${RESULTS_LOG}"
    fi
    continue
  fi

  if pr_url=$(gh pr create --repo "${repo}" \
    --head "${BRANCH_NAME}" \
    --title "fix(ci): SHA-pin fetch-metadata, fix spoofable actor check in dependabot-auto-merge.yml" \
    --body-file "${pr_body_file}" \
    2>"${SCRATCH_ROOT}/pr-err.log") && [[ "${pr_url}" =~ ^https://github\.com/ ]]; then
    echo "  PR opened: ${pr_url}"
    printf '%s\topened\t%s\n' "${repo}" "${pr_url}" >>"${RESULTS_LOG}"
  else
    pr_err_detail=$(tr '\n\t' '  ' <"${SCRATCH_ROOT}/pr-err.log")
    echo "  gh pr create failed: ${pr_err_detail}"
    printf '%s\tfailed\t%s\n' "${repo}" "${pr_err_detail}" >>"${RESULTS_LOG}"
  fi
done

echo
echo "=== Summary ==="
column -t -s $'\t' "${RESULTS_LOG}" || cat "${RESULTS_LOG}"
echo
echo "Results will be saved to ${FINAL_LOG} on exit"
