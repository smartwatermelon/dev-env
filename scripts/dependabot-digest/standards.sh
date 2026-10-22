#!/usr/bin/env bash
# Usage: standards.sh <owner>. Prints one JSON record per repo: standards-check
# annotations, or the reason none were read, plus the default branch's
# protection state (dev-env#211), CodeQL default setup (dev-env#166) and
# whether Dependabot security alerts are on.
set -uo pipefail
unset CDPATH

owner="${1-}"
if [[ -z "${owner}" ]]; then
  echo "standards.sh: usage: standards.sh <owner>" >&2
  exit 2
fi

# Match the reusable job name only: callers may name their job differently.
read -r -d '' pick_run <<'JQ'
[.check_runs[]
 | select(.app.slug == "github-actions")
 | select(.name == "run-standards-check"
          or (.name | endswith(" / run-standards-check")))]
| sort_by(.id) | last
JQ

# Nulled entries or a short page mean the list cannot be trusted.
read -r -d '' runs_sane <<'JQ'
(.check_runs | type == "array")
and (.total_count | type == "number")
and (.total_count <= (.check_runs | length))
and all(.check_runs[]; (.id | type == "number") and (.name | type == "string"))
JQ

emit() {
  # emit <repo> <state> <detail> [source] [run_url] [annotations_json] [run_at]
  local line
  line="$(jq -cn --arg owner "${owner}" --arg repo "$1" --arg state "$2" \
    --arg detail "$3" --arg source "${4-}" --arg url "${5-}" \
    --argjson ann "${6:-[]}" --arg runAt "${7-}" \
    --arg rulesAt "${RULES_AT}" --arg rulesErr "${RULES_ERR}" \
    --argjson prot "${PROT_JSON:-null}" --argjson cq "${CQ_JSON:-null}" \
    --argjson al "${ALERTS_JSON:-null}" \
    '{owner: $owner, repo: (if $repo == "" then null else $repo end),
      state: $state, detail: $detail,
      source: (if $source == "" then null else $source end),
      runUrl: (if $url == "" then null else $url end),
      runAt: (if $runAt == "" then null else $runAt end),
      rulesAt: (if $rulesAt == "" then null else $rulesAt end),
      rulesErr: (if $rulesErr == "" then null else $rulesErr end),
      annotations: $ann, protection: $prot, codeql: $cq, alerts: $al}' 2>/dev/null)"
  # If jq fails, the repo must still appear. Protection, CodeQL, alerts unknown.
  if [[ -z "${line}" ]]; then
    printf '{"owner":"%s","repo":"%s","state":"unreadable","detail":"could not encode the result","source":null,"runUrl":null,"runAt":null,"rulesAt":null,"rulesErr":null,"annotations":[],"protection":null,"codeql":null,"alerts":null}\n' \
      "${owner}" "$1"
    return 0
  fi
  printf '%s\n' "${line}"
}

# Callers run api in a subshell, so the failure reason goes to a file.
ERRF="$(mktemp)"
trap 'rm -f "${ERRF}"' EXIT
api() {
  : >"${ERRF}"
  gh api "$@" 2>"${ERRF}"
}
# emit_err <repo> <state> <what failed> <fallback reason> [source] [run_url]
emit_err() {
  local why
  why="$(last_err "$4")"
  emit "$1" "$2" "$3: ${why}" "${5-}" "${6-}"
}
set_err() { printf '%s' "$1" >"${ERRF}"; }
last_err() {
  local e
  e="$(tr '\n' ' ' <"${ERRF}" | cut -c1-160)"
  printf '%s' "${e:-$1}"
}

# Commit date of the rules tag; older runs predate the rules. On failure
# RULES_ERR says why, so the digest reports it.
RULES_REPO="smartwatermelon/github-workflows"
RULES_TAG="standards-check-v1"
RULES_AT=""
RULES_ERR=""
resolve_rules_at() {
  local pair kind sha date hops=0
  if ! pair="$(api "repos/${RULES_REPO}/git/ref/tags/${RULES_TAG}" --jq '.object.type + " " + .object.sha')"; then
    RULES_ERR="cannot read tag ${RULES_TAG}: $(last_err "no detail")"
    return 0
  fi
  kind="${pair%% *}"
  sha="${pair##* }"
  # An annotated tag points at a tag object; dereference it to the commit.
  while [[ "${kind}" == "tag" && "${hops}" -lt 3 ]]; do
    hops=$((hops + 1))
    if ! pair="$(api "repos/${RULES_REPO}/git/tags/${sha}" --jq '.object.type + " " + .object.sha')"; then
      RULES_ERR="cannot dereference tag ${RULES_TAG}: $(last_err "no detail")"
      return 0
    fi
    kind="${pair%% *}"
    sha="${pair##* }"
  done
  if [[ "${kind}" != "commit" || ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    RULES_ERR="tag ${RULES_TAG} does not resolve to a commit"
    return 0
  fi
  if ! date="$(api "repos/${RULES_REPO}/commits/${sha}" --jq '.commit.committer.date')" \
    || [[ ! "${date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    RULES_ERR="cannot read the date of ${sha:0:7}: $(last_err "malformed date")"
    return 0
  fi
  RULES_AT="${date}"
}
resolve_rules_at

# Prints the commit's standards-check run, or nothing. Returns 1 if unreadable.
run_on_commit() {
  local nwo="$1" sha="$2" body
  if ! body="$(api "repos/${nwo}/commits/${sha}/check-runs?per_page=100")"; then
    return 1
  fi
  if ! jq -e "${runs_sane}" >/dev/null 2>&1 <<<"${body}"; then
    set_err "check-run list for ${sha:0:7} is incomplete or nulled"
    return 1
  fi
  jq -c "${pick_run} // empty" <<<"${body}"
}

# dev-env#211: prints "state<TAB>detail". A withheld or odd field is
# unreadable, never a finding or a clean result.
read -r -d '' prot_verdict <<'JQ'
def std: . == "run-standards-check" or endswith(" / run-standards-check");
if (.protected | type) != "boolean" then "unreadable\tthe branch reports no protected flag"
elif .protected == false then "unprotected\tthe default branch has no protection"
else .protection as $p | $p.required_status_checks as $rsc
  | if ($rsc.contexts | type) != "array"
       or (all($rsc.contexts[]; type == "string") | not)
       or ($p.enabled | type) != "boolean"
       or ($rsc.enforcement_level | type) != "string"
    then "unreadable\tprotected, but the protection settings are not readable"
    elif $p.enabled == false or $rsc.enforcement_level == "off"
    then "protected-no-standards\tprotected, but no required check is enforced"
    elif any($rsc.contexts[]; std) then "required\t"
    elif ($rsc.contexts | length) == 0
    then "protected-no-standards\tprotected, but requires no status checks"
    else "protected-no-standards\trequires only: " + ($rsc.contexts | join(", "))
    end
end
JQ

# Unprotected by decision, so counted, not flagged. Classes, not repo names.
# Each reason carries its decision date; the digest prints it.
declare -A EXEMPT_REASON=(
  [fork]="a fork is not ours to govern (decided 2026-10-21, dev-env#211)"
  [smartwatermelon-private]="a private smartwatermelon repo is unprotected by need (decided 2026-10-12, dev-env#85)"
  [twistedmelonman-private]="a GitHub Free user account cannot protect a private repo (decided 2026-10-21, dev-env#211)"
)
# Not exempt: private nightowlstudiollc repos. NOS keeps Team; protection
# there is required (decided 2026-10-15, dev-env#144).
exempt_class() {
  local nwo="$1" fork="$2" private="$3"
  if [[ "${fork}" == "true" ]]; then
    echo fork
  elif [[ "${private}" == "true" ]]; then
    case "${nwo%%/*}" in
      smartwatermelon) echo smartwatermelon-private ;;
      twistedmelonman) echo twistedmelonman-private ;;
      *) ;;
    esac
  fi
}

PROT_JSON=""
set_prot() {
  # set_prot <state> <detail> [exempt class]
  PROT_JSON="$(jq -cn --arg s "$1" --arg d "$2" --arg c "${3-}" \
    '{state: $s, detail: (if $d == "" then null else $d end),
      exemptClass: (if $c == "" then null else $c end)}' 2>/dev/null)"
  if [[ -z "${PROT_JSON}" ]]; then
    PROT_JSON='{"state":"unreadable","detail":"could not encode the protection result","exemptClass":null}'
  fi
}

# Sets PROT_JSON for one repo. Never fails: a failed read is a state.
probe_protection() {
  local nwo="$1" branch="$2" fork="$3" private="$4" body verdict state detail cls=""
  if ! body="$(api "repos/${nwo}/branches/${branch}")"; then
    detail="$(last_err "no detail")"
    set_prot unreadable "cannot read branch ${branch}: ${detail}"
    return 0
  fi
  verdict="$(jq -r "${prot_verdict}" <<<"${body}" 2>/dev/null)"
  state="${verdict%%$'\t'*}"
  detail="${verdict#*$'\t'}"
  case "${state}" in
    required | protected-no-standards | unreadable) ;;
    unprotected)
      # Exemption needs both flags; guessing would hide a real gap.
      if [[ "${fork}" != "true" ]] \
        && [[ "${fork}" != "false" || ! "${private}" =~ ^(true|false)$ ]]; then
        state=unreadable
        detail="unprotected, but the repository listing gave no fork or private flag, so exemption cannot be decided"
      else
        cls="$(exempt_class "${nwo}" "${fork}" "${private}")"
        if [[ -n "${cls}" ]]; then
          state=exempt
          # A class with no reason must not crash the survey under set -u.
          detail="${EXEMPT_REASON[${cls}]-no reason recorded}"
        fi
      fi
      ;;
    *)
      state=unreadable
      detail="the branch response is malformed"
      ;;
  esac
  set_prot "${state}" "${detail}" "${cls}"
}

# dev-env#166: CodeQL default setup. Exempt classes are counted, not
# flagged. A private repo without paid Code Security is NOT exempt.
declare -A CQ_EXEMPT_REASON=(
  [fork]="a fork is not ours to scan (decided 2026-10-21, dev-env#166)"
  [no-supported-language]="GitHub detects no language default setup can scan (2026-10-19, dev-env#166)"
)
# The 403 body when the paid product is off. Any other 403 is a token gap.
# Matched on the body: stderr can carry noise.
CQ_NO_PRODUCT='^(Code|Advanced) Security must be enabled for this repository to use code scanning\.$'

# Prints "state<TAB>detail". An odd field is unreadable, never a result.
read -r -d '' cq_verdict <<'JQ'
if type != "object" then "unreadable\tthe default-setup response is malformed"
elif .state == "configured" then "configured\t"
elif .state != "not-configured" then "unreadable\tunknown default-setup state: " + (.state | tostring)
elif (.languages | type) != "array" then "unreadable\tnot configured, and no language list was returned"
elif (.languages | length) == 0 then "no-language\t"
else "not-configured\tdefault setup is off; languages: " + (.languages | map(tostring) | join(", "))
end
JQ

CQ_JSON=""
set_cq() {
  # set_cq <state> <detail> [exempt class] [substitute] [substitute detail]
  CQ_JSON="$(jq -cn --arg s "$1" --arg d "$2" --arg c "${3-}" \
    --arg sub "${4-}" --arg subd "${5-}" \
    '{state: $s, detail: (if $d == "" then null else $d end),
      exemptClass: (if $c == "" then null else $c end),
      substitute: (if $sub == "" then null else $sub end),
      substituteDetail: (if $subd == "" then null else $subd end)}' 2>/dev/null)"
  if [[ -z "${CQ_JSON}" ]]; then
    CQ_JSON='{"state":"unreadable","detail":"could not encode the CodeQL result","exemptClass":null,"substitute":null,"substituteDetail":null}'
  fi
}
set_cq_exempt() { set_cq exempt "${CQ_EXEMPT_REASON[$1]-no reason recorded}" "$1"; }

# Code Security is not bought (2026-10-21, dev-env#166). Semgrep CE,
# called from this path, is the substitute.
SG_PATH=".github/workflows/semgrep-scan.yml"
# A job-level or step-level uses: line, so a commented-out one does not count.
SG_USES='(^|\n)[ \t]*(-[ \t]+)?uses:[ \t]*["'"'"']?smartwatermelon/github-workflows/\.github/workflows/semgrep-scan\.yml@'

# Prints "semgrep|none|unreadable<TAB>detail". Only a 404 is none.
read -r -d '' sg_verdict <<'JQ'
if type != "object" then "unreadable\tthe contents response is malformed"
elif .type != "file" then "unreadable\tthe path is not a file: " + (.type | tostring)
elif .encoding != "base64" or (.content | type) != "string"
then "unreadable\tthe file content is not readable (encoding: " + (.encoding | tostring) + ")"
else (try (.content | gsub("\\s"; "") | @base64d) catch null) as $text
  | if ($text | type) != "string" then "unreadable\tthe file content could not be decoded"
    elif ($text | test($uses)) then "semgrep\t"
    else "none\tthe file exists but does not call the reusable semgrep-scan.yml workflow"
    end
end
JQ

probe_semgrep() {
  local nwo="$1" body why verdict
  if ! body="$(api "repos/${nwo}/contents/${SG_PATH}")"; then
    why="$(last_err "no detail")"
    why="${why%"${why##*[![:space:]]}"}"
    # The repo just answered the default-setup read, so 404 means no file.
    # Both signals, as for the paywall 403: status line and body.
    if [[ "${why}" == *"(HTTP 404)"* ]] \
      && jq -e 'type == "object" and .status == "404"' >/dev/null 2>&1 <<<"${body}"; then
      printf 'none\t'
    else
      printf 'unreadable\tcannot read %s: %s' "${SG_PATH}" "${why}"
    fi
    return 0
  fi
  verdict="$(jq -r --arg uses "${SG_USES}" "${sg_verdict}" <<<"${body}" 2>/dev/null)"
  case "${verdict%%$'\t'*}" in
    semgrep | none | unreadable) printf '%s' "${verdict}" ;;
    *) printf 'unreadable\tthe contents response is malformed' ;;
  esac
}

# Sets CQ_JSON for one repo. Never fails: a failed read is a state.
probe_codeql() {
  local nwo="$1" fork="$2" private="$3" body why msg verdict state detail sg
  if ! body="$(api "repos/${nwo}/code-scanning/default-setup")"; then
    why="$(last_err "no detail")"
    msg="$(jq -r 'if type == "object" then .message // "" else "" end' <<<"${body}" 2>/dev/null)"
    # Only the exact product message, on a repo the listing says is
    # private: a public repo has no paywall to explain it.
    if [[ "${why}" == *"(HTTP 403)"* && "${msg}" =~ ${CQ_NO_PRODUCT} \
      && "${private}" == "true" ]]; then
      sg="$(probe_semgrep "${nwo}")"
      [[ "${sg}" == *$'\t'* ]] || sg=$'unreadable\tthe Semgrep probe returned no result'
      set_cq no-code-security "${msg}" "" "${sg%%$'\t'*}" "${sg#*$'\t'}"
    else
      set_cq unreadable "cannot read default setup: ${why}"
    fi
    return 0
  fi
  verdict="$(jq -r "${cq_verdict}" <<<"${body}" 2>/dev/null)"
  state="${verdict%%$'\t'*}"
  detail="${verdict#*$'\t'}"
  case "${state}" in
    configured | unreadable) set_cq "${state}" "${detail}" ;;
    no-language) set_cq_exempt no-supported-language ;;
    not-configured)
      # A fork is exempt; without a fork flag, exemption cannot be decided.
      if [[ "${fork}" == "true" ]]; then
        set_cq_exempt fork
      elif [[ "${fork}" != "false" ]]; then
        set_cq unreadable "not configured, but the repository listing gave no fork flag, so exemption cannot be decided"
      else
        set_cq not-configured "${detail}"
      fi
      ;;
    *) set_cq unreadable "the default-setup response is malformed" ;;
  esac
}

# Dependabot security alerts: 204 is on; 404 with this exact body message is
# off (live capture 2026-10-21). Both need Administration: read.
AL_OFF_MSG='Vulnerability alerts are disabled.'

ALERTS_JSON=""
set_alerts() {
  # set_alerts <state> <detail>
  ALERTS_JSON="$(jq -cn --arg s "$1" --arg d "$2" \
    '{state: $s, detail: (if $d == "" then null else $d end)}' 2>/dev/null)"
  if [[ -z "${ALERTS_JSON}" ]]; then
    ALERTS_JSON='{"state":"unreadable","detail":"could not encode the alerts result"}'
  fi
}

# Sets ALERTS_JSON for one repo; a failed read is a state.
# A bare 404 hides what a token cannot see: never off.
probe_alerts() {
  local nwo="$1" body why
  if ! body="$(api "repos/${nwo}/vulnerability-alerts")"; then
    why="$(last_err "no detail")"
    why="${why%"${why##*[![:space:]]}"}"
    # Both signals, as for Semgrep: the status line and the exact body message.
    if [[ "${why}" == *"(HTTP 404)"* ]] \
      && jq -e --arg m "${AL_OFF_MSG}" 'type == "object" and .status == "404" and .message == $m' \
        >/dev/null 2>&1 <<<"${body}"; then
      set_alerts off "Dependabot security alerts are turned off"
    else
      set_alerts unreadable "cannot read the alerts setting: ${why}"
    fi
    return 0
  fi
  # 204 has no body. Anything else is not the documented answer.
  if [[ -n "${body//[[:space:]]/}" ]]; then
    set_alerts unreadable "the alerts read returned an unexpected body"
  else
    set_alerts on ""
  fi
}

survey_repo() {
  local nwo="$1" branch="$2" head pulls pr pr_head run source ann count url
  if ! head="$(api "repos/${nwo}/commits/${branch}" --jq '.sha')" \
    || [[ ! "${head}" =~ ^[0-9a-f]{40}$ ]]; then
    emit_err "${nwo}" unreadable "cannot read the head of ${branch}" "no sha returned"
    return 0
  fi

  if ! run="$(run_on_commit "${nwo}" "${head}")"; then
    emit_err "${nwo}" unreadable "cannot read check runs on ${branch} head ${head:0:7}" "no detail"
    return 0
  fi
  source="${branch} head ${head:0:7}"

  if [[ -z "${run}" ]]; then
    if ! pulls="$(api "repos/${nwo}/commits/${head}/pulls")" \
      || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${pulls}"; then
      emit_err "${nwo}" unreadable "cannot read the pull request for ${branch} head ${head:0:7}" "non-array body"
      return 0
    fi
    # Only the PR whose merge produced this commit vetted it.
    pr="$(jq -c --arg sha "${head}" '[.[] | select(.merge_commit_sha == $sha and .merged_at != null)] | first // empty' <<<"${pulls}" 2>/dev/null)"
    if [[ -z "${pr}" ]]; then
      emit "${nwo}" no-pr "${branch} head ${head:0:7} has no standards-check run and was not produced by a merged pull request" "${source}"
      return 0
    fi
    pr_head="$(jq -r '.head.sha // empty' <<<"${pr}")"
    source="#$(jq -r '.number' <<<"${pr}"), merged as ${branch} head ${head:0:7}"
    if [[ ! "${pr_head}" =~ ^[0-9a-f]{40}$ ]]; then
      emit "${nwo}" unreadable "pull request for ${head:0:7} has no readable head commit" "${source}"
      return 0
    fi
    if ! run="$(run_on_commit "${nwo}" "${pr_head}")"; then
      emit_err "${nwo}" unreadable "cannot read check runs on PR head ${pr_head:0:7}" "no detail" "${source}"
      return 0
    fi
    if [[ -z "${run}" ]]; then
      emit "${nwo}" no-run "no standards-check run on ${branch} head ${head:0:7} or on the head of the PR that produced it" "${source}"
      return 0
    fi
  fi

  url="$(jq -r '.html_url // ""' <<<"${run}")"
  local status run_id run_at
  run_at="$(jq -r '.completed_at // .started_at // ""' <<<"${run}")"
  status="$(jq -r '.status' <<<"${run}")"
  run_id="$(jq -r '.id' <<<"${run}")"
  if [[ "${status}" != "completed" ]]; then
    emit "${nwo}" in-progress "latest run has not completed, so its annotations are partial" "${source}" "${url}"
    return 0
  fi

  count="$(jq -r '.output.annotations_count // empty' <<<"${run}")"
  if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
    emit "${nwo}" unreadable "run reports no annotation count" "${source}" "${url}"
    return 0
  fi
  if ! ann="$(api --paginate --slurp "repos/${nwo}/check-runs/${run_id}/annotations?per_page=100")"; then
    emit_err "${nwo}" unreadable "cannot read annotations" "no detail" "${source}" "${url}"
    return 0
  fi
  # Fewer annotations than the run reports means some were withheld.
  ann="$(jq -c --argjson want "${count}" '
    (add // []) as $all
    | if all($all[]; (.annotation_level | type == "string") and (.message | type == "string"))
         and ($all | length) >= $want
      then [$all[] | select(.annotation_level == "warning" or .annotation_level == "notice")
            | {level: .annotation_level, path: (.path // ""),
               line: (.start_line // null), message: .message}]
      else "short" end' <<<"${ann}" 2>/dev/null)"
  if [[ -z "${ann}" ]] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${ann}"; then
    emit "${nwo}" unreadable "annotations are incomplete or malformed (run reports ${count})" "${source}" "${url}"
    return 0
  fi
  emit "${nwo}" ok "" "${source}" "${url}" "${ann}" "${run_at}"
}

# The installation list is exactly the set of repos this token can read.
if ! repos="$(api --paginate --slurp "installation/repositories?per_page=100")" \
  || ! repo_list="$(jq -r '
      if type == "array" and all(.[]; (.repositories | type == "array"))
         and ([.[].repositories[]] | length) >= (.[0].total_count // 0)
      then [.[].repositories[]] | sort_by(.full_name)[]
           | [.full_name, (.archived | tostring), (.fork | tostring),
              (.private | tostring), (.default_branch // "")] | @tsv
      else error("bad shape") end' <<<"${repos}" 2>/dev/null)"; then
  emit_err "" unlisted "cannot list the repositories this token can read" "unexpected response shape"
  exit 0
fi
if [[ -z "${repo_list}" ]]; then
  emit "" unlisted "the token can read no repositories, so nothing was checked"
  exit 0
fi

# The branch is last: tab is whitespace to read, so an empty field in the
# middle would shift the ones after it.
while IFS=$'\t' read -r nwo archived fork private branch; do
  [[ -z "${nwo}" ]] && continue
  PROT_JSON=""
  CQ_JSON=""
  ALERTS_JSON=""
  if [[ "${archived}" == "true" ]]; then
    emit "${nwo}" archived "archived; not surveyed"
  elif [[ -z "${branch}" ]]; then
    set_prot unreadable "no default branch reported"
    # Default setup and alerts are per repo, not per branch, so both are read.
    probe_codeql "${nwo}" "${fork}" "${private}"
    probe_alerts "${nwo}"
    emit "${nwo}" unreadable "no default branch reported"
  else
    probe_protection "${nwo}" "${branch}" "${fork}" "${private}"
    probe_codeql "${nwo}" "${fork}" "${private}"
    probe_alerts "${nwo}"
    survey_repo "${nwo}" "${branch}"
  fi
done <<<"${repo_list}"
