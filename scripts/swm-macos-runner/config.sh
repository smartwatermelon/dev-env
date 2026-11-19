#!/bin/bash
# Sourced by the supervisor and build-image.sh: defaults; each value can be overridden from the environment.

_swm_conf_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${SWM_BASE_IMAGE:=ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd}"
# Must equal ARG RUNNER_VERSION in scripts/nos-runner/image/Containerfile (test-config.sh checks).
: "${SWM_RUNNER_VERSION:=2.338.2}"
: "${SWM_RUNNER_SHA256:=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388}"
: "${SWM_CPUS:=4}"
: "${SWM_MEMORY_MB:=6144}"
: "${SWM_LABEL:=mimolette-macos}"
: "${SWM_MIN_FREE_GB:=60}"
: "${SWM_STATE_DIR:=${HOME}/.local/state/swm-macos-runner}"
: "${SWM_GUEST_DIR:=${_swm_conf_dir}/guest}"
: "${TART_HOME:=/Volumes/extra-vieille/Caches/tart}"
export TART_HOME

# Per-call limits in seconds for the tart commands.
: "${SWM_CLONE_LIMIT_S:=600}"
: "${SWM_RUN_LIMIT_S:=30}"
: "${SWM_IP_LIMIT_S:=180}"
: "${SWM_EXEC_LIMIT_S:=60}"
: "${SWM_STOP_LIMIT_S:=60}"
: "${SWM_DELETE_LIMIT_S:=120}"
: "${SWM_LIST_LIMIT_S:=60}"
: "${SWM_BUILD_LIMIT_S:=2700}"

# Supervisor waits and pauses, in seconds.
: "${SWM_DF_LIMIT_S:=20}"
: "${SWM_READY_LIMIT_S:=90}"
: "${SWM_READY_STEP_S:=5}"
: "${SWM_V6_LIMIT_S:=150}"
: "${SWM_V6_STEP_S:=5}"
: "${SWM_JOB_MAX_S:=21600}"
: "${SWM_INTERVAL_S:=10}"
: "${SWM_BACKOFF_S:=600}"
# Pass waits for a pending update:
: "${SWM_UPDATE_WAIT_S:=900}"
: "${SWM_UPDATE_POLL_S:=5}"
# While a runner waits for a job with an update pending: how often to try to end it (DELETE refused while busy).
: "${SWM_UPDATE_IDLE_CHECK_S:=300}"

# GitHub: org, runner App (swm-runner), and the pf guard's ok files.
: "${SWM_ORG:=smartwatermelon}"
: "${SWM_APP_ID:=5807971}"
: "${SWM_INSTALLATION_ID:=183107042}"
: "${SWM_PF_OK_FILE:=/var/run/swm-tart-pf.ok}"
: "${SWM_PF_OK_FILE_V6:=/var/run/swm-tart-pf-v6.ok}"
: "${SWM_DISK_PATH:=${TART_HOME}}"

: "${NTFY_BASE:=https://ntfy.sh}"
: "${SHA256SUM_BIN:=sha256sum}"
: "${SHASUM_BIN:=shasum}"

# _swm_sha256 [FILE]: GNU sha256sum when present, else macOS shasum -a 256. Both print "<hex>  <name>".
_swm_sha256() {
  if command -v "${SHA256SUM_BIN}" >/dev/null 2>&1; then "${SHA256SUM_BIN}" "$@"; else "${SHASUM_BIN}" -a 256 "$@"; fi
}

# _swm_image_hash DIR: 12 hex over file digests plus the base digest (as NOS _nos_image_hash).
_swm_image_hash() {
  local files f d list=""
  files="$(cd "$1" && find . -type f)" || return 1
  files="$(LC_ALL=C sort <<<"${files}")" || return 1
  [[ -n "${files}" ]] || return 1
  while IFS= read -r f; do
    d="$(_swm_sha256 "$1/${f}")" || return 1
    list="${list}${d%% *}  ${f}"$'\n'
  done <<<"${files}"
  list="${list}base  ${SWM_BASE_IMAGE}"$'\n'
  d="$(printf '%s' "${list}" | _swm_sha256)" || return 1
  d="${d:0:12}"
  [[ "${d}" =~ ^[0-9a-f]{12}$ ]] || return 1
  printf '%s' "${d}"
}

if [[ -z "${SWM_IMAGE:-}" ]] && _swm_h="$(_swm_image_hash "${SWM_GUEST_DIR}")"; then
  SWM_IMAGE="swm-macos-runner-${SWM_RUNNER_VERSION}-${_swm_h}"
fi
: "${SWM_IMAGE:=}"
