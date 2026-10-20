#!/usr/bin/env bash
# check-copy-paths.sh against fixture confs: covered, missing, and each input that must fail closed.
set -uo pipefail
unset CDPATH

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../check-copy-paths.sh"
FIX="${HERE}/fixtures/copy-paths"
WORK="/tmp/site-monitor-copy-paths-test-$$"
mkdir -p "${WORK}"
trap 'rm -f "${WORK}"/*; rmdir "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}
# expect_exit WANT ARGS...: run the checker with ARGS and compare its exit status.
expect_exit() {
  local want="$1" rc=0
  shift
  "${CHECK_TEST_BASH:-bash}" "${SCRIPT}" "$@" >"${WORK}/out" 2>"${WORK}/err" || rc=$?
  if [[ "${rc}" -eq "${want}" ]]; then _pass "exit ${want}"; else _fail "exit ${rc}, want ${want}"; fi
}

echo "-- every repo has an include line: exit 0"
expect_exit 0 "${FIX}/covered.conf" "${FIX}/sites.json"
check "says all covered" grep -q 'every repo' "${WORK}/out"

echo "-- a repo with only an exclude, a comment, or a near-miss name: exit 1, named once"
expect_exit 1 "${FIX}/missing.conf" "${FIX}/sites.json"
check "names the missing repo" grep -qF 'owner-b/site-b is in' "${WORK}/err"
named="$(grep -cF 'owner-b/site-b is in' "${WORK}/err")" || named=0
check "named once despite two sites" test "${named}" -eq 1
check_not "covered repo not named" grep -qF 'owner-a/site-a' "${WORK}/err"

echo "-- a conf with no owner/name include lines fails closed: exit 2"
expect_exit 2 "${FIX}/no-entries.conf" "${FIX}/sites.json"
check "says why" grep -q 'no owner/name include lines' "${WORK}/err"

echo "-- an empty conf (a failed download) fails closed: exit 2"
: >"${WORK}/empty.conf"
expect_exit 2 "${WORK}/empty.conf" "${FIX}/sites.json"

echo "-- a missing conf file: exit 2"
expect_exit 2 "${WORK}/absent.conf" "${FIX}/sites.json"
check "says why" grep -q 'cannot read' "${WORK}/err"

echo "-- no conf argument: exit 2"
expect_exit 2

echo "-- a malformed sites.json: exit 2"
printf '{"repo":"owner-a/site-a"}\n' >"${WORK}/bad-sites.json"
expect_exit 2 "${FIX}/covered.conf" "${WORK}/bad-sites.json"

echo "-- an empty sites.json array: exit 2"
printf '[]\n' >"${WORK}/empty-sites.json"
expect_exit 2 "${FIX}/covered.conf" "${WORK}/empty-sites.json"

echo "-- the default sites.json is the real one next to the script"
expect_exit 1 "${FIX}/covered.conf"
check "reads real sites.json" grep -qF 'sites.json but has no include line' "${WORK}/err"

# MIMOLETTE runs this directory under macOS /bin/bash 3.2, so repeat every case there when this host has it.
if [[ -z "${CHECK_TEST_BASH:-}" ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]' 2>/dev/null; then
  echo "-- every case again under /bin/bash"
  CHECK_TEST_BASH=/bin/bash bash "${BASH_SOURCE[0]}" || fail=1
fi

exit "${fail}"
