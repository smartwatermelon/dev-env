#!/usr/bin/env bash
# Collect open Dependabot PRs for one owner and classify each into the bucket
# that says what a human must actually do about it.
#
# Usage: collect.sh <owner>
# Reads:  GH_TOKEN (must be able to read PRs for <owner>, including private repos)
# Writes: one JSON object per PR to stdout, newline-delimited.
#
# Exits non-zero, naming the owner, when the owner cannot be read at all. A
# token that has silently lost private-repo access still answers `gh search`
# successfully while returning only public results, so the caller must verify
# visibility separately (see verify_private_visibility below) — "the search
# worked" is not evidence the search was complete.
set -uo pipefail
unset CDPATH

owner="${1-}"
if [[ -z "${owner}" ]]; then
  echo "collect.sh: usage: collect.sh <owner>" >&2
  exit 2
fi

# Every field the classifier reads, in one GraphQL call per PR. isRequired is
# only meaningful here: `gh pr view --json statusCheckRollup` returns
# isRequired: null for every check (measured 2026-09-11), which would make a
# red non-required check indistinguishable from a red required one. That is
# the distinction the whole digest turns on, so it must come from GraphQL.
# Quoted heredoc: the $owner / $repo / $number below are GraphQL variables,
# bound by the -F flags at the call site, and must reach the server unexpanded.
read -r -d '' pr_detail_query <<'GRAPHQL'
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      number title createdAt updatedAt isDraft
      mergeable mergeStateStatus headRefOid reviewDecision
      autoMergeRequest { enabledAt }
      labels(first:20) { nodes { name } }
      commits(last:1) { nodes { commit { statusCheckRollup { contexts(first:100) { nodes {
        ... on CheckRun { name conclusion status isRequired(pullRequestNumber:$number) }
        ... on StatusContext { context state isRequired(pullRequestNumber:$number) }
      } } } } } }
    }
  }
}
GRAPHQL

# A token stripped of private-repo access degrades silently: `gh search prs`
# returns 0 and lists only public PRs. Assert we can see a repo we know is
# private, so an incomplete digest fails loudly instead of reading as "clean".
verify_private_visibility() {
  local probe="$1"
  [[ -z "${probe}" ]] && return 0
  # Probe `commits`, not `repos/<name>`. Repository metadata answers under the
  # Metadata permission alone, so a metadata probe passes for a token that
  # cannot read a single commit — and the survey reads every PR's checks
  # through `pullRequest.commits`. Measured 2026-09-11: this probe passed on
  # nightowlstudiollc while every PR detail read returned FORBIDDEN, which is
  # exactly the silent incompleteness it exists to prevent.
  if ! gh api "repos/${probe}/commits?per_page=1" --jq '.[0].sha' >/dev/null 2>&1; then
    echo "collect.sh: ${owner}: cannot read commits on private probe repo ${probe};" \
      "token lacks the access this survey needs, so results would be silently incomplete" >&2
    return 1
  fi
  return 0
}

probe="${DIGEST_PRIVATE_PROBE-}"
verify_private_visibility "${probe}" || exit 1

search_json="$(gh search prs \
  --author app/dependabot --state open --owner "${owner}" \
  --limit 100 --json repository,number 2>/dev/null)"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  echo "collect.sh: ${owner}: PR search failed (exit ${rc})" >&2
  exit 1
fi
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${search_json}"; then
  echo "collect.sh: ${owner}: PR search returned a non-array body" >&2
  exit 1
fi

# Checks already failing on a repo's default branch. A PR whose only failures
# also fail on main is not broken by its own content — it inherited someone
# else's red. Measured cost of not knowing this: five amelia-boone PRs sat red
# for days behind an unrelated audit gate, and nothing distinguished them from
# genuinely broken ones (dev-env#120).
#
# Queried once per repo and cached, since several PRs usually share a repo.
declare -A BASE_RED_CACHE=()

# Quoted heredocs for the same reason as above: GraphQL variables and jq
# expressions must reach their interpreters unexpanded by the shell.
read -r -d '' base_red_query <<'GRAPHQL'
query($owner:String!, $repo:String!) {
  repository(owner:$owner, name:$repo) {
    defaultBranchRef { target { ... on Commit { statusCheckRollup {
      contexts(first:100) { nodes {
        ... on CheckRun { name conclusion }
        ... on StatusContext { context state }
      } } } } } }
  }
}
GRAPHQL

read -r -d '' base_red_filter <<'JQ'
[.data.repository.defaultBranchRef.target.statusCheckRollup.contexts.nodes[]?
 | select((.conclusion // .state) as $c
     | $c == "FAILURE" or $c == "ERROR" or $c == "TIMED_OUT"
       or $c == "CANCELLED" or $c == "STARTUP_FAILURE")
 | (.name // .context)]
JQ

base_red_for() {
  local nwo="$1" o="${1%%/*}" r="${1#*/}"
  if [[ -n "${BASE_RED_CACHE[${nwo}]-}" ]]; then
    printf '%s' "${BASE_RED_CACHE[${nwo}]}"
    return 0
  fi
  local out
  out="$(gh api graphql -f query="${base_red_query}" \
    -F owner="${o}" -F repo="${r}" 2>/dev/null \
    | jq -c "${base_red_filter}" 2>/dev/null)"
  # An unreadable or malformed answer must not masquerade as "main is green",
  # which would relabel inherited red as the PR's own fault. Emit null so the
  # renderer can say the base state is unknown.
  if [[ -z "${out}" ]] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${out}"; then
    out='null'
  fi
  BASE_RED_CACHE["${nwo}"]="${out}"
  printf '%s' "${out}"
}

# Materialize the PR list before looping. Reading it from a process
# substitution would hide a jq failure: the loop would simply run zero times
# and the owner would report an empty queue, which is indistinguishable from
# having no open PRs and is the precise way this tool could lie.
pr_list="$(jq -r '.[] | [.repository.nameWithOwner, .number] | @tsv' <<<"${search_json}")"
pr_list_rc=$?
if [[ "${pr_list_rc}" -ne 0 ]]; then
  echo "collect.sh: ${owner}: could not parse the PR search result (jq exit ${pr_list_rc})" >&2
  exit 1
fi

while IFS=$'\t' read -r nwo number; do
  [[ -z "${nwo}" ]] && continue
  repo="${nwo#*/}"
  base_red="$(base_red_for "${nwo}")"
  # Keep stderr: GraphQL reports the reason a read failed (a permission the
  # token lacks, a rate limit, a repo it cannot see), and that reason is the
  # only thing that makes this failure diagnosable. Discarding it once cost an
  # hour of guessing at token grants on 2026-09-11.
  detail_err="$(mktemp)"
  # Capture the exit status on its own line: testing $? after a [[ ]] would
  # read the test's status, not gh's.
  detail="$(gh api graphql \
    -f query="${pr_detail_query}" \
    -F owner="${owner}" -F repo="${repo}" -F number="${number}" 2>"${detail_err}")"
  detail_rc=$?
  if [[ "${detail_rc}" -ne 0 ]] \
    || ! jq -e '.data.repository.pullRequest' >/dev/null 2>&1 <<<"${detail}"; then
    echo "collect.sh: ${nwo}#${number}: could not read PR detail (exit ${detail_rc})" >&2
    # GraphQL returns errors in the body with HTTP 200, so both streams matter.
    if [[ -s "${detail_err}" ]]; then
      detail_err_text="$(tr '\n' ' ' <"${detail_err}")"
      echo "collect.sh:   stderr: ${detail_err_text}" >&2
    fi
    # Parenthesize each alternative: `+` binds tighter than `//`, so
    # `.type // "?" + ": " + .message` parses as `.type // ("?: " + .message)`
    # and yields a bare "FORBIDDEN" with the message dropped — exactly the
    # detail this block exists to print. Verified against a sample error body.
    gql_errors="$(jq -r '.errors // [] | map((.type // "?") + " at " + ((.path // []) | map(tostring) | join(".")) + ": " + (.message // "?")) | join("; ")' <<<"${detail}" 2>/dev/null)"
    if [[ -n "${gql_errors}" && "${gql_errors}" != "null" ]]; then
      echo "collect.sh:   graphql: ${gql_errors}" >&2
    fi
    rm -f "${detail_err}"
    exit 1
  fi
  rm -f "${detail_err}"
  jq -c --arg nwo "${nwo}" --argjson base_red "${base_red}" '
    .data.repository.pullRequest as $pr
    | ([$pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
        | {name: (.name // .context),
           conclusion: (.conclusion // .state),
           status: (.status // "COMPLETED"),
           required: (.isRequired == true)}]) as $checks
    | {repo: $nwo, number: $pr.number, title: $pr.title,
       createdAt: $pr.createdAt, updatedAt: $pr.updatedAt,
       isDraft: $pr.isDraft, mergeable: $pr.mergeable,
       mergeStateStatus: $pr.mergeStateStatus, headRefOid: $pr.headRefOid,
       reviewDecision: $pr.reviewDecision,
       autoMerge: ($pr.autoMergeRequest != null),
       labels: [$pr.labels.nodes[]?.name],
       baseRed: $base_red,
       checks: $checks}
  ' <<<"${detail}"
done <<<"${pr_list}"
