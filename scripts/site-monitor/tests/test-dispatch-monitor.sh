#!/usr/bin/env bash
# dispatch-monitor.sh with a stub curl: the request it sends, and each way it can fail.
set -uo pipefail
unset CDPATH
unset BASH_ENV GH_TOKEN MONITOR_REPO GITHUB_API_URL

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../dispatch-monitor.sh"
WORK="/tmp/site-monitor-dispatch-test-$$"
BIN="${WORK}/bin"
mkdir -p "${BIN}"
trap 'rm -rf "${WORK}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() { echo "  FAIL: $1" >&2; fail=1; }
# check NAME CMD...: pass when CMD succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then _pass "${name}"; else _fail "${name}"; fi
}
# check_not NAME CMD...: pass when CMD fails.
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}
# expect_exit WANT: run the script and compare its exit status.
expect_exit() {
  local rc=0
  run || rc=$?
  if [[ "${rc}" -eq "$1" ]]; then _pass "exit $1"; else _fail "exit ${rc}, want $1"; fi
}

TOKEN='github_pat_stub_9c8b7a'

# curl stub: logs argv and stdin separately, so a test can prove where the token went.
cat >"${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${STUB_STATE}/argv"
cat >"${STUB_STATE}/stdin"
if [[ -f "${STUB_STATE}/curl-fail" ]]; then echo '{"message":"Bad credentials"}'; exit 22; fi
STUB
chmod +x "${BIN}/curl"

run() {
  STUB_STATE="${WORK}/state" PATH="${BIN}:${PATH}" DISPATCH_TOKEN_FILE="${WORK}/token" \
    "${DISPATCH_TEST_BASH:-bash}" "${SCRIPT}" >"${WORK}/out" 2>"${WORK}/err"
}

reset() {
  rm -rf "${WORK}/state" "${WORK}/token"
  mkdir -p "${WORK}/state"
}

echo "-- success sends one POST to the workflow's dispatches endpoint on main"
reset
printf '%s\n' "${TOKEN}" >"${WORK}/token"
expect_exit 0
check "POST" grep -qF -- "-X POST" "${WORK}/state/argv"
check "dispatches URL" grep -qF "/repos/smartwatermelon/dev-env/actions/workflows/site-monitor.yml/dispatches" "${WORK}/state/argv"
check "ref main" grep -qF '{"ref":"main"}' "${WORK}/state/argv"
check "logs success" grep -q 'dispatched site-monitor.yml' "${WORK}/out"
check "UTC timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z dispatch-monitor: ' "${WORK}/out"

echo "-- the token goes in on stdin, never in argv or the logs"
check_not "token not in argv" grep -qF "${TOKEN}" "${WORK}/state/argv"
check "header on stdin" grep -qxF "Authorization: Bearer ${TOKEN}" "${WORK}/state/stdin"
check_not "token not in output" grep -qF "${TOKEN}" "${WORK}/out" "${WORK}/err"

echo "-- a missing token file exits 2 without calling curl"
reset
expect_exit 2
check "curl not called" test ! -f "${WORK}/state/argv"
check "says why" grep -q 'cannot read' "${WORK}/err"

echo "-- an empty token file exits 2"
reset
printf '\n' >"${WORK}/token"
expect_exit 2
check "says why" grep -q 'is empty' "${WORK}/err"

echo "-- an API error exits 1 and logs the response, not the token"
reset
printf '%s\n' "${TOKEN}" >"${WORK}/token"
touch "${WORK}/state/curl-fail"
expect_exit 1
check "logs API message" grep -q 'Bad credentials' "${WORK}/err"
check_not "token not in output" grep -qF "${TOKEN}" "${WORK}/out" "${WORK}/err"

# launchd runs the script under macOS /bin/bash 3.2, so repeat every case there when this host has it.
if [[ -z "${DISPATCH_TEST_BASH:-}" ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -lt 4 ]]' 2>/dev/null; then
  echo "-- every case again under /bin/bash"
  DISPATCH_TEST_BASH=/bin/bash bash "${BASH_SOURCE[0]}" || fail=1
fi

exit "${fail}"
