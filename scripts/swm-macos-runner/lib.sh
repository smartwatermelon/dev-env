#!/bin/bash
# Sourced helpers: log, notify, bounded, abort_bounded, wait_run. Works under /bin/bash 3.2 (no timeout(1) on macOS).

: "${CURL_BIN:=curl}"
: "${KILL_BIN:=kill}"
: "${NTFY_BASE:=https://ntfy.sh}"
RUN_PID=""
BOUNDED_PID=""

log() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" || ts=unknown-time
  printf '%s swm-macos-runner: %s\n' "${ts}" "$*" >&2
}

# notify MSG: always returns 0; NOTIFY_OK=1 only when ntfy accepted MSG. Callers start MSG "macOS runner:".
notify() {
  NOTIFY_OK=0
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
    NOTIFY_OK=1
    return 0
  fi
  log "ntfy delivery failed"
  return 0
}
notify_ok() { [[ "${NOTIFY_OK:-0}" -eq 1 ]]; }

# bounded SECS CMD...: kill CMD after SECS (status 124).
# stdin is SWM_IN, stdout SWM_OUT (default /dev/null). BOUNDED_PID names CMD while it runs.
# With BOUNDED_CHECK_S=N, the caller's bounded_check runs every N s; when it returns 0, CMD is killed (status 125).
bounded() {
  local secs="$1" pid ticks=0 rc=0 every=0
  shift
  if [[ "${BOUNDED_CHECK_S:-}" =~ ^[1-9][0-9]*$ ]]; then every=$((BOUNDED_CHECK_S * 10)); fi
  "$@" <"${SWM_IN:-/dev/null}" >"${SWM_OUT:-/dev/null}" &
  pid=$!
  BOUNDED_PID="${pid}"
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${every}" -gt 0 && "${ticks}" -gt 0 && $((ticks % every)) -eq 0 ]] && bounded_check; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      BOUNDED_PID=""
      return 125
    fi
    if [[ "${ticks}" -ge $((secs * 10)) ]]; then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      BOUNDED_PID=""
      log "timed out after ${secs} s: ${1##*/} ${2:-}"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}" 2>/dev/null || rc=$?
  BOUNDED_PID=""
  return "${rc}"
}
# abort_bounded: kill the CMD of the bounded call in progress (for a TERM trap); bounded then returns its status.
abort_bounded() {
  [[ -z "${BOUNDED_PID}" ]] || "${KILL_BIN}" -9 "${BOUNDED_PID}"
}

# wait_run: wait up to SWM_STOP_LIMIT_S for the background tart run (RUN_PID) to exit, else kill it; non-zero when killed.
wait_run() {
  local ticks=0
  [[ -n "${RUN_PID}" ]] || return 0
  while kill -0 "${RUN_PID}" 2>/dev/null; do
    if [[ "${ticks}" -ge $((SWM_STOP_LIMIT_S * 10)) ]]; then
      log "tart run did not exit within ${SWM_STOP_LIMIT_S} s; killing it"
      "${KILL_BIN}" -9 "${RUN_PID}"
      wait "${RUN_PID}" 2>/dev/null
      RUN_PID=""
      return 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${RUN_PID}" 2>/dev/null
  RUN_PID=""
  return 0
}
