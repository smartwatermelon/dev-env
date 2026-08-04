#!/usr/bin/env bash
# Fleet-wide remediation for smartwatermelon/dev-env#21: no repo in either
# org currently requires an approving review (required_approving_review_count
# is 0 everywhere), so the `gh pr review --approve` line in
# dependabot-auto-merge.yml is a dead no-op. This drops that line, leaving
# only `gh pr merge --auto --squash --delete-branch`, and opens one PR per
# repo. It does NOT touch the `can_approve_pull_request_reviews` repo
# setting — that's a separate plan file for the operator to review and
# apply by hand (see generate-settings-plan.sh in this same directory).
#
# Usage: scripts/drop-noop-approve-step.sh
#
# Only the 26 repos below (from the dev-env#21 audit comment) that actually
# have a dependabot-auto-merge.yml with the inert approve line are touched.
# This script creates real PRs (going through normal pre-commit/pre-push
# review hooks) but never merges anything — merging is a separate,
# explicitly authorized step per repo, same as every other PR in this
# workflow.
#
# NOTE: generate-settings-plan.sh's repo list has 28 entries, 2 more than
# here (nightowlstudiollc/reliquarist, nightowlstudiollc/.github). Those two
# have can_approve_pull_request_reviews=true but no dependabot-auto-merge.yml
# at all, so there's no workflow-file step to remove for them — they only
# need the repo-setting flip, not a PR from this script. Intentional, not
# a mismatch.
#
# macOS-only: uses BSD sed (`sed -i ''`). This is an operator script for
# this user's own machines (this one, TILSIT, MIMOLETTE), all macOS — not
# intended to run on Linux/CI.

set -euo pipefail

if ! auth_status_output=$(gh auth status 2>&1); then
  echo "gh is not authenticated — aborting before touching any repo:" >&2
  echo "${auth_status_output}" >&2
  exit 1
fi

REPOS=(
  "smartwatermelon/claude-config"
  "smartwatermelon/ralph-burndown"
  "smartwatermelon/dev-env"
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
  "nightowlstudiollc/tensegrity"
  "nightowlstudiollc/kebab-tax-netlify"
  "nightowlstudiollc/kebab-tax"
  "nightowlstudiollc/tnjcleaning"
  "nightowlstudiollc/amelia-boone"
  "nightowlstudiollc/financial-agent"
  "nightowlstudiollc/networth-agent"
  "nightowlstudiollc/vpn-lan-bridge"
  "nightowlstudiollc/night-owl-studio"
)

WORKFLOW_FILE=".github/workflows/dependabot-auto-merge.yml"
BRANCH_NAME="chore/drop-noop-pr-approve-$(date +%Y%m%d-%H%M%S)-$$"
SCRATCH_ROOT=$(mktemp -d)
RESULTS_LOG="${SCRATCH_ROOT}/results.tsv"
FINAL_LOG="${SCRATCH_ROOT%/}-drop-noop-approve-results.tsv"
printf 'repo\tstatus\tdetail\n' >"${RESULTS_LOG}"

trap 'cp "${RESULTS_LOG}" "${FINAL_LOG}" 2>/dev/null || true; rm -rf "${SCRATCH_ROOT}"' EXIT

commit_msg_file="${SCRATCH_ROOT}/commit-msg.txt"
cat >"${commit_msg_file}" <<'EOF'
chore(ci): drop no-op gh pr review --approve step

No repo in either org currently requires an approving review
(required_approving_review_count is 0 fleet-wide), so this step never
did anything -- gh pr merge --auto already proceeds once required
status checks pass. Removing the dead step; auto-merge behavior is
unchanged.

Ref: smartwatermelon/dev-env#21
EOF

pr_body_file="${SCRATCH_ROOT}/pr-body.txt"
cat >"${pr_body_file}" <<'EOF'
Removes the `gh pr review --approve` line from `dependabot-auto-merge.yml`.

No repo in either org currently requires an approving review
(`required_approving_review_count` is 0 fleet-wide, confirmed by audit
in smartwatermelon/dev-env#21), so this step has never done anything —
`gh pr merge --auto` already merges once required status checks pass.
Auto-merge behavior is unchanged; this only removes dead weight. The
`pull-requests: write` permission stays as-is — `gh pr merge --auto`
also requires it, independent of the removed approve call.

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

  if ! grep -qE '^[[:space:]]*gh pr review --approve' "${workflow_path}"; then
    echo "  no inert approve line found, skipping"
    printf '%s\tskipped\tno approve line present\n' "${repo}" >>"${RESULTS_LOG}"
    continue
  fi

  sed -i '' '/^[[:space:]]*gh pr review --approve/d' "${workflow_path}"

  if grep -qE '^[[:space:]]*gh pr review --approve' "${workflow_path}"; then
    echo "  sed failed to remove the approve line, skipping"
    printf '%s\tfailed\tsed did not remove approve line\n' "${repo}" >>"${RESULTS_LOG}"
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
  if ! git -C "${clone_dir}" add "${WORKFLOW_FILE}" >"${git_err_log}" 2>&1; then
    git_err_detail=$(tr '\n\t' '  ' <"${git_err_log}")
    echo "  git add failed: ${git_err_detail}"
    printf '%s\tfailed\tgit add failed: %s\n' "${repo}" "${git_err_detail}" >>"${RESULTS_LOG}"
    continue
  fi
  # Note: core.hooksPath is a machine-global git config, so the local
  # pre-commit hook DOES run here even though hooks aren't cloned with
  # the repo -- a commit failure below may be a hook rejection (see
  # retry-noop-approve-zizmor-fixes.sh, written to handle exactly that).
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
    --title "chore(ci): drop no-op gh pr review --approve step" \
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
