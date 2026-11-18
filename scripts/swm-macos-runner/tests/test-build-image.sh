#!/usr/bin/env bash
# build-image.sh with stub tart and rm: call order, cleanup on failure, which VMs get deleted, time limits.
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
check_not() {
  local name="$1"
  shift
  if "$@"; then _fail "${name}"; else _pass "${name}"; fi
}

HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(CDPATH='' cd "${HERE}/.." && pwd)"
SCRIPT="${ROOT}/image/build-image.sh"
WORK="${TMPDIR:-/tmp}/swm-build-test-$$"
mkdir -p "${WORK}/bin" "${WORK}/tmp"
trap 'rm -rf "${WORK:?}"' EXIT

IMG=swm-macos-runner-2.338.2-aaaaaaaaaaaa
OLD=swm-macos-runner-2.0.0-bbbbbbbbbbbb

# tart stub: state files in $ST choose behavior; every call is logged to $ST/calls.
cat >"${WORK}/bin/tart" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ST}/calls"
cmd="$1"
shift
case "${cmd}" in
list) cat "${ST}/vms" ;;
clone)
  [[ -f "${ST}/sleep-clone" ]] && exec sleep 30
  [[ -f "${ST}/fail-clone" ]] && exit 1
  echo "$2" >>"${ST}/vms" ;;
run)
  echo "$$" >"${ST}/run-pid"
  [[ -f "${ST}/sleep-run" ]] && exec sleep 30 ;;
stop) [[ -f "${ST}/fail-stop" ]] && exit 1 ;;
exec)
  if [[ "$1" == "-i" ]]; then
    last="${*: -1}"
    cat >"${ST}/copy-${last##*/}"
  else
    [[ -f "${ST}/fail-install" ]] && exit 1
  fi ;;
ip) echo 192.168.64.2 ;;
rename)
  [[ -f "${ST}/fail-rename" ]] && exit 1
  sed "s/^$1\$/$2/" "${ST}/vms" >"${ST}/vms.new" && cp "${ST}/vms.new" "${ST}/vms" ;;
delete)
  grep -vxF -- "$1" "${ST}/vms" >"${ST}/vms.new"
  cp "${ST}/vms.new" "${ST}/vms" ;;
esac
exit 0
STUB
# rm stub: logs; deletes only under the test's own temp dir.
cat >"${WORK}/bin/rm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ST}/rm"
for a in "$@"; do
  case "${a}" in -*) ;; "${TMPDIR}"/*) /bin/rm -f "${a}" ;; *) echo "rm stub: refused ${a}" >&2 ;; esac
done
STUB
# kill stub: logs; signals only the pid the stub tart recorded for its own run.
cat >"${WORK}/bin/kill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ST}/kills"
for a in "$@"; do
  if [[ -f "${ST}/run-pid" && "${a}" == "$(cat "${ST}/run-pid")" ]]; then kill "$@"; fi
done
STUB
chmod +x "${WORK}/bin/tart" "${WORK}/bin/rm" "${WORK}/bin/kill"

# run_build [ENV=VALUE...]: fresh state with two old-style VMs and an unrelated one; sets RC, ST, ERR.
run_build() {
  ST="${WORK}/st"
  rm -rf "${ST:?}"
  mkdir -p "${ST}"
  printf '%s\nother-vm\n' "${OLD}" >"${ST}/vms"
  [[ -z "${PRE_STATE:-}" ]] || for f in ${PRE_STATE}; do : >"${ST}/${f}"; done
  ERR="${ST}/stderr"
  env "ST=${ST}" "TMPDIR=${WORK}/tmp" "TART_BIN=${WORK}/bin/tart" "RM_BIN=${WORK}/bin/rm" "KILL_BIN=${WORK}/bin/kill" "SWM_IMAGE=${IMG}" "$@" bash "${SCRIPT}" 2>"${ERR}"
  RC=$?
}
# order: tart subcommands in call order, minus list/delete/run (run is async, its log line lands late).
order() {
  awk '$1=="list"||$1=="delete"||$1=="run"{next} $1=="exec"{print ($2=="-i")?"copy":"install";next} {print $1}' "${ST}/calls" | tr '\n' ' '
}
deleted() { awk '$1=="delete"{print $2}' "${ST}/calls"; }

echo "-- good build"
PRE_STATE="" run_build
check "exit 0" test "${RC}" -eq 0
check "order is clone, set, ip, 3 copies, install, stop, rename" test "$(order)" = "clone set ip copy copy copy install stop rename "
check "run starts the build VM headless" grep -qx "run --no-graphics swm-build-tmp" "${ST}/calls"
check "run is called after set" test "$(grep -n '^set' "${ST}/calls" | cut -d: -f1)" -lt "$(grep -n '^run' "${ST}/calls" | cut -d: -f1)"
check "clone uses the pinned base" grep -qx "clone ghcr.io/cirruslabs/macos-tahoe-base@sha256:65c3133a633fda8753cf1f71f2d55727792d534a2125b0032466563dcc8e58fd swm-build-tmp" "${ST}/calls"
check "set uses 4 cpus and 6144 MB" grep -qx "set swm-build-tmp --cpu 4 --memory 6144" "${ST}/calls"
check "rename goes to SWM_IMAGE" grep -qx "rename swm-build-tmp ${IMG}" "${ST}/calls"
for f in install-runner.sh run-job.sh job-started.sh; do
  check "guest file ${f} copied intact on stdin" cmp -s "${ROOT}/guest/${f}" "${ST}/copy-${f}"
done
check "install passes version and checksum" grep -qx "exec swm-build-tmp /bin/bash /tmp/install-runner.sh 2.338.2 25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388" "${ST}/calls"
check "only the old image is deleted" test "$(deleted)" = "${OLD}"
check "old image deleted after the rename" test "$(grep -n '^rename' "${ST}/calls" | cut -d: -f1)" -lt "$(grep -n "^delete ${OLD}" "${ST}/calls" | cut -d: -f1)"
check "other-vm is kept" grep -qx other-vm "${ST}/vms"
check "SWM_IMAGE exists" grep -qx "${IMG}" "${ST}/vms"
check_not "swm-build-tmp is gone" grep -qx swm-build-tmp "${ST}/vms"

echo "-- install fails"
PRE_STATE="fail-install" run_build
check "exit 1" test "${RC}" -eq 1
check "swm-build-tmp deleted" test "$(deleted)" = "swm-build-tmp"
check_not "no rename" grep -q "^rename" "${ST}/calls"
check "old image kept" grep -qx "${OLD}" "${ST}/vms"
check "other-vm kept" grep -qx other-vm "${ST}/vms"
check "failure logged" grep -q "image build failed: install" "${ERR}"

echo "-- rename fails"
PRE_STATE="fail-rename" run_build
check "exit 1" test "${RC}" -eq 1
check "old image kept" grep -qx "${OLD}" "${ST}/vms"

echo "-- tart exceeds its limit"
PRE_STATE="sleep-clone" run_build SWM_CLONE_LIMIT_S=1
check "exit 1" test "${RC}" -eq 1
check "timed out logged" grep -q "timed out" "${ERR}"
check "old image kept" grep -qx "${OLD}" "${ST}/vms"
check "other-vm kept" grep -qx other-vm "${ST}/vms"
check "nothing after clone but cleanup" test "$(order)" = "clone stop "

echo "-- stop fails while tart run keeps running"
PRE_STATE="sleep-run fail-stop" run_build SWM_STOP_LIMIT_S=1
check "exit 1" test "${RC}" -eq 1
check "run pid killed through KILL_BIN" grep -qx -- "-9 $(cat "${ST}/run-pid")" "${ST}/kills"
check "kill logged" grep -q "tart run did not exit" "${ERR}"
check "swm-build-tmp deleted" test "$(deleted)" = "swm-build-tmp"
check "old image kept" grep -qx "${OLD}" "${ST}/vms"

echo "-- stop works but tart run keeps running"
PRE_STATE="sleep-run" run_build SWM_STOP_LIMIT_S=1
check "exit 1" test "${RC}" -eq 1
check "run pid killed through KILL_BIN" grep -qx -- "-9 $(cat "${ST}/run-pid")" "${ST}/kills"
check "failure logged" grep -q "image build failed: run did not exit" "${ERR}"
check "no rename, stop retried in cleanup" test "$(order)" = "clone set ip copy copy copy install stop stop "
check "swm-build-tmp deleted" test "$(deleted)" = "swm-build-tmp"
check "old image kept" grep -qx "${OLD}" "${ST}/vms"

echo "-- image already built"
mkdir -p "${WORK}/st2"
ST="${WORK}/st2"
printf '%s\n%s\nother-vm\n' "${IMG}" "${OLD}" >"${ST}/vms"
env "ST=${ST}" "TMPDIR=${WORK}/tmp" "TART_BIN=${WORK}/bin/tart" "RM_BIN=${WORK}/bin/rm" "KILL_BIN=${WORK}/bin/kill" "SWM_IMAGE=${IMG}" bash "${SCRIPT}" 2>/dev/null
RC=$?
check "exit 0 when SWM_IMAGE exists" test "${RC}" -eq 0
check_not "no clone" grep -q "^clone" "${ST}/calls"
check_not "nothing deleted" grep -q "^delete" "${ST}/calls"

exit "${fail}"
