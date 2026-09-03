#!/usr/bin/env bash
# Snapshot the settings of every repo on the move list, one JSON per repo.
# Read-only. Usage: snapshot.sh <move-list> <outdir>
# Design: docs/superpowers/specs/2026-09-03-org-migration-design.md
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/org-migration/lib.sh
source "${HERE}/lib.sh"

if [[ $# -ne 2 ]]; then
  echo "usage: snapshot.sh <move-list> <outdir>" >&2
  exit 2
fi
list="$1"
outdir="$2"
mkdir -p "${outdir}"

# Fetch a sub-resource. A 404 means "not configured" and prints `null`. Any
# other failure — a transient error, an expired token — is a failure, not an
# absence: mapping it to `null` would let verify.sh read it as expected state.
# Non-zero on such a failure, with gh's message on stderr.
_optional() {
  local out err why rc=0
  err="$(mktemp)" || return 1
  # Cleanup on every exit path, including an early return.
  trap 'rm -f "${err}"' RETURN
  out="$(gh api "$1" 2>"${err}")" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    printf '%s\n' "${out}"
  elif grep -q '(HTTP 404)' "${err}"; then
    echo null
    rc=0
  else
    why="$(tr '\n' ' ' <"${err}" || true)"
    printf 'snapshot: %s: %s\n' "$1" "${why}" >&2
  fi
  return "${rc}"
}

pairs="$(om_read_move_list "${list}")" || exit 1
failed=0
while read -r repo _target; do
  base="repos/${OM_LOOKUP_OWNER}/${repo}"
  if ! core="$(gh api "${base}")"; then
    echo "snapshot: FAILED to read ${repo}" >&2
    failed=$((failed + 1))
    continue
  fi
  default_branch="$(jq -r '.default_branch' <<<"${core}")"
  topics="$(gh api "${base}/topics" --jq '.names' 2>/dev/null || echo '[]')"
  secrets="$(gh api "${base}/actions/secrets" --jq '[.secrets[].name] | sort' 2>/dev/null || echo '[]')"
  if ! protection="$(_optional "${base}/branches/${default_branch}/protection")" ||
    ! rulesets="$(_optional "${base}/rulesets")" ||
    ! pages="$(_optional "${base}/pages")"; then
    echo "snapshot: FAILED to read ${repo}" >&2
    failed=$((failed + 1))
    continue
  fi
  jq -n \
    --arg repo "${repo}" \
    --argjson core "${core}" \
    --argjson topics "${topics}" \
    --argjson secrets "${secrets}" \
    --argjson protection "${protection}" \
    --argjson rulesets "${rulesets}" \
    --argjson pages "${pages}" \
    '{repo: $repo,
      owner: {login: $core.owner.login, type: $core.owner.type},
      default_branch: $core.default_branch,
      visibility: $core.visibility,
      archived: $core.archived,
      topics: $topics, pages: $pages, secrets: $secrets,
      protection: $protection, rulesets: $rulesets}' >"${outdir}/${repo}.json"
  echo "snapshot: ${repo} -> ${outdir}/${repo}.json"
done <<<"${pairs}"

if [[ "${failed}" -gt 0 ]]; then
  echo "snapshot: ${failed} repo(s) failed" >&2
  exit 1
fi
