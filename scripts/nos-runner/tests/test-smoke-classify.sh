#!/usr/bin/env bash
# smoke-lib.sh classify_block: only curl exit 28 (timeout) counts as "blocked by pf".
set -uo pipefail
unset CDPATH
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../smoke-lib.sh"
classify_block() { bash -c '. "$1" && classify_block "$2" "$3"' _ "${LIB}" "$1" "${2:-}"; }

echo "-- classify_block"
v="$(classify_block 0)"
check "rc 0 -> open (reachable)" test "${v}" = open
v="$(classify_block 28)"
check "rc 28 with no connect time -> error" test "${v}" = error
v="$(classify_block 7)"
check "rc 7 (refused) -> error" test "${v}" = error
v="$(classify_block 6)"
check "rc 6 (no DNS) -> error" test "${v}" = error
v="$(classify_block 125)"
check "rc 125 (container failed) -> error" test "${v}" = error
v="$(classify_block 1)"
check "rc 1 -> error" test "${v}" = error

v="$(classify_block 28 0.000000)"
check "rc 28, connect time 0 -> blocked" test "${v}" = blocked
v="$(classify_block 28 0.004123)"
check "rc 28 after a completed connect -> open (silent service)" test "${v}" = open

exit "${fail}"
