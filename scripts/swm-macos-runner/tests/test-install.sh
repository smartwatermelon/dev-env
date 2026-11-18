#!/usr/bin/env bash
# install.sh in a fake HOME with stub id, launchctl, install, rm and sleep: libexec copy, modes, plist, topic check, no /Volumes writes.
set -uo pipefail
unset CDPATH
# The caller's environment must not reach real paths or change the rendered values.
unset NTFY_TOPIC NTFY_BASE TART_HOME SWM_IMAGE SWM_GUEST_DIR SWM_ENV_FILE SWM_STATE_DIR
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

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
WORK="${TMPDIR:-/tmp}/swm-install-test-$$"
mkdir -p "${WORK}/bin"
# WORK is under TMPDIR, never a volume or HOME.
trap 'rm -rf "${WORK:?}"' EXIT

cat >"${WORK}/bin/id" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_UID:-501}"
STUB
cat >"${WORK}/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/launchctl"
if [[ "$1" == bootstrap && -n "${STUB_BOOTSTRAP_FAIL:-}" ]]; then exit 5; fi
# print: loaded for STUB_LOADED_PRINTS calls after bootout (a draining job), then gone (113).
if [[ "$1" == print ]]; then
  n="$(cat "${STUB_LOG}/loaded" 2>/dev/null || echo "${STUB_LOADED_PRINTS:-0}")"
  if [[ "${n}" -gt 0 ]]; then
    echo "$((n - 1))" >"${STUB_LOG}/loaded"
    exit 0
  fi
  exit 113
fi
exit 0
STUB
cat >"${WORK}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/sleep"
STUB
# install stub: logs, refuses a destination outside HOME, then copies (or makes the directory).
cat >"${WORK}/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/install"
mode="" dir=0 args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) mode="$2"; shift 2 ;;
    -d) dir=1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
dst="${args[${#args[@]}-1]}"
if [[ "${dir}" == 1 ]]; then
  for d in "${args[@]}"; do
    case "${d}" in "${HOME}"/*) ;; *) echo "stub install: destination outside HOME: ${d}" >&2; exit 9 ;; esac
    /bin/mkdir -p "${d}" || exit 1
    chmod "${mode:-0755}" "${d}"
  done
  exit 0
fi
case "${dst}" in "${HOME}"/*) ;; *) echo "stub install: destination outside HOME: ${dst}" >&2; exit 9 ;; esac
/bin/cp "${args[0]}" "${dst}" || exit 1
chmod "${mode:-0755}" "${dst}"
STUB
# rm stub: logs, refuses anything outside TMPDIR, then removes.
cat >"${WORK}/bin/rm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}/rm"
for a in "$@"; do
  case "${a}" in -*) ;; "${TMPDIR:-/tmp}"/*) ;; *) echo "stub rm: outside TMPDIR: ${a}" >&2; exit 9 ;; esac
done
exec /bin/rm "$@"
STUB
chmod +x "${WORK}"/bin/*

# run_install [NAME=value ...]: fresh HOME and log dir; sets H, L, OUT, RC. ENV_BODY is the env file text ("" for none).
run_install() {
  n=$((n + 1))
  H="${WORK}/home${n}"
  L="${WORK}/log${n}"
  mkdir -p "${H}/.config/nos-runner" "${L}"
  if [[ -n "${ENV_BODY-NTFY_TOPIC=drill-topic_1.x}" ]]; then
    printf '%s\n' "${ENV_BODY-NTFY_TOPIC=drill-topic_1.x}" >"${H}/.config/nos-runner/env"
  fi
  OUT="$(env HOME="${H}" STUB_LOG="${L}" ID_BIN="${WORK}/bin/id" LAUNCHCTL_BIN="${WORK}/bin/launchctl" \
    INSTALL_BIN="${WORK}/bin/install" RM_BIN="${WORK}/bin/rm" SLEEP_BIN="${WORK}/bin/sleep" "$@" bash "${INSTALL}" 2>&1)"
  RC=$?
}
n=0
LX=".local/libexec/swm-macos-runner"
P="Library/LaunchAgents/com.smartwatermelon.swm-macos-runner.plist"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# image_of DIR: SWM_IMAGE as config.sh in DIR resolves it.
image_of() (
  # shellcheck source=/dev/null
  . "$1/config.sh"
  printf %s "${SWM_IMAGE}"
)
# awk program: exit 0 when v is on the line right after <key>k</key>.
cat >"${WORK}/plist.awk" <<'AWK'
prev && index($0, v) { ok = 1 }
{ prev = index($0, "<key>" k "</key>") > 0 }
END { exit !ok }
AWK
PLIST_AWK="-f${WORK}/plist.awk"
first_line() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

echo "== happy path"
run_install
check "exit 0" test "${RC}" -eq 0
for f in supervisor.sh image/build-image.sh guest/install-runner.sh guest/job-started.sh guest/run-job.sh; do
  check "${f} is 0755" test "$(mode_of "${H}/${LX}/${f}")" = 755
done
for f in config.sh lib.sh github-app.sh; do
  check "${f} is 0644" test "$(mode_of "${H}/${LX}/${f}")" = 644
done
check "plist exists" test -f "${H}/${P}"
check_not "plist has no placeholder left" grep -q '@[A-Z_]*@' "${H}/${P}"
check "plist has the libexec path" grep -q "${H}/${LX}/supervisor.sh" "${H}/${P}"
check "plist has TART_HOME" grep -q '/Volumes/extra-vieille/Caches/tart' "${H}/${P}"
check "plist has the topic" grep -q 'drill-topic_1.x' "${H}/${P}"
check "plist ExitTimeOut is 300" awk -v k=ExitTimeOut -v v='<integer>300</integer>' "${PLIST_AWK}" "${H}/${P}"
check_not "plist ExitTimeOut is not 60 (the check can fail)" awk -v k=ExitTimeOut -v v='<integer>60</integer>' "${PLIST_AWK}" "${H}/${P}"
check "plist RunAtLoad is true" awk -v k=RunAtLoad -v v='<true/>' "${PLIST_AWK}" "${H}/${P}"
check "plist KeepAlive is true" awk -v k=KeepAlive -v v='<true/>' "${PLIST_AWK}" "${H}/${P}"
check "plist logs to ~/Library/Logs/swm-macos-runner.log" grep -q "${H}/Library/Logs/swm-macos-runner.log" "${H}/${P}"
check "plist label" grep -q '<string>com.smartwatermelon.swm-macos-runner</string>' "${H}/${P}"
check "bootstrap names the plist" grep -q "^bootstrap gui/501 ${H}/${P}\$" "${L}/launchctl"
check "bootout comes before bootstrap" test "$(first_line "${L}/launchctl" '^bootout')" -lt "$(first_line "${L}/launchctl" '^bootstrap')"
check_not "no install destination under /Volumes" grep -q ' /Volumes' "${L}/install"
check "guest copied whole" test -f "${H}/${LX}/guest/run-job.sh"
check "config.sh in libexec resolves SWM_IMAGE" test -n "$(image_of "${H}/${LX}")"

echo "== no topic"
ENV_BODY="" run_install
check "no topic still installs" test "${RC}" -eq 0
check "warns about no topic" grep -q 'no NTFY_TOPIC' <<<"${OUT}"
check_not "plist has no stray placeholder" grep -q '@NTFY_ENV@' "${H}/${P}"

echo "== bad topic"
ENV_BODY='NTFY_TOPIC=bad topic/<x>' run_install
check "bad topic refused" test "${RC}" -ne 0
check "message names the characters" grep -q 'A-Za-z0-9_.-' <<<"${OUT}"
check_not "nothing bootstrapped" test -s "${L}/launchctl"
check_not "no plist written" test -e "${H}/${P}"

echo "== bootstrap failure"
run_install STUB_BOOTSTRAP_FAIL=1
check "failed bootstrap exits non-zero" test "${RC}" -ne 0

echo "== draining job"
run_install STUB_LOADED_PRINTS=3
check "waits through the drain" test "$(wc -l <"${L}/sleep")" -ge 3
check "still bootstraps" grep -q '^bootstrap' "${L}/launchctl"

echo "== root refused"
run_install STUB_UID=0
check "root refused" test "${RC}" -ne 0
check_not "root: no libexec" test -e "${H}/${LX}"

exit "${fail}"
