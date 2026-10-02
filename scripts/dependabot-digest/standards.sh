#!/usr/bin/env bash
# Usage: standards.sh <owner>. Prints one JSON record per repo: standards-check
# annotations, or the reason none were read.
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
  # emit <repo> <state> <detail> [source] [run_url] [annotations_json]
  local line
  line="$(jq -cn --arg owner "${owner}" --arg repo "$1" --arg state "$2" \
    --arg detail "$3" --arg source "${4-}" --arg url "${5-}" \
    --argjson ann "${6:-[]}" \
    '{owner: $owner, repo: (if $repo == "" then null else $repo end),
      state: $state, detail: $detail,
      source: (if $source == "" then null else $source end),
      runUrl: (if $url == "" then null else $url end),
      annotations: $ann}' 2>/dev/null)"
  # If jq fails, the repo must still appear.
  if [[ -z "${line}" ]]; then
    printf '{"owner":"%s","repo":"%s","state":"unreadable","detail":"could not encode the result","source":null,"runUrl":null,"annotations":[]}\n' \
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
  local status run_id
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
  emit "${nwo}" ok "" "${source}" "${url}" "${ann}"
}

# The installation list is exactly the set of repos this token can read.
if ! repos="$(api --paginate --slurp "installation/repositories?per_page=100")" \
  || ! repo_list="$(jq -r '
      if type == "array" and all(.[]; (.repositories | type == "array"))
         and ([.[].repositories[]] | length) >= (.[0].total_count // 0)
      then [.[].repositories[]] | sort_by(.full_name)[]
           | [.full_name, (.default_branch // ""), (.archived | tostring)] | @tsv
      else error("bad shape") end' <<<"${repos}" 2>/dev/null)"; then
  emit_err "" unlisted "cannot list the repositories this token can read" "unexpected response shape"
  exit 0
fi
if [[ -z "${repo_list}" ]]; then
  emit "" unlisted "the token can read no repositories, so nothing was checked"
  exit 0
fi

while IFS=$'\t' read -r nwo branch archived; do
  [[ -z "${nwo}" ]] && continue
  if [[ "${archived}" == "true" ]]; then
    emit "${nwo}" archived "archived; not surveyed"
  elif [[ -z "${branch}" ]]; then
    emit "${nwo}" unreadable "no default branch reported"
  else
    survey_repo "${nwo}" "${branch}"
  fi
done <<<"${repo_list}"
