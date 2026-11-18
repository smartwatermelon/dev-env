#!/bin/bash
# Sourced helpers: log, notify, bounded. Works under /bin/bash 3.2 (no timeout(1) on macOS).

: "${CURL_BIN:=curl}"
: "${NTFY_BASE:=https://ntfy.sh}"

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s swm-macos-runner: %s\n' "${ts}" "$*" >&2
}

# notify MSG: always returns 0. Same ntfy topic as the NOS runner; messages start "macOS runner:".
notify() {
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "warning: NTFY_TOPIC is unset; alert not sent: $1"
    return 0
  fi
  if [[ ! "${NTFY_TOPIC}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    log "warning: NTFY_TOPIC has characters outside A-Za-z0-9_.-; alert not sent: $1"
    return 0
  fi
  # The URL goes to the client on stdin so the topic never shows in ps.
  if printf 'url = "%s/%s"\n' "${NTFY_BASE}" "${NTFY_TOPIC}" | "${CURL_BIN}" -fsS --max-time 20 -K - -d "$1" >/dev/null 2>&1; then
    return 0
  fi
  log "ntfy delivery failed"
  return 0
}

# bounded SECS CMD...: kill CMD after SECS (status 124).
# stdin is SWM_IN, stdout SWM_OUT (default /dev/null).
bounded() {
  local secs="$1" pid ticks=0 rc=0
  shift
  "$@" <"${SWM_IN:-/dev/null}" >"${SWM_OUT:-/dev/null}" &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${ticks}" -ge $((secs * 10)) ]]; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      log "timed out after ${secs} s: ${1##*/} ${2:-}"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}" 2>/dev/null || rc=$?
  return "${rc}"
}
