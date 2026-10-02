#!/usr/bin/env bash
# Render classify.sh output as the Markdown body of the digest issue.
#
# Usage: render.sh [--run-url URL] [--standards FILE] < classified.ndjson > body.md
# --standards takes standards.sh output.
#
# The body leads with what a human must do and states, per PR, the fact that
# put it in its bucket. It never says a PR will merge: the merge path runs
# ~/.claude/hooks/pre-merge-review.sh, whose AI analysis can still return
# BLOCK_MERGE on content grounds, and no static classifier can predict that.
set -uo pipefail
unset CDPATH

run_url=""
standards_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-url) run_url="${2-}"; shift 2 ;;
    --standards) standards_file="${2-}"; shift 2 ;;
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
        if .bucket == "checks-unreadable" then
          "CHECK DATA INCOMPLETE: " + (.unreadableChecks | tostring)
          + " check(s) unreadable — treat nothing here as green"
        elif .bucket == "needs-work" then "required check failed: " + (.blockingFailures | join(", "))
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

  render_bucket checks-unreadable "Check results could not be read" \
    "The token could not read these PRs' check results, so their status is unknown — not green. GitHub returns the rollup with the right count and nulls the checks it will not show, which reads as \"nothing failing\" unless caught. A fine-grained token cannot be granted Checks: read at all (github.com/orgs/community/discussions/129512). Do not merge on the strength of this section."
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

# dev-env#179. Keep three outcomes apart: warnings, clean, not checked.
render_standards() {
  local file="$1" recs checked clean warned unchecked archived rows
  echo "## Standards warnings"
  echo
  if [[ ! -r "${file}" ]]; then
    echo "**Not checked.** The standards survey produced no readable result, so nothing below the Dependabot queue was verified."
    echo
    return 0
  fi
  # jq stops at a malformed line, dropping every repo after it.
  if ! jq -e -s 'type == "array"' "${file}" >/dev/null 2>&1; then
    echo "**Not checked.** The standards survey output is malformed, so nothing was verified."
    echo
    return 0
  fi
  recs="$(jq -c 'select(type == "object" and (.state | type == "string"))' "${file}" 2>/dev/null)"
  if [[ -z "${recs}" ]]; then
    echo "**Not checked.** The standards survey returned no repositories, so nothing was verified."
    echo
    return 0
  fi
  echo "Warning- and notice-level annotations from each repository's latest \`standards-check\` run that vetted its default branch. Fleet callers run only on pull requests, so that is usually the run on the head commit of the PR that produced the default-branch head. A PR run lints only the files that PR changed (node-floor always checks the whole repo), so \"no warnings\" means that run was clean, not that the whole repository is."
  echo
  checked="$(jq -s '[.[] | select(.state == "ok")] | length' <<<"${recs}")"
  warned="$(jq -s '[.[] | select(.state == "ok" and (.annotations | length) > 0)] | length' <<<"${recs}")"
  clean=$((checked - warned))
  unchecked="$(jq -s '[.[] | select(.state != "ok" and .state != "archived")] | length' <<<"${recs}")"
  echo "**${checked} repositories checked**: ${warned} with warnings or notices, ${clean} with none. **${unchecked} not checked.**"
  echo

  if [[ "${checked}" -eq 0 ]]; then
    # Zero warnings out of zero repositories read is not "no warnings".
    echo "**No repository could be checked**, so no warnings were looked for."
    echo
  elif [[ "${warned}" -eq 0 ]]; then
    echo "No warnings: no checked repository's latest run carried a warning or notice annotation."
    echo
  else
    # A failed jq prints nothing; an empty table would read as clean.
    if ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      # GitHub puts file-less annotations under path .github.
      def where: if .path == "" or .path == ".github" then "—"
                 else "`" + .path + (if .line then ":" + (.line | tostring) else "" end) + "`" end;
      select(.state == "ok") | . as $r | .annotations[]
      | "| " + (if $r.runUrl then "[" + $r.repo + "](" + $r.runUrl + ")" else $r.repo end)
        + " | " + .level + " | " + where + " | " + (.message | cell) + " |"
    ' <<<"${recs}")" || [[ -z "${rows}" ]]; then
      echo "**Warnings found but could not be rendered.** ${warned} repositories carry annotations; see the run log."
      echo
    else
      echo "| Repo | Level | File | Message |"
      echo "| --- | --- | --- | --- |"
      echo "${rows}"
      echo
    fi
  fi

  if [[ "${unchecked}" -gt 0 ]]; then
    echo "### Not checked"
    echo
    echo "These repositories have no readable standards-check result. Their warnings, if any, are unknown — not absent."
    echo
    if ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      def state_name: {"unreadable": "UNREADABLE", "unlisted": "OWNER NOT LISTED",
                       "no-run": "no standards-check run", "no-pr": "no run, no merged PR",
                       "in-progress": "run in progress"}[.state] // .state;
      select(.state != "ok" and .state != "archived")
      | "| " + (.repo // ("all of " + .owner)) + " | " + state_name + ": " + (.detail | cell) + " |"
    ' <<<"${recs}")" || [[ -z "${rows}" ]]; then
      echo "**${unchecked} repositories were not checked, and the list could not be rendered.** See the run log."
      echo
    else
      echo "| Repo | Why |"
      echo "| --- | --- |"
      echo "${rows}"
      echo
    fi
  fi

  archived="$(jq -rs '[.[] | select(.state == "archived") | .repo] | join(", ")' <<<"${recs}")"
  if [[ -n "${archived}" ]]; then
    echo "Archived, not surveyed: ${archived}."
    echo
  fi
}

if [[ -n "${standards_file}" ]]; then
  render_standards "${standards_file}"
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
