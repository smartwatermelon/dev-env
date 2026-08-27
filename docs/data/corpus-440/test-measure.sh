#!/usr/bin/env bash
# Pins measure.sh's scorer against known-good and known-bad inputs.
#
# This exists because the first draft of the scoring expression returned 0 for
# a finding that was plainly a hit. Every variant would have measured 0%, and
# a genuinely good narrowing would have been rejected on a harness bug. A
# scorer that has not been shown to detect a known-good case cannot be used to
# interpret a clean result.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Load the shipped function, not a copy of it.
_fn_src="$(sed -n '/^score_member() {/,/^}/p' "${HERE}/measure.sh")"
eval "${_fn_src}"

# Read by score_member.
export LINE_TOLERANCE=25

emit() { printf '%s' "$2" >"${TMP}/$1.json"; }

emit hit '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:710"}]}}'
emit exact '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:705"}]}}'
emit edge_lo '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:680"}]}}'
emit edge_hi '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:730"}]}}'
emit just_out '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:679"}]}}'
emit miss '{"structured_output":{"findings":[{"location":"hooks/run-review.sh:1500"}]}}'
emit wrongfile '{"structured_output":{"findings":[{"location":"lib/other.sh:705"}]}}'
emit empty '{"structured_output":{"verdict":"PASS","findings":[]}}'
emit noloc '{"structured_output":{"findings":[{"severity":"BLOCKING"}]}}'
emit garbage 'not json at all'
emit nofield '{}'

pass=0
fail=0
check() {
  local got raw
  raw="$(cat "${TMP}/$1.json")"
  got="$(score_member x hooks/run-review.sh 705 "${raw}")"
  if [[ "${got}" == "$2" ]]; then
    printf 'ok   %-10s = %s\n' "$1" "${got}"
    pass=$((pass + 1))
  else
    printf 'FAIL %-10s = %s (want %s)\n' "$1" "${got}" "$2"
    fail=$((fail + 1))
  fi
}

check hit 1
check exact 1
check edge_lo 1
check edge_hi 1
check just_out 0
check miss 0
check wrongfile 0
check empty 0
check noloc 0
check garbage 0
check nofield 0

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
