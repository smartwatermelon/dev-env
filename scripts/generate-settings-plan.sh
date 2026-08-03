#!/usr/bin/env bash
# Generates the exact gh api commands to flip can_approve_pull_request_reviews
# to false for the 28 repos identified as remediation candidates in
# smartwatermelon/dev-env#21 (fleet-wide "Allow GitHub Actions to approve
# PRs" audit). This script only WRITES a plan file -- it never calls the
# PATCH endpoint itself. Review the output, then run the commands yourself.
#
# Usage: scripts/generate-settings-plan.sh [output-file]
#   Default output-file: scripts/settings-plan.sh

set -euo pipefail

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
  "nightowlstudiollc/reliquarist"
  "nightowlstudiollc/kebab-tax-netlify"
  "nightowlstudiollc/kebab-tax"
  "nightowlstudiollc/tnjcleaning"
  "nightowlstudiollc/amelia-boone"
  "nightowlstudiollc/financial-agent"
  "nightowlstudiollc/networth-agent"
  "nightowlstudiollc/.github"
  "nightowlstudiollc/vpn-lan-bridge"
  "nightowlstudiollc/night-owl-studio"
)

OUT_FILE="${1:-$(dirname "${BASH_SOURCE[0]}")/settings-plan.sh}"
DRAFT_FILE=$(mktemp)
trap 'rm -f "${DRAFT_FILE}"' EXIT

generated_date=$(date +%Y-%m-%d)
failed_repos=()

{
  echo "#!/usr/bin/env bash"
  echo "# Generated ${generated_date} from smartwatermelon/dev-env#21 remediation list."
  echo "# Review before running. Flips can_approve_pull_request_reviews to false"
  echo "# for each repo, reusing default_workflow_permissions values captured"
  echo "# AT GENERATION TIME (${generated_date}) -- if you changed that setting on"
  echo "# any of these repos since generating this plan, re-run"
  echo "# generate-settings-plan.sh before applying, or it will revert your change."
  echo "set -euo pipefail"
  echo
  for repo in "${REPOS[@]}"; do
    if ! current_default=$(gh api "repos/${repo}/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null); then
      failed_repos+=("${repo}")
      continue
    fi
    echo "echo '=== ${repo} ==='"
    echo "gh api --method PUT repos/${repo}/actions/permissions/workflow \\"
    echo "  -f default_workflow_permissions='${current_default}' \\"
    echo "  -F can_approve_pull_request_reviews=false"
  done
} >"${DRAFT_FILE}"

if [[ ${#failed_repos[@]} -gt 0 ]]; then
  echo "ERROR: could not fetch default_workflow_permissions for ${#failed_repos[@]} repo(s) — aborting without writing a plan file:" >&2
  printf '  %s\n' "${failed_repos[@]}" >&2
  echo "Fix access/auth for the repos above, then re-run." >&2
  exit 1
fi

cp "${DRAFT_FILE}" "${OUT_FILE}"
chmod +x "${OUT_FILE}"
line_count=$(wc -l <"${OUT_FILE}" | tr -d ' ')
echo "Plan written to ${OUT_FILE} (${line_count} lines)"
echo "Review it, then run: bash ${OUT_FILE}"
