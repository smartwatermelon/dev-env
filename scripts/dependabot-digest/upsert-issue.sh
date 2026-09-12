#!/usr/bin/env bash
# Keep exactly one digest issue current in a repo, rewriting its body in place.
#
# Usage: upsert-issue.sh <owner/repo> <title> < body.md
# Reads: GH_TOKEN with issues:write on <owner/repo>
#
# The issue is located by the marker in its body, never by its title. The title
# carries the PR count, so matching on it would open a new issue every time the
# count changed and the old ones would rot open alongside it.
set -uo pipefail
unset CDPATH

repo="${1-}"
title="${2-}"
marker='<!-- dependabot-digest:v1 -->'

if [[ -z "${repo}" || -z "${title}" ]]; then
  echo "upsert-issue.sh: usage: upsert-issue.sh <owner/repo> <title> < body.md" >&2
  exit 2
fi

body="$(cat)"
if [[ -z "${body//[[:space:]]/}" ]]; then
  echo "upsert-issue.sh: refusing to write an empty body" >&2
  exit 1
fi
if ! grep -qF "${marker}" <<<"${body}"; then
  echo "upsert-issue.sh: body is missing the ${marker} marker;" \
    "without it the next run cannot find this issue and would open a duplicate" >&2
  exit 1
fi

# Find the existing digest issue. Precision comes from verifying each
# candidate's body below, so this stage only needs recall — and must be built
# to have it, because a miss opens a duplicate.
#
# Two mechanisms, because each one alone has a measured hole:
#
#   1. Body search, on the bare word "dependabot-digest". NOT on the full
#      marker: GitHub's index tokenizes `<!--` and `:v1` away, so searching the
#      literal marker matches nothing at all. Measured 2026-09-11 against a
#      probe issue carrying the exact marker — the full-marker query returned
#      empty while the bare word returned it immediately. Searching the marker
#      would have created a fresh duplicate on every single run.
#   2. A direct listing of recent open issues, which is not search-indexed.
#      Search indexing lags creation by an unbounded amount; two runs in quick
#      succession (exactly what a human does when verifying the workflow) would
#      otherwise duplicate. The listing sees an issue the instant it exists.
#
# The union is the candidate set. Either mechanism failing fails the run.
search_term='dependabot-digest'
existing=""
# Materialize each list first. Reading from a process substitution would turn a
# failed query into "no existing issue found", and this script would then open a
# second digest issue alongside the one it could not see.
searched="$(gh issue list --repo "${repo}" --state open --limit 100 \
  --search "${search_term} in:body" --json number --jq '.[].number' 2>/dev/null)"
search_rc=$?
if [[ "${search_rc}" -ne 0 ]]; then
  echo "upsert-issue.sh: could not search issues in ${repo} (exit ${search_rc});" \
    "refusing to continue, since creating a new issue here would duplicate the existing digest" >&2
  exit 1
fi

listed="$(gh issue list --repo "${repo}" --state open --limit 50 \
  --json number --jq '.[].number' 2>/dev/null)"
list_rc=$?
if [[ "${list_rc}" -ne 0 ]]; then
  echo "upsert-issue.sh: could not list issues in ${repo} (exit ${list_rc});" \
    "refusing to continue, since creating a new issue here would duplicate the existing digest" >&2
  exit 1
fi

candidates="$(printf '%s\n%s\n' "${searched}" "${listed}" | sort -u)"

while read -r number; do
  [[ -z "${number}" ]] && continue
  body_text="$(gh issue view "${number}" --repo "${repo}" --json body --jq '.body' 2>/dev/null)"
  if grep -qF "${marker}" <<<"${body_text}"; then
    existing="${number}"
    break
  fi
done <<<"${candidates}"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
printf '%s\n' "${body}" >"${tmp}"

if [[ -n "${existing}" ]]; then
  if gh issue edit "${existing}" --repo "${repo}" \
    --title "${title}" --body-file "${tmp}" >/dev/null 2>&1; then
    echo "updated ${repo}#${existing}"
  else
    echo "upsert-issue.sh: failed to update ${repo}#${existing}" >&2
    exit 1
  fi
else
  url="$(gh issue create --repo "${repo}" \
    --title "${title}" --body-file "${tmp}" 2>/dev/null)"
  if [[ -z "${url}" ]]; then
    echo "upsert-issue.sh: failed to create the digest issue in ${repo}" >&2
    exit 1
  fi
  echo "created ${url}"
fi
