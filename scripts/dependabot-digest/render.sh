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
  local file="$1" recs checked clean warned unchecked archived rows lines view stale stale_repos undated rules_at rules_err
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
  echo "Warning- and notice-level annotations from each repository's latest \`standards-check\` run that vetted its default branch. Fleet callers run only on pull requests, so that is usually the run on the head commit of the PR that produced the default-branch head. A PR run lints only the files that PR changed (node-floor always checks the whole repo), so \"no warnings\" means that run was clean, not that the whole repository is. Routine notices (no Markdown, shell or YAML files, no workflows) are omitted, a notice repeated across repositories is shown once, and repositories with nothing to list are counted, not listed."
  echo
  unchecked="$(jq -s '[.[] | select(.state != "ok" and .state != "archived")] | length' <<<"${recs}")"

  # Drop routine notices; collapse repeated ones. Never touch warnings.
  if ! view="$(jq -cs '
    def routine: ["no Markdown files", "no shell files", "no YAML files", "no workflows"];
    def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    [.[] | select(.state == "ok")] as $ok
    | ($ok | map(.kept = [.annotations[]
        | select((.level == "notice" and (.message as $m | routine | index($m))) | not)])) as $k
    | ([$k[] | .repo as $r
        | (.kept | map(select(.level == "notice") | .message) | unique)[]
        | {repo: $r, m: .}]
       | group_by(.m) | map({message: .[0].m, count: length}) | map(select(.count >= 2))) as $collapsed
    | {collapsed: $collapsed,
       recs: ($k | map(
         .rows = [.kept[] | select((.level == "notice"
                 and (.message as $m | $collapsed | any(.message == $m))) | not)]
         | .dated = (.runAt | iso)
         | .stale = ((.runAt | iso) and (.rulesAt | iso)
                     and ((.runAt | fromdateiso8601) < (.rulesAt | fromdateiso8601)))))}
  ' <<<"${recs}" 2>/dev/null)" || [[ -z "${view}" ]]; then
    echo "**Warnings could not be rendered.** The survey data could not be summarized; see the run log."
    echo
    return 0
  fi
  checked="$(jq '.recs | length' <<<"${view}")"
  warned="$(jq '[.recs[] | select((.rows | length) > 0)] | length' <<<"${view}")"
  clean=$((checked - warned))
  stale="$(jq '[.recs[] | select(.stale)] | length' <<<"${view}")"
  undated="$(jq '[.recs[] | select(.dated | not)] | length' <<<"${view}")"
  rules_at="$(jq -r '[.recs[].rulesAt | select(. != null)] | first // ""' <<<"${view}")"
  rules_err="$(jq -r '[.recs[].rulesErr | select(. != null)] | first // "no rules date recorded"' <<<"${view}")"
  echo "**${checked} repositories checked**: ${warned} with warnings or notices, ${clean} with none. **${unchecked} not checked.**"
  echo
  if [[ -n "${rules_at}" ]]; then
    echo "Current rules: \`standards-check-v1\` as of ${rules_at:0:10}. **${stale} run(s) predate current rules**, so their results do not reflect them."
    if [[ "${stale}" -gt 0 ]]; then
      echo
      stale_repos="$(jq -r '[.recs[] | select(.stale) | .repo] | join(", ")' <<<"${view}")"
      echo "Predate current rules: ${stale_repos}."
    fi
  elif [[ "${checked}" -gt 0 ]]; then
    echo "**Rules date unknown** (${rules_err}), so whether a run predates the current rules was not checked."
  fi
  if [[ "${undated}" -gt 0 ]]; then
    echo
    echo "**${undated} run(s) have no readable date**, so they could not be compared with the current rules."
  fi
  echo

  if [[ "${checked}" -eq 0 ]]; then
    # Zero warnings out of zero repositories read is not "no warnings".
    echo "**No repository could be checked**, so no warnings were looked for."
    echo
  else
    if [[ "${warned}" -eq 0 ]]; then
      echo "No warnings: no checked repository's latest run carried a warning or notice annotation worth listing."
      echo
    fi
    lines="$(jq -r '.collapsed[] | "- \(.count) repositories carry the same notice: \(.message | gsub("[\r\n]+"; " "))"' <<<"${view}")"
    if [[ -n "${lines}" ]]; then
      echo "${lines}"
      echo
    fi
    # Zero warnings means no table: clean repos are counted, not listed.
    # With warnings, a failed jq prints nothing and an empty table reads clean.
    if [[ "${warned}" -eq 0 ]]; then
      :
    elif ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      # GitHub puts file-less annotations under path .github.
      def where: if .path == "" or .path == ".github" then "—"
                 else "`" + .path + (if .line then ":" + (.line | tostring) else "" end) + "`" end;
      def ran: (if .dated then .runAt[:10] else "date unknown" end)
               + (if .stale then " — **predates current rules**" else "" end);
      .recs[] | . as $r
      | ((if $r.runUrl then "[" + $r.repo + "](" + $r.runUrl + ")" else $r.repo end)
         + " | " + ($r | ran)) as $head
      | $r.rows[]
      | "| " + $head + " | " + .level + " | " + where + " | " + (.message | cell) + " |"
    ' <<<"${view}")" || [[ -z "${rows}" ]]; then
      echo "**Repositories checked but the table could not be rendered.** See the run log."
      echo
    else
      echo "| Repo | Latest run | Level | File | Message |"
      echo "| --- | --- | --- | --- | --- |"
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

# dev-env#211. An unreadable repo is never counted as protected or as
# unprotected; if none was read, say so.
render_protection() {
  local file="$1" recs surveyed required exempt flagged unreadable by_class owners rows
  echo "## Branch protection"
  echo
  if [[ ! -r "${file}" ]] || ! jq -e -s 'type == "array"' "${file}" >/dev/null 2>&1; then
    echo "**Not checked.** The survey produced no readable result, so no repository's protection was verified."
    echo
    return 0
  fi
  # A record without a protection object (an older or crashed survey) is
  # unreadable, not clean.
  if ! recs="$(jq -cs '
    [.[] | select(type == "object" and (.repo | type == "string") and .state != "archived")
     | .p = (if (.protection | type) == "object"
                and (.protection.state | type) == "string"
             then .protection
             else {state: "unreadable", detail: "no protection result recorded", exemptClass: null} end)]
  ' "${file}" 2>/dev/null)" || [[ -z "${recs}" ]]; then
    echo "**Not checked.** The survey output could not be summarized, so no repository's protection was verified."
    echo
    return 0
  fi
  owners="$(jq -rs '[.[] | select(type == "object" and .repo == null and .state == "unlisted") | .owner] | unique | join(", ")' "${file}" 2>/dev/null)"
  surveyed="$(jq 'length' <<<"${recs}")"
  required="$(jq '[.[] | select(.p.state == "required")] | length' <<<"${recs}")"
  exempt="$(jq '[.[] | select(.p.state == "exempt")] | length' <<<"${recs}")"
  unreadable="$(jq '[.[] | select(.p.state != "required" and .p.state != "exempt"
                                and .p.state != "unprotected" and .p.state != "protected-no-standards")] | length' <<<"${recs}")"
  flagged=$((surveyed - required - exempt - unreadable))

  echo "Whether each repository's default branch is protected and requires \`standards-check / run-standards-check\`. Exempt repositories are unprotected by a recorded decision for their class; they are counted, not listed."
  echo
  if [[ "${surveyed}" -eq 0 ]]; then
    echo "**No repository was surveyed**, so no protection was verified."
    echo
  elif [[ "${unreadable}" -eq "${surveyed}" ]]; then
    # Zero gaps out of zero reads is not "all protected".
    echo "**Protection could not be verified for any of ${surveyed} repositories.** Every read failed or returned no protection settings. The likely cause is a token without permission to read branch protection. Nothing here means the fleet is protected or unprotected."
    echo
  else
    echo "**${surveyed} repositories surveyed**: ${required} require standards-check, ${exempt} exempt, **${flagged} need attention, ${unreadable} unreadable.**"
    echo
    if [[ "${exempt}" -gt 0 ]]; then
      by_class="$(jq -r '[.[] | select(.p.state == "exempt")] | group_by(.p.exemptClass)
        | map("- \(.[0].p.exemptClass // "unknown class"): \(length) — \(.[0].p.detail // "no reason recorded")") | join("\n")' <<<"${recs}")"
      echo "Exempt by class:"
      echo
      echo "${by_class}"
      echo
    fi
    if [[ "${flagged}" -eq 0 && "${unreadable}" -eq 0 ]]; then
      echo "No gaps: every surveyed repository requires standards-check or is exempt."
      echo
    fi
  fi
  if [[ "${flagged}" -gt 0 || "${unreadable}" -gt 0 ]]; then
    if ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      def order: {"unprotected": 0, "protected-no-standards": 1}[.p.state] // 2;
      def name: {"unprotected": "UNPROTECTED", "protected-no-standards": "standards-check not required"}[.p.state] // "UNREADABLE";
      sort_by(order, .repo)[]
      | select(.p.state != "required" and .p.state != "exempt")
      | "| [" + .repo + "](https://github.com/" + .repo + ") | " + name
        + (if .p.detail then ": " + (.p.detail | cell) else "" end) + " |"
    ' <<<"${recs}")" || [[ -z "${rows}" ]]; then
      echo "**Some repositories need attention, but listing them failed.** See the run log."
      echo
    else
      echo "| Repo | Protection |"
      echo "| --- | --- |"
      echo "${rows}"
      echo
    fi
  fi
  if [[ -n "${owners}" ]]; then
    echo "**Not listed, so not surveyed:** ${owners}. Protection of their repositories is unknown."
    echo
  fi
}

# render_sg_list <state> <count> <heading> <blurb>: one Semgrep list.
# Reads recs from render_codeql.
render_sg_list() {
  local state="$1" count="$2" heading="$3" blurb="$4" list
  [[ "${count}" -gt 0 ]] || return 0
  list="$(jq -r --arg s "${state}" '
    def cell: tostring | gsub("[\r\n]+"; " ");
    sort_by(.repo)[] | select(.s.state == $s)
    | "- [" + .repo + "](https://github.com/" + .repo + ")"
      + (if .s.detail then ": " + (.s.detail | cell) else "" end)' <<<"${recs}" 2>/dev/null)"
  echo "#### ${heading}"
  echo
  if [[ -n "${blurb}" ]]; then
    echo "${blurb}"
    echo
  fi
  echo "${list:-**${count} repositories, but listing them failed.** See the run log.}"
  echo
}

# dev-env#166. As for protection: unreadable is never on or off, and an
# all-unreadable survey says so.
render_codeql() {
  local file="$1" recs surveyed configured exempt flagged unreadable by_class owners rows
  local nocs sg_cov sg_none sg_unk
  echo "## CodeQL"
  echo
  if [[ ! -r "${file}" ]] || ! jq -e -s 'type == "array"' "${file}" >/dev/null 2>&1; then
    echo "**Not checked.** The survey produced no readable result, so no repository's CodeQL setup was verified."
    echo
    return 0
  fi
  # No codeql object (older or crashed survey) is unreadable, not clean.
  # .s, the Semgrep substitute, is unreadable when missing or unknown.
  if ! recs="$(jq -cs '
    [.[] | select(type == "object" and (.repo | type == "string") and .state != "archived")
     | .c = (if (.codeql | type) == "object" and (.codeql.state | type) == "string"
             then .codeql
             else {state: "unreadable", detail: "no CodeQL result recorded", exemptClass: null} end)
     | .s = (if .c.state != "no-code-security" then null
             elif .c.substitute == "semgrep" or .c.substitute == "none"
             then {state: .c.substitute, detail: (.c.substituteDetail // null)}
             elif .c.substitute == null then {state: "unreadable", detail: "no Semgrep result recorded"}
             else {state: "unreadable",
                   detail: (.c.substituteDetail // ("unknown Semgrep state: " + (.c.substitute | tostring)))} end)]
  ' "${file}" 2>/dev/null)" || [[ -z "${recs}" ]]; then
    echo "**Not checked.** The survey output could not be summarized, so no repository's CodeQL setup was verified."
    echo
    return 0
  fi
  owners="$(jq -rs '[.[] | select(type == "object" and .repo == null and .state == "unlisted") | .owner] | unique | join(", ")' "${file}" 2>/dev/null)"
  surveyed="$(jq 'length' <<<"${recs}")"
  configured="$(jq '[.[] | select(.c.state == "configured")] | length' <<<"${recs}")"
  exempt="$(jq '[.[] | select(.c.state == "exempt")] | length' <<<"${recs}")"
  flagged="$(jq '[.[] | select(.c.state == "not-configured")] | length' <<<"${recs}")"
  nocs="$(jq '[.[] | select(.c.state == "no-code-security")] | length' <<<"${recs}")"
  sg_cov="$(jq '[.[] | select(.s.state == "semgrep")] | length' <<<"${recs}")"
  sg_none="$(jq '[.[] | select(.s.state == "none")] | length' <<<"${recs}")"
  sg_unk=$((nocs - sg_cov - sg_none))
  unreadable=$((surveyed - configured - exempt - flagged - nocs))

  echo "Whether each repository has CodeQL default setup turned on. Exempt repositories are left off by a recorded decision for their class; they are counted, not listed."
  echo
  if [[ "${surveyed}" -eq 0 ]]; then
    echo "**No repository was surveyed**, so no CodeQL setup was verified."
    echo
  elif [[ "${unreadable}" -eq "${surveyed}" ]]; then
    # Zero gaps out of zero reads is not "all configured".
    echo "**CodeQL setup could not be verified for any of ${surveyed} repositories.** Every read failed or returned no usable state. The likely cause is a token without \`Administration: Read\`, which the default-setup endpoint needs. Nothing here means CodeQL is on or off anywhere."
    echo
  else
    echo "**${surveyed} repositories surveyed**: ${configured} configured, ${exempt} exempt, ${sg_cov} covered by Semgrep, **${flagged} not configured, ${sg_none} with no code scanning, ${sg_unk} with Semgrep coverage unreadable, ${unreadable} unreadable.**"
    echo
    if [[ "${exempt}" -gt 0 ]]; then
      by_class="$(jq -r '[.[] | select(.c.state == "exempt")] | group_by(.c.exemptClass)
        | map("- \(.[0].c.exemptClass // "unknown class"): \(length) — \(.[0].c.detail // "no reason recorded")") | join("\n")' <<<"${recs}")"
      echo "Exempt by class:"
      echo
      echo "${by_class}"
      echo
    fi
    if [[ "${flagged}" -eq 0 && "${unreadable}" -eq 0 && "${nocs}" -eq 0 ]]; then
      echo "No gaps: every surveyed repository has default setup on or is exempt."
      echo
    fi
  fi
  if [[ "${flagged}" -gt 0 || "${unreadable}" -gt 0 ]]; then
    if ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      def name: if .c.state == "not-configured" then "NOT CONFIGURED" else "UNREADABLE" end;
      sort_by((if .c.state == "not-configured" then 0 else 1 end), .repo)[]
      | select(.c.state | IN("configured", "exempt", "no-code-security") | not)
      | "| [" + .repo + "](https://github.com/" + .repo + ") | " + name
        + (if .c.detail then ": " + (.c.detail | cell) else "" end) + " |"
    ' <<<"${recs}")" || [[ -z "${rows}" ]]; then
      echo "**Some repositories need attention, but listing them failed.** See the run log."
      echo
    else
      echo "| Repo | CodeQL default setup |"
      echo "| --- | --- |"
      echo "${rows}"
      echo
    fi
  fi
  # Listed by name, not exempt: Semgrep coverage is per repo and can lapse.
  if [[ "${nocs}" -gt 0 ]]; then
    echo "### Without paid Code Security"
    echo
    echo "GitHub refuses code scanning on these private repositories until the paid GitHub Code Security add-on is enabled. Code Security is not bought, by decision (2026-10-21, dev-env#166). Semgrep CE is the substitute: a caller at \`.github/workflows/semgrep-scan.yml\` runs the reusable \`semgrep-scan.yml\` workflow from smartwatermelon/github-workflows."
    echo
    render_sg_list semgrep "${sg_cov}" "Covered by Semgrep (CodeQL substitute)" ""
    render_sg_list none "${sg_none}" "No code scanning: paid Code Security not bought, no Semgrep caller" ""
    render_sg_list unreadable "${sg_unk}" "Semgrep coverage unreadable" \
      "The Semgrep caller of these repositories could not be read, so their coverage is unknown: not present, not absent."
  fi
  if [[ -n "${owners}" ]]; then
    echo "**Not listed, so not surveyed:** ${owners}. CodeQL setup of their repositories is unknown."
    echo
  fi
}

# Dependabot security alerts. As for CodeQL: unreadable is never on or off,
# and an all-unreadable survey says so. Forks are exempt, as above.
render_alerts() {
  local file="$1" recs surveyed on off exempt unreadable by_class owners rows
  echo "## Dependabot alerts"
  echo
  if [[ ! -r "${file}" ]] || ! jq -e -s 'type == "array"' "${file}" >/dev/null 2>&1; then
    echo "**Not checked.** The survey produced no readable result, so no repository's alerts setting was verified."
    echo
    return 0
  fi
  # No alerts object (older or crashed survey) is unreadable, not on.
  if ! recs="$(jq -cs '
    [.[] | select(type == "object" and (.repo | type == "string") and .state != "archived")
     | .a = (if (.alerts | type) == "object" and (.alerts.state | type) == "string"
             then .alerts
             else {state: "unreadable", detail: "no alerts result recorded"} end)]
  ' "${file}" 2>/dev/null)" || [[ -z "${recs}" ]]; then
    echo "**Not checked.** The survey output could not be summarized, so no repository's alerts setting was verified."
    echo
    return 0
  fi
  owners="$(jq -rs '[.[] | select(type == "object" and .repo == null and .state == "unlisted") | .owner] | unique | join(", ")' "${file}" 2>/dev/null)"
  surveyed="$(jq 'length' <<<"${recs}")"
  on="$(jq '[.[] | select(.a.state == "on")] | length' <<<"${recs}")"
  off="$(jq '[.[] | select(.a.state == "off")] | length' <<<"${recs}")"
  exempt="$(jq '[.[] | select(.a.state == "exempt")] | length' <<<"${recs}")"
  unreadable=$((surveyed - on - off - exempt))

  echo "Whether each repository has Dependabot security alerts turned on. Off is a gap unless the repository is exempt."
  echo
  if [[ "${surveyed}" -eq 0 ]]; then
    echo "**No repository was surveyed**, so no alerts setting was verified."
    echo
  elif [[ "${unreadable}" -eq "${surveyed}" ]]; then
    # Zero gaps out of zero reads is not "all on".
    echo "**Alerts could not be verified for any of ${surveyed} repositories.** Every read failed or returned no usable state. The likely cause is a token without \`Administration: Read\`, which the vulnerability-alerts endpoint needs. Nothing here means alerts are on or off anywhere."
    echo
  else
    echo "**${surveyed} repositories surveyed**: ${on} on, ${exempt} exempt, **${off} off, ${unreadable} unreadable.**"
    echo
    if [[ "${exempt}" -gt 0 ]]; then
      by_class="$(jq -r '[.[] | select(.a.state == "exempt")] | group_by(.a.exemptClass)
        | map("- \(.[0].a.exemptClass // "unknown class"): \(length) — \(.[0].a.detail // "no reason recorded")") | join("\n")' <<<"${recs}")"
      echo "Exempt by class:"
      echo
      echo "${by_class}"
      echo
    fi
    if [[ "${off}" -eq 0 && "${unreadable}" -eq 0 ]]; then
      echo "No gaps: every surveyed repository has Dependabot security alerts on or is exempt."
      echo
    fi
  fi
  if [[ "${off}" -gt 0 || "${unreadable}" -gt 0 ]]; then
    if ! rows="$(jq -r '
      def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
      def name: if .a.state == "off" then "OFF" else "UNREADABLE" end;
      sort_by((if .a.state == "off" then 0 else 1 end), .repo)[]
      | select(.a.state != "on" and .a.state != "exempt")
      | "| [" + .repo + "](https://github.com/" + .repo + ") | " + name
        + (if .a.detail then ": " + (.a.detail | cell) else "" end) + " |"
    ' <<<"${recs}")" || [[ -z "${rows}" ]]; then
      echo "**Some repositories need attention, but listing them failed.** See the run log."
      echo
    else
      echo "| Repo | Dependabot alerts |"
      echo "| --- | --- |"
      echo "${rows}"
      echo
    fi
  fi
  if [[ -n "${owners}" ]]; then
    echo "**Not listed, so not surveyed:** ${owners}. The alerts setting of their repositories is unknown."
    echo
  fi
}

if [[ -n "${standards_file}" ]]; then
  render_standards "${standards_file}"
  render_protection "${standards_file}"
  render_codeql "${standards_file}"
  render_alerts "${standards_file}"
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
