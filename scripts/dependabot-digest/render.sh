#!/usr/bin/env bash
# Render classify.sh output as the Markdown body of the digest issue.
#
# Usage: render.sh [--run-url URL] < classified.ndjson > body.md
#
# The body leads with what a human must do and states, per PR, the fact that
# put it in its bucket. It never says a PR will merge: the merge path runs
# ~/.claude/hooks/pre-merge-review.sh, whose AI analysis can still return
# BLOCK_MERGE on content grounds, and no static classifier can predict that.
set -uo pipefail
unset CDPATH

run_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-url) run_url="${2-}"; shift 2 ;;
    *) echo "render.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

input="$(cat)"

# Marker for upserting. The issue is found by this string, never by its title:
# a title that changes (it carries the PR count) would create a second issue
# every time the count moved.
echo '<!-- dependabot-digest:v1 -->'
echo

if [[ -z "${input//[[:space:]]/}" ]]; then
  echo "No open Dependabot pull requests across the fleet."
  echo
else
  total="$(grep -c . <<<"${input}")"
  actionable="$(jq -s '[.[] | select(.bucket != "held")] | length' <<<"${input}")"
  oldest="$(jq -s '[.[].ageDays] | max' <<<"${input}")"
  echo "**${total} open Dependabot PRs**, ${actionable} awaiting action, oldest ${oldest} days."
  echo

  # Buckets in the order a human should work them: things that need only a
  # decision first, things that need work last.
  render_bucket() {
    local bucket="$1" heading="$2" blurb="$3" rows
    rows="$(jq -c --arg b "${bucket}" 'select(.bucket == $b)' <<<"${input}")"
    [[ -z "${rows}" ]] && return 0
    echo "## ${heading}"
    echo
    echo "${blurb}"
    echo
    echo '| PR | Why it is here | Age | Not auto-merged because |'
    echo '| --- | --- | --- | --- |'
    jq -r '
      # The one fact that explains this row. Naming the specific check beats a
      # generic status: "build" sends someone to a file, "UNSTABLE" does not.
      def reason:
        if .bucket == "needs-work" then "required check failed: " + (.blockingFailures | join(", "))
        elif .bucket == "hook-blocked" then (.hookBlockers | join("; "))
        elif .bucket == "advisory-red" then
          (if (.ownFailures | length) > 0
             then "failing (not required): " + (.ownFailures | join(", "))
             else "" end)
          + (if (.inheritedFailures | length) > 0
             then (if (.ownFailures | length) > 0 then " — plus " else "" end)
               + "inherited from a red base branch: " + (.inheritedFailures | join(", "))
             else "" end)
          + (if .baseRedKnown then "" else " (base branch state unreadable, so attribution is unverified)" end)
        elif .bucket == "waiting-on-ci" then "required checks still running"
        elif .bucket == "update-branch" then "behind its base branch"
        elif .bucket == "conflicted" then "merge conflict; only Dependabot can resolve"
        elif .bucket == "held" then "held by label or draft"
        else "all required checks passed" end;
      "| [" + .repo + "#" + (.number | tostring) + "](https://github.com/" + .repo + "/pull/" + (.number | tostring) + ") "
      + "| " + reason + " | " + (.ageDays | tostring) + "d | " + .whyManual + " |"
    ' <<<"${rows}"
    echo
  }

  render_bucket ready-to-merge "Ready for a merge-lock" \
    "Every required check passed and the pre-merge hook has no mechanical objection. The hook still runs its AI review on merge, which can block on content — this list means nothing stands in the way yet, not that the merge will succeed."
  render_bucket update-branch "Needs a branch update" \
    "Mergeable, but behind the base branch. Comment \`@dependabot rebase\` on each."
  render_bucket hook-blocked "Blocked by the pre-merge hook" \
    "GitHub branch protection would allow these, but \`pre-merge-review.sh\` will refuse them. A NEUTRAL check usually means the check could not answer rather than that it found a problem — worth fixing the check, not merging past it."
  render_bucket advisory-red "Failing checks that do not block merge" \
    "GitHub would merge these: the failing checks are not required. That does not make merging them right. Anything listed as inherited comes from an already-red base branch, so the repo needs fixing before the PR is worth judging."
  render_bucket needs-work "Needs code changes" \
    "A required check is failing. These need a person."
  render_bucket conflicted "Conflicted" \
    "Comment \`@dependabot recreate\` — but note that recreating upgrades to the latest version, which may differ from the one in the title."
  render_bucket waiting-on-ci "Waiting on CI" \
    "Required checks are still running. Nothing to do yet."
  render_bucket held "Held" \
    "Parked by a label or still a draft. Listed for completeness."

  # Paste-ready authorization lines. Merge-locks are human-only by design, so
  # the digest gets the reader as close to the command as it can without
  # running it. Only ready-to-merge PRs appear: offering a lock line for a PR
  # with failing builds would be the digest arguing for a bad merge.
  locks="$(jq -sr '
    [.[] | select(.bucket == "ready-to-merge")]
    | group_by(.repo)
    | .[]
    | "merge-lock authorize " + (.[0].repo) + "#" + ([.[].number] | map(tostring) | join(",")) + " \"ok\""
  ' <<<"${input}")"
  if [[ -n "${locks}" ]]; then
    echo "## Authorize"
    echo
    echo "Run locally; each lock lasts 30 minutes."
    echo
    echo '```bash'
    echo "${locks}"
    echo '```'
    echo
  fi
fi

echo "---"
echo
generated_at="$(date -u '+%Y-%m-%d %H:%M UTC')"
printf 'Generated %s' "${generated_at}"
if [[ -n "${run_url}" ]]; then
  printf ' by [this run](%s)' "${run_url}"
fi
printf '.\n'
echo
echo "A digest older than a day or two is stale: the scheduled run may have"
echo "stopped. GitHub disables scheduled workflows in public repositories after"
echo "60 days without repository activity."
