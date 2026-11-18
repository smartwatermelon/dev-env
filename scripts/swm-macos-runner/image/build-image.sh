#!/bin/bash
# Build VM image SWM_IMAGE from the pinned base; exit 0 if it exists.
# Deletes swm-build-tmp; old swm-macos-runner-* only after a good rename.
set -uo pipefail
unset CDPATH
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH='' cd "${HERE}/.." && pwd)"
# shellcheck source=../config.sh
. "${ROOT}/config.sh"
# shellcheck source=../lib.sh
. "${ROOT}/lib.sh"

: "${TART_BIN:=tart}"
: "${RM_BIN:=rm}"
TMP_VM=swm-build-tmp
RUN_PID=""
LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/swm-build-list.XXXXXX")" || exit 1
trap '"${RM_BIN}" -f "${LIST_FILE}"' EXIT

# t LIMIT ARGS...: one bounded tart call.
t() {
  local lim="$1"
  shift
  bounded "${lim}" "${TART_BIN}" "$@"
}
# list_vms: print local VM names, one per line; non-zero when tart fails.
list_vms() {
  SWM_OUT="${LIST_FILE}" t "${SWM_LIST_LIMIT_S}" list --source local --quiet || return 1
  cat "${LIST_FILE}"
}
delete_vm() { t "${SWM_DELETE_LIMIT_S}" delete "$1" || log "could not delete $1"; }
fail() {
  log "image build failed: $1"
  t "${SWM_STOP_LIMIT_S}" stop "${TMP_VM}" || true
  if [[ -n "${RUN_PID}" ]]; then wait "${RUN_PID}" 2>/dev/null || true; RUN_PID=""; fi
  delete_vm "${TMP_VM}"
  exit 1
}

[[ -n "${SWM_IMAGE}" ]] || { log "SWM_IMAGE is empty: cannot hash ${SWM_GUEST_DIR}"; exit 1; }
vms="$(list_vms)" || { log "tart list failed"; exit 1; }
if grep -qx -- "${SWM_IMAGE}" <<<"${vms}"; then
  log "${SWM_IMAGE} already exists"
  exit 0
fi
# A leftover from a crashed build.
if grep -qx -- "${TMP_VM}" <<<"${vms}"; then delete_vm "${TMP_VM}"; fi

log "building ${SWM_IMAGE}"
t "${SWM_CLONE_LIMIT_S}" clone "${SWM_BASE_IMAGE}" "${TMP_VM}" || fail "clone"
t "${SWM_DELETE_LIMIT_S}" set "${TMP_VM}" --cpu "${SWM_CPUS}" --memory "${SWM_MEMORY_MB}" || fail "set"
# run stays up until the VM stops, so it is not bounded; the ip wait proves it started.
"${TART_BIN}" run --no-graphics "${TMP_VM}" </dev/null >/dev/null 2>&1 &
RUN_PID=$!
t "${SWM_IP_LIMIT_S}" ip --wait "${SWM_IP_LIMIT_S}" "${TMP_VM}" || fail "ip"
for f in install-runner.sh run-job.sh job-started.sh; do
  SWM_IN="${SWM_GUEST_DIR}/${f}" t "${SWM_EXEC_LIMIT_S}" exec -i "${TMP_VM}" /bin/sh -c "cat > /tmp/${f}" || fail "copy ${f}"
done
t "${SWM_BUILD_LIMIT_S}" exec "${TMP_VM}" /bin/bash /tmp/install-runner.sh "${SWM_RUNNER_VERSION}" "${SWM_RUNNER_SHA256}" || fail "install"
t "${SWM_STOP_LIMIT_S}" stop "${TMP_VM}" || fail "stop"
wait "${RUN_PID}" 2>/dev/null || true
RUN_PID=""
t "${SWM_DELETE_LIMIT_S}" rename "${TMP_VM}" "${SWM_IMAGE}" || fail "rename"

# Only now are old images safe to remove.
vms="$(list_vms)" || {
  log "tart list failed after build; old images kept"
  exit 0
}
while IFS= read -r v; do
  [[ "${v}" =~ ^swm-macos-runner- && "${v}" != "${SWM_IMAGE}" ]] || continue
  delete_vm "${v}"
done <<<"${vms}"
log "built ${SWM_IMAGE}"
