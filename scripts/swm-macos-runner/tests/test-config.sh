#!/usr/bin/env bash
# config.sh: runner version matches the NOS Containerfile, base is digest-pinned, SWM_IMAGE tracks guest/.
set -uo pipefail
unset CDPATH
fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
check_re() {
  if [[ "$2" =~ $3 ]]; then _pass "$1"; else _fail "$1"; fi
}
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH='' cd "${HERE}/.." && pwd)"
CONFIG="${ROOT}/config.sh"
CONTAINERFILE="${ROOT}/../nos-runner/image/Containerfile"
WORK="${TMPDIR:-/tmp}/swm-config-test-$$"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK:?}"' EXIT

# cfg VAR [ENV=VALUE...]: print VAR after sourcing config.sh in a clean subshell.
cfg() {
  local var="$1"
  shift
  (
    unset SWM_IMAGE SWM_GUEST_DIR
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=../config.sh
    . "${CONFIG}"
    printf '%s' "${!var}"
  )
}

nos_version="$(sed -n 's/^ARG RUNNER_VERSION=//p' "${CONTAINERFILE}")"
check "runner version equals the NOS Containerfile" test "$(cfg SWM_RUNNER_VERSION)" = "${nos_version}"
base="$(cfg SWM_BASE_IMAGE)"
check_re "base image is digest-pinned" "${base}" '@sha256:[0-9a-f]{64}$'
check_re "runner sha256 is 64 hex" "$(cfg SWM_RUNNER_SHA256)" '^[0-9a-f]{64}$'
check "defaults: cpus, memory, label, free space" test "$(cfg SWM_CPUS)/$(cfg SWM_MEMORY_MB)/$(cfg SWM_LABEL)/$(cfg SWM_MIN_FREE_GB)" = "4/6144/mimolette-macos/60"
check "limits match the plan" test "$(cfg SWM_CLONE_LIMIT_S)/$(cfg SWM_RUN_LIMIT_S)/$(cfg SWM_IP_LIMIT_S)/$(cfg SWM_EXEC_LIMIT_S)/$(cfg SWM_STOP_LIMIT_S)/$(cfg SWM_DELETE_LIMIT_S)/$(cfg SWM_LIST_LIMIT_S)/$(cfg SWM_BUILD_LIMIT_S)" = "600/30/180/60/60/120/60/2700"
check "supervisor waits match the plan" test "$(cfg SWM_READY_LIMIT_S)/$(cfg SWM_V6_LIMIT_S)/$(cfg SWM_JOB_MAX_S)/$(cfg SWM_BACKOFF_S)" = "90/150/21600/600"
check "swm-runner App and org" test "$(cfg SWM_ORG)/$(cfg SWM_APP_ID)/$(cfg SWM_INSTALLATION_ID)" = "smartwatermelon/5807971/183107042"
check "limit can be overridden" test "$(cfg SWM_CLONE_LIMIT_S SWM_CLONE_LIMIT_S=7)" = "7"
check "TART_HOME is on the external volume" test "$(cfg TART_HOME)" = "/Volumes/extra-vieille/Caches/tart"

img="$(cfg SWM_IMAGE)"
check_re "image name is swm-macos-runner-<version>-<12 hex>" "${img}" '^swm-macos-runner-[0-9.]+-[0-9a-f]{12}$'

mkdir -p "${WORK}/guest"
printf 'one\n' >"${WORK}/guest/a.sh"
printf 'two\n' >"${WORK}/guest/b.sh"
before="$(cfg SWM_IMAGE "SWM_GUEST_DIR=${WORK}/guest")"
again="$(cfg SWM_IMAGE "SWM_GUEST_DIR=${WORK}/guest")"
printf 'changed\n' >"${WORK}/guest/b.sh"
after="$(cfg SWM_IMAGE "SWM_GUEST_DIR=${WORK}/guest")"
check "image name is stable for unchanged guest files" test -n "${before}" -a "${before}" = "${again}"
check "image name changes when a guest file changes" test -n "${after}" -a "${before}" != "${after}"
base_other="$(cfg SWM_IMAGE "SWM_GUEST_DIR=${WORK}/guest" "SWM_BASE_IMAGE=ghcr.io/x/y@sha256:$(printf '0%.0s' {1..64})")"
check "image name changes when the base digest changes" test -n "${base_other}" -a "${after}" != "${base_other}"

exit "${fail}"
